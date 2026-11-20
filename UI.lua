local _, ns = ...

-- Shared look: black and gold. Every window and row in the addon is built from these.

local UI = {}
ns.UI = UI

UI.FANTASY_FONT = "Fonts\\MORPHEUS.TTF"
local FONT_SIZE = { GameFontHighlightSmall = 12, GameFontNormalSmall = 12, GameFontHighlight = 14, GameFontNormalLarge = 19 }

-- Colors ----------------------------------------------------------------------------

local C = {
	BLACK = { 0.03, 0.025, 0.02 }, -- the window
	PANEL = { 0.075, 0.07, 0.062 }, -- a block on the window
	PANEL_HI = { 0.12, 0.108, 0.09 }, -- a block that wants attention
	LINE = { 0.27, 0.235, 0.16 }, -- quiet edges and rules
	GOLD = { 1.00, 0.82, 0.00 },
	SUFFIX = { 0.45, 0.78, 1.00 }, -- random suffix names
	GOLD_SOFT = { 0.85, 0.68, 0.30 },
	GOLD_DIM = { 0.55, 0.44, 0.20 },
	TEXT = { 0.94, 0.92, 0.86 },
	MUTED = { 0.64, 0.61, 0.55 },
	FAINT = { 0.44, 0.42, 0.38 },
	GREEN = { 0.45, 0.80, 0.40 },
	RED = { 0.96, 0.45, 0.36 },
	BLUE = { 0.47, 0.74, 1.00 },
	VIOLET = { 0.76, 0.64, 0.98 },
	TEAL = { 0.42, 0.82, 0.76 },
}
UI.C = C

-- Item quality colors, by quality number.
UI.QUALITY = {
	[0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 },
	[4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 }, [6] = { 0.9, 0.8, 0.5 },
}

-- Color code for a piece of a line of text: UI.Code(C.GOLD) .. "text" .. "|r".
function UI.Code(c)
	return ("|cff%02x%02x%02x"):format(math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

function UI.Colored(text, c)
	return UI.Code(c) .. tostring(text) .. "|r"
end

-- Class color as {r, g, b}; TEXT when unknown.
function UI.ClassColor(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then return { c.r, c.g, c.b } end
	return C.TEXT
end

-- Small builders --------------------------------------------------------------------

function UI.Color(region, c, a)
	region:SetTextColor(c[1], c[2], c[3], a or 1)
end

-- Text. font is a game font name; size is set by us, in the game's font for the language.
function UI.Text(parent, font, c, size)
	font = font or "GameFontHighlightSmall"
	local fs = parent:CreateFontString(nil, "OVERLAY", font)
	size = size or FONT_SIZE[font]
	if STANDARD_TEXT_FONT and size then fs:SetFont(STANDARD_TEXT_FONT, size, "") end
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("TOP")
	fs:SetWordWrap(false)
	UI.Color(fs, c or C.TEXT)
	return fs
end

-- Heading in the fantasy font.
function UI.Heading(parent, size, c)
	local fs = UI.Text(parent, "GameFontNormalLarge", c or C.GOLD)
	fs:SetFont(UI.FANTASY_FONT, size or 18, "")
	fs:SetShadowColor(0, 0, 0, 1)
	fs:SetShadowOffset(1, -1)
	return fs
end

function UI.Fill(parent, layer, c, a)
	local t = parent:CreateTexture(nil, layer or "BACKGROUND")
	t:SetColorTexture(c[1], c[2], c[3], a or 1)
	return t
end

-- A block: flat fill with a thin edge. f must be made with "BackdropTemplate".
function UI.Panel(f, fill, alpha, edge)
	f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
	fill, edge = fill or C.PANEL, edge or C.LINE
	f:SetBackdropColor(fill[1], fill[2], fill[3], alpha or 0.9)
	f:SetBackdropBorderColor(edge[1], edge[2], edge[3], 1)
end

-- Frame that is a block.
function UI.Box(parent, fill, alpha, edge)
	local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	UI.Panel(f, fill, alpha, edge)
	return f
end

-- Gold line that fades out to both sides.
function UI.Divider(parent, width)
	local line = CreateFrame("Frame", nil, parent)
	line:SetSize(width, 1)
	local half = width / 2
	local left = UI.Fill(line, "ARTWORK", C.GOLD_SOFT, 0.9)
	left:SetPoint("TOPLEFT")
	left:SetSize(half, 1)
	local right = UI.Fill(line, "ARTWORK", C.GOLD_SOFT, 0.9)
	right:SetPoint("TOPRIGHT")
	right:SetSize(half, 1)
	if CreateColor and left.SetGradient then
		local clear = CreateColor(C.GOLD_SOFT[1], C.GOLD_SOFT[2], C.GOLD_SOFT[3], 0)
		local solid = CreateColor(C.GOLD_SOFT[1], C.GOLD_SOFT[2], C.GOLD_SOFT[3], 0.9)
		pcall(left.SetGradient, left, "HORIZONTAL", clear, solid)
		pcall(right.SetGradient, right, "HORIZONTAL", solid, clear)
	end
	return line
end

-- Bar: dark track with a fill. bar:Set(0..1, color).
function UI.Bar(parent, width, height)
	local bar = CreateFrame("Frame", nil, parent)
	bar:SetSize(width, height)
	bar.track = UI.Fill(bar, "BACKGROUND", C.LINE, 0.8)
	bar.track:SetAllPoints()
	bar.fill = UI.Fill(bar, "ARTWORK", C.GOLD, 1)
	bar.fill:SetPoint("TOPLEFT")
	bar.fill:SetHeight(height)
	function bar:Set(fraction, c)
		fraction = math.max(0, math.min(1, fraction or 0))
		c = c or C.GOLD
		self.fill:SetColorTexture(c[1], c[2], c[3], 1)
		self.fill:SetShown(fraction > 0)
		self.fill:SetWidth(math.max(1, (self:GetWidth() or width) * fraction))
	end
	return bar
end

-- Tooltips ----------------------------------------------------------------------------

-- Plain tooltip: a gold title and grey lines.
function UI.TextTooltip(owner, title, lines, anchor)
	GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
	GameTooltip:SetText(title, C.GOLD[1], C.GOLD[2], C.GOLD[3])
	for _, line in ipairs(lines or {}) do
		GameTooltip:AddLine(line, C.TEXT[1], C.TEXT[2], C.TEXT[3], true)
	end
	GameTooltip:Show()
end

function UI.ItemTooltip(owner, item, anchor)
	GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
	if type(item) == "string" and item:find("item:") then
		GameTooltip:SetHyperlink(item)
	else
		GameTooltip:SetHyperlink("item:" .. tostring(item))
	end
	GameTooltip:Show()
end

function UI.HideTooltip()
	GameTooltip:Hide()
end

-- Gives a frame a text tooltip.
function UI.Tip(frame, title, lines)
	frame:HookScript("OnEnter", function(self) UI.TextTooltip(self, title, type(lines) == "function" and lines() or lines) end)
	frame:HookScript("OnLeave", UI.HideTooltip)
end

-- Buttons -----------------------------------------------------------------------------

-- Dark button with a gold edge. b:SetLabel(text), b:SetOn(bool) for a pressed look.
function UI.Button(parent, label, width, height)
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
	b:SetSize(width or 90, height or 24)
	UI.Panel(b, C.PANEL_HI, 1, C.GOLD_DIM)
	b.label = UI.Text(b, "GameFontNormalSmall", C.GOLD)
	b.label:SetPoint("CENTER")
	b.label:SetText(label or "")
	function b:SetLabel(text) self.label:SetText(text) end
	function b:Paint()
		local edge = (self.over or self.on) and C.GOLD or C.GOLD_DIM
		local fill = self.on and C.LINE or C.PANEL_HI
		self:SetBackdropBorderColor(edge[1], edge[2], edge[3], 1)
		self:SetBackdropColor(fill[1], fill[2], fill[3], 1)
		UI.Color(self.label, self:IsEnabled() and C.GOLD or C.FAINT)
	end
	function b:SetOn(on)
		self.on = on and true or false
		self:Paint()
	end
	b:SetScript("OnEnter", function(self) self.over = true self:Paint() end)
	b:SetScript("OnLeave", function(self) self.over = false self:Paint() end)
	b:SetScript("OnEnable", b.Paint)
	b:SetScript("OnDisable", b.Paint)
	return b
end

-- Square icon with a thin edge. b:SetItem(idOrLink) shows an item's icon and tooltip.
function UI.Icon(parent, size)
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
	b:SetSize(size, size)
	UI.Panel(b, C.BLACK, 1, C.LINE)
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetPoint("TOPLEFT", 1, -1)
	b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	function b:SetEdge(c)
		c = c or C.LINE
		self:SetBackdropBorderColor(c[1], c[2], c[3], 1)
	end
	function b:SetItem(item, quality)
		self.item = item
		local id = ns.ItemID(item)
		self.icon:SetTexture(id and C_Item.GetItemIconByID(id) or 134400)
		quality = quality or (id and C_Item.GetItemQualityByID(id))
		self:SetEdge(quality and quality > 1 and UI.QUALITY[quality] or C.LINE)
	end
	b:SetScript("OnEnter", function(self) if self.item then UI.ItemTooltip(self, self.item) end end)
	b:SetScript("OnLeave", UI.HideTooltip)
	-- shift-click links the item in chat, ctrl-click shows it in the dressing room
	b:SetScript("OnClick", function(self, button)
		if not self.item then return end
		if IsModifiedClick and (IsModifiedClick("CHATLINK") or IsModifiedClick("DRESSUP")) then
			local id = ns.ItemID(self.item)
			local link = (type(self.item) == "string" and self.item:find("|H")) and self.item or (id and select(2, C_Item.GetItemInfo(id)))
			if link and HandleModifiedItemClick then HandleModifiedItemClick(link) end
		elseif self.onClick then
			self.onClick(self, button)
		end
	end)
	return b
end

-- Check box with a label. onChange(checked).
function UI.Check(parent, label, onChange)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(200, 20)
	b.box = UI.Box(b, C.BLACK, 1, C.GOLD_DIM)
	b.box:SetSize(14, 14)
	b.box:SetPoint("LEFT", 0, 0)
	b.mark = UI.Fill(b.box, "ARTWORK", C.GOLD, 1)
	b.mark:SetPoint("TOPLEFT", 3, -3)
	b.mark:SetPoint("BOTTOMRIGHT", -3, 3)
	b.label = UI.Text(b, "GameFontHighlightSmall", C.TEXT)
	b.label:SetPoint("LEFT", b.box, "RIGHT", 6, 0)
	b.label:SetText(label or "")
	b:SetWidth(24 + (b.label:GetStringWidth() or 100))
	function b:SetChecked(on)
		self.checked = on and true or false
		self.mark:SetShown(self.checked)
	end
	function b:GetChecked() return self.checked end
	b:SetChecked(false)
	b:SetScript("OnClick", function(self)
		self:SetChecked(not self.checked)
		if onChange then onChange(self.checked) end
	end)
	b:SetScript("OnEnter", function(self) self.box:SetBackdropBorderColor(C.GOLD[1], C.GOLD[2], C.GOLD[3], 1) end)
	b:SetScript("OnLeave", function(self) self.box:SetBackdropBorderColor(C.GOLD_DIM[1], C.GOLD_DIM[2], C.GOLD_DIM[3], 1) end)
	return b
end

-- Slider with a label and the value. onChange(value). format: e.g. "%d%%".
-- lazy: onChange waits for the mouse button to come up, for a setting that moves the slider itself.
function UI.Slider(parent, label, min, max, step, onChange, format, lazy)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(220, 34)
	f.label = UI.Text(f, "GameFontHighlightSmall", C.TEXT)
	f.label:SetPoint("TOPLEFT")
	f.label:SetText(label or "")
	f.value = UI.Text(f, "GameFontHighlightSmall", C.GOLD)
	f.value:SetPoint("TOPRIGHT")
	local s = CreateFrame("Slider", nil, f)
	f.slider = s
	s:SetOrientation("HORIZONTAL")
	s:SetPoint("BOTTOMLEFT", 0, 2)
	s:SetPoint("BOTTOMRIGHT", 0, 2)
	s:SetHeight(12)
	s:SetMinMaxValues(min, max)
	s:SetValueStep(step or 1)
	if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
	local track = UI.Fill(s, "BACKGROUND", C.LINE, 0.8)
	track:SetPoint("LEFT")
	track:SetPoint("RIGHT")
	track:SetHeight(2)
	local thumb = s:CreateTexture(nil, "ARTWORK")
	thumb:SetColorTexture(C.GOLD_SOFT[1], C.GOLD_SOFT[2], C.GOLD_SOFT[3], 1)
	thumb:SetSize(8, 12)
	s:SetThumbTexture(thumb)
	local function show(v) f.value:SetText((format or "%s"):format(v)) end
	local quiet, held, waiting = false, false, nil
	s:SetScript("OnValueChanged", function(_, v)
		v = math.floor(v / (step or 1) + 0.5) * (step or 1)
		show(v)
		if not onChange or quiet then return end
		if lazy and held then waiting = v else onChange(v) end
	end)
	if lazy then
		s:HookScript("OnMouseDown", function() held = true end)
		s:HookScript("OnMouseUp", function()
			held = false
			local v = waiting
			waiting = nil
			if v ~= nil and onChange then onChange(v) end
		end)
	end
	function f:SetValue(v)
		quiet = true
		s:SetValue(v)
		show(v)
		quiet = false
	end
	function f:GetValue() return s:GetValue() end
	return f
end

-- Text box with a gold edge. onChange(text) on every edit, onEnter(text) on Enter.
function UI.Edit(parent, width, onChange, onEnter)
	local e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
	e:SetSize(width or 140, 22)
	UI.Panel(e, C.BLACK, 1, C.GOLD_DIM)
	e:SetAutoFocus(false)
	e:SetFontObject("GameFontHighlightSmall")
	e:SetTextInsets(6, 6, 0, 0)
	e:SetScript("OnEscapePressed", e.ClearFocus)
	e:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
		if onEnter then onEnter(self:GetText()) end
	end)
	e:SetScript("OnTextChanged", function(self, user)
		if user and onChange then onChange(self:GetText()) end
	end)
	return e
end

-- Pick list: a button that opens a list of choices.
-- choices: list of { value = , label = } or a function that returns one. onPick(value).
local openMenu
function UI.Picker(parent, width, choices, onPick)
	local b = UI.Button(parent, "", width or 140, 22)
	b.label:ClearAllPoints()
	b.label:SetPoint("LEFT", 8, 0)
	b.label:SetPoint("RIGHT", -18, 0)
	b.label:SetJustifyH("LEFT")
	b.arrow = UI.Text(b, "GameFontNormalSmall", C.GOLD_DIM)
	b.arrow:SetPoint("RIGHT", -6, 0)
	b.arrow:SetText("v")
	local menu = CreateFrame("Frame", nil, b, "BackdropTemplate")
	UI.Panel(menu, C.BLACK, 0.98, C.GOLD_DIM)
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	menu:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2)
	menu:Hide()
	menu.rows = {}
	local function list() return type(choices) == "function" and choices() or choices end
	function b:SetChoices(new) choices = new end
	function b:SetValue(value)
		self.value = value
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
			local row = menu.rows[i]
			if not row then
				row = CreateFrame("Button", nil, menu)
				row:SetHeight(20)
				row.hi = UI.Fill(row, "BACKGROUND", C.LINE, 0.7)
				row.hi:SetAllPoints()
				row.hi:Hide()
				row.text = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
				row.text:SetPoint("LEFT", 8, 0)
				row:SetScript("OnEnter", function(r) r.hi:Show() end)
				row:SetScript("OnLeave", function(r) r.hi:Hide() end)
				row:SetPoint("TOPLEFT", 1, -1 - (i - 1) * 20)
				row:SetPoint("TOPRIGHT", -1, -1 - (i - 1) * 20)
				menu.rows[i] = row
			end
			row.text:SetText(choice.label)
			UI.Color(row.text, choice.value == self.value and C.GOLD or C.TEXT)
			row:SetScript("OnClick", function()
				menu:Hide()
				b:SetValue(choice.value)
				if onPick then onPick(choice.value) end
			end)
			row:Show()
		end
		for i = #items + 1, #menu.rows do menu.rows[i]:Hide() end
		menu:SetSize(math.max(self:GetWidth(), 80), #items * 20 + 2)
		menu:Show()
	end)
	b:HookScript("OnHide", function() menu:Hide() end)
	return b
end

-- Scrolling ---------------------------------------------------------------------------

local WHEEL_STEP = 48

-- Scroll area with a thin gold bar. Returns the scroll frame; s.content holds the rows.
-- Set s.content's height after filling it.
function UI.Scroll(parent)
	local s = CreateFrame("ScrollFrame", nil, parent)
	local bar = CreateFrame("Button", nil, parent)
	s.bar = bar
	bar:SetWidth(8)
	bar:SetPoint("TOPLEFT", s, "TOPRIGHT", 4, 0)
	bar:SetPoint("BOTTOMLEFT", s, "BOTTOMRIGHT", 4, 0)
	bar.track = UI.Fill(bar, "BACKGROUND", C.LINE, 0.45)
	bar.track:SetPoint("TOP")
	bar.track:SetPoint("BOTTOM")
	bar.track:SetWidth(2)
	local thumb = CreateFrame("Button", nil, bar)
	s.thumb = thumb
	thumb:SetWidth(8)
	thumb.fill = UI.Fill(thumb, "ARTWORK", C.GOLD_DIM, 1)
	thumb.fill:SetPoint("TOP")
	thumb.fill:SetPoint("BOTTOM")
	thumb.fill:SetWidth(4)

	local content = CreateFrame("Frame", nil, s)
	content:SetSize(10, 10)
	s:SetScrollChild(content)
	s.content = content
	s:SetScript("OnSizeChanged", function(self, width) content:SetWidth(width) end)

	local function range() return math.max(0, s:GetVerticalScrollRange() or 0) end
	local function view() return s:GetHeight() or 0 end

	function s:Sync()
		local max, height = range(), view()
		local needed = max > 0.5 and height > 0
		bar:SetShown(needed)
		if not needed then return end
		local size = math.max(24, height * height / (height + max))
		thumb:SetHeight(size)
		thumb:ClearAllPoints()
		thumb:SetPoint("TOP", 0, -(height - size) * math.min(1, (self:GetVerticalScroll() or 0) / max))
	end

	function s:ScrollTo(offset)
		self:SetVerticalScroll(math.max(0, math.min(range(), offset)))
		self:Sync()
	end

	s:EnableMouseWheel(true)
	s:SetScript("OnMouseWheel", function(self, delta) self:ScrollTo((self:GetVerticalScroll() or 0) - delta * WHEEL_STEP) end)
	s:SetScript("OnScrollRangeChanged", function(self) self:ScrollTo(self:GetVerticalScroll() or 0) end)
	s:SetScript("OnVerticalScroll", function(self) self:Sync() end)
	s:SetScript("OnShow", function(self) self:Sync() end)

	local function color(c) thumb.fill:SetColorTexture(c[1], c[2], c[3], 1) end
	thumb:SetScript("OnEnter", function() color(C.GOLD) end)
	thumb:SetScript("OnLeave", function(self) if not self.dragging then color(C.GOLD_DIM) end end)
	thumb:SetScript("OnMouseDown", function(self)
		self.dragging = true
		local _, y = GetCursorPosition()
		self.fromY, self.fromScroll = y, s:GetVerticalScroll() or 0
		self:SetScript("OnUpdate", function(me)
			local _, now = GetCursorPosition()
			local travel = view() - (me:GetHeight() or 24)
			if travel <= 0 then return end
			s:ScrollTo(me.fromScroll + (me.fromY - now) / (me:GetEffectiveScale() or 1) * range() / travel)
		end)
	end)
	local function release(self)
		self.dragging = nil
		self:SetScript("OnUpdate", nil)
		color(C.GOLD_DIM)
	end
	thumb:SetScript("OnMouseUp", release)
	thumb:SetScript("OnHide", release)
	bar:SetScript("OnMouseDown", function(self)
		local _, y = GetCursorPosition()
		local top = thumb:GetTop()
		if not top then return end
		local up = y / (self:GetEffectiveScale() or 1) > top
		s:ScrollTo((s:GetVerticalScroll() or 0) + (up and -1 or 1) * view() * 0.9)
	end)
	bar:Hide()
	return s
end

-- Rows that are reused. pool = UI.Pool(function(i) return frame end).
-- pool:Get(i) gives row i (made when first asked); pool:HideFrom(i) hides rows i and up.
function UI.Pool(make)
	local pool = { rows = {} }
	function pool:Get(i)
		local row = self.rows[i]
		if not row then
			row = make(i)
			self.rows[i] = row
		end
		row:Show()
		return row
	end
	function pool:HideFrom(i)
		for n = i, #self.rows do self.rows[n]:Hide() end
	end
	return pool
end

-- Windows -----------------------------------------------------------------------------

-- A movable black window with a gold title and a close button. Its place is saved under
-- `name`. Returns the frame; put things on frame.body.
-- opts: { escape = true (close on Escape), strata = "MEDIUM", noClose = false,
--         scaleKey = a setting in percent: the window follows it }
function UI.Window(name, title, width, height, opts)
	opts = opts or {}
	local f = CreateFrame("Frame", "Lootomania" .. name, UIParent, "BackdropTemplate")
	f:SetSize(width, height)
	f:SetFrameStrata(opts.strata or "MEDIUM")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	UI.Panel(f, C.BLACK, 0.96, C.GOLD_DIM)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")

	local function place()
		local saved = ns.db and ns.db.windows[name]
		f:ClearAllPoints()
		if saved and saved.x then
			f:SetPoint(saved.point or "CENTER", UIParent, saved.rel or saved.point or "CENTER", saved.x, saved.y)
		else
			f:SetPoint("CENTER", UIParent, "CENTER", opts.x or 0, opts.y or 0)
		end
	end
	f.Place = place
	f:SetScript("OnDragStart", function(self) if not self.locked then self:StartMoving() end end)
	-- by the top left corner: a window that changes height keeps its top edge
	local function save()
		local left, top = f:GetLeft(), f:GetTop()
		if left and top then
			ns.db.windows[name] = { point = "TOPLEFT", rel = "BOTTOMLEFT", x = left, y = top }
		end
	end
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		save()
	end)

	-- Each window has its own scale setting. A change keeps the top left corner in place;
	-- the saved place is in the window's own scale, so it is saved again.
	if opts.scaleKey then
		local function wanted() return math.max(0.3, (tonumber(ns.db[opts.scaleKey]) or 100) / 100) end
		ns.OnLoad(function() f:SetScale(wanted()) end)
		ns.Listen("SETTINGS_CHANGED", function(key)
			if key ~= opts.scaleKey then return end
			local old, new = f:GetScale(), wanted()
			local left, top = f:GetLeft(), f:GetTop()
			f:SetScale(new)
			if left and top then
				f:ClearAllPoints()
				f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * old / new, top * old / new)
				if ns.db.windows[name] then save() end
			end
		end)
	end

	f.title = UI.Heading(f, 20)
	f.title:SetPoint("TOPLEFT", 14, -10)
	f.title:SetText(title or "")

	if not opts.noClose then
		local close = UI.Button(f, "x", 22, 22)
		close:SetPoint("TOPRIGHT", -8, -8)
		close:SetScript("OnClick", function() f:Hide() end)
		f.close = close
	end

	f.rule = UI.Divider(f, width - 28)
	f.rule:SetPoint("TOP", 0, -38)

	f.body = CreateFrame("Frame", nil, f)
	f.body:SetPoint("TOPLEFT", 12, -46)
	f.body:SetPoint("BOTTOMRIGHT", -12, 12)

	if opts.escape ~= false then table.insert(UISpecialFrames, f:GetName()) end
	f:Hide()
	ns.OnLoad(place)
	return f
end

-- Row of tabs. tabs: list of { key = , label = }. onPick(key). Returns the bar;
-- bar:Select(key) marks one.
function UI.Tabs(parent, tabs, onPick, tabWidth)
	local bar = CreateFrame("Frame", nil, parent)
	bar:SetHeight(24)
	bar.buttons = {}
	function bar:Select(key)
		self.selected = key
		for k, b in pairs(self.buttons) do b:SetOn(k == key) end
	end
	function bar:Add(tab)
		local b = UI.Button(self, tab.label, tabWidth or math.max(70, #tab.label * 7 + 22), 24)
		local n = 0
		local last
		for _, other in pairs(self.buttons) do
			n = n + 1
			if not last or other.index > last.index then last = other end
		end
		b.index = n + 1
		if last then b:SetPoint("LEFT", last, "RIGHT", 4, 0) else b:SetPoint("LEFT", 0, 0) end
		b:SetScript("OnClick", function()
			self:Select(tab.key)
			if onPick then onPick(tab.key) end
		end)
		self.buttons[tab.key] = b
		return b
	end
	for _, tab in ipairs(tabs or {}) do bar:Add(tab) end
	return bar
end

-- Text for money in copper: "1g 20s 5c".
function UI.Money(copper)
	copper = math.floor(copper or 0)
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local out = {}
	if g > 0 then out[#out + 1] = UI.Colored(g .. "g", C.GOLD) end
	if s > 0 then out[#out + 1] = UI.Colored(s .. "s", { 0.78, 0.78, 0.80 }) end
	if c > 0 or #out == 0 then out[#out + 1] = UI.Colored(c .. "c", { 0.80, 0.52, 0.30 }) end
	return table.concat(out, " ")
end
