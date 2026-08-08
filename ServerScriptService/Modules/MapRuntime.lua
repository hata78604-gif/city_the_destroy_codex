--------------------------------------------------------------------
-- 配置場所: ServerScriptService/Modules
-- Studio上の名前: MapRuntime
-- 種別: ModuleScript
--
-- 固定MAPのラウンド単位ロードと、破壊処理用メタデータの構築を担当する。
-- 原本はStudio側で ServerStorage.FixedMapTemplate に手動配置する。
--------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")

local MapRuntime = {}

local ROTATION_EPSILON = 0.0001

local function requireChild(parent, name, className)
	local child = parent:FindFirstChild(name)
	if not child then
		error(("[MapRuntime] %s.%s が見つかりません"):format(parent:GetFullName(), name))
	end
	if className and not child:IsA(className) then
		error(("[MapRuntime] %s は %s である必要があります (実際: %s)")
			:format(child:GetFullName(), className, child.ClassName))
	end
	return child
end

-- 既存workspace.Mapを消す前に、原本と最低限の構造をすべて検証する。
local function validateTemplate()
	local template = ServerStorage:FindFirstChild("FixedMapTemplate")
	if not template then
		error("[MapRuntime] ServerStorage.FixedMapTemplate が見つかりません")
	end
	if not template:IsA("Model") and not template:IsA("Folder") then
		error(("[MapRuntime] FixedMapTemplate は Model または Folder である必要があります (実際: %s)")
			:format(template.ClassName))
	end
	if not template.Archivable then
		error("[MapRuntime] FixedMapTemplate.Archivable が false のためCloneできません")
	end

	requireChild(template, "Buildings", "Folder")
	requireChild(template, "StaticGeometry", "Folder")
	local metadata = requireChild(template, "Metadata", "Folder")
	local mapBounds = requireChild(metadata, "MapBounds", "BasePart")
	local orientation = mapBounds.Orientation
	if math.abs(orientation.X) > ROTATION_EPSILON
		or math.abs(orientation.Y) > ROTATION_EPSILON
		or math.abs(orientation.Z) > ROTATION_EPSILON then
		error(("[MapRuntime] Metadata.MapBounds は回転不可です。Orientationを0, 0, 0にしてください (現在: %.3f, %.3f, %.3f)")
			:format(orientation.X, orientation.Y, orientation.Z))
	end

	return template
end

local function includePartBounds(part, bounds)
	local half = part.Size / 2
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local corner = part.CFrame:PointToWorldSpace(Vector3.new(
					half.X * sx,
					half.Y * sy,
					half.Z * sz
				))
				bounds.minX = math.min(bounds.minX, corner.X)
				bounds.maxX = math.max(bounds.maxX, corner.X)
				bounds.minY = math.min(bounds.minY, corner.Y)
				bounds.maxY = math.max(bounds.maxY, corner.Y)
				bounds.minZ = math.min(bounds.minZ, corner.Z)
				bounds.maxZ = math.max(bounds.maxZ, corner.Z)
			end
		end
	end
end

local function prepareBuilding(model, buildingId)
	model:SetAttribute("BuildingId", buildingId)

	local partBounds = {
		minX = math.huge,
		maxX = -math.huge,
		minY = math.huge,
		maxY = -math.huge,
		minZ = math.huge,
		maxZ = -math.huge,
	}
	local partCount = 0
	local destructibleCount = 0

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			partCount += 1
			includePartBounds(descendant, partBounds)

			if descendant:GetAttribute("Indestructible") == true then
				CollectionService:RemoveTag(descendant, "Destructible")
				descendant:SetAttribute("BuildingId", nil)
			else
				CollectionService:AddTag(descendant, "Destructible")
				descendant:SetAttribute("BuildingId", buildingId)
				destructibleCount += 1
			end
		end
	end

	local center = model:GetPivot().Position
	if partCount > 0 then
		center = Vector3.new(
			(partBounds.minX + partBounds.maxX) / 2,
			(partBounds.minY + partBounds.maxY) / 2,
			(partBounds.minZ + partBounds.maxZ) / 2
		)
	end

	local configuredBaseY = model:GetAttribute("BaseY")
	local baseY
	if typeof(configuredBaseY) == "number" then
		baseY = configuredBaseY
	elseif partCount > 0 then
		if configuredBaseY ~= nil then
			warn(("[MapRuntime] %s のBaseY属性が数値ではないため自動計算します"):format(model:GetFullName()))
		end
		baseY = partBounds.minY
	else
		warn(("[MapRuntime] %s にBasePartが無いため、BaseYにModelのPivot Yを使用します")
			:format(model:GetFullName()))
		baseY = center.Y
	end
	model:SetAttribute("BaseY", baseY)

	if destructibleCount == 0 then
		warn(("[MapRuntime] %s に破壊可能なBasePartがありません"):format(model:GetFullName()))
	end

	return {
		name = model.Name,
		total = destructibleCount,
		destroyed = 0,
		bonusGiven = false,
		center = center,
	}
end

local function prepareBuildings(buildingsFolder)
	local models = {}
	for _, child in buildingsFolder:GetChildren() do
		if child:IsA("Model") then
			table.insert(models, child)
		else
			warn(("[MapRuntime] Buildings直下の%sはModelではないため建物集計から除外します")
				:format(child:GetFullName()))
		end
	end
	table.sort(models, function(a, b)
		return a.Name < b.Name
	end)

	local buildings = {}
	for buildingId, model in ipairs(models) do
		buildings[buildingId] = prepareBuilding(model, buildingId)
	end
	return buildings
end

local function readBounds(mapBounds)
	-- Phase 1では回転なしを検証済み。PositionとSizeだけからAABBを作る。
	local half = mapBounds.Size / 2
	local position = mapBounds.Position
	return {
		minX = position.X - half.X,
		maxX = position.X + half.X,
		minZ = position.Z - half.Z,
		maxZ = position.Z + half.Z,
	}
end

function MapRuntime.LoadRound()
	local template = validateTemplate()

	-- 原本が正常であることを確認できた後でだけ、前ラウンドのMAPを削除する。
	local oldMap = workspace:FindFirstChild("Map")
	if oldMap then
		oldMap:Destroy()
	end

	local map = template:Clone()
	map.Name = "Map"
	map.Parent = workspace

	local buildingsFolder = requireChild(map, "Buildings", "Folder")
	local metadata = requireChild(map, "Metadata", "Folder")
	local mapBounds = requireChild(metadata, "MapBounds", "BasePart")
	mapBounds.Anchored = true
	mapBounds.CanCollide = false
	mapBounds.CanTouch = false
	mapBounds.CanQuery = false
	mapBounds.Transparency = 1

	local buildings = prepareBuildings(buildingsFolder)
	local bounds = readBounds(mapBounds)

	print(("[MapRuntime] 固定MAPをロードしました: 建物 %d棟 / bounds X[%.1f, %.1f] Z[%.1f, %.1f]")
		:format(#buildings, bounds.minX, bounds.maxX, bounds.minZ, bounds.maxZ))

	return {
		map = map,
		buildings = buildings,
		bounds = bounds,
	}
end

return MapRuntime
