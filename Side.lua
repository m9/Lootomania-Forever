local _, ns = ...

-- The side panel: details about what was clicked, to the right of the main window.
-- It slides out from the window's edge, shows one view at a time and closes on Escape before
-- the window does. A click on the same thing again closes it; a click on another replaces it.
--
--   Side.Creature(npcId, source)       a boss, creature or vendor: model, level, place, its gear
--                                      (the model: drag turns it, right drag moves it, the wheel zooms)
--   Side.Creatures(title, sources)     the creatures of one place; a click on one opens it
--   Side.Quest(source, steps)          a quest source of Gear.Sources, with its plan
--   Side.Steps(title, steps)           a plan: { { text, done = true | false | nil } }
--   Side.Item(itemId)                  an item: what it is worth, every way to get it, track and guide
--   Side.Close(), Side.Shown(), Side.Current() -> kind, key
-- A view opened from another one (a creature of a list, an item a creature drops) has Back.
--
-- A view is a function that fills the panel with the helpers below (Line, Head, Row, Model).
-- Everything is pooled: the parts of one view are reused by the next.

local UI = ns.UI
local C = UI.C
local Side = {}
ns.Side = Side

local WIDTH = 300
local PAD = 12
local INNER = WIDTH - PAD * 2 - 10 -- room for text: the scroll bar takes the rest
local LINE = 16
local SLIDE = 0.15 -- seconds to slide out
local MODEL_HEIGHT = 210
local HINT_HEIGHT = 14 -- the line under the model that says what the mouse does
local MODEL_TRIES = 8 -- looks for the model this often, half a second apart
local ZOOM_MIN, ZOOM_MAX, ZOOM_STEP = 0.3, 2.5, 0.88 -- camera distance against the game's own; under 1 is closer
local PAN_MAX = 400 -- how far the model can be moved from the middle
local PAN_UNIT = 60 -- pixels per unit of SetPosition, for a client without SetViewTranslation
local MAX_ROWS = 14

local frame, scroll, content, model
local current -- { kind, key }
local back -- the view to go back to: { open = function }

-- Parts ---------------------------------------------------------------------------------

local pools = {}
local MAKE = {
	text = function() return UI.Text(content, "GameFontHighlightSmall", C.TEXT) end,
	head = function()
		local fs = UI.Text(content, "GameFontNormalSmall", C.GOLD_SOFT)
		return fs
	end,
	-- a row that can be clicked or hovered: text on the left, a note on the right
	row = function()
		local b = CreateFrame("Button", nil, content)
		b:SetHeight(LINE + 2)
		b.hi = UI.Fill(b, "BACKGROUND", C.GOLD, 0.08)
		b.hi:SetAllPoints()
		b.hi:Hide()
		b.icon = UI.Icon(b, 16)
		b.icon:SetPoint("LEFT", 0, 0)
		b.icon:EnableMouse(false)
		b.text = UI.Text(b, "GameFontHighlightSmall", C.TEXT)
		b.note = UI.Text(b, "GameFontHighlightSmall", C.MUTED)
		b.note:SetPoint("RIGHT", 0, 0)
		b.note:SetJustifyH("RIGHT")
		b:SetScript("OnEnter", function(self)
			if self.click then self.hi:Show() end
			if self.item then
				UI.ItemTooltip(self, self.item)
			elseif self.tip then
				UI.TextTooltip(self, self.tip)
			end
		end)
		b:SetScript("OnLeave", function(self)
			self.hi:Hide()
			UI.HideTooltip()
		end)
		b:SetScript("OnClick", function(self) if self.click then ns.Safe(self.click) end end)
		return b
	end,
	button = function() return UI.Button(content, "", 110, 22) end,
}

local function Part(kind)
	local pool = pools[kind]
	if not pool then
		pool = { n = 0 }
		pools[kind] = pool
	end
	pool.n = pool.n + 1
	local part = pool[pool.n]
	if not part then
		part = MAKE[kind]()
		pool[pool.n] = part
	end
	part:Show()
	return part
end

local function HideParts()
	for _, pool in pairs(pools) do
		for i = 1, #pool do pool[i]:Hide() end
		pool.n = 0
	end
	if model then model:Hide() end
end

-- Layout: a view calls these top to bottom ------------------------------------------------

local y = 0

-- A line of text; it wraps. c: its colour.
local function Line(text, c)
	local fs = Part("text")
	fs:ClearAllPoints()
	fs:SetPoint("TOPLEFT", 0, -y)
	UI.Color(fs, c or C.MUTED)
	fs:SetText(text)
	local n = UI.Fit(fs, INNER, 4)
	fs:SetHeight(n * LINE)
	y = y + n * LINE
	return fs
end

local function Gap(height) y = y + (height or 8) end

-- A gold section heading with room above it.
local function Head(text)
	Gap(10)
	local fs = Part("head")
	fs:ClearAllPoints()
	fs:SetPoint("TOPLEFT", 0, -y)
	fs:SetWidth(INNER)
	fs:SetText(text)
	y = y + LINE + 2
end

-- A row. opts: note (right text), item (icon and item tooltip), click (function), tip (tooltip title)
local function Row(text, opts)
	opts = opts or {}
	local b = Part("row")
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", 0, -y)
	b:SetWidth(INNER)
	b.item, b.click, b.tip = opts.item, opts.click, opts.tip
	b.icon:SetShown(opts.item ~= nil)
	if opts.item then b.icon:SetItem(opts.item, opts.quality) end
	b.note:SetText(opts.note or "")
	local noteWidth = opts.note and ((b.note:GetStringWidth() or 0) + 6) or 0
	b.text:ClearAllPoints()
	b.text:SetPoint("LEFT", opts.item and 20 or 0, 0)
	b.text:SetWidth(math.max(40, INNER - (opts.item and 20 or 0) - noteWidth))
	b.text:SetText(text)
	UI.Color(b.text, opts.color or C.TEXT)
	b.hi:Hide()
	y = y + LINE + 2
	return b
end

-- beside: to the right of the button before it, on the same line.
local function Button(label, onClick, beside)
	local b = Part("button")
	b:ClearAllPoints()
	if beside then
		b:SetPoint("TOPLEFT", 118, -y + 26)
	else
		b:SetPoint("TOPLEFT", 0, -y - 2)
		y = y + 28
	end
	b:SetLabel(label)
	b:SetScript("OnClick", function() ns.Safe(onClick) end)
	return b
end

-- Model -----------------------------------------------------------------------------------

local TOP = 58 -- where the view starts, under the title and its rule
local wantModel = false -- the view being filled shows a model
local slidingOut = false -- the panel is on its way out

local function Clamp(v, low, high) return v < low and low or v > high and high or v end

local function Display(m)
	local ok, display = pcall(m.GetDisplayInfo, m)
	return ok and tonumber(ns.Plain(display)) or 0
end

-- Facing, zoom and place of the model. The game forgets them when it puts a model in, so this
-- runs again then.
local function View(m)
	pcall(m.SetFacing, m, m.facing)
	if m.SetCamDistanceScale then pcall(m.SetCamDistanceScale, m, m.zoom) end
	if m.SetViewTranslation then
		pcall(m.SetViewTranslation, m, m.panX, m.panY)
	else
		pcall(m.SetPosition, m, 0, m.panX / PAN_UNIT, m.panY / PAN_UNIT)
	end
end

-- While a button is held: the left one turns the model, the right one moves it with the cursor.
local function Drag(m)
	local d = m.drag
	if not d then return end
	local x, y = GetCursorPosition()
	x, y = tonumber(x) or d.x, tonumber(y) or d.y
	if d.button == "RightButton" then
		local scale = m:GetEffectiveScale()
		scale = type(scale) == "number" and scale > 0 and scale or 1
		m.panX = Clamp(d.panX + (x - d.x) / scale, -PAN_MAX, PAN_MAX)
		m.panY = Clamp(d.panY + (y - d.y) / scale, -PAN_MAX, PAN_MAX)
	else
		m.facing = d.facing + (x - d.x) / 80
	end
	View(m)
end

-- Puts the creature into the model. Called with the model shown: a hidden model does not take one.
-- The model is emptied first, or the creature before it would stay while the game asks the server
-- about the new one. The ask can be lost, so it is repeated; when no model comes its place says so.
local function Load()
	local m, npcId = model, model.npc
	m.load = (m.load or 0) + 1
	local load = m.load
	m.missing = false
	m.none:Hide()
	pcall(m.ClearModel, m)
	pcall(m.SetUnit, m, "none")
	local stale = Display(m) -- over 0: the game still reports the creature before
	local function set()
		pcall(m.SetCreature, m, npcId)
		View(m)
	end
	set()
	local tries = 0
	local function look()
		if not (frame:IsShown() and wantModel and m.load == load) then return end -- another view by now
		local display = Display(m)
		-- there, and not the old one (two creatures can look alike: asked twice more, then taken)
		if display > 0 and (display ~= stale or tries >= 2) then return end
		tries = tries + 1
		if tries >= MODEL_TRIES then
			m.missing = true
			m:Hide()
			m.none:Show()
			return
		end
		set()
		C_Timer.After(0.5, look)
	end
	C_Timer.After(0.5, look)
end

-- The creature in 3D, at the top of the panel. It is not in the scrolling part and is shown only
-- once the panel has slid out: the game does not clip a model to the frame around it.
local function Model(npcId)
	if not model then
		local ok, made = pcall(CreateFrame, "PlayerModel", nil, frame)
		if not ok or not made then return end
		model = made
		model.back = UI.Fill(model, "BACKGROUND", C.PANEL, 0.9)
		model.back:SetAllPoints()
		model:SetPoint("TOPLEFT", PAD, -TOP)
		model:SetSize(WIDTH - PAD * 2, MODEL_HEIGHT)
		model.none = UI.Text(frame, "GameFontHighlightSmall", C.FAINT)
		model.none:SetPoint("TOPLEFT", PAD, -TOP - 4)
		model.none:SetWidth(WIDTH - PAD * 2)
		model.none:SetText("The game has no model for it yet.")
		-- what the mouse does, under the model
		model.hint = UI.Text(frame, "GameFontHighlightSmall", C.FAINT)
		model.hint:SetPoint("TOPLEFT", PAD, -TOP - MODEL_HEIGHT - 3)
		model.hint:SetWidth(WIDTH - PAD * 2)
		model.hint:SetText("Drag: turn. Right drag: move. Wheel: zoom.")
		model.hint:Hide()
		model:HookScript("OnShow", function(self) self.hint:Show() end)
		model:EnableMouse(true)
		model:SetScript("OnMouseDown", function(self, button)
			local x, y = GetCursorPosition()
			self.drag = { button = button, x = tonumber(x) or 0, y = tonumber(y) or 0, facing = self.facing, panX = self.panX, panY = self.panY }
			self:SetScript("OnUpdate", Drag)
		end)
		local function release(self)
			self.drag = nil
			self:SetScript("OnUpdate", nil)
		end
		model:SetScript("OnMouseUp", release)
		model:SetScript("OnHide", function(self)
			release(self)
			self.hint:Hide()
		end)
		model:EnableMouseWheel(true)
		model:SetScript("OnMouseWheel", function(self, delta)
			self.zoom = Clamp(self.zoom * ((tonumber(delta) or 0) > 0 and ZOOM_STEP or 1 / ZOOM_STEP), ZOOM_MIN, ZOOM_MAX)
			View(self)
		end)
		pcall(model.SetScript, model, "OnModelLoaded", View)
		model:Hide() -- shown by Open, or by the slide when it ends
	end
	wantModel = true
	model.none:Hide()
	-- each creature starts as the game frames it
	model.npc, model.missing = npcId, false
	model.facing, model.zoom, model.panX, model.panY = 0.4, 1, 0, 0
end

-- Frame -----------------------------------------------------------------------------------

local function Build()
	local window = ns.Main.Window()
	frame = CreateFrame("Frame", "LootomaniaSide", window, "BackdropTemplate")
	UI.Panel(frame, C.BLACK, 0.96, C.GOLD_DIM)
	frame:SetWidth(WIDTH)
	frame:EnableMouse(true) -- clicks do not fall through to the world
	if frame.SetClipsChildren then frame:SetClipsChildren(true) end -- for the slide
	frame.title = UI.Heading(frame, 17)
	frame.title:SetPoint("TOPLEFT", PAD, -10)
	frame.title:SetWidth(WIDTH - PAD * 2 - 28)
	frame.title:SetWordWrap(false)
	frame.sub = UI.Text(frame, "GameFontHighlightSmall", C.MUTED)
	frame.sub:SetPoint("TOPLEFT", PAD, -32)
	frame.sub:SetWidth(WIDTH - PAD * 2)
	local close = UI.Button(frame, "x", 22, 22)
	close:SetPoint("TOPRIGHT", -8, -8)
	close:SetScript("OnClick", function() Side.Close() end)
	frame.close = close
	frame.backButton = UI.Button(frame, "Back", 50, 20)
	frame.backButton:SetPoint("TOPRIGHT", close, "TOPLEFT", -4, -1)
	frame.backButton:SetScript("OnClick", function()
		local to = back
		back = nil
		if to then ns.Safe(to.open) end
	end)
	frame.rule = UI.Divider(frame, WIDTH - 28)
	frame.rule:SetPoint("TOP", 0, -50)
	-- The scrolling part has a width of its own. Tied to both edges of the panel it had no width
	-- while the panel slid out (the panel starts 1 wide), and its content took its width from it:
	-- in game the text lines on the content were then not drawn (user, 2026-11-21).
	scroll = UI.Scroll(frame)
	scroll:SetScript("OnSizeChanged", nil)
	scroll:SetWidth(INNER)
	scroll:SetPoint("TOPLEFT", PAD, -TOP)
	scroll:SetPoint("BOTTOMLEFT", PAD, PAD)
	content = scroll.content
	content:SetWidth(INNER)
	frame:Hide()
	UI.CloseOnEscape(frame)
	frame:HookScript("OnHide", function()
		current, back = nil, nil
		frame:SetScript("OnUpdate", nil)
	end)
	-- the panel belongs to what the window shows: it goes when the window does
	window:HookScript("OnHide", function() frame:Hide() end)
end

-- On the right of the window; on the left when the screen ends there.
local function Dock()
	local window = ns.Main.Window()
	local right, scale = window:GetRight(), window:GetEffectiveScale()
	local screen = UIParent and UIParent.GetRight and UIParent:GetRight()
	local edge = screen and UIParent:GetEffectiveScale() and screen * UIParent:GetEffectiveScale() or nil
	local left = right and scale and edge and (right + WIDTH) * scale > edge
	frame:ClearAllPoints()
	if left then
		frame:SetPoint("TOPRIGHT", window, "TOPLEFT", 1, 0)
		frame:SetPoint("BOTTOMRIGHT", window, "BOTTOMLEFT", 1, 0)
	else
		frame:SetPoint("TOPLEFT", window, "TOPRIGHT", -1, 0)
		frame:SetPoint("BOTTOMLEFT", window, "BOTTOMRIGHT", -1, 0)
	end
end

local function Slide()
	local t = 0
	slidingOut = true
	frame:SetWidth(1)
	frame:SetScript("OnUpdate", function(self, elapsed)
		t = t + (elapsed or 0)
		local done = t >= SLIDE
		self:SetWidth(done and WIDTH or math.max(1, WIDTH * t / SLIDE))
		if done then
			self:SetScript("OnUpdate", nil)
			slidingOut = false
			-- the model waits for the panel to be out
			if wantModel and model then
				model:Show()
				Load()
			end
		end
	end)
end

-- Opens a view. key: what it is about; the same kind and key again closes the panel.
-- from: the view to go back to (a table with an open function), for a view opened from the panel.
local again = false -- the view shown is being drawn again: not a second click on the same thing

local function Open(kind, key, title, sub, fill, from)
	if not (ns.Main and ns.Main.Window) then return false end
	if frame and frame:IsShown() and current and current.kind == kind and current.key == key and not from and not again then
		Side.Close()
		return false
	end
	if not frame then Build() end
	local sliding = not frame:IsShown()
	HideParts()
	if model then model.none:Hide() end
	wantModel = false
	back = from
	frame.backButton:SetShown(back ~= nil)
	frame.title:SetText(title or "")
	frame.sub:SetText(sub or "")
	y = 0
	local ok, err = pcall(fill)
	if not ok then ns.Print("|cffff6060side panel|r", err) end
	content:SetHeight(math.max(10, y + 8))
	-- a model takes the top of the panel; the rest scrolls under it
	scroll:ClearAllPoints()
	scroll:SetPoint("TOPLEFT", PAD, -TOP - (wantModel and (MODEL_HEIGHT + HINT_HEIGHT + 8) or 0))
	scroll:SetPoint("BOTTOMLEFT", PAD, PAD)
	content:SetWidth(INNER)
	scroll:ScrollTo(0)
	if sliding then
		Dock()
		frame:Show()
		Slide()
	elseif wantModel and model and not slidingOut then
		model:Show()
		Load()
	end
	current = { kind = kind, key = key }
	return true
end

function Side.Close()
	if frame then frame:Hide() end
end

function Side.Shown() return frame ~= nil and frame:IsShown() end

function Side.Current()
	if not Side.Shown() or not current then return nil end
	return current.kind, current.key
end

-- Views -----------------------------------------------------------------------------------

-- "Blackfathom Deeps (dungeon, Ashenvale)", or the zone.
local function Where(s)
	if not s.inst then return s.zone end
	local notes = {}
	if s.instKind then notes[1] = s.instKind end
	if s.zone and s.zone ~= s.inst then notes[#notes + 1] = s.zone end
	return #notes > 0 and (s.inst .. " (" .. table.concat(notes, ", ") .. ")") or s.inst
end

local function HasSpots(s) return type(s) == "table" and type(s.spots) == "table" and #s.spots > 0 end

local function MapButton(source, itemId)
	if not (HasSpots(source) and ns.Pins and ns.Pins.Show) then return end
	Button("Show on map", function() ns.Pins.Show(source, itemId) end)
end

local RANK = { [1] = "Elite", [2] = "Rare elite", [3] = "World boss", [4] = "Rare" }

local function Levels(low, high)
	if not low and not high then return nil end
	low, high = low or high, high or low
	return low == high and ("Level " .. low) or ("Level " .. low .. " to " .. high)
end

-- What kind of creature it is and its level, for the line under the name.
local function CreatureSub(npc, source)
	local parts = {}
	if source and source.kind == "vendor" then
		parts[1] = source.label or "Vendor"
	elseif (npc and npc.boss) or (source and source.kind == "boss") then
		parts[1] = "Boss"
	elseif npc and RANK[npc.rank] then
		parts[1] = RANK[npc.rank]
	end
	local levels = Levels(npc and npc.min, npc and npc.max) or (source and source.level and ("Level " .. source.level))
	if levels then parts[#parts + 1] = levels end
	return table.concat(parts, ", ")
end

function Side.Creature(npcId, source, from)
	local Gear = ns.Gear
	local npc = Gear and Gear.Npc and Gear.Npc(npcId) or nil
	source = source or {}
	local name = source.name or (npc and npc.name) or ("Creature " .. tostring(npcId))
	local here = { open = function() return Side.Creature(npcId, source, from) end }
	return Open("creature", npcId, name, CreatureSub(npc, source), function()
		Model(npcId)
		local where = Where(source)
		if where then
			Head("Where")
			Line(where, C.TEXT)
			MapButton(source)
		end
		-- what it asks for, when it is a vendor of one item's row
		local rows = ns.MobTips and ns.MobTips.Rows and ns.MobTips.Rows(npcId)
		local drops, sells = {}, {}
		for _, row in ipairs(type(rows) == "table" and rows or {}) do
			local list = row.sold and sells or drops
			list[#list + 1] = row
		end
		local function list(title, items)
			if #items == 0 then return end
			Head(title)
			for i = 1, math.min(#items, MAX_ROWS) do
				local row = items[i]
				local note = row.up and ns.Tip and ns.Tip.Gain and ns.Tip.Gain(row.gain) or nil
				if not note and row.sold then
					note = row.costText or (row.cost and UI.Money(row.cost)) or nil
				end
				Row(row.name, {
					item = row.id, quality = row.quality, color = UI.QUALITY[row.quality or 1] or C.TEXT, note = note,
					click = function() Side.Item(row.id, here) end,
				})
			end
			if #items > MAX_ROWS then Line(("+%d more"):format(#items - MAX_ROWS), C.FAINT) end
		end
		list("Drops", drops)
		list("Sells", sells)
		if #drops == 0 and #sells == 0 then
			Gap(10)
			Line("No gear from it in the data.", C.FAINT)
		end
	end, from)
end

-- The creatures of one place: a row each, a click opens the creature.
function Side.Creatures(title, sources, from)
	local key = title
	local function open() return Side.Creatures(title, sources, from) end
	return Open("creatures", key, title, #sources .. (#sources == 1 and " creature" or " creatures"), function()
		local first = sources[1]
		local where = first and Where(first)
		if where then Line(where, C.TEXT) end
		if first then MapButton(first) end
		Gap(4)
		for _, s in ipairs(sources) do
			Row(s.name or "?", {
				note = s.level and ("Level " .. s.level) or nil,
				click = s.npc and function() Side.Creature(s.npc, s, { open = open }) end or nil,
				tip = s.npc and "Click for details" or nil,
			})
		end
	end, from)
end

local function StepLines(steps)
	for i, step in ipairs(steps or {}) do
		local done = step.done == true
		Line(i .. ". " .. step.text .. (done and UI.Colored(" (done)", C.GREEN) or ""), done and C.FAINT or C.TEXT)
		Gap(2)
	end
end

function Side.Steps(title, steps)
	return Open("steps", title, title, #steps .. " steps", function() StepLines(steps) end)
end

local INSIDE = { dungeon = "Dungeon", raid = "Raid" }

function Side.Quest(source, steps, from)
	local Gear = ns.Gear
	local quest = Gear and Gear.Quest and source.quest and Gear.Quest(source.quest) or {}
	local here = { open = function() return Side.Quest(source, steps, from) end }
	local sub = {}
	if source.level then sub[#sub + 1] = "Quest level " .. source.level end
	if quest.req and quest.req > 1 then sub[#sub + 1] = "requires level " .. quest.req end
	return Open("quest", source.quest or source.name, source.name or "Quest", table.concat(sub, ", "), function()
		Head("Where")
		if source.giver then
			Line("From: " .. source.giver .. (Where(source) and (", " .. Where(source)) or ""), C.TEXT)
		elseif source.starterName then
			Line("Starts with: " .. source.starterName, C.TEXT)
			if Where(source) then Line(Where(source), C.TEXT) end
		elseif Where(source) then
			Line(Where(source), C.TEXT)
		end
		if source.needs and source.needs ~= source.inst then Line((INSIDE[source.needsKind] or "Instance") .. ": " .. source.needs, C.TEXT) end
		if source.turnIn then Line("Turn in: " .. source.turnIn .. (source.turnInAt and (", " .. source.turnInAt) or ""), C.TEXT) end
		MapButton(source)
		if steps and #steps > 0 then
			Head("Steps")
			StepLines(steps)
		end
		local rewards = Gear and Gear.QuestRewards and source.quest and Gear.QuestRewards(source.quest) or nil
		if rewards and #rewards > 0 then
			Head("Rewards")
			for i = 1, math.min(#rewards, MAX_ROWS) do
				local id = rewards[i]
				local item = Gear.Item and Gear.Item(id)
				local note
				if ns.Arrows and ns.Arrows.Gain and ns.Tip and ns.Tip.Gain then
					local gain = ns.Arrows.Gain(Gear.Link and Gear.Link(id) or ("item:" .. id))
					note = gain and ns.Tip.Gain(gain) or nil
				end
				Row(item and item.name or ("Item " .. id), {
					item = id, quality = item and item.quality, color = UI.QUALITY[item and item.quality or 1] or C.TEXT, note = note,
					click = item and function() Side.Item(id, here) end or nil,
				})
			end
		end
	end, from)
end

-- An item ---------------------------------------------------------------------------------

local MAX_GROUPS = 6
local VIA = { recipe = "Recipe: ", box = "Box: " }
local CREATURE = { boss = true, drop = true, rare = true, vendor = true }

-- What the item is worth against what is worn, as the tracker says it: text, delta.
-- delta is nil for an item that cannot be worn yet ("Level 33", "Can't use").
local function Worth(id)
	if not (ns.Tracker and ns.Tracker.Worth) then return nil end
	return ns.Tracker.Worth(id)
end

-- An item of our data: what it is worth, Track and Guide, and every way to get it as the expanded
-- row of the Upgrades tab says it (Upgrades.GroupText). A click on a source opens it, with Back.
-- This is where a row of the Tracked tab, of History and of a creature's gear leads.
function Side.Item(id, from)
	local Gear = ns.Gear
	local item = Gear and Gear.Item and Gear.Item(id)
	if not item then return false end
	local ctx = Gear.PlayerContext and Gear.PlayerContext() or nil
	local name, quality = item.name, item.quality
	if Gear.Name then
		local wanted, q = Gear.Name(id, ctx)
		name, quality = wanted or name, q or quality
	end
	local link = (Gear.WantedLink and Gear.WantedLink(id, ctx)) or (Gear.Link and Gear.Link(id)) or ("item:" .. id)
	local U = ns.Upgrades
	local sub = {}
	if item.slot then sub[1] = U and U.SlotLabel and U.SlotLabel(item.slot) or item.slot end
	if item.req and item.req > 1 and not item.reach then sub[#sub + 1] = "requires level " .. item.req end
	local function open() return Side.Item(id, from) end
	local here = { open = open }
	return Open("item", id, name or ("Item " .. id), table.concat(sub, ", "), function()
		local worth, delta = Worth(id)
		Row(delta and "Against what you wear" or "For you", { item = link, quality = quality, note = worth })
		Gap(4)
		if Gear.Track and Gear.IsTracked then
			local tracked = Gear.IsTracked(id)
			Button(tracked and "Untrack" or "Track", function()
				Gear.Track(id, not tracked)
				again = true
				ns.Safe(open)
				again = false
			end)
			local way, via
			if Gear.WayTo then way, via = Gear.WayTo(id, ctx) end
			if way and ns.Guide and ns.Guide.SetSource then
				Button("Guide", function()
					ns.Guide.SetSource(way, id, via and (VIA[via] .. (way.name or way.text or "")) or nil)
				end, true)
			end
		end
		Head("How to get it")
		local groups = Gear.SourceGroups and Gear.SourceGroups(id, ctx) or {}
		for i = 1, math.min(#groups, MAX_GROUPS) do
			local g = groups[i]
			local s = type(g.source) == "table" and g.source or {}
			local head, lines = s.text or s.name or "Source", {}
			if U and U.GroupText then head, lines = U.GroupText(g) end
			local steps = U and U.Steps and U.Steps(g) or {}
			local click
			if s.kind == "quest" then
				click = function() Side.Quest(s, steps, here) end
			elseif g.byPlace and #(g.sources or {}) > 1 then
				click = function() Side.Creatures(#g.sources .. (g.kind == "boss" and " bosses" or " creatures"), g.sources, here) end
			elseif s.npc and CREATURE[s.kind] then
				click = function() Side.Creature(s.npc, s, here) end
			end
			if i > 1 then Gap(8) end
			if click then
				Row(head, { click = click, tip = "Click for details" })
			else
				Line(head, C.TEXT)
			end
			for _, line in ipairs(lines or {}) do Line(line, C.MUTED) end
			if #steps >= (U and U.MIN_STEPS or 3) then
				if click then
					-- the whole plan is one click away: the step to do now
					local next
					for n, step in ipairs(steps) do
						if step.done ~= true then next = n break end
					end
					Line(next and ("Next step, %d of %d: %s"):format(next, #steps, steps[next].text) or ("All " .. #steps .. " steps done"), C.TEXT)
				else
					Gap(4)
					StepLines(steps)
				end
			end
			-- a craft: where its recipe comes from
			if s.kind == "craft" and s.recipe and Gear.SourceSummary then
				local text, kind = Gear.SourceSummary(s.recipe, ctx)
				if text and kind ~= "unknown" then Line("Recipe: " .. text, C.MUTED) end
				local way = Gear.WayTo and Gear.WayTo(s.recipe, ctx)
				if way then MapButton(way, s.recipe) end
			end
			MapButton(s, id)
		end
		if #groups > MAX_GROUPS then
			Gap(6)
			Line(("+%d more sources"):format(#groups - MAX_GROUPS), C.FAINT)
		end
		if item.bind == 2 then
			Gap(8)
			Line("Can be bought or traded (binds when equipped)", C.MUTED)
		end
	end, from)
end

-- From an item anywhere in the game ------------------------------------------------------------

-- Opens the main window with the item's view beside it. item: an id or a link.
-- Returns false for an item that is not in the data.
function Side.Show(item)
	local id = ns.ItemID(item)
	local Gear = ns.Gear
	if not (id and Gear and Gear.Item and Gear.Item(id)) then return false end
	if not ns.Main.IsOpen() then ns.Main.Open() end
	local kind, key = Side.Current()
	if kind == "item" and key == id then return true end
	return Side.Item(id)
end

ns.Command("item", "How to get an item: <item link>", function(rest)
	if not ns.ItemID(rest) then
		ns.Print("Use: /lm item <item link>")
	elseif not Side.Show(rest) then
		ns.Print("Not in the data: " .. rest)
	end
end)

ns.Main.AddOption({ group = "Upgrades", key = "altClickItem", kind = "check", label = "Alt-click an item: how to get it", default = true,
	tip = "On an item in your bags or an item link in chat. Opens the main window with the item beside it." })

-- The game calls this for a click on an item with a modifier key held (bags, chat links, loot).
-- A hook after it: nothing of the game's own handling changes.
ns.OnLoad(function()
	if type(HandleModifiedItemClick) ~= "function" or type(hooksecurefunc) ~= "function" then return end
	pcall(hooksecurefunc, "HandleModifiedItemClick", function(link)
		if not (ns.db and ns.db.altClickItem) then return end
		if not (IsAltKeyDown and IsAltKeyDown()) then return end
		if (IsShiftKeyDown and IsShiftKeyDown()) or (IsControlKeyDown and IsControlKeyDown()) then return end
		link = ns.Plain(link)
		if type(link) == "string" then ns.Safe(Side.Show, link) end
	end)
end)
