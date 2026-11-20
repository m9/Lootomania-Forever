local _, ns = ...

-- World map pins for item sources.
--   ns.Pins.Show(source, itemId)  opens the map on the source's first spot and pins its spots
--   ns.Pins.Clear()               drops the pins of Show
--   ns.Pins.Refresh()
-- Pins of tracked items show on any open map (setting).
--
-- Pins are plain frames on the map canvas, placed from our own OnUpdate while the map is
-- open. No data provider, no hook on the map: both put addon code in the map's show and
-- hide path, which can taint it.

local UI = ns.UI
local C = UI.C
local Pins = {}
ns.Pins = Pins

local SIZE = 22
local MAX_SHOWN = 80 -- spots of the source given to Show
local MAX_TRACKED = 12 -- spots per tracked item
local MAX_PINS = 240
local ROUND = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

ns.Main.AddOption({ group = "Map", key = "pinsTracked", kind = "check", label = "Tracked items on map", default = true })
ns.Main.AddOption({ group = "Map", key = "pinScale", kind = "slider", label = "Pin size", min = 50, max = 200, step = 10,
	format = "%d%%", default = 100 })

local shown -- { source =, item = } from Show
local shownSeen = false
local list = {} -- { spot, source, item }
local frames = {}
local used = 0
local dirty = true
local placedMap, placedScale
local driver

-- Pin list ----------------------------------------------------------------------------

local function Add(source, item, max, have)
	local spots = type(source) == "table" and source.spots
	if type(spots) ~= "table" then return end
	for i = 1, math.min(#spots, max) do
		local spot = spots[i]
		if #list >= MAX_PINS then return end
		if type(spot) == "table" and spot.map and spot.x and spot.y then
			local key = ("%s:%s:%.1f:%.1f"):format(tostring(item), spot.map, spot.x, spot.y)
			if not have[key] then
				have[key] = true
				list[#list + 1] = { spot = spot, source = source, item = item }
			end
		end
	end
end

local function BuildList()
	list = {}
	local have = {}
	if shown then Add(shown.source, shown.item, MAX_SHOWN, have) end
	local Gear = ns.Gear
	if ns.db and ns.db.pinsTracked and Gear and Gear.Tracked and Gear.Sources then
		for _, id in ipairs(Gear.Tracked() or {}) do
			local sources = Gear.Sources(id)
			if sources and sources[1] then Add(sources[1], id, MAX_TRACKED, have) end
		end
	end
end

-- Map ---------------------------------------------------------------------------------

local function Map()
	local map = _G.WorldMapFrame
	if map and map.IsShown and map:IsShown() and map.GetCanvas and map.GetMapID then return map end
	return nil
end

-- A frame on the canvas that hides with the map taints the gamepad's focus clear.
local function Gamepad()
	local get = (C_CVar and C_CVar.GetCVar) or GetCVar
	if not get then return false end
	local ok, style = pcall(get, "InputDeviceInterfaceStyle")
	if not ok or style == nil then return false end
	style = tostring(style):lower()
	return style == "1" or style:find("gamepad", 1, true) ~= nil
end

local function XY(v)
	if type(v) ~= "table" then return nil end
	local x, y
	if v.GetXY then x, y = v:GetXY() else x, y = v.x, v.y end
	if type(x) ~= "number" or type(y) ~= "number" then return nil end
	return x, y
end

-- Where a spot falls on the open map, 0-1. Nil when it is not on it.
local function Project(spot, mapId)
	local x, y = spot.x / 100, spot.y / 100
	if spot.map == mapId then return x, y end
	if not (C_Map and C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
	local ok, continent, world = pcall(C_Map.GetWorldPosFromMapPos, spot.map, CreateVector2D(x, y))
	if not ok or not continent or not world then return nil end
	local ok2, first, second = pcall(C_Map.GetMapPosFromWorldPos, continent, world, mapId)
	if not ok2 then return nil end
	local mx, my = XY(second)
	if not mx then mx, my = XY(first) end
	if not mx or mx < 0 or my < 0 or mx > 1 or my > 1 then return nil end
	return mx, my
end

-- Only zone, dungeon and continent maps take pins from other maps.
local function TakesOthers(mapId)
	local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapId)
	local kind = info and info.mapType
	return kind == nil or kind >= 2
end

-- Pin frames --------------------------------------------------------------------------

local function ItemName(id)
	if ns.Gear and ns.Gear.Name then
		local name, quality = ns.Gear.Name(id)
		if name then return name, quality end
	end
	local item = ns.Gear and ns.Gear.Item and ns.Gear.Item(id)
	if item and item.name then return item.name, item.quality end
	local name, _, quality = C_Item.GetItemInfo(id)
	return name or ("Item " .. tostring(id)), quality
end

local function Tooltip(self)
	local pin = self.pin
	if not pin then return end
	local source = pin.source
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if pin.item then
		local name, quality = ItemName(pin.item)
		local c = UI.QUALITY[quality or 1] or C.TEXT
		GameTooltip:SetText(name, c[1], c[2], c[3])
	else
		GameTooltip:SetText(source.name or "Source", C.GOLD[1], C.GOLD[2], C.GOLD[3])
	end
	local text = source.text or source.name
	if text then GameTooltip:AddLine(text, C.TEXT[1], C.TEXT[2], C.TEXT[3], true) end
	if source.chance then
		GameTooltip:AddLine(("Chance: %s%%"):format(tostring(source.chance)), C.MUTED[1], C.MUTED[2], C.MUTED[3])
	end
	GameTooltip:AddLine(("Spot: %.1f, %.1f"):format(pin.spot.x, pin.spot.y), C.MUTED[1], C.MUTED[2], C.MUTED[3])
	GameTooltip:AddLine("Click: guide", C.GOLD_SOFT[1], C.GOLD_SOFT[2], C.GOLD_SOFT[3])
	GameTooltip:Show()
end

local function Click(self, button)
	local pin = self.pin
	if not pin or button ~= "LeftButton" or not ns.Guide then return end
	local source = pin.source
	ns.Guide.Set(pin.spot, source.name or source.text, pin.item)
end

local function NewPin(canvas)
	-- a Frame, not a Button: a button is a gamepad focus target
	local f = CreateFrame("Frame", nil, canvas)
	f:SetSize(SIZE, SIZE)
	f:SetFrameLevel(math.min((canvas:GetFrameLevel() or 1) + 2100, 9000))
	f.ring = f:CreateTexture(nil, "BACKGROUND")
	f.ring:SetAllPoints()
	f.icon = f:CreateTexture(nil, "ARTWORK")
	f.icon:SetPoint("TOPLEFT", 2, -2)
	f.icon:SetPoint("BOTTOMRIGHT", -2, 2)
	f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	-- round when the client has masks, else a gold square
	local round = false
	if f.CreateMaskTexture and f.icon.AddMaskTexture then
		round = pcall(function()
			local mask = f:CreateMaskTexture()
			mask:SetTexture(ROUND, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
			mask:SetAllPoints(f.icon)
			f.icon:AddMaskTexture(mask)
		end)
	end
	if round then
		f.ring:SetTexture(ROUND)
		f.ring:SetVertexColor(C.GOLD[1], C.GOLD[2], C.GOLD[3], 1)
	else
		f.ring:SetColorTexture(C.GOLD[1], C.GOLD[2], C.GOLD[3], 1)
	end
	f:EnableMouse(true)
	f:SetScript("OnEnter", Tooltip)
	f:SetScript("OnLeave", UI.HideTooltip)
	f:SetScript("OnMouseUp", Click)
	return f
end

local function HideAll()
	for i = 1, used do
		frames[i]:Hide()
		frames[i].pin = nil
	end
	used = 0
end

local function Scale(map)
	local canvas = map.GetCanvasScale and map:GetCanvasScale()
	if type(canvas) ~= "number" or canvas <= 0 then canvas = 1 end
	return (ns.db.pinScale or 100) / 100 / canvas
end

local function Position(f, canvas, scale)
	f:SetScale(scale)
	f:ClearAllPoints()
	-- offsets are in the pin's own scale
	f:SetPoint("CENTER", canvas, "TOPLEFT", canvas:GetWidth() * f.x / scale, -canvas:GetHeight() * f.y / scale)
end

local function Place(map)
	local mapId = map:GetMapID()
	local canvas = map:GetCanvas()
	HideAll()
	placedMap, placedScale, dirty = mapId, Scale(map), false
	if not mapId or not canvas or Gamepad() then return end
	if shown then shownSeen = true end
	BuildList()
	local others = TakesOthers(mapId)
	for i = 1, #list do
		local pin = list[i]
		local x, y
		if pin.spot.map == mapId or others then x, y = Project(pin.spot, mapId) end
		if x then
			used = used + 1
			local f = frames[used]
			if not f then
				f = NewPin(canvas)
				frames[used] = f
			end
			f.pin, f.x, f.y = pin, x, y
			f.icon:SetTexture(pin.item and C_Item.GetItemIconByID(pin.item) or 134400)
			Position(f, canvas, placedScale)
			f:Show()
		end
	end
end

local function Tick()
	local map = Map()
	if not map then
		-- the pins of Show last until the map closes
		if shownSeen then
			shown, shownSeen, dirty = nil, false, true
		end
		placedMap = nil
		return
	end
	local mapId = map:GetMapID()
	if dirty or mapId ~= placedMap then
		Place(map)
		return
	end
	local scale = Scale(map)
	if math.abs(scale - (placedScale or 0)) > 0.0001 then
		placedScale = scale
		local canvas = map:GetCanvas()
		for i = 1, used do Position(frames[i], canvas, scale) end
	end
end

-- Public ------------------------------------------------------------------------------

function Pins.Refresh()
	dirty = true
end

function Pins.Clear()
	shown, shownSeen, dirty = nil, false, true
end

local function OpenMap(mapId)
	if InCombatLockdown and InCombatLockdown() then
		ns.Print("In combat. Open the map later.")
		return
	end
	if C_Map and C_Map.OpenWorldMap and pcall(C_Map.OpenWorldMap, mapId) then return end
	if OpenWorldMap and pcall(OpenWorldMap, mapId) then return end
	local map = _G.WorldMapFrame
	if not map then return end
	if not map:IsShown() and ToggleWorldMap then pcall(ToggleWorldMap) end
	if map.SetMapID then pcall(map.SetMapID, map, mapId) end
end

function Pins.Show(source, itemId)
	local spot = type(source) == "table" and type(source.spots) == "table" and source.spots[1]
	if not spot or not spot.map then
		ns.Print("No spot known.")
		return false
	end
	shown, shownSeen, dirty = { source = source, item = itemId }, false, true
	OpenMap(spot.map)
	return true
end

ns.Listen("HUNTS_CHANGED", Pins.Refresh)
ns.Listen("SETTINGS_CHANGED", function(key)
	if key == "pinsTracked" or key == "pinScale" then Pins.Refresh() end
end)

ns.OnLoad(function()
	driver = CreateFrame("Frame")
	driver:SetScript("OnUpdate", function() ns.Safe(Tick) end)
end)
