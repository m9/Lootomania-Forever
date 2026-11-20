local _, ns = ...

-- Custom spec editor: a pop-up for a spec's name and stat weights. It opens from the spec
-- lists of the Upgrades and Simulator tabs: "New spec..." and the pencil on a custom spec.
--   ns.SpecEditor.Open({ class =, spec =, new = true|nil, onSave = function(key) })
-- spec: a spec of the class. new: start a new spec from its weights. Without new the custom
-- spec is edited. Deleting is done from the list (ns.SpecEditor.AskRemove: a yes or no box first).

local UI = ns.UI
local C = UI.C
local E = {}
ns.SpecEditor = E

local function Call(...) return ns.Upgrades.Call(...) end
local function List(...) return ns.Upgrades.List(...) end

local WIDTH, HEIGHT = 330, 470
local STAT_ROW = 24

local window, view
local edit -- { class, key (nil for a new spec), base, label, weights, dps, dpsRanged, shown, onSave }

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
	view.base:SetText(ns.Upgrades.ClassLabel(edit.class) .. ", based on " .. ns.Upgrades.SpecLabel(edit.class, edit.base))
	view.dps:SetText(Show(edit.dps))
	view.dpsRanged:SetText(Show(edit.dpsRanged))
	local n = 0
	for _, stat in ipairs(List("StatKeys")) do
		if edit.shown[stat] then
			n = n + 1
			local row = view.pool:Get(n)
			row.stat = stat
			row.label:SetText(Call("StatLabel", stat) or stat)
			row.box:SetText(Show(edit.weights[stat]))
		end
	end
	view.pool:HideFrom(n + 1)
	view.stats.content:SetHeight(math.max(1, n * STAT_ROW))
end

local function AddChoices()
	local out = {}
	if not edit then return out end
	for _, stat in ipairs(List("StatKeys")) do
		if not edit.shown[stat] then out[#out + 1] = { value = stat, label = Call("StatLabel", stat) or stat } end
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

	view.name = UI.Edit(body, 190, function(text) if edit then edit.label = text end end)
	view.name:SetPoint("TOPLEFT", 0, -2)
	UI.Tip(view.name, "Name")
	view.base = Label(body, "", 2, -30)

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
		key = edit.key or MakeKey(edit.class, name), label = name, base = edit.base,
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
