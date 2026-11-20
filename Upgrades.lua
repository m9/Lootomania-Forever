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

-- "+12" in green, "Equipped", or a quiet minus.
local function DeltaText(entry)
	if entry.worn then return UI.Colored("Equipped", C.GREEN) end
	-- points: 100 is the best item of the slot at this level
	local d = entry.gain or entry.delta
	if type(d) ~= "number" then return "" end
	local n = math.max(1, math.floor(math.abs(d) + 0.5))
	if d > 0 then return UI.Colored("+" .. n, C.GREEN) end
	if d < 0 then return UI.Colored("-" .. n, C.RED) end
	return UI.Colored("Same", C.MUTED)
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
-- after: { save = function(key), delete = function(key, baseKey or nil) }. With it the list can
-- change custom specs: each one gets a pencil (edit) and a cross (delete, after a yes or no box)
-- at the end of its row, and the list ends with "New spec...". after.save and after.delete say what
-- the list should show afterwards.
U.SPEC_NEW = "\1new"

function U.SpecChoices(class, after)
	local out = {}
	local editor = after and ns.SpecEditor
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

-- What a slot has to offer: best entry, how many are better than worn, the best gain.
function U.Summary(list)
	local better, gain = 0, nil
	for _, entry in ipairs(list) do
		if not entry.worn and type(entry.delta) == "number" and entry.delta > 0 then
			better = better + 1
			if not gain or entry.delta > gain then gain = entry.delta end
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
	function o:Fill(best)
		local slots = Slots()
		-- any filter on: a preset, a hidden source kind or vendor type, a zone
		local filtered = ns.Filters and ns.Filters.Active and ns.Filters.Active() > 0
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
				row.source:SetText(entry.source and SourceLine(entry.source) or "")
			else
				row.icon.item = nil
				row.icon:Hide()
				row.name:SetText("None")
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
local LINE_HEIGHT = 20
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
		UI.TextTooltip(self, type(title) == "function" and title(self) or title)
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

local function SourceRow(row, j)
	local line = row.lines[j]
	if line then return line end
	line = CreateFrame("Frame", nil, row)
	line:SetHeight(LINE_HEIGHT)
	line:SetPoint("TOPLEFT", 68, -ROW_HEIGHT - (j - 1) * LINE_HEIGHT)
	line:SetPoint("TOPRIGHT", -6, -ROW_HEIGHT - (j - 1) * LINE_HEIGHT)
	line.text = UI.Text(line, "GameFontHighlightSmall", C.TEXT)
	line.text:SetPoint("LEFT", 0, 0)
	line.text:SetWidth(ROW_WIDTH - 68 - 110)
	line.map = UI.Button(line, "Show on map", 96, 18)
	line.map:SetPoint("RIGHT", 0, 0)
	line.map:SetScript("OnClick", function()
		if ns.Pins and type(ns.Pins.Show) == "function" and line.source then
			ns.Safe(ns.Pins.Show, line.source, row.id)
		end
	end)
	row.lines[j] = line
	return line
end

local function MakeRow()
	local row = CreateFrame("Button", nil, view.scroll.content)
	row.lines = {}
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

	row.remove = Action(row, "Interface\\RaidFrame\\ReadyCheck-NotReady", function(b) return b.on and "Restore" or "Remove" end)
	row.remove:SetPoint("TOPRIGHT", -4, -11)
	row.remove:SetScript("OnClick", function(b)
		if row.id then Call("SetState", row.id, (not b.on) and "removed" or nil, row.suffix) U.Refresh() end
	end)
	row.done = Action(row, "Interface\\RaidFrame\\ReadyCheck-Ready", function(b) return b.on and "Not done" or "Done" end)
	row.done:SetPoint("RIGHT", row.remove, "LEFT", -2, 0)
	row.done:SetScript("OnClick", function(b)
		if row.id then Call("SetState", row.id, (not b.on) and "done" or nil, row.suffix) U.Refresh() end
	end)
	row.wish = Action(row, "Interface\\Icons\\INV_Misc_Note_01", function(b) return b.on and "Off wishlist" or "Wishlist" end)
	row.wish.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	row.wish:SetPoint("RIGHT", row.done, "LEFT", -2, 0)
	row.wish:SetScript("OnClick", function()
		if row.id and ns.Wish and ns.Wish.Toggle then
			local link = row.link
			ns.Safe(ns.Wish.Toggle, type(link) == "string" and link:find("|H") and link or row.id)
			U.Refresh()
		end
	end)
	row.track = Action(row, "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1", function(b) return b.on and "Untrack" or "Track" end)
	row.track:SetPoint("RIGHT", row.wish, "LEFT", -2, 0)
	row.track:SetScript("OnClick", function(b)
		if row.id then Call("Track", row.id, not b.on, row.suffix) U.Refresh() end
	end)

	row.delta = UI.Text(row, "GameFontHighlight", C.TEXT)
	row.delta:SetPoint("TOPRIGHT", -98, -6)
	row.delta:SetWidth(70)
	row.delta:SetJustifyH("RIGHT")
	row.bar = UI.Bar(row, 64, 5)
	row.bar:SetPoint("TOPRIGHT", -98, -28)
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
	if entry.req and level and entry.req > level then
		name = name .. "  " .. UI.Colored("Lvl " .. entry.req, C.RED)
	end
	row.name:SetText(name)
	row.source:SetText(entry.source and SourceLine(entry.source) or UI.Colored("Source: unknown", C.FAINT))
	row.delta:SetText(DeltaText(entry))
	local index = type(entry.index) == "number" and entry.index or 0
	row.bar:Set(index / 100, entry.worn and C.GOLD_SOFT or C.GOLD)
	row.index:SetText(("%d"):format(index))
	row.track:SetOn(entry.tracked)
	row.done:SetOn(entry.state == "done")
	row.remove:SetOn(entry.state == "removed")
	row.wish:SetShown(ns.Wish ~= nil)
	row.wish:SetOn(ns.Wish and ns.Wish.Has and ns.Wish.Has(entry.id))

	local height = ROW_HEIGHT
	local used = 0
	row.open = expanded[row.key] and true or false
	if row.open then
		local sources = List("Sources", entry.id)
		if #sources == 0 then sources = { { kind = "unknown", text = "No known source" } } end
		for j, source in ipairs(sources) do
			local line = SourceRow(row, j)
			line.source = source
			line.text:SetText(SourceLine(source, true))
			line.map:SetShown(type(source.spots) == "table" and #source.spots > 0)
			line:Show()
			used = j
		end
		height = height + used * LINE_HEIGHT + 4
	end
	for j = used + 1, #row.lines do row.lines[j]:Hide() end
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
				row.info:SetText(UI.Colored("+" .. Num(gain), C.GREEN))
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
	for key, b in pairs(view.states) do b:SetOn(key == stateView) end
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
	}
	view.spec = UI.Picker(panel, 170, function() return U.SpecChoices(playerClass(), after) end, function(key)
		if U.SpecCommand(key, playerClass(), playerSpec(), pick) then return end
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

	local top = -28
	if ns.Filters and ns.Filters.Bar then
		view.bar = ns.Filters.Bar(panel)
		view.bar:SetPoint("TOPLEFT", 0, top)
		view.bar:SetPoint("TOPRIGHT", 0, top)
		top = top - 52
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
		local b = UI.Button(view.detail, state.label, 66, 20)
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
for _, message in ipairs({ "CONTEXT_CHANGED", "GEAR_CHANGED", "HUNTS_CHANGED", "FILTERS_CHANGED", "WISHLIST_CHANGED" }) do
	ns.Listen(message, refresh)
end
ns.Listen("SETTINGS_CHANGED", function(key)
	if key == "huntsPerSlot" or key == "upHideBelowWorn" then refresh() end
end)

-- Settings and commands ----------------------------------------------------------------------------

ns.Main.AddOption({ group = "Upgrades", key = "huntsPerSlot", kind = "slider", label = "Items per slot", min = 3, max = 15, step = 1, default = 5 })
ns.Main.AddOption({ group = "Upgrades", key = "upHideBelowWorn", kind = "check", label = "Hide items below equipped", default = false })

ns.Command("upgrades", "Upgrades", function() ns.Main.Toggle("upgrades") end)

ns.Command("spec", "Set spec: <name>", function(rest)
	local ctx = Call("PlayerContext")
	local class = type(ctx) == "table" and ctx.class or (ns.player and ns.player.class)
	local specs = List("Specs", class)
	local want = (rest or ""):lower():match("^%s*(.-)%s*$")
	if want == "" then
		local names = {}
		for _, s in ipairs(specs) do names[#names + 1] = s.label or s.key end
		ns.Print("Spec: " .. U.SpecLabel(class, ctx and ctx.spec))
		ns.Print("Specs: " .. table.concat(names, ", "))
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
