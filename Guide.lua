local _, ns = ...

-- Guide: a waypoint and an arrow to one spot.
--   ns.Guide.Set(spot, label, itemId)   spot = { map = uiMapId, x =, y = }, x and y in 0-100.
--                                       A Gear source (a table with .spots) works too.
--   ns.Guide.SetSource(source, itemId)  nearest spot of a source
--   ns.Guide.Clear()
--   ns.Guide.Target()                   { map, x, y, label, item } or nil
--   ns.Guide.Measure(spot)              yards, bearing (radians, 0 north, counterclockwise) or nil
--   ns.Guide.Nearest(spots)             spot, yards (yards is nil when it cannot be measured)
--   ns.Guide.Hint(spot)                 "120 yd NE" or nil
-- Sends "GUIDE_CHANGED".

local UI = ns.UI
local C = UI.C
local Guide = {}
ns.Guide = Guide

local ARRIVE_YARDS = 12
local SAMPLE = 0.5 -- seconds between position reads
local ARROW = "Interface\\Minimap\\MiniMap-QuestArrow" -- points up

ns.Main.AddOption({ group = "Map", key = "guideArrow", kind = "check", label = "Guide arrow", default = true })

local target -- { map, x, y, label, item }
local way -- { tomtom = uid } or { user = true }
local frame, driver

-- Positions ---------------------------------------------------------------------------

local vector

local function Vector(x, y)
	if not CreateVector2D then return nil end
	if vector and vector.SetXY then
		vector:SetXY(x, y)
		return vector
	end
	vector = CreateVector2D(x, y)
	return vector
end

local function XY(v)
	if type(v) ~= "table" then return nil end
	local x, y
	if v.GetXY then x, y = v:GetXY() else x, y = v.x, v.y end
	x, y = ns.Plain(x), ns.Plain(y)
	if type(x) ~= "number" or type(y) ~= "number" then return nil end
	return x, y
end

-- World position of a map point: continent, north, west (yards).
local function World(map, x, y)
	if not (C_Map and C_Map.GetWorldPosFromMapPos) then return nil end
	local v = Vector(x, y)
	if not v then return nil end
	local ok, continent, pos = pcall(C_Map.GetWorldPosFromMapPos, map, v)
	if not ok or not continent or not pos then return nil end
	local north, west = XY(pos)
	if not north then return nil end
	return continent, north, west
end

-- The player's place on a map, 0-1. Nil in instances.
local function PlayerOn(map)
	if not (map and C_Map and C_Map.GetPlayerMapPosition) then return nil end
	local ok, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
	if not ok or not pos then return nil end
	local x, y = XY(pos)
	if not x or (x == 0 and y == 0) then return nil end
	return x, y
end

function Guide.PlayerMap()
	if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
	local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
	return ok and ns.Plain(map) or nil
end

function Guide.Measure(spot)
	if type(spot) ~= "table" or not (spot.map and spot.x and spot.y) then return nil end
	local px, py = PlayerOn(spot.map)
	if not px then return nil end
	local c1, n1, w1 = World(spot.map, px, py)
	if not c1 then return nil end
	local c2, n2, w2 = World(spot.map, spot.x / 100, spot.y / 100)
	if not c2 or c1 ~= c2 then return nil end
	local north, west = n2 - n1, w2 - w1
	return math.sqrt(north * north + west * west), math.atan2(west, north)
end

function Guide.Nearest(spots)
	if type(spots) ~= "table" or not spots[1] then return nil end
	local best, bestYards
	for i = 1, #spots do
		local yards = Guide.Measure(spots[i])
		if yards and (not bestYards or yards < bestYards) then best, bestYards = spots[i], yards end
	end
	return best or spots[1], bestYards
end

local COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

local function Yards(yards)
	return ("%d yd"):format(yards + 0.5)
end

function Guide.Hint(spot)
	local yards, bearing = Guide.Measure(spot)
	if not yards then return nil end
	local degrees = (-math.deg(bearing)) % 360
	return Yards(yards) .. " " .. COMPASS[math.floor((degrees + 22.5) / 45) % 8 + 1]
end

-- Waypoint ----------------------------------------------------------------------------

local function PlaceWaypoint()
	local t = target
	way = nil
	if not t then return end
	if TomTom and TomTom.AddWaypoint then
		local ok, uid = pcall(TomTom.AddWaypoint, TomTom, t.map, t.x / 100, t.y / 100,
			{ title = t.label, from = "Lootomania", persistent = false, crazy = true })
		if ok and uid then
			way = { tomtom = uid }
			return
		end
	end
	if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then return end
	if C_Map.CanSetUserWaypointOnMap then
		local ok, can = pcall(C_Map.CanSetUserWaypointOnMap, t.map)
		if not ok or not can then return end
	end
	local ok = pcall(function()
		C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(t.map, t.x / 100, t.y / 100))
	end)
	if not ok then return end
	way = { user = true, map = t.map, x = t.x / 100, y = t.y / 100 }
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
		pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
	end
end

-- True when the map pin is still the one we set (the player may have moved it).
local function PinIsOurs()
	if not (C_Map and C_Map.GetUserWaypoint) then return true end
	local ok, point = pcall(C_Map.GetUserWaypoint)
	if not ok then return true end
	if type(point) ~= "table" then return false end
	local x, y = XY(point.position)
	if not x then return true end
	return point.uiMapID == way.map and math.abs(x - way.x) < 0.002 and math.abs(y - way.y) < 0.002
end

local function RemoveWaypoint()
	local w = way
	way = nil
	if not w then return end
	if w.tomtom then
		if TomTom and TomTom.RemoveWaypoint then pcall(TomTom.RemoveWaypoint, TomTom, w.tomtom) end
		return
	end
	way = w
	local ours = PinIsOurs()
	way = nil
	if ours and C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
end

-- Arrow -------------------------------------------------------------------------------

local function Build()
	frame = UI.Box(UIParent, C.BLACK, 0.85, C.GOLD_DIM)
	frame:SetSize(170, 44)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	local saved = ns.db.windows.Guide
	if saved and saved.x then
		frame:SetPoint(saved.point or "CENTER", UIParent, saved.point or "CENTER", saved.x, saved.y)
	else
		frame:SetPoint("TOP", UIParent, "TOP", 0, -150)
	end
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint(1)
		ns.db.windows.Guide = { point = point, x = x, y = y }
	end)
	frame:SetScript("OnMouseUp", function(_, button)
		if button == "RightButton" then Guide.Clear() end
	end)
	frame:SetScript("OnEnter", function(self)
		UI.TextTooltip(self, target and target.label or "Guide", { "Drag: move", "Right-click: clear" })
	end)
	frame:SetScript("OnLeave", UI.HideTooltip)

	frame.arrow = frame:CreateTexture(nil, "ARTWORK")
	frame.arrow:SetTexture(ARROW)
	frame.arrow:SetSize(34, 34)
	frame.arrow:SetPoint("LEFT", 5, 0)
	frame.arrow:SetVertexColor(C.GOLD[1], C.GOLD[2], C.GOLD[3])

	frame.label = UI.Text(frame, "GameFontNormalSmall", C.GOLD)
	frame.label:SetPoint("TOPLEFT", 44, -7)
	frame.label:SetPoint("RIGHT", -6, 0)
	frame.distance = UI.Text(frame, "GameFontHighlightSmall", C.TEXT)
	frame.distance:SetPoint("BOTTOMLEFT", 44, 7)
	frame:Hide()
end

local bearing -- last measured, for turning the arrow between samples

local function Facing()
	if not GetPlayerFacing then return nil end
	local ok, facing = pcall(GetPlayerFacing)
	facing = ok and ns.Plain(facing) or nil
	return type(facing) == "number" and facing or nil
end

local function Turn()
	if not (frame and frame:IsShown() and bearing) then return end
	local facing = Facing()
	if not facing then
		frame.arrow:Hide()
		return
	end
	frame.arrow:Show()
	frame.arrow:SetRotation(bearing - facing)
end

-- Reads the position: arrival, arrow text.
local function Sample()
	if not target then return end
	local yards, angle = Guide.Measure(target)
	if yards and yards < ARRIVE_YARDS then
		ns.Print("Arrived: " .. target.label)
		Guide.Clear()
		return
	end
	bearing = angle
	local show = yards and ns.db.guideArrow and not (way and way.tomtom)
	if not show then
		if frame then frame:Hide() end
		return
	end
	if not frame then Build() end
	frame.label:SetText(target.label)
	frame.distance:SetText(Yards(yards))
	frame:Show()
	Turn()
end

local function Drive(on)
	if not driver then
		if not on then return end
		driver = CreateFrame("Frame")
	end
	if not on then
		driver:SetScript("OnUpdate", nil)
		return
	end
	local wait = 0
	driver:SetScript("OnUpdate", function(_, elapsed)
		wait = wait - elapsed
		if wait <= 0 then
			wait = SAMPLE
			ns.Safe(Sample)
		else
			Turn()
		end
	end)
end

-- Public ------------------------------------------------------------------------------

function Guide.Target()
	return target
end

function Guide.Clear()
	if not target then return end
	RemoveWaypoint()
	target, bearing = nil, nil
	if ns.char then ns.char.guide = nil end
	Drive(false)
	if frame then frame:Hide() end
	ns.Send("GUIDE_CHANGED", nil)
end

function Guide.SetSource(source, itemId, label)
	if type(source) ~= "table" then return false end
	local spot = Guide.Nearest(source.spots)
	if not spot then return false end
	return Guide.Set(spot, label or source.name or source.text, itemId)
end

function Guide.Set(spot, label, itemId)
	if type(spot) ~= "table" then return false end
	if spot.spots then return Guide.SetSource(spot, itemId, label) end
	if not (tonumber(spot.map) and tonumber(spot.x) and tonumber(spot.y)) then return false end
	RemoveWaypoint()
	target = { map = spot.map, x = spot.x, y = spot.y, label = label or "Target", item = itemId }
	if ns.char then ns.char.guide = target end
	PlaceWaypoint()
	Drive(true)
	ns.Safe(Sample)
	if target then ns.Send("GUIDE_CHANGED", target) end -- nil: already there, cleared
	return true
end

ns.Listen("SETTINGS_CHANGED", function(key)
	if key == "guideArrow" then ns.Safe(Sample) end
end)

-- The target outlives a reload. TomTom is ready a moment after login.
ns.OnLoad(function()
	local saved = ns.char.guide
	if type(saved) ~= "table" or not (saved.map and saved.x and saved.y) then
		ns.char.guide = nil
		return
	end
	C_Timer.After(2, function()
		if not target and ns.char.guide == saved then Guide.Set(saved, saved.label, saved.item) end
	end)
end)

ns.Command("guide", "Clear the guide", function()
	if target then
		Guide.Clear()
		ns.Print("Guide: off")
	else
		ns.Print("Guide: no target")
	end
end)
