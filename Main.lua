local _, ns = ...

-- The main window. Modules add their own tab with ns.Main.AddTab; this file knows
-- nothing about what is on them.

local UI = ns.UI
local Main = {}
ns.Main = Main

local WIDTH, HEIGHT = 860, 580
Main.WIDTH, Main.HEIGHT = WIDTH, HEIGHT
-- Room a tab's panel has.
Main.PANEL_WIDTH, Main.PANEL_HEIGHT = WIDTH - 24, HEIGHT - 46 - 12 - 32

ns.Defaults({ lastTab = "upgrades" })

local window, tabBar
local tabs = {} -- key -> { key, label, order, build, show, panel }
local order = {}
local current

-- Adds a tab.
--   build(panel)  called once, the first time the tab is opened; fill the panel
--   show(panel)   called each time the tab is opened (optional); refresh here
-- The panel is PANEL_WIDTH x PANEL_HEIGHT.
function Main.AddTab(key, label, position, build, show)
	tabs[key] = { key = key, label = label, order = position or 100, build = build, show = show }
	order[#order + 1] = tabs[key]
	table.sort(order, function(a, b) return a.order < b.order end)
end

local function Build()
	window = UI.Window("Main", "Lootomania", WIDTH, HEIGHT, { scaleKey = "mainScale" })
	tabBar = UI.Tabs(window.body, nil, function(key) Main.Open(key) end)
	tabBar:SetPoint("TOPLEFT", 0, 0)
	tabBar:SetPoint("TOPRIGHT", 0, 0)
	for _, tab in ipairs(order) do tabBar:Add(tab) end
	window:HookScript("OnShow", function() -- HookScript: UI.Window has its own OnShow and OnHide
		Main.Open(current or ns.db.lastTab)
	end)
end

-- The window frame, built when first asked for: the side panel hangs on it.
function Main.Window()
	if not window then Build() end
	return window
end

-- Opens the window on a tab (the last one used when key is nil).
function Main.Open(key)
	if not window then Build() end
	local tab = tabs[key] or tabs[ns.db.lastTab] or order[1]
	if not tab then return end
	-- the side panel is about what the tab showed: another tab closes it
	if current ~= tab.key and ns.Side then ns.Side.Close() end
	current = tab.key
	ns.db.lastTab = tab.key
	if not window:IsShown() then
		window:Show() -- OnShow comes back here
		return
	end
	for _, other in ipairs(order) do
		if other.panel then other.panel:SetShown(other == tab) end
	end
	if not tab.panel then
		tab.panel = CreateFrame("Frame", nil, window.body)
		tab.panel:SetPoint("TOPLEFT", 0, -32)
		tab.panel:SetPoint("BOTTOMRIGHT", 0, 0)
		local ok, err = pcall(tab.build, tab.panel)
		if not ok then ns.Print("|cffff6060" .. tab.key .. "|r", err) end
	end
	tab.panel:Show()
	tabBar:Select(tab.key)
	if tab.show then ns.Safe(tab.show, tab.panel) end
end

function Main.Toggle(key)
	if window and window:IsShown() and (not key or key == current) then
		window:Hide()
	else
		Main.Open(key)
	end
end

function Main.IsOpen(key)
	return window and window:IsShown() and (not key or key == current) or false
end

-- Calls the open tab's show again, if `key` is the open tab.
function Main.Refresh(key)
	if not Main.IsOpen(key) then return end
	local tab = tabs[current]
	if tab and tab.show and tab.panel then ns.Safe(tab.show, tab.panel) end
end

-- Minimap button ----------------------------------------------------------------------

local button

local function Place()
	local angle = math.rad(ns.db.minimap.angle or 215)
	local radius = Minimap:GetWidth() / 2 + 5
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function Follow()
	local centerX, centerY = Minimap:GetCenter()
	local x, y = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	ns.db.minimap.angle = math.floor(math.deg(math.atan2(y / scale - centerY, x / scale - centerX)) % 360 + 0.5)
	Place()
end

local function BuildButton()
	button = CreateFrame("Button", "LootomaniaMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local back = button:CreateTexture(nil, "BACKGROUND")
	back:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	back:SetSize(20, 20)
	back:SetPoint("TOPLEFT", 7, -5)
	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(ns.ICON)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	icon:SetSize(20, 20)
	icon:SetPoint("TOPLEFT", 7, -5)
	local ring = button:CreateTexture(nil, "OVERLAY")
	ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	ring:SetSize(53, 53)
	ring:SetPoint("TOPLEFT")
	button:SetScript("OnClick", function(_, mouse)
		if mouse == "RightButton" then Main.Toggle("settings") else Main.Toggle() end
	end)
	button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", Follow) end)
	button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	button:SetScript("OnEnter", function(self)
		UI.TextTooltip(self, "Lootomania", { "Click: open or close", "Right-click: settings", "Drag: move" }, "ANCHOR_LEFT")
	end)
	button:SetScript("OnLeave", UI.HideTooltip)
end

function Main.ApplyMinimap()
	if not Minimap then return end
	if ns.db.minimapButton == false then
		if button then button:Hide() end
		return
	end
	if not button then BuildButton() end
	Place()
	button:Show()
end

ns.OnLoad(function()
	-- the button's on/off was kept beside its angle; it is a setting of its own now
	if ns.db.minimap.hide then
		ns.db.minimap.hide = false
		ns.db.minimapButton = false
	end
	Main.ApplyMinimap()
end)

ns.Listen("SETTINGS_CHANGED", function(key)
	if key == "minimapButton" then Main.ApplyMinimap() end
end)

-- Settings tab ------------------------------------------------------------------------
-- Modules add their options with ns.Main.AddOption; the tab lays them out in groups.
--   { group = "Roll window", key = "rollSound", kind = "check"|"slider", label = "...",
--     min =, max =, step =, format =, choices = {{value=,label=}}, tip = "...",
--     lazy = true (slider: applies when the mouse button comes up) }
-- Values live in ns.db[key]; a change sends "SETTINGS_CHANGED".

local options = {}
local groups = {}

function Main.AddOption(option)
	options[#options + 1] = option
	if not groups[option.group] then
		groups[option.group] = true
		groups[#groups + 1] = option.group
	end
	if option.default ~= nil then ns.Defaults({ [option.key] = option.default }) end
end

local controls = {}
local ShowSettings

-- Every setting back to its default. Tracked items, history, custom specs and window places are
-- not settings and stay.
function Main.ResetOptions()
	for _, option in ipairs(options) do
		-- keep: a setting whose default would delete what the player has (runs of the history)
		if option.default ~= nil and not option.keep then ns.Set(option.key, option.default) end
	end
	if ShowSettings then ShowSettings() end
end

local function BuildSettings(panel)
	local scroll = UI.Scroll(panel)
	scroll:SetPoint("TOPLEFT", 0, 0)
	scroll:SetPoint("BOTTOMRIGHT", -14, 0)
	local content = scroll.content
	local columnWidth = 270
	local columns = { 0, 0, 0 } -- height used in each column
	for _, group in ipairs(groups) do
		-- next group goes in the shortest column
		local col = 1
		for i = 2, #columns do if columns[i] < columns[col] then col = i end end
		local x, y = (col - 1) * columnWidth, -columns[col]
		local head = UI.Heading(content, 16)
		head:SetPoint("TOPLEFT", x, y)
		head:SetText(group)
		y = y - 24
		for _, option in ipairs(options) do
			if option.group == group then
				local control
				if option.kind == "check" then
					control = UI.Check(content, option.label, function(on) ns.Set(option.key, on) end)
					control:SetPoint("TOPLEFT", x, y)
					y = y - 22
				elseif option.kind == "slider" then
					control = UI.Slider(content, option.label, option.min, option.max, option.step, function(v) ns.Set(option.key, v) end, option.format, option.lazy)
					control:SetWidth(columnWidth - 40)
					control:SetPoint("TOPLEFT", x, y - 2)
					y = y - 40
				end
				if control then
					control.option = option
					controls[#controls + 1] = control
					if option.tip then UI.Tip(control, option.label, { option.tip }) end
				end
			end
		end
		columns[col] = -y + 14
	end
	-- under the columns: all settings back to their defaults, on a second click
	local bottom = math.max(columns[1], columns[2], columns[3]) + 6
	local reset = UI.Button(content, "Reset settings", 150, 22)
	reset:SetPoint("TOPLEFT", 0, -bottom)
	local function disarm(self)
		self.armed = nil
		self:SetLabel("Reset settings")
	end
	reset:SetScript("OnClick", function(self)
		if self.armed and GetTime() < self.armed then
			disarm(self)
			Main.ResetOptions()
			ns.Print("Settings: back to the defaults")
		else
			self.armed = GetTime() + 5
			self:SetLabel("Click again to reset")
		end
	end)
	reset:SetScript("OnHide", disarm)
	UI.Tip(reset, "Reset settings", { "Every setting back to its default, but \"Runs to keep\". Tracked items, history and custom specs stay." })
	content:SetHeight(bottom + 34)
end

ShowSettings = function()
	for _, control in ipairs(controls) do
		local value = ns.db[control.option.key]
		if control.option.kind == "check" then
			control:SetChecked(value)
		elseif value ~= nil then
			control:SetValue(value)
		end
	end
end

Main.AddTab("settings", "Settings", 900, BuildSettings, ShowSettings)

Main.AddOption({ group = "General", key = "welcome", kind = "check", label = "Login message", default = true })
Main.AddOption({ group = "General", key = "minimapButton", kind = "check", label = "Minimap button", default = true })
-- lazy: the slider sits in the window it scales
Main.AddOption({ group = "Main window", key = "mainScale", kind = "slider", label = "Scale", min = 60, max = 140, step = 5,
	format = "%d%%", default = 100, lazy = true })

ns.OnLoad(function()
	if ns.db.welcome then ns.Print("v" .. ns.VERSION .. ". /lm to open.") end
end)
