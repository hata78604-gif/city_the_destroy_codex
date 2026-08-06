--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: TemplateValidator
-- 種別: ModuleScript
--
-- ReplicatedStorage/BuildingTemplates に置かれた手作り建物モデルを
-- 起動時に一度だけ検証する。問題は分かりやすい日本語の警告で知らせ、
-- 直せるものは自動補正する(エラーでゲームを止めない):
--   ・Model でなければスキップ
--   ・PrimaryPart 未設定 → 最下部のパーツを自動設定
--   ・Script / LocalScript / ModuleScript → 削除(Toolbox由来の不正スクリプト対策)
--   ・Humanoid などの余計なインスタンス → 削除
--   ・パーツが少なすぎる / 大きすぎるパーツ → 警告のみ
--------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local TemplateValidator = {}
local cache = nil -- 検証は起動時の1回だけ。以降は結果を使い回す

-- Config.Handmade が無い場合(Configの貼り替え漏れ)でも既定値で動かす
local rules = Config.Handmade or {
	FolderName = "BuildingTemplates",
	MinParts = 10,
	MaxPartSize = 8,
}

--------------------------------------------------------------------
-- モデル1つを検証する。使えるなら { model, name, partCount } を返す
--------------------------------------------------------------------
local function validateModel(model)
	if not model:IsA("Model") then
		warn(("[TemplateValidator] %s: Model ではないためスキップします。"
			.. "パーツを全選択して右クリック→「グループ化(Model)」してください"):format(model.Name))
		return nil
	end

	local warnings = {}
	local parts = {}
	local lowestPart, lowestY = nil, math.huge
	local oversized = 0

	for _, obj in model:GetDescendants() do
		if obj:IsA("BasePart") then
			table.insert(parts, obj)
			-- PrimaryPart 自動設定用に、いちばん低い(=土台らしい)パーツを覚えておく
			local bottom = obj.Position.Y - obj.Size.Y / 2
			if bottom < lowestY then
				lowestY = bottom
				lowestPart = obj
			end
			if math.max(obj.Size.X, obj.Size.Y, obj.Size.Z) > rules.MaxPartSize then
				oversized += 1
			end
		elseif obj:IsA("LuaSourceContainer") then
			-- Script / LocalScript / ModuleScript はすべて削除
			table.insert(warnings, ("スクリプト「%s」を削除しました"):format(obj.Name))
			obj:Destroy()
		elseif obj:IsA("Humanoid") then
			table.insert(warnings, "余計なインスタンス(Humanoid)を削除しました")
			obj:Destroy()
		end
	end

	if #parts == 0 then
		warn(("[TemplateValidator] %s: パーツが1つも無いためスキップします"):format(model.Name))
		return nil
	end

	-- PrimaryPart 未設定なら最下部のパーツを自動設定(接地計算に使う)
	if not model.PrimaryPart then
		model.PrimaryPart = lowestPart
		table.insert(warnings,
			("PrimaryPart が未設定のため、最下部のパーツ「%s」を自動設定しました"):format(lowestPart.Name))
	end

	if #parts < rules.MinParts then
		table.insert(warnings,
			("パーツが %d 個しかありません。壊す部分が少ないので、小さいブロックを積んで作るのがおすすめです"):format(#parts))
	end
	if oversized > 0 then
		table.insert(warnings,
			("%d stud を超える大きなパーツが %d 個あります。大きなパーツは崩れる楽しさが減ります"):format(rules.MaxPartSize, oversized))
	end

	-- 検証結果のログ(総パーツ数6,000の管理用にパーツ数も出す)
	if #warnings == 0 then
		print(("[TemplateValidator] %s: OK (パーツ %d個)"):format(model.Name, #parts))
	else
		warn(("[TemplateValidator] %s: 警告あり (パーツ %d個) - %s")
			:format(model.Name, #parts, table.concat(warnings, " / ")))
	end

	return { model = model, name = model.Name, partCount = #parts }
end

--------------------------------------------------------------------
-- 使用可能なテンプレートの一覧を返す(初回のみ検証、以降キャッシュ)
--------------------------------------------------------------------
function TemplateValidator.GetValidTemplates()
	if cache then
		return cache
	end
	cache = {}

	local folder = ReplicatedStorage:FindFirstChild(rules.FolderName)
	if not folder then
		print(("[TemplateValidator] %s フォルダが無いため、手作り建物なしで進めます(登録方法はSETUP.md参照)")
			:format(rules.FolderName))
		return cache
	end

	for _, child in folder:GetChildren() do
		local entry = validateModel(child)
		if entry then
			table.insert(cache, entry)
		end
	end
	print(("[TemplateValidator] 検証完了: 使用可能な手作りテンプレート %d 個"):format(#cache))
	return cache
end

return TemplateValidator
