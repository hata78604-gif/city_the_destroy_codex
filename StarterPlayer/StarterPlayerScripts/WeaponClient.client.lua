--------------------------------------------------------------------
-- 配置場所: StarterPlayer/StarterPlayerScripts
-- Studio上の名前: WeaponClient
-- 種別: LocalScript
--
-- 武器の「入力処理」専用スクリプト。画面(HUD・ボタン)は一切作らない。
-- HUDの生成はすべて UIController に一本化されている。
--
-- 担当:
-- ・クリック / タップ(Tool.Activated/Deactivated)で照準位置に発射リクエストを送る。
--   AutoFireが真の武器(バズーカ)は押しっぱなしで連射する(Step4d)
-- ・数字キー 1/2/3 での武器切替(標準ツールバーはUIController側で
--   無効化しているため、キー処理もここで自前で行う)
-- ・F キーでリモート爆弾の起爆
-- ・装備中の武器が変わったら WeaponSelected イベントで UIController へ通知
--
-- UIController との連携は PlayerScripts 内の BindableEvent
-- (WeaponClientEvents フォルダ)で行う:
--   EquipRequest    (UI → ここ) スロットタップによる武器切替の依頼
--   FireRequest     (UI → ここ) モバイル発射ボタンを押した(画面中央に向けて連射開始)
--   FireRelease     (UI → ここ) モバイル発射ボタンを離した(連射停止。Step4d)
--   DetonateRequest (UI → ここ) 起爆ボタン
--   WeaponSelected  (ここ → UI) 装備中の武器キー(外したら nil)
--------------------------------------------------------------------

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local fireRemote = remotes:WaitForChild("Fire")
local actionRemote = remotes:WaitForChild("Action")
local roundStateRemote = remotes:WaitForChild("RoundState")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local camera = workspace.CurrentCamera

--------------------------------------------------------------------
-- UIController との連携イベント(こちらが作り、UI側が WaitForChild する)
--------------------------------------------------------------------
local eventsFolder = Instance.new("Folder")
eventsFolder.Name = "WeaponClientEvents"
local events = {}
for _, name in { "EquipRequest", "FireRequest", "FireRelease", "DetonateRequest", "WeaponSelected" } do
	local ev = Instance.new("BindableEvent")
	ev.Name = name
	ev.Parent = eventsFolder
	events[name] = ev
end
eventsFolder.Parent = script.Parent -- PlayerScripts

--------------------------------------------------------------------
-- 発射
--------------------------------------------------------------------
local equippedTool = nil
local lastFire = 0
local hooked = {} -- Activated/Deactivated を二重接続しないための記録
local roundState = "LOBBY"
local firingToken = 0 -- 連射ループの世代トークン。増やすだけで現在のループを止められる

roundStateRemote.OnClientEvent:Connect(function(state)
	roundState = state
	if state ~= "BATTLE" then
		firingToken += 1 -- LOBBY/RESULT中は撃ち続けない
	end
end)

local function tryFire(targetPos)
	if not equippedTool then
		return
	end
	local key = equippedTool:GetAttribute("WeaponKey")
	if not key then
		return
	end
	-- 連打防止の軽いゲート(本判定はサーバー側のクールダウン)。
	-- 武器のCooldownより大きいと連射そのものを飲み込んでしまうため、Cooldownとの
	-- 小さい方を使う(バズーカの0.3秒連射をこのゲートが呑み込まないように。Step4d)
	local wc = Config.Weapons[key]
	local gate = math.min(0.25, (wc and wc.Cooldown) or 0.25)
	if os.clock() - lastFire < gate then
		return
	end
	lastFire = os.clock()
	fireRemote:FireServer(key, targetPos)
end

-- 連射を止める。ループは firingToken の不一致で自然に終了する
local function stopFiring()
	firingToken += 1
end

-- 連射を開始する。aimFn は呼ぶたびに現在の狙点を返す関数
-- (押したまま照準を動かすと爆発がなぞるように移動するのはこのため。Step4d)。
-- AutoFireが真の武器だけCooldown間隔でループし、それ以外は1発撃って終わる
local function startFiring(aimFn)
	stopFiring() -- 前のループを必ず止めてから開始する(二重ループの防止)
	local tool = equippedTool
	if not tool then
		return
	end
	local key = tool:GetAttribute("WeaponKey")
	local wc = key and Config.Weapons[key]
	if not wc then
		return
	end
	tryFire(aimFn())
	if not wc.AutoFire then
		return -- 単発武器(エアストライク・リモート爆弾)はここで終わり
	end

	local token = firingToken
	task.spawn(function()
		while firingToken == token do
			task.wait(wc.Cooldown)
			if firingToken ~= token
				or roundState ~= "BATTLE"
				or not player.Character
				or equippedTool ~= tool then
				break
			end
			tryFire(aimFn())
		end
	end)
end

-- モバイル発射ボタン用の狙点: 画面中央=カメラの向いている先
local function aimCameraCenter()
	local origin = camera.CFrame.Position
	local dir = camera.CFrame.LookVector
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	local result = workspace:Raycast(origin, dir * 1000, params)
	return if result then result.Position else origin + dir * 500
end

--------------------------------------------------------------------
-- 武器切替
--------------------------------------------------------------------
local function findTool(key)
	for _, container in { player:FindFirstChild("Backpack"), player.Character } do
		if container then
			for _, tool in container:GetChildren() do
				if tool:IsA("Tool") and tool:GetAttribute("WeaponKey") == key then
					return tool
				end
			end
		end
	end
	return nil
end

local function equipWeapon(key)
	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	stopFiring() -- 武器を切り替えたら連射中でも必ず止める(Step4d §5-1)
	-- 装備中の武器をもう一度選んだら、しまう(標準ツールバーと同じ挙動)
	if equippedTool and equippedTool:GetAttribute("WeaponKey") == key then
		humanoid:UnequipTools()
		return
	end
	local tool = findTool(key)
	if tool then
		humanoid:EquipTool(tool)
	end
end

--------------------------------------------------------------------
-- ツール装備の監視(装備が変わったらUIへ通知)
--------------------------------------------------------------------
-- PCでのマウス照準: 押したまま照準を動かせるよう、呼ぶたびに現在位置を取り直す
local function aimMouse()
	return mouse.Hit.Position
end

local function onCharacter(char)
	stopFiring() -- 前のキャラクターに紐づく連射ループを必ず止める
	equippedTool = nil
	events.WeaponSelected:Fire(nil)
	char.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and child:GetAttribute("WeaponKey") then
			equippedTool = child
			events.WeaponSelected:Fire(child:GetAttribute("WeaponKey"))
			if not hooked[child] then
				hooked[child] = true
				-- クリック/タップで連射開始、離す・ツールが外れたら停止(照準はマウス位置=タッチ位置)
				child.Activated:Connect(function()
					startFiring(aimMouse)
				end)
				child.Deactivated:Connect(stopFiring)
				child.Unequipped:Connect(stopFiring)
			end
		end
	end)
	char.ChildRemoved:Connect(function(child)
		if child == equippedTool then
			stopFiring()
			equippedTool = nil
			events.WeaponSelected:Fire(nil)
		end
	end)
end

if player.Character then
	onCharacter(player.Character)
end
player.CharacterAdded:Connect(onCharacter)
player.CharacterRemoving:Connect(stopFiring)

--------------------------------------------------------------------
-- キーボード入力(1/2/3 = 武器切替、F = 起爆)
--------------------------------------------------------------------
-- Config の SlotKey(1〜3)をキーコードに対応付ける
local SLOT_KEYCODES = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three }
local keyToWeapon = {}
for _, weaponKey in Config.WeaponOrder do
	local slot = Config.Weapons[weaponKey].SlotKey
	if SLOT_KEYCODES[slot] then
		keyToWeapon[SLOT_KEYCODES[slot]] = weaponKey
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if keyToWeapon[input.KeyCode] then
		equipWeapon(keyToWeapon[input.KeyCode])
	elseif input.KeyCode == Enum.KeyCode.F then
		actionRemote:FireServer("Detonate")
	end
end)

--------------------------------------------------------------------
-- UIControllerからの依頼(ボタン類はすべてUIController側で描画)
--------------------------------------------------------------------
events.EquipRequest.Event:Connect(equipWeapon)
events.FireRequest.Event:Connect(function()
	startFiring(aimCameraCenter)
end)
events.FireRelease.Event:Connect(stopFiring)
events.DetonateRequest.Event:Connect(function()
	actionRemote:FireServer("Detonate")
end)
