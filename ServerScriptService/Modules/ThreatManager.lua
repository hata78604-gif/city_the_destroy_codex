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
local roundToken = 0 -- Clear()のたびに+1。task.delay(RespawnDelay待機)の世代確認に使う
local roundStartClock = 0 -- 到達秒数のログ用

function ThreatManager.Init(dependencies)
	deps = dependencies
end

--------------------------------------------------------------------
-- 昇格
--------------------------------------------------------------------
local function promote(n)
	local def = Config.Threat.Stages[n]
	stage = n
	squadSeq += 1
	currentSquadId = squadSeq
	waitingRespawn = false

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

	deps.enemies.DeploySquad(currentSquadId, def.Squad)
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

			if currentSquadId and not waitingRespawn
				and deps.enemies.CountAlive(currentSquadId) == 0 then
				-- 二重派遣防止ガード。CheckIntervalが1秒なので、これが無いと
				-- 「生存者0」を毎秒検出してRespawnDelay秒の間に何度も派遣されてしまう
				waitingRespawn = true
				local respawnDelay = stages[stage].RespawnDelay
				local myToken = roundToken
				task.delay(respawnDelay, function()
					if roundToken ~= myToken or not running then
						return -- 待機中にラウンドが終わっていたら派遣しない
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
	waitingRespawn = false
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
	deps.enemies.SetAggressive(false)
end

function ThreatManager.Clear()
	roundToken += 1
	running = false
	stage = 0
	squadSeq = 0
	currentSquadId = nil
	waitingRespawn = false
end

return ThreatManager
