local _, ns = ...

-- Play-style filters for the upgrade lists. Saved per character:
--   ns.char.filters = {
--     on    = { presetKey = true },   -- active presets
--     kinds = { kind = false },       -- source kinds that are hidden
--     zone  = "Zone name" or nil,     -- focus zone; nil: the zone the player is in
--     vendors = { type = false },     -- vendor types that are hidden: gold, rep, pvp, currency
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
	-- not in the filters window: the zone box sets it ("Anywhere" is off)
	{ key = "focusZone", label = "Zone", tip = "Only sources in one zone.", hidden = true },
	-- "No profession gear" in the filters window
	{ key = "noProfession", label = "Profession gear", tip = "Hide gear that needs a profession to wear.", hidden = true },
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

-- Vendor types (Gear.VENDOR_TYPES), for the filters window.
F.VENDORS = { "gold", "rep", "pvp", "currency" }
local VENDOR_LABEL = { gold = "Gold", rep = "Reputation", pvp = "PvP rank", currency = "Other currency" }

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
	if type(f.vendors) ~= "table" then f.vendors = {} end
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
	local new = { any = false, kindOff = {}, vendorOff = {} }
	for _, kind in ipairs(F.VENDORS) do
		if f.vendors[kind] == false then
			new.vendorOff[kind] = true
			new.any = true
		end
	end
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

function F.VendorShown(kind)
	local f = Saved()
	return not (f and f.vendors[kind] == false)
end

function F.SetVendor(kind, shown)
	local f = Saved()
	if not f then return end
	if shown then f.vendors[kind] = nil else f.vendors[kind] = false end
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
	f.on, f.kinds, f.vendors, f.zone = {}, {}, {}, nil
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
	for _, shown in pairs(f.vendors) do
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

local function SourcePass(s, entry, level, faction, anyZone)
	local kind = s.kind or "unknown"
	if st.kindOff[kind] then return false end
	if kind == "vendor" and st.vendorOff[s.vendor or "gold"] then return false end
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
	if st.focusZone and not anyZone then
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
-- counts as one source of kind "unknown". anyZone: the zone filter is left out.
function F.Pass(entry, sources, ctx, anyZone)
	if not st then
		Compile()
		if not st then return true end
	end
	if not st.any then return true end
	if type(entry) ~= "table" then return true end
	-- gear that needs a profession to wear, such as engineering goggles
	if st.noProfession and entry.id and ns.Gear and ns.Gear.ItemSkill and ns.Gear.ItemSkill(entry.id) then return false end
	local level, faction = ctx and ctx.level, ctx and ctx.faction
	if type(sources) ~= "table" or #sources == 0 then return SourcePass(NO_SOURCE, entry, level, faction, anyZone) end
	for i = 1, #sources do
		if SourcePass(sources[i], entry, level, faction, anyZone) then return true end
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
-- stays, the list is an "add" menu), keep = true (the list stays open after a pick and is
-- read again: a menu of switches), right = true (the list lines up with the button's right
-- edge), menuWidth = 120 }
-- A choice may carry its own colour: { value =, label =, color = }.

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
	elseif opts.right then
		menu:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", 0, -2)
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
	local function fill()
		local items = list()
		for i, choice in ipairs(items) do
			local row = pool:Get(i)
			row.text:SetText(choice.label)
			UI.Color(row.text, choice.color or ((not opts.fixed and choice.value == b.value) and C.GOLD or C.TEXT))
			row:SetScript("OnClick", function()
				if not opts.keep then menu:Hide() end
				b:SetValue(choice.value)
				if onPick then onPick(choice.value) end
				if opts.keep and menu:IsShown() then fill() end
			end)
		end
		pool:HideFrom(#items + 1)
		scroll.content:SetHeight(math.max(1, #items * ROW))
		menu:SetSize(math.max(b:GetWidth(), opts.menuWidth or 120), math.max(1, math.min(#items, opts.rows or 12)) * ROW + 2)
	end
	b:SetScript("OnClick", function()
		if menu:IsShown() then menu:Hide() return end
		if openMenu and openMenu ~= menu then openMenu:Hide() end
		openMenu = menu
		fill()
		menu:Show()
		scroll:ScrollTo(0)
	end)
	b:HookScript("OnHide", function() menu:Hide() end)
	b.menu = menu
	return b
end

-- Pick list with a search box -------------------------------------------------------------
-- A text box with an arrow inside it. The box shows the picked choice; typing in it narrows the list.
-- choices: list of { value =, label =, pin = true } or a function. Pinned choices come first,
-- with a line under them. Enter picks the first match, Escape puts the picked label back.
-- opts: { rows = 12 }

local GAP = 7 -- room for the line under the pinned rows

function F.SearchPicker(parent, width, choices, onPick, opts)
	opts = opts or {}
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(width or 160, 22)
	-- one box: the arrow sits inside its right end
	local edit = UI.Edit(f, width or 160)
	edit:SetPoint("LEFT")
	edit:SetTextInsets(6, 22, 0, 0)
	local arrow = CreateFrame("Button", nil, edit)
	arrow:SetSize(20, 22)
	arrow:SetPoint("RIGHT")
	arrow.label = UI.Text(arrow, "GameFontNormalSmall", C.GOLD_DIM)
	arrow.label:SetPoint("CENTER")
	arrow.label:SetText("v")
	arrow:SetScript("OnEnter", function(self) UI.Color(self.label, C.GOLD) end)
	arrow:SetScript("OnLeave", function(self) UI.Color(self.label, C.GOLD_DIM) end)
	f.edit, f.arrow = edit, arrow

	local menu = CreateFrame("Frame", nil, f, "BackdropTemplate")
	UI.Panel(menu, C.BLACK, 0.98, C.GOLD_DIM)
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	menu:EnableMouse(true)
	menu:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -2)
	menu:Hide()
	local scroll = UI.Scroll(menu)
	scroll:SetPoint("TOPLEFT", 1, -1)
	scroll:SetPoint("BOTTOMRIGHT", -13, 1)
	local line = UI.Fill(scroll.content, "ARTWORK", C.GOLD_DIM, 0.8)
	line:SetHeight(1)
	local none = UI.Text(scroll.content, "GameFontHighlightSmall", C.FAINT)
	none:SetPoint("TOPLEFT", 8, -4)
	none:SetText("No match")
	local pool = UI.Pool(function()
		local row = CreateFrame("Button", nil, scroll.content)
		row:SetHeight(ROW)
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
	local function labelOf(value)
		for _, choice in ipairs(list()) do
			if choice.value == value then return choice.label end
		end
		return value ~= nil and tostring(value) or ""
	end
	local function pick(choice)
		f.value = choice.value
		menu:Hide()
		edit:SetText(choice.label)
		edit:ClearFocus()
		if onPick then onPick(choice.value) end
	end

	local shown = {} -- the choices in the list now, in order
	-- query: text to look for; nil or "" shows every choice
	local function fill(query)
		query = query and query ~= "" and query:lower() or nil
		wipe(shown)
		local pinned = 0
		for _, choice in ipairs(list()) do
			if not query or choice.label:lower():find(query, 1, true) then
				shown[#shown + 1] = choice
				if choice.pin then pinned = pinned + 1 end
			end
		end
		local split = pinned > 0 and pinned < #shown -- a line between the two groups
		for i, choice in ipairs(shown) do
			local row = pool:Get(i)
			local y = (i - 1) * ROW + ((split and i > pinned) and GAP or 0)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", 0, -y)
			row:SetPoint("TOPRIGHT", 0, -y)
			row.text:SetText(choice.label)
			UI.Color(row.text, choice.value == f.value and C.GOLD or C.TEXT)
			row:SetScript("OnClick", function() pick(choice) end)
		end
		pool:HideFrom(#shown + 1)
		line:SetShown(split)
		if split then
			line:ClearAllPoints()
			line:SetPoint("TOPLEFT", 6, -(pinned * ROW + 3))
			line:SetPoint("TOPRIGHT", -6, -(pinned * ROW + 3))
		end
		none:SetShown(#shown == 0)
		local height = math.max(1, #shown) * ROW + (split and GAP or 0)
		scroll.content:SetHeight(height)
		menu:SetSize(math.max(f:GetWidth(), 120), math.min(height, (opts.rows or 12) * ROW + (split and GAP or 0)) + 2)
		scroll:ScrollTo(0)
	end
	local function open(query)
		if openMenu and openMenu ~= menu then openMenu:Hide() end
		openMenu = menu
		fill(query)
		menu:Show()
	end

	function f:SetChoices(new) choices = new end
	function f:SetValue(value)
		self.value = value
		if not edit:HasFocus() then edit:SetText(labelOf(value)) end
	end
	function f:GetValue() return self.value end
	-- For tests and key handling: the labels in the list now.
	function f:Shown() return shown end
	function f:Search(text)
		edit:SetText(text or "")
		open(text)
	end

	arrow:SetScript("OnClick", function()
		if menu:IsShown() then
			menu:Hide()
			edit:ClearFocus()
		else
			open(nil)
		end
	end)
	edit:SetScript("OnEditFocusGained", function(self)
		self:HighlightText()
		open(nil) -- the whole list until something is typed
	end)
	edit:SetScript("OnEditFocusLost", function(self)
		self:HighlightText(0, 0)
		self:SetText(labelOf(f.value))
	end)
	edit:SetScript("OnTextChanged", function(self, user)
		if user then open(self:GetText()) end
	end)
	edit:SetScript("OnEnterPressed", function(self)
		if menu:IsShown() and shown[1] then pick(shown[1]) else self:ClearFocus() end
	end)
	edit:SetScript("OnEscapePressed", function(self)
		menu:Hide()
		self:ClearFocus()
	end)
	f:HookScript("OnHide", function() menu:Hide() end)
	f.menu = menu
	return f
end

-- Bar -------------------------------------------------------------------------------------

local bars = {}
local ANY = "\1any" -- zone box value for "no zone filter"
local HERE = "\1here" -- zone box value for "the zone I am in"

-- "Anywhere" and "Current zone", then every zone by name.
local function ZoneChoices()
	local out = { { value = ANY, label = "Anywhere", pin = true }, { value = HERE, label = "Current zone", pin = true } }
	local zones = {}
	for i, zone in ipairs(F.Zones()) do zones[i] = zone end
	table.sort(zones)
	for _, zone in ipairs(zones) do out[#out + 1] = { value = zone, label = zone } end
	return out
end

-- The zone box sets two things: whether the zone filter is on, and which zone.
local function PickZone(value)
	local f = Saved()
	if not f then return end
	f.on.focusZone = value ~= ANY and true or nil
	if value ~= ANY then f.zone = value ~= HERE and value or nil end
	Changed()
end

local function ZoneValue()
	if not F.Get("focusZone") then return ANY end
	return F.Zone() or HERE
end

-- Filters window --------------------------------------------------------------------------------
-- Every filter but the zone is a checkbox in a pop-up, in three columns:
--   Sources   ticked: that kind of source counts
--   Vendors   ticked: that kind of vendor counts
--   Rules     ticked: the rule is on ("No raids", "No profession gear", ...)

local window, boxes
local RULE_LABEL = { noProfession = "No profession gear" }

local function Heading(parent, text, x)
	local head = UI.Heading(parent, 14)
	head:SetPoint("TOPLEFT", x, -2)
	head:SetText(text)
	return head
end

local function BuildWindow()
	local rules = {}
	for _, preset in ipairs(F.PRESETS) do
		if preset.key ~= "focusZone" then rules[#rules + 1] = preset end -- the zone has its own box
	end
	local rows = math.max(#F.KINDS, #F.VENDORS, #rules)
	window = UI.Window("Filters", "Filters", 520, 46 + 24 + rows * 22 + 46, { strata = "DIALOG" })
	boxes = {}
	local body = window.body
	local function column(x, title, list, make)
		Heading(body, title, x)
		for i, entry in ipairs(list) do
			local check = make(entry)
			check:SetPoint("TOPLEFT", x, -24 - (i - 1) * 22)
			boxes[#boxes + 1] = check
		end
	end
	column(0, "Sources", F.KINDS, function(kind)
		local check = UI.Check(body, KIND_LABEL[kind], function(on) F.SetKind(kind, on) end)
		check.read = function() return F.KindShown(kind) end
		return check
	end)
	column(130, "Vendors", F.VENDORS, function(kind)
		local check = UI.Check(body, VENDOR_LABEL[kind], function(on) F.SetVendor(kind, on) end)
		check.read = function() return F.VendorShown(kind) end
		return check
	end)
	column(320, "Rules", rules, function(preset)
		local check = UI.Check(body, RULE_LABEL[preset.key] or preset.label, function(on) F.Set(preset.key, on) end)
		check.read = function() return F.Get(preset.key) end
		UI.Tip(check, RULE_LABEL[preset.key] or preset.label, { preset.tip })
		return check
	end)
	window.reset = UI.Button(body, "Reset", 64, 22)
	window.reset:SetPoint("BOTTOMRIGHT", 0, 0)
	window.reset:SetScript("OnClick", F.Reset)
	UI.Tip(window.reset, "Reset filters", { "Everything shown, no rule, any zone." })
	window.note = UI.Text(body, "GameFontHighlightSmall", C.FAINT)
	window.note:SetPoint("BOTTOMLEFT", 0, 4)
	window.note:SetText("\"not confirmed\" on an item: its vendor's price is still being checked.")
end

local function FillWindow()
	if not window then return end
	for _, check in ipairs(boxes) do check:SetChecked(check.read()) end
	window.reset:SetEnabled(F.Active() > 0)
end

function F.ShowWindow()
	if not window then BuildWindow() end
	FillWindow()
	window:Show()
end

function F.HideWindow()
	if window then window:Hide() end
end

function F.ToggleWindow()
	if window and window:IsShown() then F.HideWindow() else F.ShowWindow() end
end

function F.WindowShown() return window ~= nil and window:IsShown() end

-- The window's checkboxes, for tests.
function F.Boxes() return boxes or {} end

-- At the right end of a row: the zone box, the "Filters" button that opens the window, Reset.
-- bar:Refresh() shows the saved state.
function F.Bar(parent)
	local bar = CreateFrame("Frame", nil, parent)
	bar:SetHeight(22)

	-- from the right edge: Reset, the Filters button, the zone box
	bar.reset = UI.Button(bar, "Reset", 54, 22)
	bar.reset:SetPoint("TOPRIGHT", 0, 0)
	bar.reset:SetScript("OnClick", F.Reset)
	UI.Tip(bar.reset, "Reset filters")

	bar.open = UI.Button(bar, "Filters", 96, 22)
	bar.open:SetPoint("RIGHT", bar.reset, "LEFT", -4, 0)
	bar.open:SetScript("OnClick", F.ToggleWindow)
	UI.Tip(bar.open, "Filters", { "Sources, vendors and rules.", "The number is how many filters are on." })

	bar.zone = F.SearchPicker(bar, 190, ZoneChoices, PickZone, { rows = 14 })
	bar.zone:SetPoint("RIGHT", bar.open, "LEFT", -4, 0)
	UI.Tip(bar.zone.edit, "Zone", { "Only sources in one zone.", "Type to search." })

	function bar:Refresh()
		-- the zone has its own box: count the other filters on the button
		local n = F.Active() - (F.Get("focusZone") and 1 or 0)
		self.open:SetLabel(n > 0 and ("Filters: " .. n) or "Filters")
		self.open:SetOn(n > 0)
		self.zone:SetValue(ZoneValue())
		self.reset:SetEnabled(F.Active() > 0)
	end
	bar:HookScript("OnHide", F.HideWindow)

	bars[#bars + 1] = bar
	if ns.char then bar:Refresh() end
	return bar
end

ns.Listen("FILTERS_CHANGED", function()
	for _, bar in ipairs(bars) do bar:Refresh() end
	if window and window:IsShown() then FillWindow() end
end)
