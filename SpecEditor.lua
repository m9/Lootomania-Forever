local _, ns = ...

-- Custom spec editor: a pop-up for a spec's name, icon and stat weights. It opens from the spec
-- lists of the Upgrades and Simulator tabs: "New spec..." and the pencil on a custom spec.
--   ns.SpecEditor.Open({ class =, spec =, new = true|nil, onSave = function(key) })
-- spec: a spec of the class. new: start a new spec from its weights. Without new the custom
-- spec is edited. Deleting is done from the list (ns.SpecEditor.AskRemove: a yes or no box first).
-- The icon is picked from the game's macro icons; a spec without one shows the question mark.

local UI = ns.UI
local C = UI.C
local E = {}
ns.SpecEditor = E

local function Call(...) return ns.Upgrades.Call(...) end
local function List(...) return ns.Upgrades.List(...) end

local WIDTH, HEIGHT = 330, 470
local STAT_ROW = 24

local window, view, picker
local edit -- { class, key (nil for a new spec), base, label, icon, weights, dps, dpsRanged, shown, onSave }

local function Copy(t)
	local out = {}
	for k, v in pairs(type(t) == "table" and t or {}) do out[k] = v end
	return out
end

local function Number(text)
	if type(text) ~= "string" then return nil end
	return tonumber((text:gsub(",", "."):gsub("%s", "")))
end

local function Show(v)
	return ("%.4g"):format(tonumber(v) or 0)
end

local function Custom(class, key)
	for _, c in ipairs(List("CustomSpecs", class)) do
		if c.key == key then return c end
	end
	return nil
end

local function HasSpec(class, key)
	for _, s in ipairs(List("Specs", class)) do
		if s.key == key then return true end
	end
	return false
end

local function MakeKey(class, name)
	local base = "custom_" .. name:lower():gsub("[^%w]+", "_")
	local key, n = base, 1
	while HasSpec(class, key) do
		n = n + 1
		key = base .. n
	end
	return key
end

local Fill

-- Icons ---------------------------------------------------------------------------------------------
-- The icon list works with names: the game's icon files, by the names the build read from the
-- client's file list (Gear.IconNames). The game's own macro icon lists are file ids with no
-- names, so they cannot be searched.

local ICON_FOLDER = "Interface\\Icons\\"
local NO_ICON = ICON_FOLDER .. "INV_Misc_QuestionMark"
local ICON_COLS, ICON_ROWS, ICON_STEP = 8, 6, 36
local SEARCH_HEIGHT = 28

-- The file name of an icon path, lower case; nil for a file id.
local function IconName(texture)
	if type(texture) ~= "string" then return nil end
	return (texture:lower():gsub("^.*[\\/]", ""):gsub("%.blp$", ""))
end

-- Square picture button. b:SetIcon(texture, picked): a path or a file id, nil for the question mark.
local function IconButton(parent, size, edge)
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
	b:SetSize(size, size)
	UI.Panel(b, C.BLACK, 1, edge)
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetPoint("TOPLEFT", 1, -1)
	b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	function b:Paint()
		local c = (self.over or self.picked) and C.GOLD or edge
		self:SetBackdropBorderColor(c[1], c[2], c[3], 1)
	end
	function b:SetIcon(texture, picked)
		self.texture, self.picked = texture, picked and true or false
		self.icon:SetTexture(texture or NO_ICON)
		self:Paint()
	end
	b:SetScript("OnEnter", function(self) self.over = true self:Paint() end)
	b:SetScript("OnLeave", function(self) self.over = false self:Paint() end)
	return b
end

-- The icons to choose from, by name: the question mark, the class's own spec icons, icons the
-- player put into Interface\Icons, then every icon of the game in name order.
local function IconChoices(class)
	local out, seen = {}, {}
	local function add(name)
		if name and name ~= "" and not seen[name] then
			seen[name] = true
			out[#out + 1] = name
		end
	end
	add(IconName(NO_ICON))
	for _, spec in ipairs(List("Specs", class)) do
		if not spec.custom then add(IconName(spec.icon)) end
	end
	local loose = {}
	local fill = _G.GetLooseMacroIcons
	if type(fill) == "function" then pcall(fill, loose) end
	for _, name in ipairs(loose) do add(IconName(name)) end
	for _, name in ipairs(List("IconNames")) do add(name) end
	return out
end

-- The names that have every word of the search text.
local function Matching(names, text)
	local words = {}
	for word in (text or ""):lower():gmatch("%S+") do words[#words + 1] = word end
	if #words == 0 then return names end
	local out = {}
	for _, name in ipairs(names) do
		local all = true
		for _, word in ipairs(words) do
			if not name:find(word, 1, true) then
				all = false
				break
			end
		end
		if all then out[#out + 1] = name end
	end
	return out
end

-- Draws the rows of the icon list that are in view; the cells are reused while it scrolls.
local function DrawIcons()
	if not (picker and picker.list and edit) then return end
	local inUse = IconName(edit.icon or NO_ICON)
	local first = math.floor((picker.scroll:GetVerticalScroll() or 0) / ICON_STEP)
	for i, cell in ipairs(picker.cells) do
		local row, col = first + math.floor((i - 1) / ICON_COLS), (i - 1) % ICON_COLS
		local name = picker.list[row * ICON_COLS + col + 1]
		cell:SetShown(name ~= nil)
		cell.name = name
		if name then
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT", col * ICON_STEP, -row * ICON_STEP)
			cell:SetIcon(ICON_FOLDER .. name, name == inUse)
		end
	end
end

-- Shows the icons that match the search text, from the top.
local function Search(text)
	if not (picker and picker.all) then return end
	picker.list = Matching(picker.all, text)
	picker.count:SetText(#picker.list == 1 and "1 icon" or (#picker.list .. " icons"))
	picker.scroll.content:SetHeight(math.max(1, math.ceil(#picker.list / ICON_COLS) * ICON_STEP))
	picker.scroll:ScrollTo(0)
	DrawIcons()
end

local function BuildPicker()
	local width = ICON_COLS * ICON_STEP + 24 + 14
	picker = UI.Window("SpecIcon", "Icon", width, 46 + SEARCH_HEIGHT + ICON_ROWS * ICON_STEP + 14, { strata = "DIALOG", x = (WIDTH + width) / 2 + 8 })
	picker.search = UI.Edit(picker.body, 170, Search)
	picker.search:SetPoint("TOPLEFT", 0, 0)
	UI.Tip(picker.search, "Search", { "Part of an icon's name: fire, sword, nature" })
	picker.count = UI.Text(picker.body, "GameFontHighlightSmall", C.MUTED)
	picker.count:SetPoint("TOPRIGHT", -14, -5)
	picker.count:SetJustifyH("RIGHT")
	picker.scroll = UI.Scroll(picker.body)
	picker.scroll:SetPoint("TOPLEFT", 0, -SEARCH_HEIGHT)
	picker.scroll:SetPoint("BOTTOMRIGHT", -14, 0)
	picker.cells = {}
	for i = 1, ICON_COLS * (ICON_ROWS + 1) do
		local cell = IconButton(picker.scroll.content, ICON_STEP - 2, C.LINE)
		cell:SetScript("OnClick", function(self)
			E.SetIcon(self.texture)
			picker:Hide()
		end)
		cell:HookScript("OnEnter", function(self) if self.name then UI.TextTooltip(self, self.name) end end)
		cell:HookScript("OnLeave", UI.HideTooltip)
		picker.cells[i] = cell
	end
	picker.scroll:HookScript("OnVerticalScroll", DrawIcons)
	-- the names are held only while the list is open
	picker:HookScript("OnHide", function(self) self.all, self.list = nil, nil end)
end

-- Opens the icon list for the spec in the editor.
function E.PickIcon()
	if not edit then return end
	if not picker then BuildPicker() end
	picker.all = IconChoices(edit.class)
	picker.search:SetText("")
	picker:Show()
	picker:Raise()
	Search("")
end

-- Types into the icon list's search box, for tests.
function E.SearchIcons(text)
	if not (picker and picker:IsShown()) then return end
	picker.search:SetText(text)
	Search(text)
end

-- Sets the icon of the spec in the editor: a path or a file id; nil or the question mark for none.
function E.SetIcon(texture)
	if not edit then return end
	edit.icon = (texture and IconName(texture) ~= IconName(NO_ICON)) and texture or nil
	if view then view.icon:SetIcon(edit.icon) end
end

-- The editor's icon button, for tests.
function E.IconButton() return view and view.icon end

local function StatRow(i)
	local row = CreateFrame("Frame", nil, view.stats.content)
	row:SetHeight(STAT_ROW - 2)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * STAT_ROW)
	row:SetPoint("TOPRIGHT", 0, -(i - 1) * STAT_ROW)
	row.label = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
	row.label:SetPoint("LEFT", 2, 0)
	row.label:SetWidth(170)
	row.box = UI.Edit(row, 64, function(text)
		if row.stat and edit then edit.weights[row.stat] = Number(text) or 0 end
	end)
	row.box:SetPoint("LEFT", 178, 0)
	row.drop = UI.Button(row, "x", 20, 20)
	row.drop:SetPoint("LEFT", row.box, "RIGHT", 6, 0)
	row.drop:SetScript("OnClick", function()
		if not (row.stat and edit) then return end
		edit.weights[row.stat] = nil
		edit.shown[row.stat] = nil
		Fill()
	end)
	UI.Tip(row.drop, "Remove stat")
	return row
end

function Fill()
	if not (window and edit) then return end
	window.title:SetText(edit.key and "Edit spec" or "New spec")
	view.name:SetText(edit.label or "")
	view.icon:SetIcon(edit.icon)
	view.base:SetText(ns.Upgrades.ClassLabel(edit.class) .. ", based on " .. ns.Upgrades.SpecLabel(edit.class, edit.base))
	view.dps:SetText(Show(edit.dps))
	view.dpsRanged:SetText(Show(edit.dpsRanged))
	local n = 0
	-- the weights the scorer reads (Gear.WeightKeys), not the stat keys: a weight typed for
	-- "Expertise" or a weapon skill was saved under a key nothing read
	for _, stat in ipairs(List("WeightKeys")) do
		if edit.shown[stat] then
			n = n + 1
			local row = view.pool:Get(n)
			row.stat = stat
			row.label:SetText(Call("WeightLabel", stat) or stat)
			row.box:SetText(Show(edit.weights[stat]))
		end
	end
	view.pool:HideFrom(n + 1)
	view.stats.content:SetHeight(math.max(1, n * STAT_ROW))
end

local function AddChoices()
	local out = {}
	if not edit then return out end
	for _, stat in ipairs(List("WeightKeys")) do
		if not edit.shown[stat] then out[#out + 1] = { value = stat, label = Call("WeightLabel", stat) or stat } end
	end
	return out
end

local function Label(parent, text, x, y)
	local fs = UI.Text(parent, "GameFontHighlightSmall", C.MUTED)
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

local function Build()
	window = UI.Window("SpecEditor", "New spec", WIDTH, HEIGHT, { strata = "DIALOG" })
	view = {}
	local body = window.body

	view.icon = IconButton(body, 40, C.GOLD_DIM)
	view.icon:SetPoint("TOPLEFT", 0, -2)
	view.icon:SetScript("OnClick", function() E.PickIcon() end)
	UI.Tip(view.icon, "Icon")
	view.name = UI.Edit(body, 190, function(text) if edit then edit.label = text end end)
	view.name:SetPoint("TOPLEFT", 48, -2)
	UI.Tip(view.name, "Name")
	view.base = Label(body, "", 50, -30)
	window:HookScript("OnHide", function() if picker then picker:Hide() end end)

	Label(body, "Weapon DPS", 2, -56)
	view.dps = UI.Edit(body, 64, function(text) if edit then edit.dps = Number(text) or 0 end end)
	view.dps:SetPoint("TOPLEFT", 178, -51)
	Label(body, "Ranged DPS", 2, -80)
	view.dpsRanged = UI.Edit(body, 64, function(text) if edit then edit.dpsRanged = Number(text) or 0 end end)
	view.dpsRanged:SetPoint("TOPLEFT", 178, -75)

	view.stats = UI.Scroll(body)
	view.stats:SetPoint("TOPLEFT", 0, -104)
	view.stats:SetPoint("BOTTOMRIGHT", -14, 34)
	view.pool = UI.Pool(StatRow)

	view.add = ns.Filters.ListPicker(body, 96, AddChoices, function(stat)
		if not edit then return end
		edit.shown[stat] = true
		edit.weights[stat] = edit.weights[stat] or 0
		Fill()
	end, { fixed = "Add stat", up = true, rows = 14, menuWidth = 200 })
	view.add:SetPoint("BOTTOMLEFT", 0, 2)

	view.save = UI.Button(body, "Save", 64, 22)
	view.save:SetPoint("BOTTOMRIGHT", 0, 2)
	view.save:SetScript("OnClick", function() E.Save() end)
end

function E.Open(opts)
	opts = opts or {}
	local class = opts.class or (ns.player and ns.player.class)
	if not class then return end
	local custom = opts.spec and Custom(class, opts.spec) or nil
	local editing = custom and not opts.new
	local from = custom or Call("Weights", class, opts.spec)
	from = type(from) == "table" and from or {}
	edit = {
		class = class,
		key = editing and custom.key or nil,
		base = custom and custom.base or opts.spec,
		label = editing and custom.label or "",
		icon = editing and custom.icon or nil,
		weights = Copy(from.weights),
		dps = tonumber(from.dps) or 0,
		dpsRanged = tonumber(from.dpsRanged) or 0,
		shown = {},
		onSave = opts.onSave,
	}
	for stat, weight in pairs(edit.weights) do
		if weight ~= 0 then edit.shown[stat] = true end
	end
	if not window then Build() end
	Fill()
	window:Show()
	if view.stats.ScrollTo then view.stats:ScrollTo(0) end
end

-- Saves the spec. Returns its key, or nil when it has no name.
function E.Save()
	if not edit then return nil end
	-- the box keeps edit.label up to date as the player types
	local name = (edit.label or ""):match("^%s*(.-)%s*$")
	if name == "" then
		ns.Print("Custom spec: name needed")
		return nil
	end
	local weights = {}
	for stat, weight in pairs(edit.weights) do
		if edit.shown[stat] and type(weight) == "number" and weight ~= 0 then weights[stat] = weight end
	end
	local spec = {
		key = edit.key or MakeKey(edit.class, name), label = name, base = edit.base, icon = edit.icon,
		weights = weights, dps = edit.dps or 0, dpsRanged = edit.dpsRanged or 0,
	}
	local saved = Call("SaveCustom", edit.class, spec)
	local key = type(saved) == "string" and saved or spec.key
	ns.Print("Custom spec saved: " .. name)
	local done = edit.onSave
	edit = nil
	if window then window:Hide() end
	if done then ns.Safe(done, key) end
	return key
end

-- Deletes a custom spec. Returns the spec it was based on, or nil when that one is gone too.
function E.Remove(class, key)
	local custom = Custom(class, key)
	if not custom then return nil end
	Call("DeleteCustom", class, key)
	ns.Print("Custom spec deleted: " .. tostring(custom.label))
	-- an editor open on it has nothing left to edit
	if edit and edit.class == class and edit.key == key then E.Close() end
	return HasSpec(class, custom.base) and custom.base or nil
end

-- Asks in the game's own message box, then deletes. done(key, baseKey or nil) runs after a yes.
local DIALOG = "LOOTOMANIA_DELETE_SPEC"

function E.AskRemove(class, key, done)
	local custom = Custom(class, key)
	if not custom then return end
	local function remove()
		local base = E.Remove(class, key)
		if done then ns.Safe(done, key, base) end
	end
	if not (StaticPopupDialogs and StaticPopup_Show) then
		remove()
		return
	end
	if not StaticPopupDialogs[DIALOG] then
		StaticPopupDialogs[DIALOG] = {
			text = "Delete the custom spec \"%s\"?",
			button1 = YES or "Yes",
			button2 = NO or "No",
			OnAccept = function(_, data) if type(data) == "function" then data() end end,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			showAlert = true,
			preferredIndex = 3,
		}
	end
	StaticPopup_Show(DIALOG, custom.label, nil, remove)
end

function E.Close()
	edit = nil
	if window then window:Hide() end
end

function E.IsShown() return window ~= nil and window:IsShown() end

-- The spec in the editor, for tests.
function E.Editing() return edit end
