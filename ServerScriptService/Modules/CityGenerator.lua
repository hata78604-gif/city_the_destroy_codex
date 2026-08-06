--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: CityGenerator
-- 種別: ModuleScript
--
-- 道路で区切られた小さな街角をプロシージャル生成する。
-- ・十字路1つ(道路2本 + 歩道 + 白線)でフィールドを4区画に分ける
-- ・破壊対象の建物をテンプレートから5〜6棟、道路に面して配置
--   (パレット=材質+色/窓枠の差し色/屋根材質、階数、窓パターンをランダムに)
-- ・ReplicatedStorage/BuildingTemplates の手作りモデルも建物として使える
--   (スロットの building 指定で選択。タグ・BuildingId・Anchoredは自動付与)
-- ・区画の縁に壊せる石垣(Destructible)
-- ・非破壊の街小物(街灯・車・木・ベンチ)で雰囲気づくり
--
-- 破壊対象のブロックには "Destructible" タグ(建物のみ BuildingId 属性付き)、
-- 道路・小物には "CityProp" タグを付ける(爆発しても壊れない)。
-- すべて workspace/Map フォルダ配下に生成するので、ラウンドごとの
-- 削除は Map を Destroy するだけでよい(削除対象の管理を一元化)。
--
-- 高さの基準: Terrain草地(VisualSetup)の表面はY≒0.5。
-- 道路・歩道は草より上に出るよう厚みを持たせ、建物・石垣・木は
-- Terrain有効時に0.5持ち上げて草に沈まないようにしている。
--------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local TemplateValidator = require(script.Parent:WaitForChild("TemplateValidator"))

-- ビジュアル設定(Configの貼り替え漏れでキーが無くてもエラーで止まらないよう、
-- 無ければ警告を出して仮の見た目で続行する)
local Visual = Config.Visual
if not Visual then
	warn("[CityGenerator] Config.Visual が見つかりません。ReplicatedStorage の Config を"
		.. "最新の Config.lua に貼り替えてください(仮の見た目で続行します)")
	Visual = {
		TerrainEnabled = false,
		StoneWall = { Enabled = false },
		BuildingPalettes = {
			{
				name = "仮",
				material = Enum.Material.Concrete,
				wallColors = { Color3.fromRGB(222, 204, 168) },
				frameColor = Color3.fromRGB(72, 122, 188),
				roofMaterial = Enum.Material.Slate,
				roofColor = Color3.fromRGB(120, 120, 125),
			},
		},
	}
end

local CityGenerator = {}
local rng = Random.new()

local BW = Config.Block.Size.X -- ブロック幅
local BH = Config.Block.Size.Y -- ブロック高
local BD = Config.Block.Size.Z -- ブロック奥行き(壁の厚み)

-- 高さの基準(Terrainの草の上に載せるための調整)
local GROUND = if Visual.TerrainEnabled then 0.5 else 0 -- 建物・木の足元
-- 車道の上面。Terrain表面(Y≒0.5)とほぼツライチになる薄い値にする。
-- ここを大きくして道路を持ち上げる対処はしないこと(段差=崖ができてNPC/プレイヤーが登れなくなる)。
-- 高さを上げずに見えるようにするため、道路の下のTerrainの草を削る(clearTerrainUnder)方式にしている
local ROAD_TOP = 0.8
local SIDEWALK_TOP = ROAD_TOP + Config.City.SidewalkHeight -- 歩道の上面(車道より一段上)

--------------------------------------------------------------------
-- 街のレイアウト方式の切り替え
--   USE_GRID_MODE = true  … 街区(タイル)を格子状に並べた市街地
--                           (buildRoadGrid + generateGridSlots を使う)
--                 = false … 従来の十字路1つの街
--                           (buildRoads + Config.City.Slots を使う)
-- ※ false の経路は一切変更していないので、これまで通り動作する
--------------------------------------------------------------------
local USE_GRID_MODE = true
local GRID_SIZE = 4 -- N×N街区。この1つで街の広さ(タイル数)が決まる
local TILE_BUILDINGS_PER_EDGE = 2 -- 1街区の1辺に並べる建物数(4辺に配置＝1街区あたり最大 4×この数 棟)
-- ▲ GRID_SIZE=4 は 4×4×(4辺×2棟)= 128 スロットになる。
--   ブロック粗大化(Config.Block.Size)で1棟あたり約120パーツまで軽量化済みのため、
--   パーツ上限20000には収まる見込み(概算約15,000)。収まらない場合は overBudget() で
--   途中打ち切りになるので安全だが、それでも重い場合は GRID_SIZE=3 以下に下げること。

-- グリッド寸法の自動計算(Config.City.Templates の最大サイズから算出する)
local GRID_GAP = 12 -- 街区内の建物どうしの隙間の余裕(stud)
local function maxTemplateDim()
	local m = 0
	for _, t in Config.City.Templates do
		m = math.max(m, t.sizeX, t.sizeZ)
	end
	return m
end
-- blockSpan: 1街区の建物区画の一辺。仕様どおり「最大テンプレサイズ × 1辺の棟数 ＋ 隙間」
local GRID_BLOCKSPAN = maxTemplateDim() * TILE_BUILDINGS_PER_EDGE + GRID_GAP
-- GRID_MAXSIZE: 各スロットに入る建物の最大サイズ。
--   仕様の blockSpan/P だと、隣り合う辺の建物が街区の「角」で必ず重なってしまう
--   (2棟×4辺を正方形の街区に詰めると角が二重取りになるため)。
--   角のクリアランスを確保できる blockSpan/(2*P) を採用している(重なり0を数値検証済み)。
local GRID_MAXSIZE = math.floor(GRID_BLOCKSPAN / (2 * TILE_BUILDINGS_PER_EDGE))
-- tileSize: タイル中心どうしの間隔(建物区画 ＋ 道路幅)
local GRID_TILESIZE = Config.City.RoadWidth + GRID_BLOCKSPAN

local blockCount = 0 -- 建物ブロックの数
local stoneCount = 0 -- 石垣ブロックの数
local propCount = 0 -- 道路・小物パーツの数
local budgetWarned = false

-- 総パーツ数の上限チェック(超えたら生成を打ち切る)
local function overBudget()
	if blockCount + stoneCount + propCount >= Config.Performance.MaxTotalParts then
		if not budgetWarned then
			budgetWarned = true
			warn(("[CityGenerator] 総パーツ数が上限(%d)に達したため、以降の生成を打ち切ります")
				:format(Config.Performance.MaxTotalParts))
		end
		return true
	end
	return false
end

-- ベース色に少しばらつきを加える(同じ建物内の彩度・明度の揺らぎ)
local function jitterColor(base)
	local j = Config.Block.ColorJitter
	return Color3.fromRGB(
		math.clamp(base.R * 255 + rng:NextInteger(-j, j), 0, 255),
		math.clamp(base.G * 255 + rng:NextInteger(-j, j), 0, 255),
		math.clamp(base.B * 255 + rng:NextInteger(-j, j), 0, 255)
	)
end

--------------------------------------------------------------------
-- 破壊対象ブロック(建物・石垣の共通生成)
--------------------------------------------------------------------
local function createBlock(cf, buildingId, color, material, parent)
	if overBudget() then
		return nil
	end
	local block = Instance.new("Part")
	block.Size = Config.Block.Size
	block.CFrame = cf
	block.Anchored = true
	block.Material = material
	block.TopSurface = Enum.SurfaceType.Smooth
	block.BottomSurface = Enum.SurfaceType.Smooth
	block.CastShadow = false -- パーツが多いので影を切って軽くする
	block.Color = jitterColor(color)

	CollectionService:AddTag(block, "Destructible")
	if buildingId then
		block:SetAttribute("BuildingId", buildingId) -- 破壊率の集計対象は建物のみ
	end

	block.Parent = parent
	blockCount += 1
	return block
end

--------------------------------------------------------------------
-- 窓・ドアの開口部判定(窓パターン3種)
-- 範囲外の col/row を渡しても安全に false を返す(窓枠判定で利用)
--------------------------------------------------------------------
local function makeSkipFn(cols, hasDoor, pattern)
	local doorCol = math.floor(cols / 2)
	local rowsPer = Config.RowsPerStorey
	-- 開口部の行範囲は段数(rowsPer)に対する比率で決める(段数を変えても
	-- 窓・ドアの見た目比率を保つため。ブロック粗大化でrowsPerが小さくなると
	-- 段数が足りず「localRow==2 or 3」のような固定行指定は成立しなくなる)
	local doorRows = math.max(1, math.floor(rowsPer * 0.6 + 0.5)) -- ドアの高さ(1階の下から何段)
	local winStart = math.max(0, math.floor(rowsPer * 0.35 + 0.5)) -- 窓帯の開始段
	local winEnd = math.min(rowsPer - 1, math.max(winStart, math.floor(rowsPer * 0.75 + 0.5) - 1)) -- 窓帯の終了段
	return function(col, row)
		local localRow = row % rowsPer -- フロア内での段
		local storey = row // rowsPer -- 何階か(0始まり)
		-- ドア(1階中央・下側)
		if hasDoor and storey == 0 and col == doorCol and localRow < doorRows then
			return true
		end
		local inner = col > 0 and col < cols - 1 -- 端の列は柱として残す
		local inBand = localRow >= winStart and localRow <= winEnd
		if pattern == "storefront" then
			-- 店舗風: 1階は正面がほぼ全面ガラスの大開口
			if storey == 0 and inBand and inner then
				return true
			end
			-- 2階以上は標準の窓
			return storey > 0 and inBand and col % 2 == 1 and inner
		elseif pattern == "wide" then
			-- 広い窓: 3列中2列が開口
			return inBand and col % 3 ~= 0 and inner
		else
			-- 標準: 1列おき
			return inBand and col % 2 == 1 and inner
		end
	end
end

--------------------------------------------------------------------
-- 壁・スラブ(建物ローカル座標で組んで baseCf で配置・回転する)
--------------------------------------------------------------------
local function buildWall(parent, buildingId, palette, baseCf, startLocal, dirLocal, rotY, cols, rows, skipFn)
	for col = 0, cols - 1 do
		for row = 0, rows - 1 do
			if not skipFn(col, row) then
				-- 開口部(窓・ドア)の周囲1ブロックは窓枠色にして差し色を入れる
				local isFrame = skipFn(col - 1, row) or skipFn(col + 1, row)
					or skipFn(col, row - 1) or skipFn(col, row + 1)
				local color = if isFrame
					then palette.frameColor
					else palette.wallColors[rng:NextInteger(1, #palette.wallColors)]
				local localPos = startLocal + dirLocal * (col * BW) + Vector3.new(0, row * BH, 0)
				createBlock(baseCf * CFrame.new(localPos) * CFrame.Angles(0, rotY, 0),
					buildingId, color, palette.material, parent)
			end
		end
	end
end

local function buildSlab(parent, buildingId, color, material, baseCf, centerLocal, sizeX, sizeZ)
	local colsX = math.floor(sizeX / BW) -- X方向はブロック幅(BW)刻み
	local colsZ = math.floor(sizeZ / BD) -- Z方向はブロック奥行き(BD)刻み
	local x0 = centerLocal.X - sizeX / 2 + BW / 2
	local z0 = centerLocal.Z - sizeZ / 2 + BD / 2
	for i = 0, colsX - 1 do
		for k = 0, colsZ - 1 do
			createBlock(baseCf * CFrame.new(x0 + i * BW, centerLocal.Y, z0 + k * BD),
				buildingId, color, material, parent)
		end
	end
end

--------------------------------------------------------------------
-- 建物1棟(slot の位置・向きに、template の形 + palette の質感で建てる)
--------------------------------------------------------------------
local function buildBuilding(slot, template, storeys, palette, buildingId, parent)
	local rows = storeys * Config.RowsPerStorey
	local sx, sz = template.sizeX, template.sizeZ
	local halfX, halfZ = sx / 2, sz / 2
	local colsX = math.floor(sx / BW) -- 正面・背面の列数
	local colsZ = math.floor((sz - 2 * BD) / BW) -- 側面(角=前後壁の厚み分だけ短くして重なりを避ける)
	local y0 = BH / 2 -- 最下段ブロック中心(ローカル)

	-- 建物全体の位置と向き(正面=ローカル-Z側が道路を向くように回す)
	local baseCf = CFrame.new(slot.position + Vector3.new(0, GROUND, 0))
		* CFrame.Angles(0, math.rad(slot.rotationY), 0)

	local model = Instance.new("Model")
	model.Name = ("%s(%d号棟)"):format(template.name, buildingId)

	-- 側面の窓は店舗パターンだと不自然なので標準に落とす
	local sidePattern = if template.pattern == "storefront" then "standard" else template.pattern

	-- 正面(-Z側、ドアあり)
	buildWall(model, buildingId, palette, baseCf,
		Vector3.new(-halfX + BW / 2, y0, -halfZ + BD / 2),
		Vector3.xAxis, 0, colsX, rows, makeSkipFn(colsX, true, template.pattern))
	-- 背面(+Z側)
	buildWall(model, buildingId, palette, baseCf,
		Vector3.new(-halfX + BW / 2, y0, halfZ - BD / 2),
		Vector3.xAxis, 0, colsX, rows, makeSkipFn(colsX, false, sidePattern))
	-- 左面(-X側)ブロックはY軸90度回転でZ方向に並べる
	buildWall(model, buildingId, palette, baseCf,
		Vector3.new(-halfX + BD / 2, y0, -halfZ + BD + BW / 2),
		Vector3.zAxis, math.rad(90), colsZ, rows, makeSkipFn(colsZ, false, sidePattern))
	-- 右面(+X側)
	buildWall(model, buildingId, palette, baseCf,
		Vector3.new(halfX - BD / 2, y0, -halfZ + BD + BW / 2),
		Vector3.zAxis, math.rad(90), colsZ, rows, makeSkipFn(colsZ, false, sidePattern))

	-- 中間フロアの床(2階建て以上のみ。壁と同じ質感で、内側にピッタリ収まるサイズ)
	local storeyHeight = Config.RowsPerStorey * BH
	for i = 1, storeys - 1 do
		buildSlab(model, buildingId, palette.wallColors[1], palette.material, baseCf,
			Vector3.new(0, i * storeyHeight + BH / 2, 0), sx - 2 * BD, sz - 2 * BD)
	end
	-- 屋根(最上段は壁と違う色・材質にして質感を出す)
	buildSlab(model, buildingId, palette.roofColor, palette.roofMaterial, baseCf,
		Vector3.new(0, rows * BH + BH / 2, 0), sx, sz)

	model.Parent = parent
	return model.Name
end

--------------------------------------------------------------------
-- 手作りテンプレート建物(ReplicatedStorage/BuildingTemplates のクローン)
--------------------------------------------------------------------
-- スロットの building 指定から使うテンプレートを決める。
-- 戻り値: 手作りテンプレートの情報 { model, name, partCount }、
--         プロシージャル生成にする場合は nil
local function chooseBuildingSource(slot, handmade)
	local spec = slot.building or "random"
	if spec == "procedural" then
		return nil
	end

	-- "template:〇〇" 指定
	local templateName = spec:match("^template:(.+)$")
	if templateName then
		if #handmade == 0 then
			warn(("[CityGenerator] 手作りテンプレートが1つも無いため、スロット指定「%s」は"
				.. "プロシージャル生成にフォールバックします"):format(spec))
			return nil
		end
		if templateName == "random" then
			return handmade[rng:NextInteger(1, #handmade)]
		end
		for _, entry in handmade do
			if entry.name == templateName then
				return entry
			end
		end
		warn(("[CityGenerator] テンプレート「%s」が見つからないため、プロシージャル生成に"
			.. "フォールバックします(BuildingTemplates内の名前を確認してください)"):format(templateName))
		return nil
	end

	-- "random": プロシージャルの各テンプレと手作りの各テンプレを同じ重みで抽選
	if #handmade == 0 then
		return nil
	end
	local pick = rng:NextInteger(1, #Config.City.Templates + #handmade)
	if pick <= #Config.City.Templates then
		return nil
	end
	return handmade[pick - #Config.City.Templates]
end

-- 手作りテンプレートをクローンしてスロットに配置する。
-- タグ・BuildingId・Anchored は作り手の設定ミスをカバーするため全部自動付与。
-- 戻り値: 表示名, パーツ数, 建物の中心(粉塵エフェクト用)
local function placeTemplateBuilding(slot, entry, buildingId, parent)
	local clone = entry.model:Clone()
	clone.Name = ("%s(%d号棟)"):format(entry.name, buildingId)

	local count = 0
	for _, obj in clone:GetDescendants() do
		if obj:IsA("BasePart") then
			obj.Anchored = true
			obj.CastShadow = false -- 建物ブロックと同じく影を切って軽くする
			CollectionService:AddTag(obj, "Destructible")
			obj:SetAttribute("BuildingId", buildingId)
			count += 1
		end
	end

	-- 配置: 正面(PrimaryPartのLookVector)をプロシージャル建物と同じ向き=道路側へ
	clone:PivotTo(CFrame.new(slot.position) * CFrame.Angles(0, math.rad(slot.rotationY), 0))

	-- 接地: モデルの底面が地面(Terrainの草の上)に合うようY方向に平行移動
	local boxCf, boxSize = clone:GetBoundingBox()
	local bottomY = boxCf.Y - boxSize.Y / 2
	clone:PivotTo(clone:GetPivot() + Vector3.new(0, GROUND - bottomY, 0))

	-- 区画に収まらない場合は警告だけ出してそのまま置く
	-- (自動縮小はしない。スケール変更は破壊の粒度が崩れるため)
	if math.max(boxSize.X, boxSize.Z) > slot.maxSize then
		warn(("[CityGenerator] テンプレート「%s」(横幅 %.0f stud)がスロットの区画(%d stud)より"
			.. "大きいですが、そのまま配置します。はみ出す場合は Config.City.Slots の maxSize や建物の大きさを調整してください")
			:format(entry.name, math.max(boxSize.X, boxSize.Z), slot.maxSize))
	end

	clone.Parent = parent
	blockCount += count

	local center = Vector3.new(slot.position.X, GROUND + boxSize.Y / 2, slot.position.Z)
	return clone.Name, count, center
end

-- パーツ数上限が厳しいときの避難先: いちばん小さいプロシージャルテンプレ
local function smallestTemplate()
	local best = nil
	for _, t in Config.City.Templates do
		if not best
			or t.storeys < best.storeys
			or (t.storeys == best.storeys and t.sizeX * t.sizeZ < best.sizeX * best.sizeZ) then
			best = t
		end
	end
	return best
end

--------------------------------------------------------------------
-- 石垣(区画の縁の低い壁。Destructibleなので壊せる)
--------------------------------------------------------------------
-- 建物の正面・周囲をふさがないよう、スロットの近くには置かない
local function nearBuilding(x, z)
	for _, slot in Config.City.Slots do
		local half = slot.maxSize / 2 + 8
		if math.abs(x - slot.position.X) < half and math.abs(z - slot.position.Z) < half then
			return true
		end
	end
	return false
end

local function buildStoneWalls(parent)
	local SW = Visual.StoneWall
	if not SW.Enabled then
		return
	end
	local model = Instance.new("Model")
	model.Name = "石垣"
	local y = GROUND + BH / 2 -- 高さ2のブロックを地面に置く
	local ranges = { { 16, 112 }, { -112, -16 } }
	for _, sign in { -1, 1 } do
		for _, range in ranges do
			for d = range[1], range[2], SW.Spacing do
				-- 横方向の道路沿い(z = ±14、歩道のすぐ内側)
				if not nearBuilding(d, sign * 14) then
					createBlock(CFrame.new(d, y, sign * 14),
						nil, SW.Color, Enum.Material.Cobblestone, model)
				end
				-- 縦方向の道路沿い(x = ±14)
				if not nearBuilding(sign * 14, d) then
					createBlock(CFrame.new(sign * 14, y, d) * CFrame.Angles(0, math.rad(90), 0),
						nil, SW.Color, Enum.Material.Cobblestone, model)
				end
			end
		end
	end
	model.Parent = parent
end

--------------------------------------------------------------------
-- 非破壊パーツ(道路・小物)の共通生成
--------------------------------------------------------------------
local function propPart(props, parent)
	if overBudget() then
		return nil
	end
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CastShadow = false
	for key, value in props do
		p[key] = value
	end
	CollectionService:AddTag(p, "CityProp") -- 破壊対象外の目印(掃除対象の管理用)
	p.Parent = parent
	propCount += 1
	return p
end

--------------------------------------------------------------------
-- 道路のツライチ化: 道路・歩道の下のTerrainの草を削って空洞(Air)にする。
-- 道路を持ち上げるのではなく地面側を削ることで、段差(崖)を作らずに
-- 草に埋もれず見えるようにする。
--------------------------------------------------------------------
local Terrain = workspace.Terrain
local CLEAR_TOP_Y = 1 -- 削る範囲の上端(Y)。地表(Y≒0.5)より少し上まで含めて草の葉先も消す

-- cf: 対象パーツのCFrame(水平位置だけ使う。Yは地表基準に揃え直す)
-- size: 対象パーツのSize(X/Zだけ使う)
-- marginXZ: 水平方向に広げる余白(継ぎ目や道路端から草が漏れないよう少し大きめに削る。既定1)
-- depth: 削る深さ(草の根まで届かせる。掘りすぎると空洞に落ちて見えるので最小限に。既定6)
local function clearTerrainUnder(cf, size, marginXZ, depth)
	if not Visual.TerrainEnabled then
		return -- Terrainを使わない設定(ベースプレート運用)なら削る対象が無い
	end
	marginXZ = marginXZ or 1
	depth = depth or 6
	local fillSize = Vector3.new(size.X + marginXZ * 2, depth, size.Z + marginXZ * 2)
	local fillCf = CFrame.new(cf.X, CLEAR_TOP_Y - depth / 2, cf.Z)
	Terrain:FillBlock(fillCf, fillSize, Enum.Material.Air)
end

--------------------------------------------------------------------
-- 道路グリッド(車道 + 白線 + 歩道)。Terrainとツライチになるよう、
-- 置いた直後に下の草を clearTerrainUnder で削る(段差を作らないため)
--------------------------------------------------------------------
local function buildRoads(parent)
	local C = Config.City
	local L, W = C.RoadLength, C.RoadWidth
	local roadColor = Color3.fromRGB(58, 58, 62)
	local walkColor = Color3.fromRGB(178, 178, 180)

	-- 車道(十字の2本)。marginを広め(2)にして交差点の継ぎ目の草も消す
	local road1 = propPart({ Name = "Road", Size = Vector3.new(L, ROAD_TOP, W), CFrame = CFrame.new(0, ROAD_TOP / 2, 0),
		Color = roadColor, Material = Enum.Material.Asphalt }, parent)
	if road1 then
		clearTerrainUnder(road1.CFrame, road1.Size, 2, 6)
	end
	local road2 = propPart({ Name = "Road", Size = Vector3.new(W, ROAD_TOP, L), CFrame = CFrame.new(0, ROAD_TOP / 2, 0),
		Color = roadColor, Material = Enum.Material.Asphalt }, parent)
	if road2 then
		clearTerrainUnder(road2.CFrame, road2.Size, 2, 6)
	end

	-- 中央の白線(細長いPartを点線状に。交差点内はあけておく)
	for d = -L / 2 + 4, L / 2 - 4, 8 do
		if math.abs(d) > W / 2 + 2 then
			propPart({ Name = "Line", Size = Vector3.new(4, 0.05, 0.8), CFrame = CFrame.new(d, ROAD_TOP + 0.03, 0),
				Color = Color3.new(1, 1, 1), Material = Enum.Material.SmoothPlastic,
				CanCollide = false, CanQuery = false }, parent)
			propPart({ Name = "Line", Size = Vector3.new(0.8, 0.05, 4), CFrame = CFrame.new(0, ROAD_TOP + 0.03, d),
				Color = Color3.new(1, 1, 1), Material = Enum.Material.SmoothPlastic,
				CanCollide = false, CanQuery = false }, parent)
		end
	end

	-- 歩道(道路の両脇に一段高く。交差点を避けて4分割ずつ)
	local swW = C.SidewalkWidth
	local edge = W / 2 + swW / 2 -- 歩道の中心線(道路端から歩道半分外)
	local segLen = L / 2 - (W / 2 + swW) -- 交差点そばを除いた長さ
	local segMid = (W / 2 + swW) + segLen / 2
	for _, s in { -1, 1 } do
		for _, m in { -1, 1 } do
			-- 横方向の道路(X軸沿い)の歩道
			local sw1 = propPart({ Name = "Sidewalk", Size = Vector3.new(segLen, SIDEWALK_TOP, swW),
				CFrame = CFrame.new(m * segMid, SIDEWALK_TOP / 2, s * edge),
				Color = walkColor, Material = Enum.Material.Concrete }, parent)
			if sw1 then
				clearTerrainUnder(sw1.CFrame, sw1.Size, 1, 6)
			end
			-- 縦方向の道路(Z軸沿い)の歩道
			local sw2 = propPart({ Name = "Sidewalk", Size = Vector3.new(swW, SIDEWALK_TOP, segLen),
				CFrame = CFrame.new(s * edge, SIDEWALK_TOP / 2, m * segMid),
				Color = walkColor, Material = Enum.Material.Concrete }, parent)
			if sw2 then
				clearTerrainUnder(sw2.CFrame, sw2.Size, 1, 6)
			end
		end
	end
end

--------------------------------------------------------------------
-- 動作確認の観点(Studioでのテストプレイ時に見るポイント):
-- ・道路が草とツライチで、崖・段差ができていないこと
-- ・道路・歩道の継ぎ目や脇から草が突き抜けていないこと
--   (突き抜ける場合は clearTerrainUnder の marginXZ を広げる)
-- ・削り範囲が広すぎて建物や石垣の足元まで草が消えていないこと
--   (削っているのは buildRoads 内、道路・歩道の下だけ)
-- ・道路の下が空洞に落ちて見えないこと(見える場合は depth を減らす)
--------------------------------------------------------------------

--------------------------------------------------------------------
-- 街小物(すべて非破壊。将来「車も壊せる」等にしやすいよう関数を分離)
--------------------------------------------------------------------
-- 街灯: 支柱 + ネオンのランプ(現状維持)
local function buildStreetlight(x, z, parent)
	propPart({ Name = "LampPole", Size = Vector3.new(0.5, 8, 0.5),
		CFrame = CFrame.new(x, SIDEWALK_TOP + 4, z),
		Color = Color3.fromRGB(70, 70, 75), Material = Enum.Material.Metal }, parent)
	propPart({ Name = "LampHead", Size = Vector3.new(1.6, 0.7, 1.6),
		CFrame = CFrame.new(x, SIDEWALK_TOP + 8.35, z),
		Color = Color3.fromRGB(255, 235, 170), Material = Enum.Material.Neon }, parent)
end

-- 車: 車体(少し反射) + キャビン + 窓ガラス風の暗色バンド + タイヤ4個(計7パーツ)
local function buildCar(baseCf, bodyColor, parent)
	propPart({ Name = "CarBody", Size = Vector3.new(7, 1.8, 4),
		CFrame = baseCf * CFrame.new(0, 1.7, 0),
		Color = bodyColor, Material = Enum.Material.SmoothPlastic, Reflectance = 0.1 }, parent)
	propPart({ Name = "CarCabin", Size = Vector3.new(3.6, 1.3, 3.4),
		CFrame = baseCf * CFrame.new(-0.4, 3.25, 0),
		Color = bodyColor, Material = Enum.Material.SmoothPlastic, Reflectance = 0.1 }, parent)
	propPart({ Name = "CarGlass", Size = Vector3.new(3.7, 0.6, 3.5),
		CFrame = baseCf * CFrame.new(-0.4, 3.3, 0),
		Color = Color3.fromRGB(25, 30, 40), Material = Enum.Material.SmoothPlastic, Reflectance = 0.2 }, parent)
	for _, wx in { -2.2, 2.2 } do
		for _, wz in { -2.1, 2.1 } do
			propPart({ Name = "CarWheel", Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.8, 1.6, 1.6),
				CFrame = baseCf * CFrame.new(wx, 0.8, wz) * CFrame.Angles(0, math.rad(90), 0),
				Color = Color3.fromRGB(30, 30, 30), Material = Enum.Material.SmoothPlastic }, parent)
		end
	end
end

-- 木: 幹1本 + 葉の球3個の重ね合わせ(計4パーツ。1個の球より自然に見える)
local function buildTree(x, z, parent)
	propPart({ Name = "TreeTrunk", Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(5, 1.4, 1.4),
		CFrame = CFrame.new(x, GROUND + 2.5, z) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(105, 70, 45), Material = Enum.Material.Wood }, parent)
	local mainSize = 5.5 + rng:NextNumber(0, 1.5)
	local leafColor = Color3.fromRGB(60 + rng:NextInteger(0, 30), 140 + rng:NextInteger(0, 40), 60)
	-- メインの葉 + 左右にひとまわり小さい葉をずらして重ねる
	local leaves = {
		{ size = mainSize, offset = Vector3.new(0, 0, 0) },
		{ size = mainSize * 0.7, offset = Vector3.new(1.6, -0.8, 1.0) },
		{ size = mainSize * 0.65, offset = Vector3.new(-1.5, -0.5, -1.2) },
	}
	for _, leaf in leaves do
		propPart({ Name = "TreeLeaves", Shape = Enum.PartType.Ball,
			Size = Vector3.new(leaf.size, leaf.size, leaf.size),
			CFrame = CFrame.new(Vector3.new(x, GROUND + 4 + mainSize / 2, z) + leaf.offset),
			Color = leafColor, Material = Enum.Material.Grass }, parent)
	end
end

-- ベンチ: 座面 + 脚2本
local function buildBench(baseCf, parent)
	propPart({ Name = "BenchSeat", Size = Vector3.new(4, 0.4, 1.4),
		CFrame = baseCf * CFrame.new(0, 1.2, 0),
		Color = Color3.fromRGB(130, 95, 60), Material = Enum.Material.WoodPlanks }, parent)
	for _, lx in { -1.6, 1.6 } do
		propPart({ Name = "BenchLeg", Size = Vector3.new(0.4, 1, 1.4),
			CFrame = baseCf * CFrame.new(lx, 0.5, 0),
			Color = Color3.fromRGB(60, 60, 65), Material = Enum.Material.Metal }, parent)
	end
end

local function buildProps(parent)
	-- 街灯12本(両道路沿いに交互の側で。建物2列目に合わせて外側にも追加)
	for _, p in { { -70, 10 }, { -30, -10 }, { 30, 10 }, { 70, -10 }, { -90, -10 }, { 90, 10 } } do
		buildStreetlight(p[1], p[2], parent) -- 横の道路沿い
		buildStreetlight(p[2], p[1], parent) -- 縦の道路沿い
	end

	-- 路肩の車6台(色ランダム)
	local carColors = {
		Color3.fromRGB(200, 60, 55), Color3.fromRGB(65, 110, 200),
		Color3.fromRGB(230, 230, 230), Color3.fromRGB(55, 140, 75),
	}
	local carSpots = {
		CFrame.new(-50, ROAD_TOP, 5.8), -- 横道路の路肩
		CFrame.new(24, ROAD_TOP, -5.8) * CFrame.Angles(0, math.rad(180), 0),
		CFrame.new(5.8, ROAD_TOP, 60) * CFrame.Angles(0, math.rad(90), 0), -- 縦道路の路肩
		CFrame.new(-5.8, ROAD_TOP, -46) * CFrame.Angles(0, math.rad(-90), 0),
		CFrame.new(90, ROAD_TOP, 5.8), -- 横道路2列目の路肩
		CFrame.new(-5.8, ROAD_TOP, 90) * CFrame.Angles(0, math.rad(-90), 0), -- 縦道路の路肩(奥)
	}
	for _, cf in carSpots do
		buildCar(cf, carColors[rng:NextInteger(1, #carColors)], parent)
	end

	-- 区画の隅の木9本(横道路2列目の外側にも追加。建物スロットと重ならない位置)
	for _, p in { { -95, -95 }, { 95, 95 }, { -90, 80 }, { 90, -80 }, { -20, 95 }, { 20, -95 },
		{ 60, 110 }, { -60, -110 }, { -60, 110 } } do
		buildTree(p[1], p[2], parent)
	end

	-- 歩道のベンチ2脚(道路の方を向ける)
	buildBench(CFrame.new(24, SIDEWALK_TOP, 10), parent)
	buildBench(CFrame.new(-24, SIDEWALK_TOP, -10) * CFrame.Angles(0, math.rad(180), 0), parent)
end

--------------------------------------------------------------------
-- プロシージャル建物を1棟生成して info エントリを返す
-- (grid モードで使用。従来経路の生成ロジックと同じ内容を関数化したもの)
--------------------------------------------------------------------
local function generateProceduralBuilding(slot, id, parent)
	-- スロットに収まるテンプレートからランダムに選ぶ(候補が無ければ最小テンプレで避難)
	local candidates = {}
	for _, t in Config.City.Templates do
		if t.sizeX <= slot.maxSize and t.sizeZ <= slot.maxSize then
			table.insert(candidates, t)
		end
	end
	local template = if #candidates > 0 then candidates[rng:NextInteger(1, #candidates)] else smallestTemplate()

	-- 階数±1の揺らぎ(街並みのランダム感)
	local storeys = template.storeys
	if rng:NextNumber() < Config.City.StoreyJitterChance then
		storeys = math.clamp(storeys + (if rng:NextNumber() < 0.5 then -1 else 1), 1, Config.City.MaxStoreys)
	end

	-- 質感パレット(砂岩/コンクリ/レンガ)をランダムに
	local palettes = Visual.BuildingPalettes
	local palette = palettes[rng:NextInteger(1, #palettes)]

	local before = blockCount
	local displayName = buildBuilding(slot, template, storeys, palette, id, parent)
	return {
		name = displayName,
		total = blockCount - before,
		destroyed = 0,
		bonusGiven = false,
		-- 建物の中心(全壊時の粉塵エフェクトの発生位置)
		center = slot.position + Vector3.new(0, GROUND + storeys * Config.RowsPerStorey * BH / 2, 0),
	}
end

--------------------------------------------------------------------
-- グリッド街のスロット生成(座標計算のみ。建物の実生成は Generate が行う)
-- 各街区(タイル)の4辺に TILE_BUILDINGS_PER_EDGE 棟ずつ、道路側を正面にして並べる。
-- 戻り値は既存 Config.City.Slots と同じ構造 { position, rotationY, maxSize } の配列。
--------------------------------------------------------------------
local function generateGridSlots()
	local N = GRID_SIZE
	local P = TILE_BUILDINGS_PER_EDGE
	local span = GRID_BLOCKSPAN
	local inset = GRID_MAXSIZE / 2 -- 街区の外縁から建物中心までの引っ込み量(道路にはみ出さないため)
	local usable = span - 2 * GRID_MAXSIZE -- 辺方向に建物を置ける範囲(両端に角クリアランスを残す)
	local slots = {}
	for i = 0, N - 1 do
		for j = 0, N - 1 do
			-- 街全体が原点中心になるようタイル(i,j)の中心を求める
			local cx = (i - (N - 1) / 2) * GRID_TILESIZE
			local cz = (j - (N - 1) / 2) * GRID_TILESIZE
			for n = 0, P - 1 do
				local o = ((n + 0.5) / P - 0.5) * usable -- 辺に沿った位置(中央そろえ)
				-- 各建物の正面(ローカル-Z)が道路側を向くよう rotationY を辺ごとに設定
				-- (buildBuilding の向き基準: rotationY=0 で正面が -Z を向く)
				-- 南辺: -Z側の道路を向く
				table.insert(slots, { position = Vector3.new(cx + o, 0, cz - span / 2 + inset), rotationY = 0, maxSize = GRID_MAXSIZE })
				-- 北辺: +Z側の道路を向く
				table.insert(slots, { position = Vector3.new(cx + o, 0, cz + span / 2 - inset), rotationY = 180, maxSize = GRID_MAXSIZE })
				-- 西辺: -X側の道路を向く
				table.insert(slots, { position = Vector3.new(cx - span / 2 + inset, 0, cz + o), rotationY = 90, maxSize = GRID_MAXSIZE })
				-- 東辺: +X側の道路を向く
				table.insert(slots, { position = Vector3.new(cx + span / 2 - inset, 0, cz + o), rotationY = -90, maxSize = GRID_MAXSIZE })
			end
		end
	end
	return slots
end

--------------------------------------------------------------------
-- グリッド道路(縦 N+1 本・横 N+1 本の車道 ＋ 両脇の歩道)。
-- 既存 buildRoads と同じく、置いた直後に下の草を clearTerrainUnder で削る。
-- 色/材質/ROAD_TOP/SIDEWALK_TOP は既存の値をそのまま使う。
-- ※歩道は全長ストレートなので交差点上を横切る(見た目は後で作り込み可。まずは車道＋歩道)
--------------------------------------------------------------------
local function buildRoadGrid(parent)
	local W = Config.City.RoadWidth
	local swW = Config.City.SidewalkWidth
	local roadColor = Color3.fromRGB(58, 58, 62)
	local walkColor = Color3.fromRGB(178, 178, 180)
	local N = GRID_SIZE
	local roadLen = N * GRID_TILESIZE + W -- グリッド全体をカバーする長さ(端＋交差点分)
	local swOff = W / 2 + swW / 2 -- 車道中心から歩道中心までの距離

	for k = 0, N do
		local p = (k - N / 2) * GRID_TILESIZE -- k番目の道路の中心座標

		-- 縦の道路(Z方向に伸びる。x=p)。marginを広め(2)にして交差点の継ぎ目の草も消す
		local vr = propPart({ Name = "Road", Size = Vector3.new(W, ROAD_TOP, roadLen),
			CFrame = CFrame.new(p, ROAD_TOP / 2, 0),
			Color = roadColor, Material = Enum.Material.Asphalt }, parent)
		if vr then
			clearTerrainUnder(vr.CFrame, vr.Size, 2, 6)
		end
		for _, s in { -1, 1 } do
			local sw = propPart({ Name = "Sidewalk", Size = Vector3.new(swW, SIDEWALK_TOP, roadLen),
				CFrame = CFrame.new(p + s * swOff, SIDEWALK_TOP / 2, 0),
				Color = walkColor, Material = Enum.Material.Concrete }, parent)
			if sw then
				clearTerrainUnder(sw.CFrame, sw.Size, 1, 6)
			end
		end

		-- 横の道路(X方向に伸びる。z=p)
		local hr = propPart({ Name = "Road", Size = Vector3.new(roadLen, ROAD_TOP, W),
			CFrame = CFrame.new(0, ROAD_TOP / 2, p),
			Color = roadColor, Material = Enum.Material.Asphalt }, parent)
		if hr then
			clearTerrainUnder(hr.CFrame, hr.Size, 2, 6)
		end
		for _, s in { -1, 1 } do
			local sw = propPart({ Name = "Sidewalk", Size = Vector3.new(roadLen, SIDEWALK_TOP, swW),
				CFrame = CFrame.new(0, SIDEWALK_TOP / 2, p + s * swOff),
				Color = walkColor, Material = Enum.Material.Concrete }, parent)
			if sw then
				clearTerrainUnder(sw.CFrame, sw.Size, 1, 6)
			end
		end
	end
end

--------------------------------------------------------------------
-- マップ全体の生成
--------------------------------------------------------------------
-- 戻り値は建物ごとの情報テーブル:
-- { [buildingId] = { name, total(総ブロック数), destroyed, bonusGiven, center } }
function CityGenerator.Generate()
	CityGenerator.Clear()
	blockCount, stoneCount, propCount, budgetWarned = 0, 0, 0, false

	local map = Instance.new("Folder")
	map.Name = "Map"

	local info = {}

	if USE_GRID_MODE then
		-- グリッド街: 道路を先に生成してから建物を建てる。
		-- スロット数(128)はパーツ上限を超えうるため、overBudget()で建物側が
		-- 打ち切られても道路網は必ず完成しているようにする(道路が上限で消えるのを防ぐ)
		buildRoadGrid(map)

		-- 座標計算したスロットにプロシージャル建物を建てる。
		-- 手作りテンプレ(chooseBuildingSource)・石垣・小物は当面使わない
		-- (まず建物と道路だけで動作確認する方針)
		local slots = generateGridSlots()
		for id, slot in ipairs(slots) do
			if overBudget() then
				break -- 上限に達したら以降のスロットは生成しない(打ち切り)
			end
			info[id] = generateProceduralBuilding(slot, id, map)
		end

		map.Parent = workspace
		print(("[CityGenerator] 生成完了(グリッド街 %dx%d): 建物ブロック %d / 石垣 %d / 道路・小物 %d / 合計 %d (上限 %d)")
			:format(GRID_SIZE, GRID_SIZE, blockCount, stoneCount, propCount,
				blockCount + stoneCount + propCount, Config.Performance.MaxTotalParts))
		return info
	end

	-- 建物(破壊対象)を先に生成する。パーツ数上限に達した場合に
	-- 削られるのが石垣・小物側になるようにするため
	local handmade = TemplateValidator.GetValidTemplates()
	for id, slot in ipairs(Config.City.Slots) do
		-- スロットの building 指定に従って「手作りテンプレ」か「プロシージャル」かを決める
		local entry = chooseBuildingSource(slot, handmade)
		local forceSmallest = false

		-- 手作りテンプレのパーツ数が総パーツ上限に収まらないなら、
		-- 最小のプロシージャル建物に切り替える(上限6,000は厳守)
		if entry and blockCount + stoneCount + propCount + entry.partCount > Config.Performance.MaxTotalParts then
			warn(("[CityGenerator] テンプレート「%s」(%d パーツ)を置くと総パーツ数上限(%d)を超えるため、"
				.. "このスロットは最小のプロシージャル建物に切り替えます")
				:format(entry.name, entry.partCount, Config.Performance.MaxTotalParts))
			entry = nil
			forceSmallest = true
		end

		if entry then
			-- 手作りテンプレートをクローン配置
			local displayName, count, center = placeTemplateBuilding(slot, entry, id, map)
			info[id] = {
				name = displayName,
				total = count,
				destroyed = 0,
				bonusGiven = false,
				center = center,
			}
		else
			-- プロシージャル生成(従来どおり)
			local template
			if forceSmallest then
				template = smallestTemplate()
			else
				-- スロットに収まるテンプレートからランダムに選ぶ
				local candidates = {}
				for _, t in Config.City.Templates do
					if t.sizeX <= slot.maxSize and t.sizeZ <= slot.maxSize then
						table.insert(candidates, t)
					end
				end
				template = candidates[rng:NextInteger(1, #candidates)]
			end

			-- 階数±1の揺らぎ(街並みのランダム感)
			local storeys = template.storeys
			if not forceSmallest and rng:NextNumber() < Config.City.StoreyJitterChance then
				storeys = math.clamp(storeys + (if rng:NextNumber() < 0.5 then -1 else 1), 1, Config.City.MaxStoreys)
			end

			-- 質感パレット(砂岩/コンクリ/レンガ)をランダムに
			local palettes = Visual.BuildingPalettes
			local palette = palettes[rng:NextInteger(1, #palettes)]

			local before = blockCount
			local displayName = buildBuilding(slot, template, storeys, palette, id, map)
			info[id] = {
				name = displayName,
				total = blockCount - before,
				destroyed = 0,
				bonusGiven = false,
				-- 建物の中心(全壊時の粉塵エフェクトの発生位置)
				center = slot.position + Vector3.new(0, GROUND + storeys * Config.RowsPerStorey * BH / 2, 0),
			}
		end
	end

	-- 石垣(破壊対象だが破壊率の集計外)
	local beforeStone = blockCount
	buildStoneWalls(map)
	stoneCount = blockCount - beforeStone
	blockCount = beforeStone -- 建物ブロック数と石垣を分けて数える

	-- 道路と街小物(非破壊)
	buildRoads(map)
	buildProps(map)

	map.Parent = workspace
	print(("[CityGenerator] 生成完了: 建物ブロック %d / 石垣 %d / 道路・小物 %d / 合計 %d (上限 %d)")
		:format(blockCount, stoneCount, propCount,
			blockCount + stoneCount + propCount, Config.Performance.MaxTotalParts))
	return info
end

--------------------------------------------------------------------
-- 敵の湧き位置・走行ルート用のgetter(EnemyManagerが使用。Step0時点では未使用)。
-- GRID_SIZE/GRID_TILESIZEはグリッドモード専用のローカル定数のため、
-- 従来モード(USE_GRID_MODE=false)で呼ばれると意味を持たない値になってしまう。
-- 従来モードは凍結中で敵システムの対象外(THREAT_DESIGN_PROPOSAL.md参照)なので、
-- その場合は明示的にnilを返す(嘘の値を返さない)。
--------------------------------------------------------------------
-- 道路の中心線の配列(例: GRID_SIZE=4なら { -248, -124, 0, 124, 248 })
function CityGenerator.GetRoadLines()
	if not USE_GRID_MODE then
		return nil
	end
	local N = GRID_SIZE
	local lines = {}
	for k = 0, N do
		table.insert(lines, (k - N / 2) * GRID_TILESIZE)
	end
	return lines
end

-- 街の外周座標の絶対値(例: GRID_SIZE=4なら 248。街は ±この値 の正方形に収まる)
function CityGenerator.GetCityBounds()
	if not USE_GRID_MODE then
		return nil
	end
	return (GRID_SIZE / 2) * GRID_TILESIZE
end

-- マップを全削除する(道路・小物も含めてMapフォルダごと消す)
function CityGenerator.Clear()
	local old = workspace:FindFirstChild("Map")
	if old then
		old:Destroy()
	end
end

return CityGenerator
