--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: EnemyManager
-- 種別: ModuleScript
--
-- 敵(★1〜)の実体。NPCManagerの軽量設計(Humanoidを使わない・全パーツAnchored・
-- 共有Heartbeatで補間移動・撃破時のみ物理化するラグドール)を手法としてコピーしている
-- (NPCManager自体は変更しない。呼び出しもしない)。
--
-- 生成・移動・攻撃(テレグラフ→着弾時の再判定)・被弾・撃破・全消去を担当する。
-- どの敵を何体・いつ出すかの判断はThreatManagerが行う(ここは機構のみ)。
--------------------------------------------------------------------

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local EnemyManager = {}
local rng = Random.new()

-- Init()で注入される依存:
-- { addScore(player,points,category), addTime(delta,reason,player)->applied, getRemaining()->number,
--   roadLines(配列 or nil), effectRemote, hudRemote }
local deps = nil

local folder = nil -- workspace.Enemies(初回spawnEnemyで遅延生成)
local enemies = {} -- enemies[model] = enemyState(生存中のみ)
local playerState = {} -- playerState[player] = { invincibleUntil }
local killCounts = {} -- killCounts[player] = number(倒した敵の合計数。種類は問わない)
local aggressive = false -- ThreatManager.Start/Stopで切り替わる(移動・攻撃の可否)
local roundToken = 0 -- Clear()のたびに+1。task.delayコールバックの世代確認に使う
local spawnPoints = {} -- 道路交点の座標リスト(Init時に一度だけ計算)
local systemDisabled = false -- roadLinesがnil/空だった場合にtrue(warn1回・以降no-op)
local savedRoadLines = {} -- 道路中心線の配列(Init時に保存。Movement=="road"の経路計算に使う)
local cityBounds = 0 -- 街の外周座標の絶対値。roadLines[#roadLines]から導出(下記Init参照)
-- 撤退済み部隊の集合(Step5-0)。retiredSquads[squadId]=true。このsquadIdからの新規生成を
-- spawnEnemy/DeploySquadの両方で防ぐ。Clear()でリセットしないと次ラウンドでsquadIdが
-- 再利用されたときに誤って撤退済み扱いになる
local retiredSquads = {}

-- ヘリ輸送(Step5-1)。squadId=>まだ地上にいないが派遣中の数。CountAliveに加算することで
-- 「ヘリ飛行中は生存0体」の誤判定(全滅済みと誤認されて余分な再派遣が起きる)を防ぐ
local pendingDeployments = {}
-- 飛行中のヘリを追跡する。activeTransports[model] = { squadId, cancelled }。
-- RetreatSquad/Clearから中断できるようにするための機構のみで、ヘリ自体はenemiesに入れない
local activeTransports = {}
local transportFolder = nil -- workspace.EnemyTransports(初回ヘリ生成時に遅延生成)

local THINK_INTERVAL = 0.2 -- 標的の再選択・攻撃判定を行う頻度(移動自体は毎フレーム)

--------------------------------------------------------------------
-- 湧き位置の計算(道路中心線の直積 = 交点)
--------------------------------------------------------------------
local function computeSpawnPoints(roadLines)
	local points = {}
	for _, x in roadLines do
		for _, z in roadLines do
			-- Y=3はここでは意味を持たない仮値。実際の接地Yはspawnenemy側で
			-- etype.SpawnY(敵種別ごとの値)により必ず上書きされる(体格が違うため)
			table.insert(points, Vector3.new(x, 3, z))
		end
	end
	return points
end

-- 指定地点から最も近い生存プレイヤーとの水平距離
local function nearestPlayerDist(point)
	local nearest = math.huge
	local flatPoint = Vector3.new(point.X, 0, point.Z)
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			local flatRoot = Vector3.new(root.Position.X, 0, root.Position.Z)
			nearest = math.min(nearest, (flatPoint - flatRoot).Magnitude)
		end
	end
	return nearest
end

-- usedPoints(手順6)のキー生成。spawnPointsは同一のVector3群から来るため文字列化で比較できる
local function pointKey(point)
	return ("%.1f,%.1f"):format(point.X, point.Z)
end

-- 湧き位置を1つ選ぶ: MinDistanceFromPlayer以上離れた点のうち、最も近い3点からランダムに1つ。
-- 候補が0件(プレイヤーが街の隅にいる等)なら最も遠い交点にフォールバックする(湧かない、にはしない)。
-- usedPointsを渡すと、そこに登録済みの点を優先的に除外する(手順6: パトカー同士の交差点重複防止)。
-- 除外した結果候補が0件になった場合はMinDistanceFromPlayerの方は諦めず、除外だけを諦めて選び直す
local function pickSpawnPoint(usedPoints)
	local minDist = Config.Threat.Spawn.MinDistanceFromPlayer
	local scored = {}
	for _, point in spawnPoints do
		table.insert(scored, { point = point, dist = nearestPlayerDist(point) })
	end
	table.sort(scored, function(a, b)
		return a.dist < b.dist
	end)

	local function buildCandidates(respectUsed)
		local list = {}
		for _, entry in scored do
			if entry.dist >= minDist and (not respectUsed or not usedPoints or not usedPoints[pointKey(entry.point)]) then
				table.insert(list, entry)
			end
		end
		return list
	end

	local candidates = buildCandidates(true)
	if #candidates == 0 and usedPoints then
		warn("[EnemyManager] 湧き位置の候補が枯渇。重複を許可して配置します")
		candidates = buildCandidates(false)
	end

	if #candidates == 0 then
		return scored[#scored].point -- 昇順ソート済みなので末尾が最遠
	end

	local topN = math.min(3, #candidates)
	return candidates[rng:NextInteger(1, topN)].point
end

--------------------------------------------------------------------
-- モデル生成
--------------------------------------------------------------------
local function makePart(size, cf, parent, name, color, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true -- 生存中はアンカー(物理コストゼロ)。ラグドール時に外す
	p.CanCollide = false -- 常時false。プレイヤーが引っかかる事故を防ぐ(当たり判定は爆発半径で行う)
	p.CanQuery = true -- 生存中はtrueを維持する(バズーカのレイキャストによる直撃判定に必要)
	p.CastShadow = false
	p.Parent = parent
	return p
end

-- 頭上マーカー(BillboardGui)。NPCManager.createHelpBubbleと同じ方式:
-- 生成時に1個だけ作って隠しておき、以後はEnabledを切り替えるだけにする。
-- anchorPartは人型ならHead、パトカーならCabin等、種別ごとに異なる部位が渡される
local function createMarker(anchorPart)
	local cfg = Config.Threat.Marker
	local gui = Instance.new("BillboardGui")
	gui.Name = "EnemyMarker"
	gui.Size = UDim2.fromOffset(30, 30)
	gui.StudsOffset = Vector3.new(0, 1.6, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = cfg.MaxDistance
	gui.Enabled = cfg.Enabled
	gui.Parent = anchorPart

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = cfg.Text
	label.TextColor3 = cfg.Color
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Parent = gui

	return gui
end

-- 人型の身体パーツを作る。core=Torso(被弾判定・移動の基準)、markerAnchor=Headを返す
local function buildHumanBody(model, rootCf, etype)
	local skin = Config.NPC.SkinColor
	local core = makePart(Vector3.new(1.6, 2, 1), rootCf, model, "Torso", etype.BodyColors.Shirt)
	local markerAnchor = makePart(Vector3.new(1.2, 1.2, 1.2), rootCf * CFrame.new(0, 1.7, 0), model, "Head", skin)
	makePart(Vector3.new(0.6, 2, 0.6), rootCf * CFrame.new(-1.15, 0, 0), model, "LeftArm", skin)
	makePart(Vector3.new(0.6, 2, 0.6), rootCf * CFrame.new(1.15, 0, 0), model, "RightArm", skin)
	makePart(Vector3.new(0.6, 2, 0.6), rootCf * CFrame.new(-0.45, -2, 0), model, "LeftLeg", etype.BodyColors.Pants)
	makePart(Vector3.new(0.6, 2, 0.6), rootCf * CFrame.new(0.45, -2, 0), model, "RightLeg", etype.BodyColors.Pants)
	return core, markerAnchor
end

-- パトカーの車体パーツを作る。core=Chassis(被弾判定・移動の基準)、markerAnchor=Cabinを返す。
-- 進行方向はRoblox標準どおり-Zを正面とする(CFrame.LookVectorはローカル-Z軸を指す仕様のため。
-- 人型と同じCFrame.lookAt(pos, pos+dir)がそのまま使えるよう、AxleFrontを-Z側に置く)。
-- 回転灯の点滅は今回実装しない(任意扱い。常時点灯で十分)
local function buildCarBody(model, rootCf, etype)
	local colors = etype.BodyColors
	local core = makePart(Vector3.new(6, 2.2, 12), rootCf, model, "Chassis", colors.Main)
	local cabin = makePart(Vector3.new(5, 1.8, 5), rootCf * CFrame.new(0, 2.0, 0.5), model, "Cabin", colors.Sub)
	makePart(Vector3.new(1.4, 0.6, 0.8), rootCf * CFrame.new(-0.8, 3.2, 0.5), model, "LightRed",
		Color3.fromRGB(255, 40, 40), Enum.Material.Neon)
	makePart(Vector3.new(1.4, 0.6, 0.8), rootCf * CFrame.new(0.8, 3.2, 0.5), model, "LightBlue",
		Color3.fromRGB(40, 80, 255), Enum.Material.Neon)
	makePart(Vector3.new(6.6, 1.6, 1.6), rootCf * CFrame.new(0, -1.0, -3.8), model, "AxleFront",
		Color3.fromRGB(30, 30, 30))
	makePart(Vector3.new(6.6, 1.6, 1.6), rootCf * CFrame.new(0, -1.0, 3.8), model, "AxleRear",
		Color3.fromRGB(30, 30, 30))
	return core, cabin
end

-- 個体生成の単一入口。警官の生成経路はここだけにする(Step3のパトカー降車、Step5-1のヘリ降下もこれを通す)。
-- squadIdの付け忘れが構造的に起きないようにするため。
-- options(任意。Step5-1で追加): { deploying=true, deployFromY=number, suppressSpawnEffect=true }。
-- 省略時(第4引数なし)は既存呼び出しと完全に同じ挙動を維持する
local function spawnEnemy(typeName, position, squadId, options)
	if systemDisabled then
		return nil
	end
	-- 撤退済み部隊からの新規生成を防ぐ最終防衛線(Step5-0)。DeploySquad/deployFromCarの
	-- どちらの経路から呼ばれても、ここで必ず止まる
	if retiredSquads[squadId] then
		return nil
	end
	local etype = Config.Threat.EnemyTypes[typeName]
	if not etype then
		warn(("[EnemyManager] 未知の敵タイプ '%s' が指定されました。無視します"):format(typeName))
		return nil
	end
	-- Bodyの妥当性はここで確定させる(既知の値以外は個体を作らず1体諦める)。
	-- Step5(ヘリ)・Step6(戦車)でも同じ仕組みで守られるよう、Bodyが増えるたびに
	-- ここへ1行足すだけで済む形にしてある
	if etype.Body ~= "human" and etype.Body ~= "car" then
		warn(("[EnemyManager] 未知のBody '%s' (タイプ '%s') が指定されました。この個体はスキップします")
			:format(tostring(etype.Body), typeName))
		return nil
	end

	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Enemies"
		folder.Parent = workspace
	end

	local model = Instance.new("Model")
	model.Name = etype.DisplayName

	-- 接地Y座標は敵種別ごとに異なる(体格が違うため)データ駆動値。
	-- etype.SpawnYが無ければ呼び出し側が渡したYをそのまま使う
	local y = etype.SpawnY or position.Y
	local rootCf = CFrame.new(position.X, y, position.Z)

	-- core: 本体の代表パーツ(人型ならTorso、パトカーならChassis等)。
	-- markerAnchor: 頭上マーカーの取り付け先(人型ならHead、パトカーならCabin等)
	local core, markerAnchor
	if etype.Body == "car" then
		core, markerAnchor = buildCarBody(model, rootCf, etype)
	else -- "human"(Bodyの妥当性は上でチェック済み)
		core, markerAnchor = buildHumanBody(model, rootCf, etype)
	end
	local marker = createMarker(markerAnchor)

	-- 全パーツをcoreに溶接(ラグドール化のときに一部を壊す)
	for _, part in model:GetChildren() do
		if part ~= core and part:IsA("BasePart") then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = core
			weld.Part1 = part
			weld.Parent = core
		end
	end

	model.PrimaryPart = core
	model:SetAttribute("EnemyType", typeName)
	model:SetAttribute("Dead", false)
	-- SquadId/Retreating(Step5-0)はデバッグとクライアント読み取り用の属性。
	-- サーバー側の部隊判定本体はenemy.squadId(下のenemyテーブル)を使う
	model:SetAttribute("SquadId", squadId)
	model:SetAttribute("Retreating", false)
	model.Parent = folder

	-- 被弾フラッシュ用Highlight(手順7)。Hits>1の敵にのみ作る(1発で死ぬ敵は光る出番が無いため。
	-- 種別名でのベタ書き分岐は禁止なのでetype.Hits>1で判定する)。生成時に作ってEnabledを
	-- 切り替えるだけにする(NPCManager.createHelpBubbleと同じ作法。被弾のたびにInstanceを作らない)
	local hitFlash = nil
	if etype.Hits > 1 then
		hitFlash = Instance.new("Highlight")
		-- 白だとパトカーの車体色(240,240,245)とほぼ同化しコントラストが出ないため、
		-- オレンジ系で塗る(FillColorのみ変更。OutlineColorは白のまま)
		hitFlash.FillColor = Color3.fromRGB(255, 90, 40)
		hitFlash.OutlineColor = Color3.fromRGB(255, 255, 255)
		hitFlash.FillTransparency = 0.4
		hitFlash.Enabled = false
		hitFlash.Adornee = model
		hitFlash.Parent = model
	end

	local enemy = {
		model = model,
		core = core,
		markerAnchor = markerAnchor,
		marker = marker,
		typeName = typeName,
		etype = etype,
		squadId = squadId,
		alive = true,
		hp = etype.Hits,
		hitFlash = hitFlash,
		lastHitAt = 0,
		-- 初期値にばらつきを入れる: 同編成が同時発砲すると無敵時間で無駄弾が出て演出も団子になる
		nextAttack = os.clock() + rng:NextNumber(0, etype.AttackInterval),
		nextThink = 0,
		target = nil,
		spawnY = y, -- etype.SpawnYで上書き済みのY(§修正2)。updateEnemyの接地高さ固定に使う
		-- 降車ロジック(手順5)用。Body/Movementで分岐させず全タイプに持たせる(非対象タイプでは無害に未使用のまま)
		spawnedAt = os.clock(),
		tripsUsed = 0,
		lastDeployAt = nil,
		-- ヘリ降下(Step5-1)用。非対象タイプでは無害にfalseのまま
		deploying = false,
		bursting = false,
	}

	-- ヘリ降下中の個体(Step5-1)。移動・標的選択・攻撃・被弾・頭上「!」をすべて無効化してから登録する
	if options and options.deploying then
		enemy.deploying = true
		local startY = options.deployFromY or y
		model:PivotTo(CFrame.new(position.X, startY, position.Z))
		model:SetAttribute("Deploying", true)
		for _, part in model:GetChildren() do
			if part:IsA("BasePart") then
				part.CanQuery = false
			end
		end
		marker.Enabled = false
	end

	enemies[model] = enemy

	if Config.Threat.DebugLog then
		print(("[EnemyManager] %s が湧きました (squad=%d)"):format(etype.DisplayName, squadId))
	end
	-- ヘリ降下中は着地演出(updateDeployingEnemy)側で1回だけ出す。ここで出すと
	-- 空中降下中なのに地上で湧き煙が先に出てしまうため(Step5-1)
	if not (options and options.suppressSpawnEffect) then
		deps.effectRemote:FireAllClients("enemySpawn", { position = Vector3.new(position.X, y, position.Z) })
	end

	return enemy
end

--------------------------------------------------------------------
-- 移動・攻撃(共有Heartbeatループ)
--------------------------------------------------------------------
local function pickTarget(enemy)
	local best, bestDist = nil, math.huge
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			local d = (root.Position - enemy.core.Position).Magnitude
			if d < bestDist then
				bestDist = d
				best = player
			end
		end
	end
	return best
end

-- fromPos→toPosの直線上に workspace.Map が挟まっていればRaycastResultを返す(無ければnil)。
-- isBlocked(警官の既存LOS判定)とresolveBurstShot(兵士の曳光弾終点)の両方がこれを使う
local function raycastMap(fromPos, toPos)
	local map = workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map }
	return workspace:Raycast(fromPos, toPos - fromPos, params)
end

-- 敵Head→標的HumanoidRootPartの直線上に workspace.Map が挟まっていれば true
local function isBlocked(fromPos, toPos)
	return raycastMap(fromPos, toPos) ~= nil
end

local function damagePlayer(player, penalty, hitPos)
	local state = playerState[player]
	if not state then
		state = { invincibleUntil = 0 }
		playerState[player] = state
	end
	local now = os.clock()
	if state.invincibleUntil > now then
		-- 無敵中: 何もしない。エフェクトも出さない
		-- (無敵中に画面が赤く光ると「効いていないのに効いた」と誤認させるため)
		return
	end
	state.invincibleUntil = now + Config.Threat.Damage.Invincible

	-- appliedの値(損失キャップで0になったか)は見ない。0でも赤フラッシュは出す。
	-- それだけで「守られた」がプレイヤーに伝わる(Hud "notice"は送らない)
	deps.addTime(-penalty, "hit", player)
	deps.hudRemote:FireClient(player, "hit", {}) -- 撃たれた本人だけに赤フラッシュ
	deps.effectRemote:FireAllClients("enemyShotHit", { position = hitPos })
end

-- 着弾判定の中身(テレグラフ0秒の同期経路・テレグラフありのtask.delay経路の両方から呼ぶ。
-- コードを2箇所に複製しない)。判定はすべて「呼ばれた時点の状態」で再評価する
local function resolveAttack(enemy, targetPlayer, toPos, token)
	if roundToken ~= token then
		return -- ラウンドが終わっていたら何もしない
	end
	if not enemy.alive or not aggressive then
		return
	end
	local char = targetPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		deps.effectRemote:FireAllClients("enemyShotMiss", { position = toPos })
		return
	end

	local etype = enemy.etype
	local flatOffset = Vector3.new(
		root.Position.X - enemy.core.Position.X, 0, root.Position.Z - enemy.core.Position.Z)
	local d = flatOffset.Magnitude
	local maxRange = etype.AttackRange * Config.Threat.Damage.RangeGrace
	if d > maxRange then
		deps.effectRemote:FireAllClients("enemyShotMiss", { position = root.Position })
		return
	end
	if Config.Threat.Damage.RequireLineOfSight and isBlocked(enemy.markerAnchor.Position, root.Position) then
		deps.effectRemote:FireAllClients("enemyShotMiss", { position = root.Position })
		return
	end

	damagePlayer(targetPlayer, etype.TimePenalty, root.Position)
end

-- 攻撃シーケンス: 判定タイミング(0秒=発砲と同時、または敵種別のTelegraph秒後)と、
-- 赤い線の表示時間(BeamDuration。見た目だけで判定とは無関係)を分離する
local function fireAttack(enemy, targetPlayer, targetRoot)
	local etype = enemy.etype
	local token = roundToken
	local toPos = targetRoot.Position
	local tg = etype.Telegraph or Config.Threat.Damage.DefaultTelegraph

	deps.effectRemote:FireAllClients("enemyAim", {
		from = enemy.markerAnchor.Position,
		to = toPos,
		duration = Config.Threat.Damage.BeamDuration, -- tgではなくBeamDurationを渡す(見た目専用)
	})

	if tg <= 0 then
		-- 同じフレーム内で同期的に判定する。task.delay(0, ...)は使わない
		-- (1フレーム遅れて「線と同時」に見えなくなるため)。
		-- 同期でもラウンドトークン検査は残す(将来tgを戻したときに片方だけ検査漏れになるのを防ぐ)
		resolveAttack(enemy, targetPlayer, toPos, token)
	else
		task.delay(tg, function()
			resolveAttack(enemy, targetPlayer, toPos, token)
		end)
	end
end

--------------------------------------------------------------------
-- 兵士の5連射(Step5-1)。AttackType=="burst"の敵専用。既存fireAttack/resolveAttack
-- (警官のshoot)には一切触れない
--------------------------------------------------------------------

-- 1発ぶんの判定。テレグラフは持たない(発射=即判定)。命中/はずれいずれも曳光弾(enemyTracer)を
-- 出す。赤いenemyAimは使わない(§19)。戻り値: 命中したか, 命中位置(命中時のみ)
local function resolveBurstShot(enemy, targetPlayer)
	local etype = enemy.etype
	local fromPos = enemy.markerAnchor.Position
	local char = targetPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return false, nil
	end

	local flatOffset = Vector3.new(
		root.Position.X - enemy.core.Position.X, 0, root.Position.Z - enemy.core.Position.Z)
	local d = flatOffset.Magnitude
	local maxRange = etype.AttackRange * Config.Threat.Damage.RangeGrace
	if d > maxRange then
		deps.effectRemote:FireAllClients("enemyTracer", { from = fromPos, to = root.Position })
		return false, nil
	end

	if Config.Threat.Damage.RequireLineOfSight then
		local hitResult = raycastMap(fromPos, root.Position)
		if hitResult then
			-- 遮蔽物で止まった曳光弾の終点はRaycastの着弾点にする(建物を貫通して見えるのを防ぐ。§21)
			deps.effectRemote:FireAllClients("enemyTracer", { from = fromPos, to = hitResult.Position })
			return false, nil
		end
	end

	deps.effectRemote:FireAllClients("enemyTracer", { from = fromPos, to = root.Position })
	return true, root.Position
end

-- バースト全体の制御。5発をBurstInterval間隔で撃ち、命中数をまとめて1回だけタイムに反映する(§22)。
-- enemy.burstingで多重起動を防ぐ(同じ敵が同時に複数バーストを開始しない。§17)
local function fireBurst(enemy, targetPlayer)
	if enemy.bursting then
		return
	end
	enemy.bursting = true
	local etype = enemy.etype
	local token = roundToken

	task.spawn(function()
		local hitCount = 0
		local lastHitPos = nil

		for shot = 1, etype.BurstCount do
			-- 各弾の発射直前に中断条件を確認する(§23): ラウンド終了・撤退中(非aggressive)・
			-- この敵自身の撃破・対象プレイヤーの退出のいずれかで残弾を撃たない
			if roundToken ~= token or not enemy.alive or not aggressive or not targetPlayer.Parent then
				break
			end
			local hit, hitPos = resolveBurstShot(enemy, targetPlayer)
			if hit then
				hitCount += 1
				lastHitPos = hitPos
			end
			if shot < etype.BurstCount then
				task.wait(etype.BurstInterval)
			end
		end

		enemy.bursting = false

		if roundToken ~= token or hitCount <= 0 then
			return
		end
		-- Retreating中に撃破・撤退が挟まった場合は蓄積ダメージを丸ごと破棄する(§23)。
		-- Step5-0の「撤退後は旧部隊からダメージを受けない」を優先するため
		if enemy.model and enemy.model:GetAttribute("Retreating") then
			return
		end
		damagePlayer(targetPlayer, hitCount * etype.TimePenalty, lastHitPos)
	end)
end

-- Movement=="direct"(直進)の敵の移動・攻撃。既存ロジックは無変更(リネームのみ)
local function updateDirectEnemy(enemy, dt)
	local now = os.clock()
	if now >= enemy.nextThink then
		enemy.nextThink = now + THINK_INTERVAL
		enemy.target = pickTarget(enemy)
	end

	local target = enemy.target
	local root = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not (target and root) then
		return -- 標的が居ない: 待機(エラーを出さない)
	end

	local etype = enemy.etype
	local pos = enemy.core.Position
	local offset = root.Position - pos
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local d = flat.Magnitude
	local dir = if d > 0.01 then flat.Unit else enemy.model.PrimaryPart.CFrame.LookVector

	if d > etype.StopDistance then
		local speed = if d > etype.AttackRange then etype.ApproachSpeed else etype.MoveSpeed
		local newPos = pos + dir * speed * dt
		newPos = Vector3.new(newPos.X, enemy.spawnY, newPos.Z) -- Yは湧いた時点の接地高さに固定
		enemy.model:PivotTo(CFrame.lookAt(newPos, newPos + dir))
	else
		enemy.model:PivotTo(CFrame.lookAt(pos, pos + dir)) -- 停止して向きだけ標的に合わせる
	end

	if now >= enemy.nextAttack and d <= etype.AttackRange then
		-- nextAttackはここ(攻撃"開始"時点)で次回分を積む。兵士のバーストも同じ意味を維持する:
		-- AttackInterval=3.0は「バースト開始から次のバースト開始まで」であり、
		-- バースト終了後にさらに3秒待つ実装にはしない(5連射 約0.48秒 + 休止 約2.5秒になる)
		enemy.nextAttack = now + etype.AttackInterval
		if etype.AttackType == "burst" then
			fireBurst(enemy, target)
		else
			fireAttack(enemy, target, root)
		end
	end
end

-- ヘリ降下中(Step5-1)の垂直降下のみを行う。移動・標的選択・攻撃は一切行わない
local function updateDeployingEnemy(enemy, dt)
	local cfg = Config.Threat.HelicopterTransport
	local pos = enemy.core.Position
	local targetY = enemy.spawnY -- 最終接地Y(etype.SpawnY)。updateDirectEnemyと同じ値を使う
	local newY = pos.Y - cfg.DescendSpeed * dt

	if newY <= targetY then
		enemy.model:PivotTo(CFrame.new(pos.X, targetY, pos.Z))
		enemy.deploying = false
		enemy.model:SetAttribute("Deploying", false)
		for _, part in enemy.model:GetChildren() do
			if part:IsA("BasePart") then
				part.CanQuery = true
			end
		end
		if enemy.marker then
			enemy.marker.Enabled = Config.Threat.Marker.Enabled
		end
		-- 着地直後の一斉射撃を防ぐ(§15)
		enemy.nextAttack = os.clock() + cfg.LandingAttackGrace
		-- 着地演出はここで初めて出す(spawnEnemy側では抑制済み。§5の指示)
		deps.effectRemote:FireAllClients("enemySpawn", { position = enemy.core.Position })
	else
		enemy.model:PivotTo(CFrame.new(pos.X, newY, pos.Z))
	end
end

--------------------------------------------------------------------
-- 道路走行(Movement=="road")のヘルパー。§3-1〜§3-5
--------------------------------------------------------------------
-- vに最も近い道路中心線の値を返す
local function nearestLine(v)
	local best, bestDist = savedRoadLines[1], math.huge
	for _, line in savedRoadLines do
		local d = math.abs(line - v)
		if d < bestDist then
			bestDist = d
			best = line
		end
	end
	return best
end

-- 街の範囲(±cityBounds)にクランプする
local function clampToCity(v)
	return math.clamp(v, -cityBounds, cityBounds)
end

-- 目的地(プレイヤー位置を道路中心線へ投影した点)を求める。§3-2(ユーザー決定):
-- 最寄り交差点ではなく、縦道路上・横道路上それぞれへの投影のうち近い方を選ぶ。
-- 戻り値: 目的地の座標, 縦道路上かどうか
local function computeTargetPoint(playerPos, y)
	local px, pz = playerPos.X, playerPos.Z
	local vx, hz = nearestLine(px), nearestLine(pz)
	local cx, cz = clampToCity(px), clampToCity(pz)
	local candidateA = Vector3.new(vx, y, cz) -- 縦道路上
	local candidateB = Vector3.new(cx, y, hz) -- 横道路上
	local distA = (Vector3.new(vx, 0, cz) - Vector3.new(px, 0, pz)).Magnitude
	local distB = (Vector3.new(cx, 0, hz) - Vector3.new(px, 0, pz)).Magnitude
	if distA <= distB then
		return candidateA, true
	end
	return candidateB, false
end

-- マンハッタン経路を構築する(最大3レグ。centerline上の座標のみで、車線オフセットは含まない)。§3-4。
-- 各要素は { point, axis, line }。axisは「その地点に到達後、車がどちらの道路に乗っている
-- ことになるか」を表し、次のretarget時にbuildRouteの起点として使う
local function buildRoute(roadAxis, roadLine, target, targetIsVertical)
	local waypoints = {}
	local targetAxis = if targetIsVertical then "vertical" else "horizontal"
	local targetLine = if targetIsVertical then target.X else target.Z

	if roadAxis == "vertical" then
		local cx = roadLine
		if targetIsVertical then
			local tx = target.X
			if math.abs(cx - tx) < 0.5 then
				table.insert(waypoints, { point = target, axis = targetAxis, line = targetLine })
			else
				local zc = nearestLine(target.Z)
				table.insert(waypoints, { point = Vector3.new(cx, target.Y, zc), axis = "horizontal", line = zc })
				table.insert(waypoints, { point = Vector3.new(tx, target.Y, zc), axis = "vertical", line = tx })
				table.insert(waypoints, { point = target, axis = targetAxis, line = targetLine })
			end
		else
			table.insert(waypoints, { point = Vector3.new(cx, target.Y, target.Z), axis = "horizontal", line = target.Z })
			table.insert(waypoints, { point = target, axis = targetAxis, line = targetLine })
		end
	else -- "horizontal"
		local cz = roadLine
		if not targetIsVertical then
			local tz = target.Z
			if math.abs(cz - tz) < 0.5 then
				table.insert(waypoints, { point = target, axis = targetAxis, line = targetLine })
			else
				local xc = nearestLine(target.X)
				table.insert(waypoints, { point = Vector3.new(xc, target.Y, cz), axis = "vertical", line = xc })
				table.insert(waypoints, { point = Vector3.new(xc, target.Y, tz), axis = "horizontal", line = tz })
				table.insert(waypoints, { point = target, axis = targetAxis, line = targetLine })
			end
		else
			table.insert(waypoints, { point = Vector3.new(target.X, target.Y, cz), axis = "vertical", line = target.X })
			table.insert(waypoints, { point = target, axis = targetAxis, line = targetLine })
		end
	end
	return waypoints
end

-- レグ(legStart→legEndのcenterline)を車線オフセットぶんずらした終点と、そのレグの進行方向を返す。§3-5②。
-- レグごとにオフセット方向が変わるため、レグの継ぎ目にキンクが出るが仕様どおり許容する
local function computeLegDriveTarget(legStart, legEnd, laneOffset)
	local flatStart = Vector3.new(legStart.X, 0, legStart.Z)
	local flatEnd = Vector3.new(legEnd.X, 0, legEnd.Z)
	local legVec = flatEnd - flatStart
	local legDir = if legVec.Magnitude > 0.01 then legVec.Unit else Vector3.new(0, 0, 1)
	local leftVec = Vector3.new(legDir.Z, 0, -legDir.X)
	local laneShift = leftVec * laneOffset
	return flatEnd + laneShift, legDir
end

-- 現在のレグ(enemy.wpIndex)のdriveTarget/legDirを計算し直す
local function startLeg(enemy, legStartPoint)
	local wp = enemy.waypoints[enemy.wpIndex]
	enemy.driveTarget, enemy.legDir = computeLegDriveTarget(legStartPoint, wp.point, enemy.etype.LaneOffset)
end

-- 経路構築後、直前の点(車の現在位置、または前のウェイポイント)からWaypointRadius未満しか
-- 離れていない中間ウェイポイントを取り除く。車は交差点に湧くため経路の1本目がほぼゼロ長になる
-- ケースがあり、そのまま使うと(E-S).Unitが不定になって車線オフセットの点を周回してしまう。
-- 最終ウェイポイント(targetPoint)は距離に関わらず必ず残す(目的地そのものなので)
local function pruneShortLegs(waypoints, startPos, waypointRadius)
	local pruned = {}
	local prevPoint = Vector3.new(startPos.X, 0, startPos.Z)
	for i, wp in waypoints do
		local isLast = (i == #waypoints)
		local flatPoint = Vector3.new(wp.point.X, 0, wp.point.Z)
		local dist = (flatPoint - prevPoint).Magnitude
		if isLast or dist >= waypointRadius then
			table.insert(pruned, wp)
			prevPoint = flatPoint
		end
	end
	return pruned
end

--------------------------------------------------------------------
-- 降車(手順5)。パトカーが警官を降ろす処理。DeployOnArrive=trueの車種のみ意味を持つ
--------------------------------------------------------------------

-- 車の左右のドア横に警官を降ろす。円周ランダムにはしない(車体にめり込むため)。
-- Y座標はここで計算しない: spawnEnemy側がetype.SpawnYで上書きするので車のYをそのまま渡してよい
local function deployFromCar(enemy, isFallback)
	local cfg = enemy.etype
	local cf = enemy.model:GetPivot()
	local right = cf.RightVector
	local look = cf.LookVector

	for i = 1, cfg.DeployCount do
		local side = (i % 2 == 1) and 1 or -1 -- 左右交互
		local lon = (rng:NextNumber() * 2 - 1) * cfg.DeployLongOffset -- 前後にランダム
		local pos = cf.Position + right * (side * cfg.DeploySideOffset) + look * lon
		spawnEnemy(cfg.DeployType, pos, enemy.squadId) -- squadIdを必ず渡す(編成の全滅判定に必須)
	end

	-- 降車演出(手順7)。強制降車でも区別せず同じ演出を出す(§2-1)
	deps.effectRemote:FireAllClients("enemyDeploy", { position = cf.Position })

	enemy.tripsUsed += 1
	enemy.lastDeployAt = os.clock()

	if isFallback then
		-- 保険発動の計測用。最寄りプレイヤーまでの水平距離を添えて出す(実機で「常時発動していないか」確認するため)
		local dist = 0
		local player = pickTarget(enemy)
		local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			local flatCar = Vector3.new(cf.Position.X, 0, cf.Position.Z)
			local flatPlayer = Vector3.new(root.Position.X, 0, root.Position.Z)
			dist = (flatPlayer - flatCar).Magnitude
		end
		print(("[EnemyManager] PoliceCar 強制降車(未到着) trip=%d dist=%.0f"):format(enemy.tripsUsed, dist))
	end
end

-- 到着している間ずっと評価する。到着していなくても、解禁されてからDeployFallbackTime秒
-- 経てば強制的に降ろす(保険。プレイヤーが逃げ続けてarrivedが立たないケースの救済)
local function checkDeploy(enemy)
	if not enemy.alive then
		return
	end
	local cfg = enemy.etype
	if not cfg.DeployOnArrive then
		return
	end
	local canDeploy = (cfg.MaxDeployTrips == nil) or (enemy.tripsUsed < cfg.MaxDeployTrips)
	if not canDeploy then
		return
	end

	local base = if enemy.lastDeployAt then enemy.lastDeployAt + cfg.DeployInterval else enemy.spawnedAt
	local waited = os.clock() - base

	if waited >= 0 and enemy.arrived then
		deployFromCar(enemy, false)
	elseif waited >= cfg.DeployFallbackTime then
		deployFromCar(enemy, true)
	end
end

-- Movement=="road"(道路網走行)の敵の移動。パトカーは攻撃しないため発砲判定は行わない
local function updateRoadEnemy(enemy, dt)
	checkDeploy(enemy) -- 到着判定(enemy.arrived)は1フレーム遅れうるが許容範囲
	local etype = enemy.etype
	local now = os.clock()

	-- 初回呼び出し時の初期化(湧いた地点は交差点なので縦道路にいるものとして扱う。§3-4末尾)
	if not enemy.roadAxis then
		enemy.roadAxis = "vertical"
		enemy.roadLine = nearestLine(enemy.core.Position.X)
		enemy.waypoints = nil
		enemy.wpIndex = 1
		enemy.arrived = false
		enemy.facing = enemy.model.PrimaryPart.CFrame.LookVector
		enemy.nextRetarget = 0 -- 即座に最初の目的地を計算させる
	end

	-- §3-3: 目的地の追尾とヒステリシス。RetargetIntervalごとにのみ再評価する
	if now >= enemy.nextRetarget then
		enemy.nextRetarget = now + etype.RetargetInterval
		local player = pickTarget(enemy)
		local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			local newTarget, newIsVertical = computeTargetPoint(root.Position, enemy.spawnY)
			local flatPlayer = Vector3.new(root.Position.X, 0, root.Position.Z)
			local shouldSwitch = not enemy.targetPoint
			if enemy.targetPoint then
				-- 新しい目的地が現在の目的地よりRetargetThreshold以上プレイヤーに近い場合のみ切り替える
				-- (これが無いと、プレイヤーが道路の継ぎ目付近をうろつくだけで目的地が細かく
				-- 前後して停車位置が定まらない)
				local curDist = (Vector3.new(enemy.targetPoint.X, 0, enemy.targetPoint.Z) - flatPlayer).Magnitude
				local newDist = (Vector3.new(newTarget.X, 0, newTarget.Z) - flatPlayer).Magnitude
				shouldSwitch = (curDist - newDist) >= etype.RetargetThreshold
			end
			if shouldSwitch then
				enemy.targetPoint = newTarget
				enemy.targetIsVertical = newIsVertical
				local route = buildRoute(enemy.roadAxis, enemy.roadLine, newTarget, newIsVertical)
				enemy.waypoints = pruneShortLegs(route, enemy.core.Position, etype.WaypointRadius)
				enemy.wpIndex = 1
				enemy.arrived = false
				startLeg(enemy, enemy.core.Position)

				if Config.Threat.DebugLog then
					local parts = {}
					for _, wp in enemy.waypoints do
						table.insert(parts, ("(%.0f,%.0f)"):format(wp.point.X, wp.point.Z))
					end
					print(("[EnemyManager] route: %s"):format(table.concat(parts, " -> ")))
				end
			end
		end
	end

	if not enemy.waypoints then
		return -- 目的地未確定(生存プレイヤーが居ない等)。待機
	end

	local pos = enemy.core.Position
	local flatPos = Vector3.new(pos.X, 0, pos.Z)
	local isFinalLeg = enemy.wpIndex >= #enemy.waypoints

	if isFinalLeg then
		-- 最終ウェイポイント(=targetPoint)への到着判定は、車線オフセット込みのdriveTargetではなく
		-- 素のtargetPointとの距離で行う(StopDistanceは「目的地にどれだけ近いか」の指標のため)。
		-- こちらは「通り過ぎたか」判定を適用しない(追尾中に通り過ぎたと誤判定させないため)
		local flatTarget = Vector3.new(enemy.targetPoint.X, 0, enemy.targetPoint.Z)
		enemy.arrived = (flatTarget - flatPos).Magnitude <= etype.StopDistance
		if enemy.arrived then
			return -- 到着済み: 停車(検問所のようにその場に留まる。§3-3)
		end
	else
		-- 中間ウェイポイントの到着判定: 距離ではなく「通り過ぎたか」で判定する。
		-- 距離判定(旧実装)だと、旋回中に進む距離(MoveSpeed*TurnDuration)の方が大きい場合、
		-- 永久に「到着」できず交差点を周回してしまうため。
		-- さらに根本原因として、車はセンターラインからLaneOffset分ずれた線を走る一方、
		-- ウェイポイントはレグごとに向きが変わるため毎回異なる方向にLaneOffset分ずれる。
		-- この結果、車の走行線とウェイポイントは常にLaneOffset相当(数stud)離れたままになり、
		-- 距離だけで「到着」を判定する方式では原理的に到達できない(2026-08 実機診断で確定)
		local toE = enemy.driveTarget - flatPos
		local passed = toE:Dot(enemy.legDir) <= 0 -- Eを通り過ぎた
		local close = toE.Magnitude < etype.WaypointRadius
		if passed or close then
			local reached = enemy.waypoints[enemy.wpIndex]
			enemy.roadAxis, enemy.roadLine = reached.axis, reached.line
			enemy.wpIndex += 1
			startLeg(enemy, reached.point)
			return -- このフレームの移動はここまで。次フレームで新しいレグを進む
		end
	end

	local toTarget = enemy.driveTarget - flatPos
	local dist = toTarget.Magnitude
	local dir = if dist > 0.01 then toTarget.Unit else enemy.legDir

	-- 向きの補間(TurnDuration秒ほどかけて現在の向きから目標の向きへ。瞬間的に反転させない。§3-5④)
	local turnRate = 1 / math.max(etype.TurnDuration, 0.01)
	local blended = enemy.facing:Lerp(dir, math.clamp(turnRate * dt, 0, 1))
	if blended.Magnitude > 0.01 then
		enemy.facing = blended.Unit
	end

	local newFlatPos = flatPos + enemy.facing * etype.MoveSpeed * dt
	local newPos = Vector3.new(newFlatPos.X, enemy.spawnY, newFlatPos.Z)
	-- Roblox標準どおり-Zを正面として扱う(人型と同じ式)。§4でAxleFrontを-Z側に置いたため一致する
	enemy.model:PivotTo(CFrame.lookAt(newPos, newPos + enemy.facing))
end

local function updateEnemy(enemy, dt)
	if enemy.deploying then
		updateDeployingEnemy(enemy, dt)
	elseif enemy.etype.Movement == "road" then
		updateRoadEnemy(enemy, dt)
	else
		updateDirectEnemy(enemy, dt)
	end
end

RunService.Heartbeat:Connect(function(dt)
	if not aggressive then
		return
	end
	for model, enemy in enemies do
		if enemy.alive and model.Parent then
			updateEnemy(enemy, dt)
		end
	end
end)

--------------------------------------------------------------------
-- 撃破処理
--------------------------------------------------------------------
local function killEnemy(enemy, ctx)
	enemy.alive = false
	enemy.model:SetAttribute("Dead", true)
	if enemy.marker then
		enemy.marker.Enabled = false
	end

	-- ラグドール化(NPCManager.killNpcの手法をコピー): Weldを2〜3個ランダムに破壊
	local welds = {}
	for _, w in enemy.core:GetChildren() do
		if w:IsA("WeldConstraint") then
			table.insert(welds, w)
		end
	end
	for _ = 1, rng:NextInteger(2, 3) do
		if #welds > 0 then
			local w = table.remove(welds, rng:NextInteger(1, #welds))
			if w then
				w:Destroy()
			end
		end
	end

	for _, part in enemy.model:GetChildren() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = true
			-- 死体はCanQuery=falseにする。trueのままだと6秒間、バズーカのレイキャストを
			-- 死体が遮ってしまい、建物を狙った弾が死体で爆発する事故になる
			part.CanQuery = false
			part.CollisionGroup = "Debris" -- 既存グループを流用(DestructionManager.Initで登録済み)
			pcall(function()
				part:SetNetworkOwner(nil)
			end)
			local offset = part.Position - ctx.position
			local dir = if offset.Magnitude > 0.01 then offset.Unit else Vector3.yAxis
			dir = (dir + Vector3.new(0, 0.6, 0)).Unit
			part:ApplyImpulse(dir * part:GetMass() * 60)
		end
	end

	-- ctx.attacker==nil(将来の戦車のフレンドリーファイア用)ではスコアもタイムも与えない。
	-- 自滅で稼げてはならない
	if ctx.attacker then
		deps.addScore(ctx.attacker, enemy.etype.ScoreReward, "enemy")
		killCounts[ctx.attacker] = (killCounts[ctx.attacker] or 0) + 1 -- リザルトの撃破数集計用

		local reward = enemy.etype.TimeReward
		local dmgCfg = Config.Threat.Damage
		if deps.getRemaining() < dmgCfg.ComebackThreshold then
			reward = reward * dmgCfg.ComebackMultiplier
		end
		deps.addTime(reward, "enemyKill", ctx.attacker)
	end

	deps.effectRemote:FireAllClients("enemyKill", { position = enemy.core.Position })

	if Config.Threat.DebugLog then
		print(("[EnemyManager] %s を撃破 (squad=%d)"):format(enemy.etype.DisplayName, enemy.squadId))
	end

	local model = enemy.model
	local token = roundToken
	task.delay(Config.Threat.CorpseDespawnTime, function()
		if roundToken ~= token then
			return
		end
		if model.Parent then
			model:Destroy()
		end
	end)

	-- 死体はDestructionManagerの瓦礫キューには入れない(自前のタイマーで消す)。
	-- squadIdの生存カウントからも外れる(CountAliveの対象から除外される)
	enemies[model] = nil
end

-- DestructionManager.blastListenersから呼ばれる。敵はworkspace.Mapの外に居るため
-- Explodeのspatial query(GetPartBoundsInRadius)には引っかからない。よって
-- ここで自前に距離判定する(NPCManager.OnExplosionと同じ構造)
function EnemyManager.OnExplosion(ctx)
	local now = os.clock()
	for model, enemy in enemies do
		-- 降下中(Step5-1)は爆風の巻き添えも受けない。CanQuery=falseは直撃レイキャストしか
		-- 防げない(爆風は距離判定のみでCanQueryを見ない)ため、ここでも明示的に除外する
		if enemy.alive and not enemy.deploying then
			-- coreの1点判定のみ(車体半長6 < バズーカ半径12なので、パトカーでも実用上問題ない)
			local dist = (enemy.core.Position - ctx.position).Magnitude
			if dist <= ctx.radius + 2 then -- マージン2はNPCManager.killNpcの既存値に揃える
				if now - enemy.lastHitAt >= enemy.etype.HitCooldown then
					enemy.lastHitAt = now
					enemy.hp -= 1
					if enemy.hp <= 0 then
						killEnemy(enemy, ctx)
					elseif enemy.hitFlash then
						-- ダメージが入り、かつ生き残ったときだけ光らせる(手順7 §3-3)。
						-- HitCooldown中で無効化された被弾はこのifブロックに入らないので出ない
						enemy.hitFlash.Enabled = true
						task.delay(0.12, function()
							if enemy.hitFlash and enemy.hitFlash.Parent then
								enemy.hitFlash.Enabled = false
							end
						end)
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------
-- 公開API
--------------------------------------------------------------------
function EnemyManager.Init(dependencies)
	deps = dependencies
	local roadLines = deps.roadLines
	if not roadLines or #roadLines == 0 then
		warn("[EnemyManager] CityGenerator.GetRoadLines()がnil/空を返しました"
			.. "(従来モード等で湧き位置が算出できません)。敵システムを無効化します")
		systemDisabled = true
		return
	end
	savedRoadLines = roadLines
	-- gridモードでは最外周の道路中心線 = 街の外周座標。roadLinesは昇順配列
	-- (CityGenerator.GetRoadLinesがk=0..Nの順で挿入するため)なので末尾が最大値になる
	cityBounds = roadLines[#roadLines]
	spawnPoints = computeSpawnPoints(roadLines)
end

--------------------------------------------------------------------
-- 軍用ヘリ輸送(Step5-1)。戦闘する敵ではなく兵士投入の演出専用オブジェクト。
-- Config.Threat.EnemyTypesへは登録せず、workspace.EnemyTransports(=transportFolder)に
-- 生成する。これによりCountAlive/画面端▲/頭上「!」/爆風判定/killCounts/スコアの
-- いずれの対象にもならない(それぞれworkspace.Enemies/enemiesテーブルしか見ないため)
--------------------------------------------------------------------
local HELI_OLIVE = Color3.fromRGB(70, 83, 58)
local HELI_DARKGRAY = Color3.fromRGB(50, 52, 55)

local function makeHeliPart(size, cf, parent, name, color, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false -- ヘリは撃破対象ではないため常にfalse(バズーカのレイキャストが素通りする)
	p.CastShadow = false
	p.Parent = parent
	return p
end

-- ブロック状の簡易軍用ヘリ。原点でパーツを組み、最後にcfへPivotToで一括移動する
-- (胴体・コックピット・テールブーム・尾翼・メインローター2本・ローターハブ。静止した十字ローターでよい。§8)
local function buildHelicopterModel(cf)
	if not transportFolder then
		transportFolder = Instance.new("Folder")
		transportFolder.Name = "EnemyTransports"
		transportFolder.Parent = workspace
	end

	local model = Instance.new("Model")
	model.Name = "MilitaryHelicopter"

	local body = makeHeliPart(Vector3.new(6, 5, 16), CFrame.new(0, 0, 0), model, "Body", HELI_OLIVE)
	makeHeliPart(Vector3.new(5, 3.4, 5), CFrame.new(0, 1.2, -6.5), model, "Cockpit", HELI_DARKGRAY, Enum.Material.Glass)
	makeHeliPart(Vector3.new(1.6, 1.6, 12), CFrame.new(0, 0.5, 12), model, "TailBoom", HELI_OLIVE)
	makeHeliPart(Vector3.new(1, 5, 0.6), CFrame.new(0, 2.5, 17.5), model, "TailFin", HELI_DARKGRAY)
	makeHeliPart(Vector3.new(1, 0.6, 1), CFrame.new(0, 3, 0), model, "RotorHub", HELI_DARKGRAY)
	makeHeliPart(Vector3.new(26, 0.2, 1), CFrame.new(0, 3.3, 0), model, "RotorA", HELI_DARKGRAY)
	makeHeliPart(Vector3.new(1, 0.2, 26), CFrame.new(0, 3.3, 0), model, "RotorB", HELI_DARKGRAY)

	model.PrimaryPart = body
	model:PivotTo(cf)
	model.Parent = transportFolder
	return model
end

-- fromPos→toPosへ直線飛行させる(毎フレームPivotTo。TweenServiceはModelのCFrameを
-- 直接扱えないため既存の敵移動と同じ手動補間方式を使う)。
-- transport.cancelled/roundTokenは各yield(Heartbeat:Wait())から戻った直後、
-- モデルに触れる前に必ず確認する(破棄済みモデルへ誤って触れないため)。
-- 戻り値: 最後まで飛行できたか(false=中断)
local function heliFlyTo(model, transport, fromPos, toPos, speed, token)
	local diff = toPos - fromPos
	local dist = diff.Magnitude
	if dist < 0.01 then
		return true
	end
	local dir = diff.Unit
	local pos = fromPos
	model:PivotTo(CFrame.lookAt(pos, pos + dir))

	while true do
		local dt = RunService.Heartbeat:Wait()
		if transport.cancelled or roundToken ~= token or not model.Parent then
			return false
		end
		local remaining = (toPos - pos).Magnitude
		local step = speed * dt
		if step >= remaining then
			pos = toPos
			model:PivotTo(CFrame.lookAt(pos, pos + dir))
			return true
		end
		pos = pos + dir * step
		model:PivotTo(CFrame.lookAt(pos, pos + dir))
	end
end

-- centerからspread以内でランダムにずらした地点を返す(Y座標はcenterのまま。spawnEnemy側で上書きされる)
local function jitterPoint(center, spread)
	local ang = rng:NextNumber(0, math.pi * 2)
	local r = spread * rng:NextNumber(0, 1.0)
	return Vector3.new(center.X + math.cos(ang) * r, center.Y, center.Z + math.sin(ang) * r)
end

-- ヘリ輸送1回ぶんの処理本体。DeploySquadから直接呼ばれる(このsquadListにはヘリ以外の
-- 同時エントリが無い前提だが、将来混在しても後続entryをブロックしない設計にはしていない。
-- 現状の★2編成が単一entryのため許容する)
local function deployByHelicopter(squadId, entry, token)
	if roundToken ~= token or retiredSquads[squadId] then
		return
	end
	local cfg = Config.Threat.HelicopterTransport

	-- yieldする前に同期的にpendingを加算する(§10)。CountAlive誤判定の窓を作らないための要
	pendingDeployments[squadId] = (pendingDeployments[squadId] or 0) + entry.count

	local dropPoint = pickSpawnPoint(nil) -- 既存のMinDistanceFromPlayerルールをそのまま使う(§9-1)
	local axisIsX = rng:NextNumber() < 0.5
	local sign = if rng:NextNumber() < 0.5 then 1 else -1
	local farDist = cityBounds + cfg.EntryMargin
	local entryPos, exitPos
	if axisIsX then
		entryPos = Vector3.new(sign * farDist, cfg.Altitude, dropPoint.Z)
		exitPos = Vector3.new(-sign * farDist, cfg.Altitude, dropPoint.Z)
	else
		entryPos = Vector3.new(dropPoint.X, cfg.Altitude, sign * farDist)
		exitPos = Vector3.new(dropPoint.X, cfg.Altitude, -sign * farDist)
	end
	local dropAtAltitude = Vector3.new(dropPoint.X, cfg.Altitude, dropPoint.Z)

	local model = buildHelicopterModel(CFrame.lookAt(entryPos, dropAtAltitude))
	local transport = { squadId = squadId, cancelled = false }
	activeTransports[model] = transport

	local function cleanup()
		activeTransports[model] = nil
		if model.Parent then
			model:Destroy()
		end
	end

	-- 街外Entry → 投下地点
	if not heliFlyTo(model, transport, entryPos, dropAtAltitude, cfg.CruiseSpeed, token) then
		cleanup()
		return
	end

	-- 兵士を1人ずつ降下させる(DropInterval間隔)
	for i = 1, entry.count do
		if transport.cancelled or roundToken ~= token or retiredSquads[squadId] then
			cleanup()
			return
		end
		local landPos = jitterPoint(dropPoint, cfg.LandingSpread)
		local enemy = spawnEnemy("Soldier", landPos, squadId, {
			deploying = true,
			deployFromY = cfg.Altitude - cfg.DropOffsetY,
			suppressSpawnEffect = true,
		})
		if not enemy then
			-- systemDisabled等でspawnEnemyが失敗した場合でも、この個体ぶんのpendingは
			-- 必ず消費する(残留するとCountAliveが永久に0にならず再派遣が起きなくなる)
			warn(("[EnemyManager] ヘリ降下でSoldierの生成に失敗しました (squad=%d)"):format(squadId))
		end
		if pendingDeployments[squadId] then
			pendingDeployments[squadId] -= 1
			if pendingDeployments[squadId] <= 0 then
				pendingDeployments[squadId] = nil
			end
		end
		if i < entry.count then
			task.wait(cfg.DropInterval)
		end
	end

	if transport.cancelled or roundToken ~= token then
		cleanup()
		return
	end

	-- 投下地点 → 反対側Exit
	heliFlyTo(model, transport, dropAtAltitude, exitPos, cfg.ExitSpeed, token)
	cleanup()
end

-- squadList = Stage.Squad の配列({ {type=..., count=..., transport=...}, ... })。
-- transportが無ければ従来どおりの直接生成、"helicopter"ならヘリ輸送、それ以外の文字列は
-- warnして無視する(通常スポーンへの黙示フォールバックはしない。§27)
function EnemyManager.DeploySquad(squadId, squadList)
	if systemDisabled then
		return
	end
	local token = roundToken
	task.spawn(function()
		-- 撤退済みチェック(Step5-0)。開始直後に1回。retiredSquads[squadId]は通常
		-- ここではまだ立っていない(新規squadIdなので)が、多重防御として置く
		if roundToken ~= token or retiredSquads[squadId] then
			return
		end
		-- この1回の派遣に閉じた使用済み座標の集合(手順6)。road個体だけが書き込む
		local usedPoints = {}
		for _, entry in squadList do
			if entry.transport == "helicopter" then
				deployByHelicopter(squadId, entry, token)
			elseif entry.transport ~= nil then
				warn(("[EnemyManager] 未知の輸送方式 '%s' (タイプ '%s') のentryを無視します")
					:format(tostring(entry.transport), entry.type))
			else
				local etype = Config.Threat.EnemyTypes[entry.type]
				local isRoad = etype ~= nil and etype.Movement == "road"
				for _ = 1, entry.count do
					-- 各個体を生成する直前の撤退済みチェック(Step5-0)。派遣途中で昇格すると
					-- ここで止まり、旧squadIdの残り個体を生成しなくなる
					if roundToken ~= token or retiredSquads[squadId] then
						return
					end
					local point = pickSpawnPoint(usedPoints)
					if isRoad then
						-- パトカー(将来の戦車も)は交差点そのものを使う。ジッターをかけると
						-- 湧いた瞬間どちらの道路線にも乗っていない状態になり横滑りするため(§4-4)
						usedPoints[pointKey(point)] = true
					else
						-- 警官は交差点中心からジッターで散らす。同じ交差点の共有は許容する(§4-1)
						local jitter = Config.Threat.Spawn.Jitter
						local ang = rng:NextNumber(0, math.pi * 2)
						local r = jitter * rng:NextNumber(0.5, 1.0)
						point = Vector3.new(point.X + math.cos(ang) * r, point.Y, point.Z + math.sin(ang) * r)
					end
					spawnEnemy(entry.type, point, squadId)
					task.wait(Config.Threat.Spawn.Interval)
					-- task.waitから戻った直後の撤退済みチェック(Step5-0)。待機中に昇格した場合に備える
					if roundToken ~= token or retiredSquads[squadId] then
						return
					end
				end
			end
		end
	end)
end

--------------------------------------------------------------------
-- 撤退処理(Step5-0)。危険度昇格時に前段階の部隊をその場で行動停止させ、フェードアウトさせる。
-- 撤退は撃破ではない: killEnemy()は呼ばない。スコア・タイム・撃破数・撃破演出・死体は発生させない
--------------------------------------------------------------------
function EnemyManager.RetreatSquad(squadId)
	if not squadId then
		return 0
	end
	retiredSquads[squadId] = true -- 以降このsquadIdからの新規生成をspawnEnemy/DeploySquadで防ぐ
	pendingDeployments[squadId] = nil -- ヘリ飛行中の残り降下人数を破棄(Step5-1)

	-- 飛行中のヘリ輸送を中断する(Step5-1)。将来★3実装後、非同期の事故防止として置く
	-- (現状★2は通常プレイで発生しうる唯一のケース)。ヘリは即Destroyしてよい(§12)
	for model, transport in activeTransports do
		if transport.squadId == squadId and not transport.cancelled then
			transport.cancelled = true
			activeTransports[model] = nil
			if model.Parent then
				model:Destroy()
			end
		end
	end

	-- enemiesを反復しながら削除しない(取りこぼし防止)。対象を先に配列へ集めてから処理する
	local toRetreat = {}
	for model, enemy in enemies do
		if enemy.squadId == squadId and enemy.alive then
			table.insert(toRetreat, { model = model, enemy = enemy })
		end
	end

	for _, entry in toRetreat do
		local model, enemy = entry.model, entry.enemy

		-- alive=falseはフェード開始前に設定する。これにより既に予約済みのテレグラフ攻撃も
		-- resolveAttack()の既存enemy.aliveチェックで無効になる(§8-1)
		enemy.alive = false
		model:SetAttribute("Retreating", true)
		model:SetAttribute("Dead", true) -- 画面端▲インジケータは既存のDead判定で自動的に除外される
		if enemy.marker then
			enemy.marker.Enabled = false -- 頭上「!」を即座に消す
		end
		if enemy.hitFlash then
			enemy.hitFlash.Enabled = false
		end

		for _, part in model:GetChildren() do
			if part:IsA("BasePart") then
				part.CanQuery = false -- バズーカのレイキャストをすり抜けさせる
				part.CanCollide = false
				TweenService:Create(part,
					TweenInfo.new(Config.Threat.Retreat.FadeTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
					{ Transparency = 1 }):Play()
			end
		end

		enemies[model] = nil -- 以降Heartbeatループ(updateEnemy)の対象外になる

		-- Destroy予約は1モデルにつき1本だけ(パーツごとにCompleted:Connect()しない)。
		-- ラウンド終了でClear()がfolderごと先に破棄している場合があるため、
		-- 消滅済みモデルへ二重にDestroy()しないようmodel.Parentを確認する(§8-6)
		task.delay(Config.Threat.Retreat.FadeTime, function()
			if model.Parent then
				model:Destroy()
			end
		end)
	end

	if Config.Threat.DebugLog then
		print(("[EnemyManager] squad=%d 撤退開始 (対象=%d体)"):format(squadId, #toRetreat))
	end

	return #toRetreat
end

-- pending(ヘリ飛行中でまだ地上にいない兵士)も加算する(Step5-1)。
-- これが無いと「ヘリ飛行中は生存0体」を全滅と誤認し、余分な再派遣が予約されてしまう
function EnemyManager.CountAlive(squadId)
	local count = pendingDeployments[squadId] or 0
	for _, enemy in enemies do
		if enemy.squadId == squadId and enemy.alive then
			count += 1
		end
	end
	return count
end

-- リザルト用: 倒した敵の合計数(種類は問わない)。プレイヤーごとの生データをそのまま返さず
-- シャローコピーを返す(呼び出し側での意図しない書き換えを避けるため。他のgetterと同じ流儀)
function EnemyManager.GetKillCounts()
	local copy = {}
	for player, count in killCounts do
		copy[player] = count
	end
	return copy
end

-- false: 新規の発砲を止め、移動も止める(モデルは消さない。見た目の継続性のため)
function EnemyManager.SetAggressive(enabled)
	aggressive = enabled
end

function EnemyManager.Clear()
	roundToken += 1
	aggressive = false
	for model in enemies do
		model:Destroy()
	end
	table.clear(enemies)
	table.clear(playerState)
	table.clear(killCounts) -- RESULTでGetKillCounts()を読み終えた後のLOBBYで呼ばれるので、順序は問題ない
	table.clear(retiredSquads) -- 次ラウンドでsquadIdが1から再利用されるため必須(Step5-0)
	table.clear(pendingDeployments) -- 次ラウンドへ持ち越さない(Step5-1)
	for model in activeTransports do
		if model.Parent then
			model:Destroy()
		end
	end
	table.clear(activeTransports)
	if folder then
		folder:Destroy()
		folder = nil
	end
	if transportFolder then
		transportFolder:Destroy()
		transportFolder = nil
	end
end

Players.PlayerRemoving:Connect(function(player)
	playerState[player] = nil
	killCounts[player] = nil
end)

return EnemyManager
