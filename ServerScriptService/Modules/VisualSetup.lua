--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: VisualSetup
-- 種別: ModuleScript
--
-- ライティングと地形(Terrain草地)の初期設定。
-- サーバー起動時に GameManager から一度だけ呼ばれる。
-- ※ Lighting.Technology(Future)だけはスクリプトから変更できないため
--   Studioでの手動設定(SETUP.md 2-3節)。それ以外はここで自動設定する。
--
-- Terrainは破壊対象外なので、ラウンドごとには再生成しない(初回のみ)。
-- 設定値はすべて Config.Visual にある。
--------------------------------------------------------------------

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local VisualSetup = {}
local done = false -- 二重実行(Terrain二重生成)の防止

--------------------------------------------------------------------
-- ライティング(明るい昼下がりの屋外)
--------------------------------------------------------------------
local function setupLighting()
	local L = Config.Visual.Lighting

	-- Lighting.Technology(Future)はスクリプトから変更できないため、
	-- ここでは触らない。Studioで手動設定する(SETUP.md 2-3節。1回でOK)

	Lighting.Brightness = L.Brightness
	Lighting.EnvironmentDiffuseScale = L.EnvironmentDiffuseScale
	Lighting.EnvironmentSpecularScale = L.EnvironmentSpecularScale
	Lighting.ClockTime = L.ClockTime

	-- Atmosphere(遠景の霞み)。無ければ生成する
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Parent = Lighting
	end
	atmosphere.Density = L.AtmosphereDensity
	atmosphere.Haze = L.AtmosphereHaze
end

--------------------------------------------------------------------
-- 地形(ベースプレートの上に草地Terrainを敷く)
--------------------------------------------------------------------
local function setupTerrain()
	if not Config.Visual.TerrainEnabled then
		return
	end
	local terrain = workspace.Terrain

	-- 街区(±120)より一回り広い草地。表面がベースプレート(Y0)より
	-- 約0.5上に来るように敷く(道路・歩道側はこの分だけ厚くしてある)
	terrain:FillBlock(CFrame.new(0, -1.75, 0), Vector3.new(400, 4.5, 400), Enum.Material.Grass)

	-- 街の外周に緩やかな丘(球の上端だけ地上に出す)
	local hills = {
		Vector3.new(170, -18, 60),
		Vector3.new(-170, -18, -40),
		Vector3.new(50, -18, 175),
		Vector3.new(-60, -18, -175),
	}
	for _, pos in hills do
		terrain:FillBall(pos, 26, Enum.Material.Grass)
	end

	-- 揺れる草。Terrain.Decoration プロパティが存在しない環境があるため
	-- pcall で試し、使えなければ静かにスキップする(草が揺れないだけで実害なし)
	-- ※その場合は Studio で Terrain を選び、プロパティの Decoration をオンにする
	pcall(function()
		terrain.Decoration = Config.Visual.TerrainDecoration
	end)
end

--------------------------------------------------------------------
function VisualSetup.Setup()
	if done then
		return
	end
	done = true
	-- Configの貼り替え漏れ対策(無ければ何もしないで警告のみ)
	if not Config.Visual then
		warn("[VisualSetup] Config.Visual が見つかりません。ReplicatedStorage の Config を"
			.. "最新の Config.lua に貼り替えてください(ビジュアル設定をスキップします)")
		return
	end
	setupLighting()
	setupTerrain()
	print("[VisualSetup] ライティングと地形を設定しました")
end

return VisualSetup
