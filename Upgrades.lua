local _, ns = ...

-- The "Upgrades" tab: slots on the left, the ranked list for one slot (or the best pick of
-- every slot) on the right. All data comes from ns.Gear.

local UI = ns.UI
local C = UI.C
local U = {}
ns.Upgrades = U

local function Result(ok, ...)
	if ok then return ... end
	ns.Debug(...)
	return nil
end

-- Calls ns.Gear[name]; nil when Gear or the function is missing or it fails.
local function Call(name, ...)
	local g = ns.Gear
	local fn = g and g[name]
	if type(fn) ~= "function" then return nil end
	return Result(pcall(fn, ...))
end
U.Call = Call

local function List(name, ...)
	local list = Call(name, ...)
	return type(list) == "table" and list or {}
end
U.List = List

-- Text helpers ------------------------------------------------------------------------------

local function Num(v)
	if v == math.floor(v) or math.abs(v) >= 100 then return ("%d"):format(v) end
	return ("%.1f"):format(v)
end
U.Num = Num

-- A gain in points (100 is the best item of the slot at this level): "+12" in green, "-3" in red, "Same".
-- A real change never reads 0.
local function GainText(d)
	local n = math.max(1, math.floor(math.abs(d) + 0.5))
	if d > 0 then return UI.Colored("+" .. n, C.GREEN) end
	if d < 0 then return UI.Colored("-" .. n, C.RED) end
	return UI.Colored("Same", C.MUTED)
end

-- "+12" in green, "Equipped", or a quiet minus.
local function DeltaText(entry)
	if entry.worn then return UI.Colored("Equipped", C.GREEN) end
	local d = entry.gain or entry.delta
	if type(d) ~= "number" then return "" end
	return GainText(d)
end
U.DeltaText = DeltaText

local function Chance(chance)
	if type(chance) ~= "number" then return nil end
	return (chance >= 10 and "%d%%" or "%.1f%%"):format(chance)
end

-- One line for a source: "Boss: Lady Sarevess, Blackfathom Deeps, 12%".
local function SourceLine(s, full)
	if type(s) ~= "table" then return "" end
	local text = s.text or s.name or "Unknown"
	local kind = s.label or Call("KindLabel", s.kind) -- a vendor's label says which kind of vendor
	-- no label when the text has one ("Quest: ...", "In: ...") or is the label ("World drop")
	if s.kind == "unknown" or text == kind or text:find("^%a[%a ]*: ") then kind = nil end
	local parts = { (kind and kind ~= "" and (UI.Colored(kind .. ":", C.GOLD_SOFT) .. " ") or "") .. text }
	local chance = Chance(s.chance)
	if chance and not text:find("%", 1, true) then parts[#parts + 1] = chance end -- Gear's text may carry it
	if s.zone and not text:find(s.zone, 1, true) and not (s.inst and text:find(s.inst, 1, true)) then
		parts[#parts + 1] = s.zone
	end
	-- a vendor: what the item asks for, and the price
	if s.need then parts[#parts + 1] = s.need end
	if s.costText then parts[#parts + 1] = s.costText elseif s.cost then parts[#parts + 1] = UI.Money(s.cost) end
	if s.limited then parts[#parts + 1] = "limited stock" end
	if s.unsure then parts[#parts + 1] = UI.Colored(Call("UnsureMark") or "not confirmed", C.FAINT) end
	if full then
		if s.level then parts[#parts + 1] = "Lvl " .. s.level end
		if s.prof and not text:find(s.prof, 1, true) then
			parts[#parts + 1] = s.prof .. (s.skill and (" " .. s.skill) or "")
		elseif s.skill and not text:find(tostring(s.skill), 1, true) then
			parts[#parts + 1] = "Skill " .. s.skill
		end
	end
	return table.concat(parts, ", ")
end
U.SourceLine = SourceLine

-- The source line of a list row. A drop or a chest reads as Gear's summary, so one of many does
-- not look like the only one: "Drop: 29 creatures, Scarlet Monastery, +2 places". A vendor, a
-- quest and a craft keep their own line (the price, the standing, the skill).
local SUMMED = { boss = true, drop = true, rare = true, object = true, world = true }
local function RowSource(entry)
	local s = entry.source
	if type(s) ~= "table" then return "" end
	if type(entry.summary) ~= "string" or not SUMMED[s.kind] then return SourceLine(s) end
	local label = Call("KindLabel", s.kind)
	if not label or label == "" or entry.summary:find(label, 1, true) == 1 then return entry.summary end
	return UI.Colored(label .. ":", C.GOLD_SOFT) .. " " .. entry.summary
end
U.RowSource = RowSource

local function ItemName(entry)
	local name = entry.name or ("Item " .. tostring(entry.id))
	-- the random suffix in its own colour
	local suffix = entry.suffix and entry.suffix.name
	if suffix and suffix ~= "" then
		if name:sub(-#suffix) == suffix then name = name:sub(1, -#suffix - 1):gsub("%s+$", "") end
		name = name .. " " .. UI.Colored(suffix, C.SUFFIX)
	end
	return name
end
U.ItemName = ItemName

local function Slots()
	local g = ns.Gear
	return g and type(g.SLOTS) == "table" and g.SLOTS or {}
end

local function SlotLabel(key)
	for _, slot in ipairs(Slots()) do
		if slot.key == key then return slot.label or key end
	end
	return key or ""
end
U.SlotLabel = SlotLabel

function U.ClassLabel(class)
	for _, c in ipairs(List("Classes")) do
		if c.key == class then return c.label end
	end
	return class or ""
end

function U.SpecLabel(class, spec)
	for _, s in ipairs(List("Specs", class)) do
		if s.key == spec then return s.label end
	end
	return spec or ""
end

-- Spec choices for a pick list: the class's specs, custom ones included.
-- after: { save = function(key), delete = function(key, baseKey or nil), auto = true }. With it the
-- list can change custom specs: each one gets a pencil (edit) and a cross (delete, after a yes or
-- no box) at the end of its row, and the list ends with "New spec...". after.save and after.delete
-- say what the list should show afterwards. after.auto: the list starts with "From talents", the
-- way back from a spec picked by hand (the player's own list only).
U.SPEC_NEW = "\1new"
U.SPEC_AUTO = "\1auto"

function U.SpecChoices(class, after)
	local out = {}
	local editor = after and ns.SpecEditor
	if after and after.auto then
		out[1] = { value = U.SPEC_AUTO, label = Call("SpecPicked") and "From talents" or "From talents (on)", action = true, color = C.GOLD_SOFT }
	end
	for _, s in ipairs(List("Specs", class)) do
		local choice = { value = s.key, label = s.label or s.key }
		if editor and s.custom then
			-- the first one is drawn at the right end
			choice.icons = {
				{ texture = "Delete", tip = "Delete spec", danger = true, onClick = function()
					editor.AskRemove(class, s.key, after.delete) -- asks first
				end },
				{ texture = "Edit", tip = "Edit spec", onClick = function()
					editor.Open({ class = class, spec = s.key, onSave = after.save })
				end },
			}
		end
		out[#out + 1] = choice
	end
	if editor then out[#out + 1] = { value = U.SPEC_NEW, label = "New spec...", action = true, color = C.GOLD_SOFT } end
	return out
end

-- Runs "New spec..." when that is what was picked in a spec list. True when it was.
--   class, current: the list's class and the spec it shows; the new spec starts from that one.
function U.SpecCommand(key, class, current, onSave)
	if key ~= U.SPEC_NEW then return false end
	ns.SpecEditor.Open({ class = class, spec = current, new = true, onSave = onSave })
	return true
end

local function PlayerLevel()
	local ctx = Call("PlayerContext")
	return type(ctx) == "table" and ctx.level or (UnitLevel and UnitLevel("player")) or 60
end

-- What a slot has to offer: best entry, how many are better than worn, the best gain in points.
function U.Summary(list)
	local better, gain = 0, nil
	for _, entry in ipairs(list) do
		if not entry.worn and type(entry.delta) == "number" and entry.delta > 0 then
			better = better + 1
			local points = entry.gain or entry.delta
			if not gain or points > gain then gain = points end
		end
	end
	return list[1], better, gain
end

-- Overview: best pick per slot ------------------------------------------------------------------
-- o:Fill(best) with best(slotKey) -> entry or nil. o.onPick(slotKey) on a click.

local OVER_ROW = 26

function U.Overview(parent, width)
	local o = CreateFrame("Frame", nil, parent)
	o.rows = {}
	local nameWidth = math.floor((width - 108 - 66) * 0.5)
	local sourceWidth = width - 108 - 66 - nameWidth - 8
	local function Row(i)
		local row = CreateFrame("Button", nil, o)
		row:SetSize(width, OVER_ROW - 2)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * OVER_ROW)
		row.back = UI.Fill(row, "BACKGROUND", C.PANEL, 0.9)
		row.back:SetAllPoints()
		row.slot = UI.Text(row, "GameFontHighlightSmall", C.GOLD_SOFT)
		row.slot:SetPoint("LEFT", 6, 0)
		row.slot:SetWidth(72)
		row.icon = UI.Icon(row, 22)
		row.icon:SetPoint("LEFT", 80, 0)
		row.name = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
		row.name:SetPoint("LEFT", 108, 0)
		row.name:SetWidth(nameWidth)
		row.delta = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
		row.delta:SetPoint("LEFT", 108 + nameWidth, 0)
		row.delta:SetWidth(58)
		row.delta:SetJustifyH("RIGHT")
		row.source = UI.Text(row, "GameFontHighlightSmall", C.MUTED)
		row.source:SetPoint("LEFT", 108 + nameWidth + 66, 0)
		row.source:SetWidth(sourceWidth)
		row:SetScript("OnEnter", function(self) self.back:SetColorTexture(C.PANEL_HI[1], C.PANEL_HI[2], C.PANEL_HI[3], 1) end)
		row:SetScript("OnLeave", function(self) self.back:SetColorTexture(C.PANEL[1], C.PANEL[2], C.PANEL[3], 0.9) end)
		row:SetScript("OnClick", function(self) if o.onPick and self.key then o.onPick(self.key) end end)
		row.icon.onClick = function() if o.onPick and row.key then o.onPick(row.key) end end
		return row
	end
	-- plain: the list was made without the player's filters (the Simulator)
	function o:Fill(best, plain)
		local slots = Slots()
		-- any filter on: a preset, a hidden source kind or vendor type, a zone
		local filtered = not plain and ns.Filters and ns.Filters.Active and ns.Filters.Active() > 0
		for i, slot in ipairs(slots) do
			local row = self.rows[i]
			if not row then
				row = Row(i)
				self.rows[i] = row
			end
			row.key = slot.key
			row.slot:SetText(slot.label or slot.key)
			local entry = best(slot.key)
			if type(entry) == "table" then
				row.icon:SetItem(entry.link or entry.id, entry.quality)
				row.icon:Show()
				local name = UI.Colored(ItemName(entry), entry.quality and UI.QUALITY[entry.quality] or C.TEXT)
				-- with filters on, the best item left is rarely the best of the slot: say where it stands
				if filtered and entry.rank then name = name .. " " .. UI.Colored("#" .. entry.rank, C.MUTED) end
				UI.Color(row.name, C.TEXT)
				row.name:SetText(name)
				row.delta:SetText(DeltaText(entry))
				row.source:SetText(RowSource(entry))
			else
				row.icon.item = nil
				row.icon:Hide()
				row.name:SetText(filtered and "None with the filters in use" or "None")
				UI.Color(row.name, C.FAINT)
				row.delta:SetText("")
				row.source:SetText("")
			end
			row:Show()
		end
		for i = #slots + 1, #self.rows do self.rows[i]:Hide() end
		self:SetSize(width, math.max(1, #slots * OVER_ROW))
	end
	return o
end

-- Tab ---------------------------------------------------------------------------------------------

ns.Defaults({ upHideBelowWorn = false })

local view = {}
local sel -- selected slot key; nil: all slots
local stateView = "active" -- "active", "done" or "removed"
local expanded = {} -- item id -> true: sources are shown
local cache = {} -- slot key -> active list

local LEFT_WIDTH = 186
local SLOT_STEP = 25
local ROW_HEIGHT = 42
local ROW_WIDTH = ns.Main.PANEL_WIDTH - LEFT_WIDTH - 4 - 20

local function ActiveList(slot)
	local list = cache[slot]
	if not list then
		list = List("List", slot)
		cache[slot] = list
	end
	return list
end

local function Shown(slot)
	if stateView ~= "active" then
		return List("List", slot, nil, { state = stateView, count = 100 })
	end
	local list = ActiveList(slot)
	if not (ns.db and ns.db.upHideBelowWorn) then return list end
	local out = {}
	for _, entry in ipairs(list) do
		if entry.worn or type(entry.delta) ~= "number" or entry.delta >= 0 then out[#out + 1] = entry end
	end
	return out
end

local Fill

-- Small picture button for a row action. b:SetOn(bool) lights it.
-- title: its tooltip, or a function of the button; a second value is a line under it.
local function Action(parent, texture, title)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(20, 20)
	b.tex = b:CreateTexture(nil, "ARTWORK")
	b.tex:SetPoint("TOPLEFT", 2, -2)
	b.tex:SetPoint("BOTTOMRIGHT", -2, 2)
	b.tex:SetTexture(texture)
	function b:SetOn(on)
		self.on = on and true or false
		if self.tex.SetDesaturated then self.tex:SetDesaturated(not self.on) end
		self.tex:SetAlpha(self.on and 1 or 0.35)
	end
	b:SetScript("OnEnter", function(self)
		self.tex:SetAlpha(1)
		local head, body = title, nil
		if type(title) == "function" then head, body = title(self) end
		UI.TextTooltip(self, head, body and { body } or nil)
	end)
	b:SetScript("OnLeave", function(self)
		self.tex:SetAlpha(self.on and 1 or 0.35)
		UI.HideTooltip()
	end)
	b:SetOn(false)
	return b
end

local function Paint(row, over)
	local c = (over or row.open) and C.PANEL_HI or C.PANEL
	row.back:SetColorTexture(c[1], c[2], c[3], 0.95)
end

-- Expanded row ----------------------------------------------------------------------------------
-- Under the row: how to get the item on the left, what it changes on the right, the item's facts below.

local DETAIL_X = 68 -- under the item name
local DETAIL_LINE = 16
local SOURCE_WIDTH = 296
local STAT_X = DETAIL_X + SOURCE_WIDTH + 16
local STAT_WIDTH = ROW_WIDTH - STAT_X - 8
-- MAX_RECIPE: a recipe's sources are whole blocks, so two of them, the rest in a tooltip
local MAX_GROUPS, MAX_PLACES, MAX_REAGENTS, MAX_STATS, MAX_RECIPE = 4, 4, 6, 8, 2
local INFO = "|TInterface\\FriendsFrame\\InformationIcon:14:14|t"

-- The parts of a row's expanded area, pooled per row and made on first use.
local MAKE = {
	text = function(row) return UI.Text(row, "GameFontHighlightSmall", C.TEXT) end,
	icon = function(row) return UI.Icon(row, 16) end,
	-- a map picture: shows b.source on the world map, for the row's item or for b.item (a recipe)
	map = function(row)
		local b = Action(row, "Interface\\Icons\\INV_Misc_Map_01", "Show on map")
		b:SetSize(18, 18)
		b.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		b:SetOn(true)
		b:SetScript("OnClick", function(self)
			if ns.Pins and type(ns.Pins.Show) == "function" and self.source then ns.Safe(ns.Pins.Show, self.source, self.item or row.id) end
		end)
		return b
	end,
	-- a spec's icon; its name (b.title) is the tooltip
	spec = function(row)
		local b = CreateFrame("Button", nil, row)
		b:SetSize(16, 16)
		b.tex = b:CreateTexture(nil, "ARTWORK")
		b.tex:SetAllPoints()
		b.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		b:SetScript("OnEnter", function(self) if self.title then UI.TextTooltip(self, self.title) end end)
		b:SetScript("OnLeave", UI.HideTooltip)
		return b
	end,
	-- a line with a tooltip: an item (b.item), or a title and lines (b.title, b.tip). b.click: what
	-- a click does, when it does something.
	link = function(row)
		local b = CreateFrame("Button", nil, row)
		b:SetHeight(DETAIL_LINE)
		b.text = UI.Text(b, "GameFontHighlightSmall", C.MUTED)
		b.text:SetPoint("TOPLEFT", 0, 0)
		b:SetScript("OnEnter", function(self)
			if self.item then
				UI.ItemTooltip(self, self.item)
			elseif self.title then
				UI.TextTooltip(self, self.title, self.tip)
			end
		end)
		b:SetScript("OnLeave", UI.HideTooltip)
		b:SetScript("OnClick", function(self) if self.click then ns.Safe(self.click) end end)
		return b
	end,
	-- a place to click over a line of text: it lights up under the pointer and opens the side
	-- panel with details (b.click)
	hit = function(row)
		local b = CreateFrame("Button", nil, row)
		b.hi = UI.Fill(b, "BACKGROUND", C.GOLD, 0.08)
		b.hi:SetAllPoints()
		b.hi:Hide()
		b:SetScript("OnEnter", function(self)
			self.hi:Show()
			UI.TextTooltip(self, self.title or "Details", { "Click for details" })
		end)
		b:SetScript("OnLeave", function(self)
			self.hi:Hide()
			UI.HideTooltip()
		end)
		b:SetScript("OnClick", function(self) if self.click then ns.Safe(self.click) end end)
		return b
	end,
}

local function Part(row, kind)
	local pool = row.parts[kind]
	if not pool then
		pool = { n = 0 }
		row.parts[kind] = pool
	end
	pool.n = pool.n + 1
	local part = pool[pool.n]
	if not part then
		part = MAKE[kind](row)
		pool[pool.n] = part
	end
	part:Show()
	return part
end

local function HideParts(row)
	for _, pool in pairs(row.parts) do
		for i = 1, #pool do pool[i]:Hide() end
		pool.n = 0
	end
end

-- A line of text at x, y from the row's top left. lines: how many it may wrap to (UI.Fit: the
-- count errs on the high side, so text is not cut; the user's screenshot of a vendor's price
-- lost behind "..."). Returns its height and the font string.
local function Text(row, x, y, width, text, c, lines)
	local fs = Part(row, "text")
	fs:ClearAllPoints()
	fs:SetPoint("TOPLEFT", x, -y)
	UI.Color(fs, c or C.TEXT)
	fs:SetText(text)
	local n = UI.Fit(fs, width, lines)
	fs:SetHeight(n * DETAIL_LINE)
	return n * DETAIL_LINE, fs
end

-- A line of text with a tooltip, as wide as its text. click: what a click on it does (optional).
-- Returns its height.
local function Link(row, x, y, width, text, item, title, tip, click)
	local b = Part(row, "link")
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", x, -y)
	b.text:SetWidth(width)
	b.text:SetText(text)
	b:SetWidth(math.max(20, math.min(width, (b.text:GetStringWidth() or width) + 2)))
	b.item, b.title, b.tip, b.click = item, title, tip, click
	return DETAIL_LINE
end

-- Makes the line at x, y a place to click: details in the side panel.
local function Hit(row, x, y, width, height, title, click)
	local b = Part(row, "hit")
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", x - 2, -y)
	b:SetSize(width + 2, height)
	b.hi:Hide()
	b.title, b.click = title, click
end

-- The map picture at x, y: shows a source's spots. item: the item the spots are for, when it is
-- not the row's own (a recipe).
local function Map(row, x, y, source, item)
	local b = Part(row, "map")
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", x, -y + 1)
	b.source, b.item = source, item
end

local function HasSpots(source)
	return type(source) == "table" and type(source.spots) == "table" and #source.spots > 0
end

-- "Wolf, Bear, Boar, +2 more"
local function Names(names, max)
	return table.concat(names, ", ", 1, math.min(#names, max)) .. (#names > max and (", +" .. (#names - max) .. " more") or "")
end

local function Gold(label) return UI.Colored(label, C.GOLD_SOFT) end

-- "Scarlet Monastery (dungeon, Tirisfal Glades)", or the zone.
local function Where(s)
	if not s.inst then return s.zone end
	local notes = {}
	if s.instKind then notes[1] = s.instKind end
	if s.zone and s.zone ~= s.inst then notes[#notes + 1] = s.zone end
	return #notes > 0 and (s.inst .. " (" .. table.concat(notes, ", ") .. ")") or s.inst
end

-- Names the game has not sent yet: item id -> true. The row is filled again when one arrives.
local waiting = {}
local function NameOf(id)
	local name, _, quality = C_Item.GetItemInfo(id)
	if not name then waiting[id] = true end
	return name or ("Item " .. id), quality
end

local INSIDE = { dungeon = "Dungeon", raid = "Raid" }
local MAX_AFTER = 3 -- quests named on the "After:" line

-- What the game says about the player's own character (ns.Me: Me.Skill, Me.Standing, ...), or
-- nil: the game gave no answer, or the list is about another character (the Simulator's preview).
local function Mine(name, ...)
	local me = ns.Me
	if type(me) ~= "table" or type(me[name]) ~= "function" then return nil end
	local ctx = Call("Context")
	if type(ctx) == "table" and ctx.preview then return nil end
	local ok, value = pcall(me[name], ...)
	if ok then return value end
	return nil
end

-- What the character has, after what is asked for: green when that is enough, red when it is not.
-- "Durotar Supply and Logistics: Honored" .. Have(false, "you are Friendly")
local function Have(enough, text)
	return UI.Colored(", " .. text, enough and C.GREEN or C.RED)
end

local function StandingName(standing)
	return _G["FACTION_STANDING_LABEL" .. (standing + 1)] or (ns.Me and ns.Me.STANDING and ns.Me.STANDING[standing]) or tostring(standing)
end

local OneLine -- a source group on one line; defined after GroupText

-- Where an item that is not gear comes from (a box, an item that starts a quest): its best
-- sources, one line each. Nothing when the data has none.
local function OriginLines(id, max)
	local out = {}
	for i, g in ipairs(List("SourceGroups", id, Call("Context"))) do
		if i > max or g.source.kind == "unknown" or g.source.kind == "closed" then break end
		out[#out + 1] = OneLine(g)
	end
	return out
end

-- One source group as text: the head line ("Boss: Lady Sarevess") and the lines under it.
local function GroupText(g)
	local s = g.source
	local kind = s.kind
	local lines = {}
	-- nothing to act on: no source in the data, or only raids that are not open ("Onyxia's Lair opens on 9 Dec 2026")
	if kind == "unknown" or kind == "closed" then return UI.Colored(s.text or "Source unknown", C.FAINT), lines end
	if kind == "world" then
		if s.minLevel and s.maxLevel then lines[1] = "Mostly creatures of level " .. s.minLevel .. " to " .. s.maxLevel end
		return "World drop", lines
	end
	if kind == "container" then
		-- where the box comes from
		lines = s.container and OriginLines(s.container, 2) or lines
		if #lines == 0 then lines[1] = UI.Colored("Its source is unknown", C.FAINT) end
		return Gold("In:") .. " " .. (s.name or "?"), lines
	end
	if kind == "craft" then
		local prof = s.prof or s.name or "?"
		-- the character's own skill, when the game says it. With only "at most" known, a lower
		-- skill is not called too low.
		local rank = s.prof and (s.skill or s.skillMax) and Mine("Skill", s.prof, s.profId)
		if rank and rank > 0 then
			local enough = rank >= (s.skill or s.skillMax)
			lines[#lines + 1] = UI.Colored("You have " .. prof .. " " .. rank, enough and C.GREEN or (s.skill and C.RED or C.MUTED))
		elseif rank == 0 then
			lines[#lines + 1] = UI.Colored("You do not have " .. prof, C.RED)
		end
		if not s.skill and s.skillMax then lines[#lines + 1] = "Skill needed: " .. s.skillMax .. " or less" end
		if s.spec then lines[#lines + 1] = "Specialization: " .. s.spec end
		-- tools and the place it is made at ("Blacksmith Hammer, Anvil")
		local needs = {}
		for _, tool in ipairs(s.tools or {}) do needs[#needs + 1] = tool end
		if s.place then needs[#needs + 1] = s.place end
		if #needs > 0 then lines[#lines + 1] = "Needs: " .. table.concat(needs, ", ") end
		return Gold("Craft:") .. " " .. prof .. (s.skill and (" " .. s.skill) or ""), lines
	end
	local label = s.label or Call("KindLabel", kind) or "Source"
	-- a source with no name of its own is its label: "PvP reward" when the rank is not in the data
	local head = s.name and (Gold(label .. ":") .. " " .. s.name) or label
	local where = #g.places > 1 and table.concat(g.places, ", ", 1, math.min(4, #g.places)) or Where(s)
	-- a chest in many zones names four: "Durotar, Mulgore, Teldrassil, Darkshore, +6 more"
	if #g.places > 4 then where = where .. ", +" .. (#g.places - 4) .. " more" end
	-- the facts under the place, one line each
	local facts = {}
	-- drops from several creatures or bosses (drawn by Drops; this is their one-line form)
	local names = g.names or {}
	local many = g.byPlace ~= nil and #names > 1
	if many then head = Gold((Call("KindLabel", kind) or "Drop") .. ":") .. " " .. #names .. (kind == "boss" and " bosses" or " creatures") end
	if kind == "quest" then
		if s.giver then
			where = "From: " .. s.giver .. (where and (", " .. where) or "")
		elseif s.starter then
			-- the quest starts from an item: the item, then where the item is found
			where = "Starts with: " .. (s.starterName or NameOf(s.starter))
			for _, line in ipairs(OriginLines(s.starter, 1)) do lines[#lines + 1] = line end
		end
		local quest = s.quest and Call("Quest", s.quest)
		quest = type(quest) == "table" and quest or {}
		local levels = {}
		if s.level then levels[#levels + 1] = "Quest level: " .. s.level end
		if quest.req and quest.req > 1 then
			local level = Mine("Level")
			levels[#levels + 1] = "Required level: " .. quest.req .. (level and level < quest.req and Have(false, "you are " .. level) or "")
		end
		if #levels > 0 then facts[1] = table.concat(levels, ", ") end
		-- the dungeon or raid the quest is done in, when that is not where its giver stands
		if s.needs and s.needs ~= s.inst then
			lines[#lines + 1] = (INSIDE[s.needsKind] or "Instance") .. ": " .. s.needs
		elseif s.needsKind == "raid" and not s.inst then
			lines[#lines + 1] = "Raid quest"
		end
		if s.turnIn then lines[#lines + 1] = "Turn in: " .. s.turnIn .. (s.turnInAt and (", " .. s.turnInAt) or "") end
		-- the quests before it: all of them ("A, B") or any one ("A or B"). A quest in several parts
		-- has one name for all of them: "After: its earlier parts".
		local before = {}
		for _, id in ipairs(quest.prevList or {}) do
			local prev = Call("Quest", id)
			if type(prev) == "table" and prev.name then
				local name = prev.name == s.name and "its earlier parts" or prev.name
				if Mine("QuestDone", id) == true then name = name .. UI.Colored(" (done)", C.GREEN) end
				before[#before + 1] = name
			end
		end
		if #before > MAX_AFTER then
			local more = #before - MAX_AFTER
			for i = #before, MAX_AFTER + 1, -1 do before[i] = nil end
			before[#before] = before[#before] .. (", +%d more"):format(more)
		end
		if #before > 0 then lines[#lines + 1] = "After: " .. table.concat(before, quest.prevAny and " or " or ", ") end
	elseif kind == "vendor" then
		-- what the vendor asks for: the standing or rank, then the price, each on a line of its own,
		-- and after each what the character has when the game says it
		local rank = s.rank and Mine("PvpRank")
		local standing = s.faction and s.standing and Mine("Standing", s.faction)
		local own, enough -- what the character has of what is asked for
		if rank then
			own, enough = rank == 0 and "you have no rank" or ("you are rank " .. rank), rank >= s.rank
		elseif standing then
			own, enough = "you are " .. StandingName(standing), standing >= s.standing
		end
		if s.need then
			facts[#facts + 1] = s.need .. (own and Have(enough, own) or "")
		elseif own then
			-- the rank asked for is the head line ("PvP reward: Rank 7")
			facts[#facts + 1] = UI.Colored(own:sub(1, 1):upper() .. own:sub(2), enough and C.GREEN or C.RED)
		end
		local price
		if s.costs then
			local parts = {}
			for _, cost in ipairs(s.costs) do
				local have = Mine("Count", cost.kind, cost.id)
				parts[#parts + 1] = cost.amount .. " " .. cost.name .. (have and Have(have >= cost.amount, "you have " .. have) or "")
			end
			price = table.concat(parts, ", ")
		elseif s.costText then
			price = s.costText
		elseif s.cost then
			local gold = Mine("Gold")
			price = UI.Money(s.cost) .. (gold and gold < s.cost and Have(false, "you have " .. UI.Money(gold)) or "")
		end
		if price then
			facts[#facts + 1] = "Price: " .. price .. (s.limited and ", limited stock" or "")
		elseif s.limited then
			facts[#facts + 1] = "Limited stock"
		end
		if s.unsure then facts[#facts + 1] = UI.Colored(Call("UnsureMark") or "not confirmed", C.FAINT) end
	else
		local low, high = g.minLevel or s.level, g.maxLevel or s.level
		local drop = {}
		if low then drop[#drop + 1] = "Level " .. low .. (high ~= low and (" to " .. high) or "") end
		local chance = Chance(g.chance)
		if chance then drop[#drop + 1] = "Drop chance: " .. (many and "up to " or "") .. chance end
		if #drop > 0 then facts[1] = table.concat(drop, ", ") end
	end
	for i = #facts, 1, -1 do table.insert(lines, 1, facts[i]) end
	if where then
		table.insert(lines, 1, where)
	elseif kind == "object" or kind == "drop" or kind == "rare" or kind == "vendor" then
		-- the data names it and not where it is: said, so that the block does not read as cut short
		table.insert(lines, 1, UI.Colored("Place unknown", C.FAINT))
	end
	return head, lines
end

OneLine = function(g)
	local head, lines = GroupText(g)
	return head .. (#lines > 0 and (", " .. table.concat(lines, ", ")) or "")
end

-- The steps a source takes, in the order they are done: { { text, done = true | false | nil } }.
-- done comes from the game (Mine); nil: it did not say. A source that is one act (kill it, buy it)
-- has fewer than MIN_STEPS and gets no plan.
local MIN_STEPS = 3
local MAX_CHAIN = 12 -- quests followed back from a reward quest

local function Steps(g)
	local s = g.source
	local steps = {}
	local function add(text, done) steps[#steps + 1] = { text = text, done = done } end
	if s.kind == "quest" and s.quest then
		-- the quests before it, the earliest first
		local seen, names = {}, {}
		local function visit(id, depth)
			if seen[id] or depth > MAX_CHAIN then return end
			seen[id] = true
			local quest = Call("Quest", id)
			if type(quest) ~= "table" then return end
			local prev = quest.prevList or {}
			if quest.prevAny and #prev > 1 then
				-- any one of them will do: one step that names them
				local any, done = {}, false
				for _, other in ipairs(prev) do
					local q = Call("Quest", other)
					if type(q) == "table" and q.name then any[#any + 1] = q.name end
					if Mine("QuestDone", other) == true then done = true end
				end
				if #any > 0 then add("Quest: " .. table.concat(any, " or "), done or nil) end
			else
				for _, other in ipairs(prev) do visit(other, depth + 1) end
			end
			if id ~= s.quest and quest.name then
				-- a quest in several parts has one name for all of them
				names[quest.name] = (names[quest.name] or 0) + 1
				local part = (names[quest.name] > 1 or quest.name == s.name) and (", part " .. names[quest.name]) or ""
				add("Quest: " .. quest.name .. part, Mine("QuestDone", id))
			end
		end
		visit(s.quest, 0)
		if s.starter then
			add("Get " .. (s.starterName or NameOf(s.starter)) .. ": it starts the quest")
		end
		local from = s.giver and (" from " .. s.giver .. (Where(s) and (", " .. Where(s)) or "")) or ""
		add("Take the quest " .. (s.name or "") .. from)
		if s.needs and s.needs ~= s.inst then add("Go through " .. s.needs) end
		add(s.turnIn and ("Turn it in to " .. s.turnIn .. (s.turnInAt and (", " .. s.turnInAt) or "")) or "Finish it")
	elseif s.kind == "craft" then
		if Mine("Knows", s.spell) == true then
			add("Learn the recipe", true)
		elseif s.recipe and not waiting[s.recipe] then
			add("Get " .. NameOf(s.recipe) .. " and learn it")
		else
			add("Learn the recipe")
		end
		local rank = s.prof and Mine("Skill", s.prof, s.profId)
		if s.skill then
			add("Reach " .. s.prof .. " " .. s.skill, rank and rank >= s.skill)
		elseif s.skillMax then
			add("Reach the " .. s.prof .. " skill it needs (" .. s.skillMax .. " or less)", rank and rank >= s.skillMax or nil)
		end
		if s.spec then add("Learn the specialization " .. s.spec) end
		local parts, all = {}, true
		for _, reagent in ipairs(s.reagents or {}) do
			local count = reagent.count or 1
			parts[#parts + 1] = count .. " " .. NameOf(reagent.id)
			local have = Mine("Count", "i", reagent.id)
			if not have then all = nil elseif all and have < count then all = false end
		end
		if #parts > 0 then add("Gather " .. table.concat(parts, ", "), all) end
		local with = {}
		for _, tool in ipairs(s.tools or {}) do with[#with + 1] = tool end
		add("Craft it" .. (s.place and (" at " .. s.place) or "") .. (#with > 0 and (" with " .. table.concat(with, ", ")) or ""))
	elseif s.kind == "vendor" then
		local rank = s.rank and Mine("PvpRank")
		local standing = s.faction and s.standing and Mine("Standing", s.faction)
		if s.rank then
			add("Reach PvP rank " .. s.rank, rank and rank >= s.rank)
		elseif s.faction and s.standing then
			add("Reach " .. StandingName(s.standing) .. " with " .. s.faction, standing and standing >= s.standing)
		end
		for _, cost in ipairs(s.costs or {}) do
			local have = Mine("Count", cost.kind, cost.id)
			add("Bring " .. cost.amount .. " " .. cost.name, have and have >= cost.amount)
		end
		if s.cost and not s.costs then
			local gold = Mine("Gold")
			add("Bring " .. UI.Money(s.cost), gold and gold >= s.cost)
		end
		if s.npc then add("Buy it from " .. (s.name or "the vendor") .. (Where(s) and (", " .. Where(s)) or "")) end
	end
	return steps
end

-- What a click on a source opens in the side panel, or nil: a creature (boss, drop, rare, vendor),
-- a quest with its plan.
local function Details(g)
	local side = ns.Side
	local s = g.source
	if type(side) ~= "table" or type(s) ~= "table" then return nil end
	if s.kind == "quest" and side.Quest then
		return function() side.Quest(s, Steps(g)) end
	end
	if s.npc and side.Creature and (s.kind == "boss" or s.kind == "drop" or s.kind == "rare" or s.kind == "vendor") then
		return function() side.Creature(s.npc, s) end
	end
	return nil
end

-- A plan as one line: "Next step, 2 of 5: Quest: Murky Trouble". All steps are in its tooltip, and
-- a click opens them in the side panel (a quest's with the rest about the quest).
-- Returns its height; 0 when the source is one act.
local function StepsLine(row, g, x, y, width)
	local steps = Steps(g)
	if #steps < MIN_STEPS then return 0 end
	local tip, next = {}, nil
	for i, step in ipairs(steps) do
		tip[i] = i .. ". " .. step.text .. (step.done == true and UI.Colored(" (done)", C.GREEN) or "")
		if not next and step.done ~= true then next = i end
	end
	local text = next and (Gold(("Next step, %d of %d:"):format(next, #steps)) .. " " .. steps[next].text)
		or UI.Colored("All " .. #steps .. " steps done", C.GREEN)
	local side = ns.Side
	local click = Details(g)
	if not click and type(side) == "table" and side.Steps then
		local s = g.source
		local title = s.kind == "craft" and ("Craft: " .. (s.prof or "")) or (s.name or "Steps")
		click = function() side.Steps(title, steps) end
	end
	return Link(row, x, y, width, text, nil, "Steps", tip, click)
end

-- For the side panel's item view and the tracker: a source group of Gear.SourceGroups as text
-- (head, lines), its plan, and the plan of an item's best source for the player when it takes
-- several steps (nil when it is one act).
U.GroupText, U.Steps, U.MIN_STEPS = GroupText, Steps, MIN_STEPS
function U.Plan(id)
	local groups = Call("SourceGroups", id, Call("PlayerContext"))
	local g = type(groups) == "table" and groups[1]
	if type(g) ~= "table" or type(g.source) ~= "table" then return nil end
	local steps = Steps(g)
	return #steps >= MIN_STEPS and steps or nil
end

local BIND = { [1] = "Binds when picked up", [2] = "Binds when equipped" }

-- Plain drops from several creatures: one block, a line per place with its creatures.
-- mapItem: the item the spots are for, when it is not the row's own (a recipe).
local function Drops(row, g, x, y, width, mapItem)
	local head = GroupText(g)
	local side = type(ns.Side) == "table" and ns.Side.Creatures and ns.Side or nil
	-- a click on the head: every creature; on a place: the creatures of that place
	local headHeight = Text(row, x, y, width, head)
	if side then Hit(row, x, y, width, headHeight, nil, function() side.Creatures(#g.sources .. (g.kind == "boss" and " bosses" or " creatures"), g.sources) end) end
	y = y + headHeight + 1
	local facts = {}
	if g.minLevel then facts[1] = "Level " .. g.minLevel .. (g.maxLevel ~= g.minLevel and (" to " .. g.maxLevel) or "") end
	local chance = Chance(g.chance)
	if chance then facts[#facts + 1] = "Drop chance: up to " .. chance end
	if #facts > 0 then y = y + Text(row, x + 12, y, width - 12, table.concat(facts, ", "), C.MUTED) end
	local function line(part)
		local s = part.source
		local names = Names(part.names, 3)
		if not part.place then return names end
		return UI.Colored(part.place .. ((s.inst and s.instKind) and (" (" .. s.instKind .. ")") or "") .. ":", C.TEXT) .. " " .. names
	end
	local parts = g.byPlace
	for i = 1, math.min(#parts, MAX_PLACES) do
		local part = parts[i]
		local map = HasSpots(part.source)
		if map then Map(row, x + width - 18, y, part.source, mapItem) end
		local lineWidth = width - 12 - (map and 24 or 0)
		local height = Text(row, x + 12, y, lineWidth, line(part), C.MUTED, 3)
		if side then Hit(row, x + 12, y, lineWidth, height, part.place, function() side.Creatures(part.place or "Creatures", part.sources) end) end
		y = y + height + 2
	end
	if #parts > MAX_PLACES then
		local rest = {}
		for i = MAX_PLACES + 1, #parts do rest[#rest + 1] = line(parts[i]) end
		y = y + Link(row, x + 12, y, width - 12, ("+%d more places"):format(#rest), nil, "More places", rest)
	end
	return y
end

-- One source as a block, the same for an item and for its recipe: the head line with the map
-- picture ("Reputation vendor: Pawani"), then one fact per line under it (the place, the standing,
-- the price). A line wraps rather than being cut. Returns the y below it.
local function SourceBlock(row, g, x, y, width, mapItem)
	if g.byPlace and #(g.names or {}) > 1 then return Drops(row, g, x, y, width, mapItem) end
	local head, lines = GroupText(g)
	local map = HasSpots(g.source)
	if map then Map(row, x + width - 18, y, g.source, mapItem) end
	local headWidth = width - (map and 24 or 0)
	local headHeight = Text(row, x, y, headWidth, head, nil, 2)
	local details = Details(g)
	if details then Hit(row, x, y, headWidth, headHeight, g.source.name, details) end
	y = y + headHeight + 1
	for _, line in ipairs(lines) do
		y = y + Text(row, x + 12, y, width - 12, line, C.MUTED, 3)
	end
	-- the plan of a source that takes several steps; a craft's comes under its materials, and a
	-- recipe's own source (mapItem) is a step of the craft's
	if not mapItem and g.kind ~= "craft" then y = y + StepsLine(row, g, x + 12, y, width - 12) end
	return y
end

-- Where a recipe comes from: its best sources as blocks, the rest in a tooltip.
local function RecipeSources(row, recipe, x, y, width)
	local groups = List("SourceGroups", recipe, Call("Context"))
	for i = 1, math.min(#groups, MAX_RECIPE) do
		y = SourceBlock(row, groups[i], x, y, width, recipe) + 3
	end
	if #groups > MAX_RECIPE then
		local rest = {}
		for i = MAX_RECIPE + 1, #groups do rest[#rest + 1] = OneLine(groups[i]) end
		y = y + Link(row, x, y, width, ("+%d more"):format(#rest), nil, "More recipe sources", rest)
	end
	return y
end

-- What a craft needs: materials with their icons, two per line, the recipe in its quality colour
-- with where it comes from, and for a bind on pickup item the binding with a note on who can wear it.
local function Craft(row, s, item, x, y, width)
	-- materials: two per line when every name fits half the width, else one per line
	local cell = math.floor(width / 2)
	local n = math.min(#(s.reagents or {}), MAX_REAGENTS)
	local cells, wide = {}, false
	for i = 1, n do
		local reagent = s.reagents[i]
		local icon = Part(row, "icon")
		icon:SetItem(reagent.id)
		-- "8 Medium Leather, you have 3": the bank counts
		local have = Mine("Count", "i", reagent.id)
		local count = reagent.count or 1
		local text = count .. " " .. NameOf(reagent.id) .. (have and Have(have >= count, "you have " .. have) or "")
		local _, fs = Text(row, 0, 0, width - 22, text, C.MUTED)
		local need = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth() or 0
		if need > cell - 22 then wide = true end
		cells[i] = { icon = icon, text = fs }
	end
	local perLine = wide and 1 or 2
	for i, part in ipairs(cells) do
		local cx, cy = x + ((i - 1) % perLine) * cell, y + math.floor((i - 1) / perLine) * (DETAIL_LINE + 4)
		part.icon:ClearAllPoints()
		part.icon:SetPoint("TOPLEFT", cx, -cy)
		part.text:ClearAllPoints()
		part.text:SetPoint("TOPLEFT", cx + 20, -(cy + 1))
		part.text:SetWidth((wide and width or cell) - 22)
	end
	y = y + math.ceil(n / perLine) * (DETAIL_LINE + 4)
	-- The recipe item, when it is real: the game has its name, or the data has where it comes from.
	-- Otherwise how the craft is learned is not known (a trainer or a recipe: the data cannot tell).
	-- A character that knows the craft needs neither.
	local known = false
	if Mine("Knows", s.spell) == true then
		known = true
		y = y + Text(row, x, y, width, UI.Colored("You know this recipe", C.GREEN))
	elseif s.recipe then
		local name, quality = NameOf(s.recipe)
		local first = List("SourceGroups", s.recipe, Call("Context"))[1]
		if not waiting[s.recipe] or (first and first.source.kind ~= "unknown") then
			known = true
			y = y + Link(row, x, y, width, Gold("Recipe:") .. " " .. UI.Colored(name, UI.QUALITY[quality or 1] or C.TEXT), s.recipe)
			y = RecipeSources(row, s.recipe, x + 12, y, width - 12)
		end
	end
	if not known then y = y + Text(row, x, y, width, UI.Colored("Learned from: unknown", C.FAINT)) end
	if item.bind == 1 then
		y = y + Link(row, x, y, width, BIND[1] .. " " .. INFO, nil, BIND[1], { "Only the character who crafted it can wear it." })
	else
		y = y + Text(row, x, y, width, "Another player can craft it", C.MUTED)
	end
	return y
end

-- Left column: how to get the item. Returns the y below it, and true when the binding was said there.
local function Sources(row, entry, item, y)
	local x, width = DETAIL_X, SOURCE_WIDTH
	local saidBind = false
	y = y + Text(row, x, y, width, "How to get it", C.GOLD_SOFT) + 2
	-- for the character the list is about: the player, or the Simulator's preview
	local groups = List("SourceGroups", entry.id, Call("Context"))
	if #groups == 0 then groups = { { kind = "unknown", places = {}, source = { kind = "unknown" } } } end
	for i = 1, math.min(#groups, MAX_GROUPS) do
		local g = groups[i]
		y = SourceBlock(row, g, x, y, width)
		if g.kind == "craft" then
			y = Craft(row, g.source, item, x + 12, y + 2, width - 12)
			y = y + StepsLine(row, g, x + 12, y, width - 12)
			saidBind = saidBind or item.bind == 1
		end
		y = y + 5
	end
	-- an item that does not bind when picked up can come from another player
	if item.bind == 2 then
		y = y + Text(row, x, y, width, "Can be bought or traded (binds when equipped)", C.MUTED, 2) + 5
		saidBind = true
	end
	if #groups > MAX_GROUPS then
		local rest, names = {}, {}
		for i = MAX_GROUPS + 1, #groups do
			local head, lines = GroupText(groups[i])
			rest[#rest + 1] = head .. (lines[1] and (", " .. lines[1]) or "")
			if #names < 2 then names[#names + 1] = groups[i].name end
		end
		local text = ("+%d more: %s%s"):format(#rest, table.concat(names, ", "), #rest > #names and ", ..." or "")
		y = y + Link(row, x, y, width, text, nil, "More sources", rest) + 5
	end
	return y, saidBind
end

local function StatValue(v, unit)
	return UI.Colored(UI.Signed(v) .. (unit or ""), v > 0 and C.GREEN or v < 0 and C.RED or C.MUTED)
end

local ATTR = { str = "Strength", agi = "Agility", sta = "Stamina", int = "Intellect", spi = "Spirit" }

-- Right column: what the item changes against the worn one (its own stats when there is nothing to
-- compare), the suffix, the other specs. Returns the y below it.
local function Stats(row, entry, y)
	local x, width = STAT_X, STAT_WIDTH
	local link = entry.link or entry.id
	local diff = not entry.worn and Call("StatDiff", link)
	local shown = 0
	if type(diff) == "table" then
		local names = {}
		for _, old in ipairs(diff.vs or {}) do
			names[#names + 1] = UI.Colored(old.name or "?", UI.QUALITY[old.quality or 1] or C.TEXT)
		end
		y = y + Text(row, x, y, width, UI.Colored("Compared to: ", C.GOLD_SOFT) .. (#names > 0 and table.concat(names, " + ") or "empty slot"), C.MUTED) + 2
		-- what the item gives in the end; the attributes behind it follow on one line
		for _, stat in ipairs(diff.rows or {}) do
			if not ATTR[stat.key] and shown < MAX_STATS then
				local percent = stat.unit == "%"
				local text = StatValue(stat.value, percent and "%" or nil) .. " " .. stat.label
				if stat.unit and not percent then text = text .. " " .. stat.unit end
				y = y + Text(row, x, y, width, text)
				shown = shown + 1
			end
		end
		local attrs = {}
		for _, attr in ipairs(diff.attrs or {}) do
			attrs[#attrs + 1] = StatValue(attr.value) .. " " .. (ATTR[attr.key] or attr.label)
		end
		if #attrs > 0 then
			y = y + Text(row, x, y, width, "Attributes: " .. table.concat(attrs, ", "), C.MUTED, 2)
		elseif shown == 0 then
			y = y + Text(row, x, y, width, "Same stats", C.MUTED)
		end
	else
		y = y + Text(row, x, y, width, entry.worn and "Equipped" or "Stats", entry.worn and C.GREEN or C.GOLD_SOFT) + 2
		for _, line in ipairs(List("StatLines", link)) do
			if shown < MAX_STATS then
				y = y + Text(row, x, y, width, line)
				shown = shown + 1
			end
		end
	end
	if entry.suffix then
		for _, suffix in ipairs(List("Suffixes", link)) do
			if suffix.current and suffix.text then
				y = y + 4 + Text(row, x, y + 4, width, UI.Colored((entry.suffix.name or suffix.name) .. ":", C.SUFFIX) .. " " .. suffix.text, C.TEXT, 2)
			end
		end
	end
	-- the other specs that rank it: each spec's icon (its name is the tooltip) and the rank
	local others = List("OtherRanks", link)
	if #others > 0 then
		y = y + 4
		local _, label = Text(row, x, y, width, "Other specs:", C.MUTED)
		local first = x + math.max(60, math.min(96, (label:GetStringWidth() or 72) + 6))
		local cx = first
		for _, other in ipairs(others) do
			local rank = "#" .. tostring(other.rank)
			local cell = 16 + 3 + #rank * 7 + 9
			if cx + cell > x + width and cx > first then
				cx, y = first, y + DETAIL_LINE + 3
			end
			local b = Part(row, "spec")
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", cx, -y + 1)
			b.tex:SetTexture(other.icon or 134400)
			b.title = other.label
			Text(row, cx + 19, y, cell - 19, rank, C.MUTED)
			cx = cx + cell
		end
		y = y + DETAIL_LINE
	end
	return y
end

-- "Requires level 25, Item level 30, Binds when picked up, Leather". saidBind: the binding is said above.
-- An item that asks for no level says none: the level it can be had at is its source's to say.
local function Facts(entry, item, level, saidBind)
	local parts = {}
	if item.req and item.req > 1 and not item.reach then
		local text = "Requires level " .. item.req
		parts[#parts + 1] = (level and item.req > level) and UI.Colored(text, C.RED) or text
	end
	if item.ilvl then parts[#parts + 1] = "Item level " .. item.ilvl end
	if BIND[item.bind] and not saidBind then parts[#parts + 1] = BIND[item.bind] end
	if item.armor then parts[#parts + 1] = item.armor end
	if type(item.weapon) == "table" and item.weapon.dps then
		parts[#parts + 1] = ("%.1f DPS"):format(item.weapon.dps)
		if item.weapon.speed then parts[#parts + 1] = ("Speed %.2f"):format(item.weapon.speed) end
	end
	if item.unique then parts[#parts + 1] = "Unique" end
	local skill = Call("ItemSkill", entry.id)
	if type(skill) == "table" and skill.name then
		parts[#parts + 1] = "Requires " .. skill.name .. (skill.rank and skill.rank > 0 and (" " .. skill.rank) or "")
	end
	return table.concat(parts, ", ")
end

-- Fills the expanded area. Returns the row's height.
local function FillDetail(row, entry, level)
	local item = Call("Item", entry.id)
	item = type(item) == "table" and item or {}
	local top = ROW_HEIGHT + 6
	local left, saidBind = Sources(row, entry, item, top)
	local y = math.max(left, Stats(row, entry, top) + 5)
	local facts = Facts(entry, item, level, saidBind)
	if facts ~= "" then y = y + Text(row, DETAIL_X, y, ROW_WIDTH - DETAIL_X - 8, facts, C.MUTED) + 5 end
	return y + 1
end

local function MakeRow()
	local row = CreateFrame("Button", nil, view.scroll.content)
	row.parts = {}
	row.rule = UI.Fill(row, "ARTWORK", C.LINE, 0.6)
	row.rule:SetHeight(1)
	row.rule:SetPoint("TOPLEFT", DETAIL_X, -ROW_HEIGHT)
	row.rule:SetPoint("TOPRIGHT", -6, -ROW_HEIGHT)
	row.back = UI.Fill(row, "BACKGROUND", C.PANEL, 0.95)
	row.back:SetAllPoints()
	row.rank = UI.Text(row, "GameFontHighlight", C.GOLD_DIM)
	row.rank:SetPoint("TOPLEFT", 2, -13)
	row.rank:SetWidth(24)
	row.rank:SetJustifyH("CENTER")
	row.icon = UI.Icon(row, 32)
	row.icon:SetPoint("TOPLEFT", 28, -5)
	row.name = UI.Text(row, "GameFontHighlight", C.TEXT)
	row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
	row.name:SetWidth(ROW_WIDTH - 68 - 200)
	row.source = UI.Text(row, "GameFontHighlightSmall", C.MUTED)
	row.source:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
	row.source:SetWidth(ROW_WIDTH - 68 - 200)

	row.remove = Action(row, "Interface\\RaidFrame\\ReadyCheck-NotReady", function(b)
		if b.on then return "Restore" end
		return "Remove", "Hides the item from this list. The Tracked tab can restore it."
	end)
	row.remove:SetPoint("TOPRIGHT", -4, -11)
	row.remove:SetScript("OnClick", function(b)
		if not row.id then return end
		local removing = not b.on
		local name = row.name:GetText()
		Call("SetState", row.id, removing and "removed" or nil, row.suffix)
		-- one click with no question asked: say where the item went and how it comes back
		if removing then ns.Print(("Removed: %s. Restore it on the Tracked tab."):format(name or "item")) end
		U.Refresh()
	end)
	row.done = Action(row, "Interface\\RaidFrame\\ReadyCheck-Ready", function(b)
		if b.on then return "Not done" end
		return "Done", "You have it or do not need it: hides it from this list."
	end)
	row.done:SetPoint("RIGHT", row.remove, "LEFT", -2, 0)
	row.done:SetScript("OnClick", function(b)
		if row.id then Call("SetState", row.id, (not b.on) and "done" or nil, row.suffix) U.Refresh() end
	end)
	-- one button for "I want this": the tracked list (the wishlist is part of it since 2026-11-21)
	row.track = Action(row, "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1", function(b)
		if b.on then return "Untrack" end
		return "Track", "Puts it in the tracker window and on the map, and says when you have it."
	end)
	row.track:SetPoint("RIGHT", row.done, "LEFT", -2, 0)
	row.track:SetScript("OnClick", function(b)
		if row.id then Call("Track", row.id, not b.on, row.suffix) U.Refresh() end
	end)

	row.delta = UI.Text(row, "GameFontHighlight", C.TEXT)
	row.delta:SetPoint("TOPRIGHT", -76, -6)
	row.delta:SetWidth(70)
	row.delta:SetJustifyH("RIGHT")
	row.bar = UI.Bar(row, 64, 5)
	row.bar:SetPoint("TOPRIGHT", -76, -28)
	row.index = UI.Text(row, "GameFontHighlightSmall", C.MUTED)
	row.index:SetPoint("RIGHT", row.bar, "LEFT", -6, 0)
	row.index:SetWidth(30)
	row.index:SetJustifyH("RIGHT")

	row:SetScript("OnEnter", function(self) Paint(self, true) end)
	row:SetScript("OnLeave", function(self) Paint(self, false) end)
	local function toggle()
		if not row.id then return end
		expanded[row.key] = (not expanded[row.key]) or nil
		Fill()
	end
	row:SetScript("OnClick", toggle)
	row.icon.onClick = toggle
	return row
end

local function FillRow(row, entry, y, level)
	row.id, row.link = entry.id, entry.link
	row.suffix = entry.suffix and entry.suffix.id or nil
	row.key = entry.key or entry.id
	row:ClearAllPoints()
	row:SetPoint("TOPLEFT", 0, -y)
	row:SetPoint("TOPRIGHT", 0, -y)
	row.rank:SetText(entry.rank or "")
	row.icon:SetItem(entry.link or entry.id, entry.quality)
	local name = UI.Colored(ItemName(entry), entry.quality and UI.QUALITY[entry.quality] or C.TEXT)
	local own = Call("Item", entry.id)
	if entry.req and level and entry.req > level and not (own and own.reach) then
		name = name .. "  " .. UI.Colored("Lvl " .. entry.req, C.RED)
	end
	row.name:SetText(name)
	row.source:SetText(entry.source and RowSource(entry) or UI.Colored("Source: unknown", C.FAINT))
	row.delta:SetText(DeltaText(entry))
	local index = type(entry.index) == "number" and entry.index or 0
	row.bar:Set(index / 100, entry.worn and C.GOLD_SOFT or C.GOLD)
	row.index:SetText(("%d"):format(index))
	row.track:SetOn(entry.tracked)
	row.done:SetOn(entry.state == "done")
	row.remove:SetOn(entry.state == "removed")

	local height = ROW_HEIGHT
	row.open = expanded[row.key] and true or false
	HideParts(row)
	if row.open then height = FillDetail(row, entry, level) end
	row.rule:SetShown(row.open)
	row:SetHeight(height)
	Paint(row, false)
	return height
end

local function FillSlots()
	for _, row in ipairs(view.slotRows) do
		local on = row.key == sel
		row.hi:SetShown(on)
		UI.Color(row.label, on and C.GOLD or C.TEXT)
		if row.key then
			local worn = List("Worn", row.key)[1]
			if worn then
				row.icon:SetItem(worn.link or worn.id)
				row.icon.icon:SetAlpha(1)
			else
				row.icon.item = nil
				row.icon.icon:SetTexture(134400)
				row.icon.icon:SetAlpha(0.25)
				row.icon:SetEdge(C.LINE)
			end
			local best, better, gain = U.Summary(ActiveList(row.key))
			if better > 0 then
				row.info:SetText(GainText(gain))
			elseif best and (best.worn or best.delta ~= nil) then -- a preview has no delta
				row.info:SetText(UI.Colored("Best", C.FAINT))
			else
				row.info:SetText("")
			end
			row.better = better
		end
	end
end

local function FillHeader()
	local ctx = Call("Context")
	ctx = type(ctx) == "table" and ctx or {}
	local preview = ctx.preview and true or false
	view.spec:SetShown(not preview)
	view.note:SetShown(preview)
	view.back:SetShown(preview)
	if preview then
		local parts = { U.ClassLabel(ctx.class), U.SpecLabel(ctx.class, ctx.spec) }
		if ctx.level then parts[#parts + 1] = tostring(ctx.level) end
		view.note:SetText("Preview: " .. table.concat(parts, ", "))
	else
		view.spec:SetValue(ctx.spec)
	end
end

local function FillInfo()
	local parts = {}
	local enchant = Call("BestEnchant", sel)
	if type(enchant) == "table" then
		parts[#parts + 1] = UI.Colored("Enchant:", C.GOLD_SOFT) .. " " .. (enchant.text or enchant.name or "")
	end
	if sel == "MainHand" or sel == "OffHand" then
		local route = Call("Route")
		if route == "twohand" then
			parts[#parts + 1] = UI.Colored("Weapons:", C.GOLD_SOFT) .. " two-hand"
		elseif route == "onehand" then
			parts[#parts + 1] = UI.Colored("Weapons:", C.GOLD_SOFT) .. " one-hand"
		end
	end
	if #parts == 0 then parts[1] = UI.Colored(SlotLabel(sel), C.GOLD_SOFT) end
	view.info:SetText(table.concat(parts, "    "))
end

function Fill()
	if not view.scroll then return end
	FillHeader()
	FillSlots()
	local all = sel == nil
	view.over:SetShown(all)
	view.detail:SetShown(not all)
	if all then
		view.over:Fill(function(slot) return ActiveList(slot)[1] end)
		return
	end
	FillInfo()
	-- Done and Removed say how many items they hold, so that a hidden item can be found
	for key, b in pairs(view.states) do
		b:SetOn(key == stateView)
		if key ~= "active" then
			local n = #List("List", sel, nil, { state = key, count = 100 })
			b:SetLabel((key == "done" and "Done" or "Removed") .. (n > 0 and (": " .. n) or ""))
		end
	end
	local list = Shown(sel)
	local level = PlayerLevel()
	local y = 0
	for i, entry in ipairs(list) do
		local row = view.pool:Get(i)
		y = y + FillRow(row, entry, y, level) + 2
	end
	view.pool:HideFrom(#list + 1)
	view.scroll.content:SetHeight(math.max(1, y))
	view.empty:SetShown(#list == 0)
	view.reset:Hide()
	if #list == 0 then
		-- why there is nothing, and the way out when there is one
		local text = "No items for this slot"
		if stateView == "done" then
			text = "Nothing marked done in this slot"
		elseif stateView == "removed" then
			text = "Nothing removed in this slot"
		elseif #List("List", sel, nil, { all = true, count = 1 }) > 0 then
			if #ActiveList(sel) > 0 then
				text = "Nothing better than what you wear.\nSettings, Upgrades: Hide items below equipped."
			elseif ns.Filters and ns.Filters.Active and ns.Filters.Active() > 0 then
				text = "No items with the filters in use"
				view.reset:Show()
			else
				text = "No items with a known source that is open"
			end
		end
		view.empty:SetText(text)
	end
end

-- Rebuilds the lists and redraws.
function U.Refresh()
	wipe(cache)
	Fill()
end

local function Select(slot)
	if slot ~= sel then
		sel = slot
		view.scroll:ScrollTo(0)
	end
	Fill()
end

local function SlotRow(parent, i, key, label)
	local row = CreateFrame("Button", nil, parent)
	row.key = key
	row:SetHeight(SLOT_STEP - 1)
	row:SetPoint("TOPLEFT", 3, -3 - (i - 1) * SLOT_STEP)
	row:SetPoint("TOPRIGHT", -3, -3 - (i - 1) * SLOT_STEP)
	row.hi = UI.Fill(row, "BACKGROUND", C.LINE, 0.8)
	row.hi:SetAllPoints()
	row.hi:Hide()
	row.over = UI.Fill(row, "BORDER", C.LINE, 0.4)
	row.over:SetAllPoints()
	row.over:Hide()
	row.label = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
	if key then
		row.icon = UI.Icon(row, 20)
		row.icon:SetPoint("LEFT", 3, 0)
		row.icon.onClick = function() Select(key) end
		row.label:SetPoint("LEFT", 30, 0)
	else
		row.label:SetPoint("LEFT", 6, 0)
	end
	row.label:SetText(label)
	row.info = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
	row.info:SetPoint("RIGHT", -6, 0)
	row.info:SetJustifyH("RIGHT")
	row:SetScript("OnEnter", function(self)
		self.over:Show()
		if self.key and self.better and self.better > 0 then
			UI.TextTooltip(self, label, { "Better items: " .. self.better })
		end
	end)
	row:SetScript("OnLeave", function(self)
		self.over:Hide()
		UI.HideTooltip()
	end)
	row:SetScript("OnClick", function() Select(key) end)
	return row
end

local STATES = { { key = "active", label = "Active" }, { key = "done", label = "Done" }, { key = "removed", label = "Removed" } }

local function Build(panel)
	local playerClass = function()
		local ctx = Call("PlayerContext")
		return type(ctx) == "table" and ctx.class or (ns.player and ns.player.class)
	end
	local function playerSpec()
		local ctx = Call("PlayerContext")
		return type(ctx) == "table" and ctx.spec or nil
	end
	local function pick(key)
		if key then Call("SetSpec", key) end
		U.Refresh()
	end
	local after = {
		save = pick, -- a saved spec becomes the one in use
		-- the spec in use was deleted: back to its base; another one: nothing changes
		delete = function(key, base) pick(view.spec:GetValue() == key and base or nil) end,
		auto = true,
	}
	view.spec = UI.Picker(panel, 170, function() return U.SpecChoices(playerClass(), after) end, function(key)
		if U.SpecCommand(key, playerClass(), playerSpec(), pick) then return end
		if key == U.SPEC_AUTO then
			-- the spec follows the talents again
			Call("SetSpec", nil)
			U.Refresh()
			return
		end
		pick(key)
	end)
	view.spec:SetPoint("TOPLEFT", 0, 0)
	UI.Tip(view.spec, "Spec")
	view.note = UI.Text(panel, "GameFontHighlightSmall", C.BLUE)
	view.note:SetPoint("TOPLEFT", 2, -5)
	view.back = UI.Button(panel, "Back to me", 90, 22)
	view.back:SetPoint("LEFT", view.note, "RIGHT", 10, 0)
	view.back:SetScript("OnClick", function()
		Call("SetPreview", nil)
		U.Refresh()
	end)

	-- the filters share the top row with the spec list: spec on the left, filters on the right
	local top = -28
	if ns.Filters and ns.Filters.Bar then
		view.bar = ns.Filters.Bar(panel)
		view.bar:SetPoint("TOPLEFT", 0, 0)
		view.bar:SetPoint("TOPRIGHT", 0, 0)
	end

	local left = UI.Box(panel)
	left:SetPoint("TOPLEFT", 0, top)
	left:SetPoint("BOTTOMLEFT", 0, 0)
	left:SetWidth(LEFT_WIDTH)
	view.slotRows = { SlotRow(left, 1, nil, "All slots") }
	for i, slot in ipairs(Slots()) do
		view.slotRows[i + 1] = SlotRow(left, i + 1, slot.key, slot.label or slot.key)
	end

	local right = UI.Box(panel)
	right:SetPoint("TOPLEFT", LEFT_WIDTH + 4, top)
	right:SetPoint("BOTTOMRIGHT", 0, 0)

	view.over = U.Overview(right, ROW_WIDTH + 12)
	view.over:SetPoint("TOPLEFT", 4, -4)
	view.over.onPick = Select

	view.detail = CreateFrame("Frame", nil, right)
	view.detail:SetAllPoints()
	view.info = UI.Text(view.detail, "GameFontHighlightSmall", C.TEXT)
	view.info:SetPoint("TOPLEFT", 8, -9)
	view.info:SetWidth(ROW_WIDTH - 210)
	view.states = {}
	local last
	for i = #STATES, 1, -1 do
		local state = STATES[i]
		local b = UI.Button(view.detail, state.label, 80, 20)
		if last then b:SetPoint("RIGHT", last, "LEFT", -4, 0) else b:SetPoint("TOPRIGHT", -6, -5) end
		b:SetScript("OnClick", function()
			stateView = state.key
			view.scroll:ScrollTo(0)
			Fill()
		end)
		view.states[state.key] = b
		last = b
	end
	view.scroll = UI.Scroll(view.detail)
	view.scroll:SetPoint("TOPLEFT", 4, -30)
	view.scroll:SetPoint("BOTTOMRIGHT", -16, 4)
	view.pool = UI.Pool(MakeRow)
	view.empty = UI.Text(view.detail, "GameFontHighlightSmall", C.FAINT)
	view.empty:SetPoint("TOP", 0, -46)
	view.empty:SetText("No items")
	view.reset = UI.Button(view.detail, "Reset filters", 110, 22)
	view.reset:SetPoint("TOP", view.empty, "BOTTOM", 0, -8)
	view.reset:SetScript("OnClick", function()
		if ns.Filters and ns.Filters.Reset then ns.Filters.Reset() end
	end)
	view.reset:Hide()
end

ns.Main.AddTab("upgrades", "Upgrades", 100, Build, function() U.Refresh() end)

-- Opens the tab on one slot (nil: all slots).
function U.OpenSlot(slotKey)
	local found
	for _, slot in ipairs(Slots()) do
		if slot.key == slotKey then found = slot.key end
	end
	sel = found
	stateView = "active"
	if ns.Main.IsOpen("upgrades") then
		U.Refresh()
	else
		ns.Main.Open("upgrades")
	end
end

function U.Slot() return sel end

-- Refresh ---------------------------------------------------------------------------------------

local refresh = ns.Debounce(0.1, function()
	if ns.Main.IsOpen("upgrades") then U.Refresh() end
end)
for _, message in ipairs({ "CONTEXT_CHANGED", "GEAR_CHANGED", "HUNTS_CHANGED", "FILTERS_CHANGED" }) do
	ns.Listen(message, refresh)
end
ns.Listen("SETTINGS_CHANGED", function(key)
	if key == "huntsPerSlot" or key == "upHideBelowWorn" then refresh() end
end)
-- names of materials and recipes in an expanded row arrive late; a name the game does not have is asked once
local named = ns.Debounce(0.3, function()
	if ns.Main.IsOpen("upgrades") then Fill() end
end)
ns.On("GET_ITEM_INFO_RECEIVED", function(_, id, success)
	if not waiting[id] then return end
	waiting[id] = nil
	if success then named() end
end)

-- Settings and commands ----------------------------------------------------------------------------

ns.Main.AddOption({ group = "Upgrades", key = "huntsPerSlot", kind = "slider", label = "Items per slot", min = 3, max = 15, step = 1, default = 5 })
ns.Main.AddOption({ group = "Upgrades", key = "upHideBelowWorn", kind = "check", label = "Hide items below equipped", default = false })

ns.Command("upgrades", "Upgrades", function() ns.Main.Toggle("upgrades") end)

ns.Command("spec", "Set spec: <name>, or auto (from talents)", function(rest)
	local ctx = Call("PlayerContext")
	local class = type(ctx) == "table" and ctx.class or (ns.player and ns.player.class)
	local specs = List("Specs", class)
	local want = (rest or ""):lower():match("^%s*(.-)%s*$")
	if want == "" then
		local names = {}
		for _, s in ipairs(specs) do names[#names + 1] = s.label or s.key end
		ns.Print("Spec: " .. U.SpecLabel(class, ctx and ctx.spec) .. (Call("SpecPicked") and "" or " (from talents)"))
		ns.Print("Specs: " .. table.concat(names, ", ") .. ", auto")
		return
	end
	if want == "auto" or want == "talents" then
		Call("SetSpec", nil)
		ctx = Call("PlayerContext")
		ns.Print("Spec: " .. U.SpecLabel(class, ctx and ctx.spec) .. " (from talents)")
		return
	end
	local found
	for _, s in ipairs(specs) do
		local key, label = tostring(s.key):lower(), tostring(s.label or ""):lower()
		if key == want or label == want or key == want:gsub("%s+", "_") then
			found = s
			break
		end
		if not found and (key:find(want, 1, true) == 1 or label:find(want, 1, true) == 1) then found = s end
	end
	if not found then
		ns.Print("Spec: not found")
		return
	end
	Call("SetSpec", found.key)
	ns.Print("Spec: " .. (found.label or found.key))
end)
