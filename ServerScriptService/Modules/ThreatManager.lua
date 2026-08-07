--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: ThreatManager
-- 種別: ModuleScript
--
-- 段階(★)の政策。累計スコアを監視して閾値を跨いだら昇格し、
-- Config.Threat.Stages の編成をEnemyManagerへ指示する。
-- 敵1体1体の挙動には一切関与しない(EnemyManagerの仕事)。
--------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))

local ThreatManager = {}

-- Init()で注入される依存: { getScore()->number, enemies(EnemyManager), hudRemote, effectRemote }
local deps = nil

local running = false
local stage = 0
local squadSeq = 0
local currentSquadId = nil
local waitingRespawn = false
-- 定期増援(全滅を待たない再派遣)の次回派遣時刻。ReinforcementIntervalを持つ段階でのみ使う値で、
-- 持たない段階(★1)ではnil。promote()で段階が変わるたびに必ず上書きされるため、
-- ★3以降へ昇格した瞬間に★2用の値は自動的に無効化される
local nextReinforcementAt = nil
local roundToken = 0 -- Clear()のたびに+1。task.delay(RespawnDelay待機)の世代確認に使う
-- 再派遣予約(RespawnDelay待機)だけを無効化する世代トークン(Step5-0)。roundTokenと役割が違う:
-- roundTokenはラウンドをまたぐ非同期処理を無効化し、respawnTokenは同じラウンド内で
-- 段階昇格が起きたときに、昇格前に予約された再派遣を無効化する
local respawnToken = 0
local roundStartClock = 0 -- 到達秒数のログ用

function ThreatManager.Init(dependencies)
	deps = dependencies
end

-- 保留中の再派遣予約を無効化する(Step5-0)。段階昇格時・Start/Stop/Clearで呼ぶ。
-- ここでwaitingRespawnをfalseに戻すのはこの関数のみ: 古い再派遣コールバック自身は
-- 自分がキャンセルされたときにwaitingRespawnを書き戻さない(新しい状態を上書きしないため)
local function cancelPendingRespawn()
	respawnToken += 1
	waitingRespawn = false
end

--------------------------------------------------------------------
-- 昇格
--------------------------------------------------------------------
local function promote(n)
	local previousSquadId = currentSquadId -- 上書き前に保存(Step5-0: 撤退させる対象)
	cancelPendingRespawn() -- 旧段階の再派遣予約(あれば)を無効化

	local def = Config.Threat.Stages[n]
	stage = n
	squadSeq += 1
	currentSquadId = squadSeq

	deps.hudRemote:FireAllClients("threat", {
		stage = n,
		total = #Config.Threat.Stages,
		name = def.Name,
		telop = def.Telop,
	})
	deps.effectRemote:FireAllClients("threatUp", { sound = def.Sound })

	if Config.Threat.DebugLog then
		print(("[ThreatManager] %s に到達 (開始から %.1f 秒 / スコア %d)")
			:format(def.Name, os.clock() - roundStartClock, deps.getScore()))
	end

	-- ★0からの初回昇格はpreviousSquadId==nilなので撤退処理を呼ばない。
	-- Retreat.Enabled=falseのときは呼ばず、旧部隊を残したまま新部隊を派遣する(切り分け用)
	if previousSquadId then
		if Config.Threat.Retreat.Enabled then
			deps.enemies.RetreatSquad(previousSquadId)
		elseif Config.Threat.DebugLog then
			print("[ThreatManager] Retreat.Enabled=false のため旧部隊を残します")
		end
	end

	deps.enemies.DeploySquad(currentSquadId, def.Squad)

	-- 定期増援タイマーの(再)設定。新段階がReinforcementIntervalを持たなければnilに戻す
	-- (これにより★2→★3昇格のような場合、★2用の次回時刻が確実に無効化される)
	if def.ReinforcementInterval then
		nextReinforcementAt = os.clock() + def.ReinforcementInterval
	else
		nextReinforcementAt = nil
	end
end

--------------------------------------------------------------------
-- 監視ループ
--------------------------------------------------------------------
local function monitorLoop()
	local token = roundToken
	while running and roundToken == token do
		if Config.Threat.Enabled then
			local stages = Config.Threat.Stages
			local score = deps.getScore()
			-- whileにする: 一気に閾値を跨いだ場合でも段階を飛ばさない。
			-- if stage==1 then... のような段階固定の分岐は書かない(配列を昇順に走査するだけ)
			while stages[stage + 1] and score >= stages[stage + 1].Threshold do
				promote(stage + 1)
			end

			local def = stages[stage]
			if def and def.ReinforcementInterval then
				-- 定期増援方式: 生存数を見ず、一定間隔で同じsquadIdへSquad一式を追加派遣する。
				-- waitingRespawn/squadSeqには触れない(全滅再派遣方式とは排他)
				if currentSquadId and os.clock() >= nextReinforcementAt then
					deps.enemies.DeploySquad(currentSquadId, def.Squad)
					nextReinforcementAt = os.clock() + def.ReinforcementInterval
				end
			elseif currentSquadId and not waitingRespawn
				and deps.enemies.CountAlive(currentSquadId) == 0 then
				-- 二重派遣防止ガード。CheckIntervalが1秒なので、これが無いと
				-- 「生存者0」を毎秒検出してRespawnDelay秒の間に何度も派遣されてしまう
				waitingRespawn = true
				-- 予約時点のsquadId・段階を捕捉する(Step5-0)。コールバック発火時に
				-- これらが変わっていたら、待機中に昇格したと分かり再派遣しない
				local watchedSquadId = currentSquadId
				local watchedStage = stage
				local respawnDelay = stages[stage].RespawnDelay
				respawnToken += 1
				local myRespawnToken = respawnToken
				local myRoundToken = roundToken
				task.delay(respawnDelay, function()
					if roundToken ~= myRoundToken
						or respawnToken ~= myRespawnToken
						or not running
						or currentSquadId ~= watchedSquadId
						or stage ~= watchedStage then
						return -- ラウンド終了・段階昇格・二重予約のいずれかで無効化された
					end
					waitingRespawn = false
					squadSeq += 1
					currentSquadId = squadSeq
					deps.enemies.DeploySquad(currentSquadId, stages[stage].Squad)
				end)
			end
		end
		task.wait(Config.Threat.CheckInterval)
	end
end

--------------------------------------------------------------------
-- ラウンド制御
--------------------------------------------------------------------
function ThreatManager.Start()
	stage = 0
	squadSeq = 0
	currentSquadId = nil
	nextReinforcementAt = nil
	cancelPendingRespawn()
	running = true
	roundStartClock = os.clock()
	deps.enemies.SetAggressive(true) -- Stop()の逆(移動・攻撃を許可)。忘れると敵が永久に動かない

	-- ★インジケータを☆☆☆にリセットするため、開始時にstage=0を1回送る
	deps.hudRemote:FireAllClients("threat", {
		stage = 0,
		total = #Config.Threat.Stages,
		name = "",
		telop = nil,
	})

	task.spawn(monitorLoop)
end

function ThreatManager.Stop()
	running = false
	nextReinforcementAt = nil
	cancelPendingRespawn()
	deps.enemies.SetAggressive(false)
end

function ThreatManager.Clear()
	roundToken += 1
	running = false
	stage = 0
	squadSeq = 0
	currentSquadId = nil
	nextReinforcementAt = nil
	cancelPendingRespawn()
end

return ThreatManager
