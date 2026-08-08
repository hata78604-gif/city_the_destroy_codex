--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: VisualSetup
-- 種別: ModuleScript
--
-- 固定MAP版のライティング初期設定。
-- サーバー起動時に GameManager から一度だけ呼ばれる。
-- ※ Lighting.Technology(Future)だけはスクリプトから変更できないため
--   Studioでの手動設定(SETUP.md 2-3節)。それ以外はここで自動設定する。
--
-- Terrain・地面はFixedMapTemplate側で用意し、このモジュールからは生成しない。
-- 設定値はすべて Config.Visual にある。
--------------------------------------------------------------------

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local VisualSetup = {}
local done = false -- 二重実行の防止

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
	print("[VisualSetup] ライティングを設定しました (Terrainは固定MAP側で管理)")
end

return VisualSetup
