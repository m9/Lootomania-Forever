local _, ns = ...

-- Play-style filters for the upgrade lists. Saved per character:
--   ns.char.filters = {
--     on    = { presetKey = true },   -- active presets
--     kinds = { kind = false },       -- source kinds that are hidden
--     zone  = "Zone name" or nil,     -- focus zone; nil: the zone the player is in
--   }
-- Gear.List asks ns.Filters.Pass for every candidate. Sends "FILTERS_CHANGED".

local UI = ns.UI
local C = UI.C
local F = {}
ns.Filters = F

ns.Defaults({ filters = { on = {}, kinds = {} } }, "char")

F.PRESETS = {
	{ key = "noDungeons", label = "No dungeons", tip = "Hide dungeon loot." },
	{ key = "noRaids", label = "No raids", tip = "Hide raid loot." },
	{ key = "dungeonsOnly", label = "Dungeons only", tip = "Only dungeon loot." },
	{ key = "buyOnly", label = "Buy only", tip = "Only vendor items." },
	{ key = "nearLevel", label = "Near my level", tip = "Hide quests and dungeons over 4 levels above me." },
	{ key = "noCraftBop", label = "No crafted BoP", tip = "Hide crafted items that bind on pickup." },
	{ key = "noEnemyCity", label = "No enemy cities", tip = "Hide sources in enemy cities." },
	{ key = "focusZone", label = "Zone", tip = "Only sources in one zone." },
}

-- Turning one on turns these off.
local EXCLUDES = {
	noDungeons = { "dungeonsOnly" },
	dungeonsOnly = { "noDungeons", "buyOnly" },
	buyOnly = { "dungeonsOnly" },
}

F.KINDS = { "boss", "drop", "rare", "object", "quest", "vendor", "craft", "world", "unknown" }
local KIND_LABEL = {
	boss = "Boss", drop = "Drop", rare = "Rare", object = "Object", quest = "Quest", vendor = "Vendor",
	craft = "Craft", world = "World", unknown = "Unknown",
}

local NEAR_LEVELS = 4

local RAID_MAPS = { [249] = true, [309] = true, [409] = true, [469] = true, [509] = true, [531] = true, [533] = true }
local RAID_NAMES = {
	["Molten Core"] = true, ["Onyxia's Lair"] = true, ["Blackwing Lair"] = true, ["Zul'Gurub"] = true,
	["Ruins of Ahn'Qiraj"] = true, ["Temple of Ahn'Qiraj"] = true, ["Ahn'Qiraj"] = true,
	["Ahn'Qiraj Temple"] = true, ["Naxxramas"] = true,
}

-- Cities by the faction that owns them.
local CITIES = {
	Alliance = { ["Stormwind City"] = true, ["Stormwind"] = true, ["Ironforge"] = true, ["Darnassus"] = true },
	Horde = { ["Orgrimmar"] = true, ["Thunder Bluff"] = true, ["Undercity"] = true },
}

-- Zones for the focus list, used when Gear has no zone list of its own.
local ZONES = {
	"Alterac Mountains", "Arathi Highlands", "Ashenvale", "Azshara", "Badlands", "Blasted Lands",
	"Burning Steppes", "Darkshore", "Darnassus", "Deadwind Pass", "Desolace", "Dun Morogh", "Durotar",
	"Duskwood", "Dustwallow Marsh", "Eastern Plaguelands", "Elwynn Forest", "Felwood", "Feralas",
	"Hillsbrad Foothills", "Ironforge", "Loch Modan", "Moonglade", "Mulgore", "Orgrimmar",
	"Redridge Mountains", "Searing Gorge", "Silithus", "Silverpine Forest", "Stonetalon Mountains",
	"Stormwind City", "Stranglethorn Vale", "Swamp of Sorrows", "Tanaris", "Teldrassil", "The Barrens",
	"The Hinterlands", "Thousand Needles", "Thunder Bluff", "Tirisfal Glades", "Un'Goro Crater",
	"Undercity", "Western Plaguelands", "Westfall", "Wetlands", "Winterspring",
	"Blackfathom Deeps", "Blackrock Depths", "Blackrock Spire", "Blackwing Lair", "Dire Maul", "Gnomeregan",
	"Maraudon", "Molten Core", "Naxxramas", "Onyxia's Lair", "Ragefire Chasm", "Razorfen Downs",
	"Razorfen Kraul", "Ruins of Ahn'Qiraj", "Scarlet Monastery", "Scholomance", "Shadowfang Keep",
	"Stratholme", "Temple of Ahn'Qiraj", "The Deadmines", "The Stockade", "The Temple of Atal'Hakkar",
	"Uldaman", "Wailing Caverns", "Zul'Farrak", "Zul'Gurub",
}

function F.Zones()
	local g = ns.Gear
	if g and type(g.Zones) == "function" then
		local ok, list = pcall(g.Zones)
		if ok and type(list) == "table" and #list > 0 then return list end
	end
	return ZONES
end

-- State ---------------------------------------------------------------------------------

local st -- the saved filters in a form that is quick to test

local function Saved()
	local f = ns.char and ns.char.filters
	if type(f) ~= "table" then return nil end
	if type(f.on) ~= "table" then f.on = {} end
	if type(f.kinds) ~= "table" then f.kinds = {} end
	return f
end

local function HereZone()
	local zone = GetRealZoneText and GetRealZoneText() or (GetZoneText and GetZoneText())
	zone = ns.Plain(zone)
	if type(zone) == "string" and zone ~= "" then return zone end
	return nil
end

local function HereMap()
	if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
	local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
	map = ok and ns.Plain(map) or nil
	return type(map) == "number" and map or nil
end

local function Compile()
	local f = Saved()
	if not f then
		st = nil
		return
	end
	local new = { any = false, kindOff = {} }
	for _, kind in ipairs(F.KINDS) do
		if f.kinds[kind] == false then
			new.kindOff[kind] = true
			new.any = true
		end
	end
	new.kindOff.container = new.kindOff.object
	for _, preset in ipairs(F.PRESETS) do
		if f.on[preset.key] then
			new[preset.key] = true
			new.any = true
		end
	end
	if new.focusZone then
		if type(f.zone) == "string" then
			new.zone = f.zone
		else
			new.zone, new.map = HereZone(), HereMap()
		end
	end
	st = new
end

local function Changed()
	Compile()
	ns.Send("FILTERS_CHANGED")
end

function F.Get(key)
	local f = Saved()
	return f and f.on[key] and true or false
end

function F.Set(key, on)
	local f = Saved()
	if not f then return end
	f.on[key] = on and true or nil
	if on then
		for _, other in ipairs(EXCLUDES[key] or {}) do f.on[other] = nil end
	end
	Changed()
end

function F.KindShown(kind)
	local f = Saved()
	return not (f and f.kinds[kind] == false)
end

function F.SetKind(kind, shown)
	local f = Saved()
	if not f then return end
	if shown then f.kinds[kind] = nil else f.kinds[kind] = false end
	Changed()
end

-- Focus zone by name; nil: the zone the player is in.
function F.SetZone(zone)
	local f = Saved()
	if not f then return end
	f.zone = type(zone) == "string" and zone ~= "" and zone or nil
	Changed()
end

function F.Zone()
	local f = Saved()
	return f and f.zone or nil
end

function F.Reset()
	local f = Saved()
	if not f then return end
	f.on, f.kinds, f.zone = {}, {}, nil
	Changed()
end

-- How many filters are on.
function F.Active()
	local f = Saved()
	local n = 0
	if not f then return n end
	for _ in pairs(f.on) do n = n + 1 end
	for _, shown in pairs(f.kinds) do
		if shown == false then n = n + 1 end
	end
	return n
end

-- Test ----------------------------------------------------------------------------------

local function IsRaid(s)
	if s.raid ~= nil then return s.raid and true or false end
	return RAID_MAPS[s.instMap] or RAID_NAMES[s.inst] or false
end

local function IsBop(entry)
	if entry.bind ~= nil then return entry.bind == 1 end
	local g = ns.Gear
	if not (g and g.Item and entry.id) then return false end
	local ok, item = pcall(g.Item, entry.id)
	return ok and type(item) == "table" and item.bind == 1 or false
end

local NO_SOURCE = { kind = "unknown" }
local ENEMY = { Alliance = "Horde", Horde = "Alliance" }
local SIDE = { Alliance = "A", Horde = "H" }

local function SourcePass(s, entry, level, faction)
	local kind = s.kind or "unknown"
	if st.kindOff[kind] then return false end
	local inst = s.inst ~= nil or s.instMap ~= nil
	local raid = inst and IsRaid(s)
	if st.noDungeons and inst and not raid then return false end
	if st.noRaids and raid then return false end
	if st.dungeonsOnly and (not inst or raid) then return false end
	if st.buyOnly and kind ~= "vendor" then return false end
	if st.nearLevel and level and s.level and (kind == "quest" or inst) and s.level > level + NEAR_LEVELS then return false end
	if st.noCraftBop and kind == "craft" and IsBop(entry) then return false end
	if st.noEnemyCity and faction then
		local cities = CITIES[ENEMY[faction]]
		if cities and s.zone and cities[s.zone] then return false end
		if s.side and SIDE[faction] and s.side ~= SIDE[faction] then return false end
	end
	if st.focusZone then
		local zone = st.zone
		if zone and (s.zone == zone or s.inst == zone) then return true end
		if st.map and s.spots then
			for i = 1, #s.spots do
				if s.spots[i].map == st.map then return true end
			end
		end
		return false
	end
	return true
end

-- True when at least one source of the item passes. An item without a known source
-- counts as one source of kind "unknown".
function F.Pass(entry, sources, ctx)
	if not st then
		Compile()
		if not st then return true end
	end
	if not st.any then return true end
	if type(entry) ~= "table" then return true end
	local level, faction = ctx and ctx.level, ctx and ctx.faction
	if type(sources) ~= "table" or #sources == 0 then return SourcePass(NO_SOURCE, entry, level, faction) end
	for i = 1, #sources do
		if SourcePass(sources[i], entry, level, faction) then return true end
	end
	return false
end

ns.OnLoad(Compile)

-- The focus zone follows the player when no zone is picked.
local function ZoneChanged()
	if not st then return end
	local f = Saved()
	if not (f and f.on.focusZone and f.zone == nil) then return end
	local zone, map = HereZone(), HereMap()
	if zone ~= st.zone or map ~= st.map then Changed() end
end
ns.On("ZONE_CHANGED_NEW_AREA", ZoneChanged)
ns.On("PLAYER_ENTERING_WORLD", ZoneChanged)

-- Pick list that scrolls ------------------------------------------------------------------
-- Like UI.Picker, for long lists. choices: list of { value =, label = } or a function.
-- opts: { rows = 12 (shown at once), up = false (open upwards), fixed = "label" (button text
-- stays, the list is an "add" menu) }

local openMenu
local ROW = 20

function F.ListPicker(parent, width, choices, onPick, opts)
	opts = opts or {}
	local b = UI.Button(parent, opts.fixed or "", width or 140, 22)
	if not opts.fixed then
		b.label:ClearAllPoints()
		b.label:SetPoint("LEFT", 8, 0)
		b.label:SetPoint("RIGHT", -18, 0)
		b.label:SetJustifyH("LEFT")
		b.arrow = UI.Text(b, "GameFontNormalSmall", C.GOLD_DIM)
		b.arrow:SetPoint("RIGHT", -6, 0)
		b.arrow:SetText("v")
	end
	local menu = CreateFrame("Frame", nil, b, "BackdropTemplate")
	UI.Panel(menu, C.BLACK, 0.98, C.GOLD_DIM)
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	menu:EnableMouse(true)
	if opts.up then
		menu:SetPoint("BOTTOMLEFT", b, "TOPLEFT", 0, 2)
	else
		menu:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2)
	end
	menu:Hide()
	local scroll = UI.Scroll(menu)
	scroll:SetPoint("TOPLEFT", 1, -1)
	scroll:SetPoint("BOTTOMRIGHT", -13, 1)
	local pool = UI.Pool(function(i)
		local row = CreateFrame("Button", nil, scroll.content)
		row:SetHeight(ROW)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW)
		row:SetPoint("TOPRIGHT", 0, -(i - 1) * ROW)
		row.hi = UI.Fill(row, "BACKGROUND", C.LINE, 0.7)
		row.hi:SetAllPoints()
		row.hi:Hide()
		row.text = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
		row.text:SetPoint("LEFT", 8, 0)
		row:SetScript("OnEnter", function(r) r.hi:Show() end)
		row:SetScript("OnLeave", function(r) r.hi:Hide() end)
		return row
	end)
	local function list() return (type(choices) == "function" and choices() or choices) or {} end
	function b:SetChoices(new) choices = new end
	function b:SetValue(value)
		self.value = value
		if opts.fixed then return end
		for _, choice in ipairs(list()) do
			if choice.value == value then
				self:SetLabel(choice.label)
				return
			end
		end
		self:SetLabel(value ~= nil and tostring(value) or "")
	end
	function b:GetValue() return self.value end
	b:SetScript("OnClick", function(self)
		if menu:IsShown() then menu:Hide() return end
		if openMenu and openMenu ~= menu then openMenu:Hide() end
		openMenu = menu
		local items = list()
		for i, choice in ipairs(items) do
			local row = pool:Get(i)
			row.text:SetText(choice.label)
			UI.Color(row.text, (not opts.fixed and choice.value == self.value) and C.GOLD or C.TEXT)
			row:SetScript("OnClick", function()
				menu:Hide()
				b:SetValue(choice.value)
				if onPick then onPick(choice.value) end
			end)
		end
		pool:HideFrom(#items + 1)
		scroll.content:SetHeight(math.max(1, #items * ROW))
		menu:SetSize(math.max(self:GetWidth(), 120), math.max(1, math.min(#items, opts.rows or 12)) * ROW + 2)
		menu:Show()
		scroll:ScrollTo(0)
	end)
	b:HookScript("OnHide", function() menu:Hide() end)
	b.menu = menu
	return b
end

-- Bar -------------------------------------------------------------------------------------

local bars = {}
local HERE = "\1here" -- pick list value for "the zone I am in"

local function ZoneChoices()
	local out = { { value = HERE, label = "Current zone" } }
	for _, zone in ipairs(F.Zones()) do out[#out + 1] = { value = zone, label = zone } end
	return out
end

local function Chip(parent, preset)
	local chip = UI.Button(parent, preset.label, 60, 20)
	chip:SetWidth(math.max(40, math.ceil(chip.label:GetStringWidth() or 0) + 16))
	chip:SetScript("OnClick", function() F.Set(preset.key, not F.Get(preset.key)) end)
	UI.Tip(chip, preset.label, { preset.tip })
	return chip
end

-- Two rows: presets, then source kinds and the focus zone. bar:Refresh() shows the saved state.
function F.Bar(parent)
	local bar = CreateFrame("Frame", nil, parent)
	bar:SetHeight(46)
	bar.chips, bar.checks = {}, {}

	local last, zoneChip
	for _, preset in ipairs(F.PRESETS) do
		local chip = Chip(bar, preset)
		bar.chips[preset.key] = chip
		if preset.key == "focusZone" then
			zoneChip = chip
		else
			if last then chip:SetPoint("LEFT", last, "RIGHT", 4, 0) else chip:SetPoint("TOPLEFT", 0, 0) end
			last = chip
		end
	end

	bar.reset = UI.Button(bar, "Reset", 54, 20)
	bar.reset:SetPoint("TOPRIGHT", 0, 0)
	bar.reset:SetScript("OnClick", F.Reset)
	UI.Tip(bar.reset, "Reset filters")

	last = nil
	for _, kind in ipairs(F.KINDS) do
		local check = UI.Check(bar, KIND_LABEL[kind], function(on) F.SetKind(kind, on) end)
		if last then check:SetPoint("LEFT", last, "RIGHT", 6, 0) else check:SetPoint("TOPLEFT", 0, -25) end
		bar.checks[kind] = check
		last = check
	end

	bar.zone = F.ListPicker(bar, 150, ZoneChoices, function(value)
		F.SetZone(value ~= HERE and value or nil)
	end, { rows = 14 })
	bar.zone:SetPoint("TOPRIGHT", 0, -24)
	if zoneChip then zoneChip:SetPoint("RIGHT", bar.zone, "LEFT", -4, 0) end

	function bar:Refresh()
		for key, chip in pairs(self.chips) do chip:SetOn(F.Get(key)) end
		for kind, check in pairs(self.checks) do check:SetChecked(F.KindShown(kind)) end
		self.zone:SetValue(F.Zone() or HERE)
		self.reset:SetEnabled(F.Active() > 0)
	end

	bars[#bars + 1] = bar
	if ns.char then bar:Refresh() end
	return bar
end

ns.Listen("FILTERS_CHANGED", function()
	for _, bar in ipairs(bars) do bar:Refresh() end
end)
