local _, ns = ...

-- The "Simulator" tab: best pick per slot for any class, spec, faction and level
-- (Gear.SetPreview), and the editor for custom spec weights.

local UI = ns.UI
local C = UI.C
local S = {}
ns.Simulator = S

local function Call(...) return ns.Upgrades.Call(...) end
local function List(...) return ns.Upgrades.List(...) end

local view = {}
local sim -- { class, spec, faction, level }
local edit -- the custom spec in the editor

local function Copy(t)
	local out = {}
	for k, v in pairs(type(t) == "table" and t or {}) do out[k] = v end
	return out
end

local function FirstSpec(class)
	local first = List("Specs", class)[1]
	return first and first.key or nil
end

local function HasSpec(class, key)
	for _, s in ipairs(List("Specs", class)) do
		if s.key == key then return true end
	end
	return false
end

-- Starts from the active context: the preview when one is set, else the player.
local function Init()
	local ctx = Call("Context") or Call("PlayerContext")
	ctx = type(ctx) == "table" and ctx or {}
	sim = {
		class = ctx.class or (ns.player and ns.player.class),
		spec = ctx.spec,
		faction = ctx.faction or (ns.player and ns.player.faction) or "Alliance",
		level = ctx.level or 60,
	}
	if not sim.spec or not HasSpec(sim.class, sim.spec) then sim.spec = FirstSpec(sim.class) or sim.spec end
end

local function SimContext()
	return { class = sim.class, spec = sim.spec, faction = sim.faction, level = sim.level, preview = true }
end

-- Editor ------------------------------------------------------------------------------------------

local function Number(text)
	if type(text) ~= "string" then return nil end
	return tonumber((text:gsub(",", "."):gsub("%s", "")))
end

local function Show(v)
	return ("%.4g"):format(tonumber(v) or 0)
end

local function LoadEdit()
	local custom
	for _, c in ipairs(List("CustomSpecs", sim.class)) do
		if c.key == sim.spec then custom = c end
	end
	local from = custom or Call("Weights", sim.class, sim.spec)
	from = type(from) == "table" and from or {}
	edit = {
		class = sim.class,
		key = custom and custom.key or nil,
		base = custom and custom.base or sim.spec,
		label = custom and custom.label or "",
		weights = Copy(from.weights),
		dps = tonumber(from.dps) or 0,
		dpsRanged = tonumber(from.dpsRanged) or 0,
		shown = {},
	}
	for stat, weight in pairs(edit.weights) do
		if weight ~= 0 then edit.shown[stat] = true end
	end
end

local STAT_ROW = 24

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
		S.FillEdit()
	end)
	UI.Tip(row.drop, "Remove stat")
	return row
end

function S.FillEdit()
	if not (view.stats and edit) then return end
	view.name:SetText(edit.label or "")
	view.base:SetText("Base: " .. ns.Upgrades.SpecLabel(edit.class, edit.base))
	view.dps:SetText(Show(edit.dps))
	view.dpsRanged:SetText(Show(edit.dpsRanged))
	view.delete:SetEnabled(edit.key ~= nil)
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

local function MakeKey(class, name)
	local base = "custom_" .. name:lower():gsub("[^%w]+", "_")
	local key, n = base, 1
	while HasSpec(class, key) do
		n = n + 1
		key = base .. n
	end
	return key
end

local Apply

-- Saves the editor's spec. Returns its key, or nil when it has no name.
function S.Save()
	if not edit then return nil end
	local name = (view.name and view.name:GetText() or edit.label or ""):match("^%s*(.-)%s*$")
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
	sim.spec = key
	LoadEdit()
	Apply()
	return key
end

function S.Delete()
	if not (edit and edit.key) then return end
	local label = edit.label
	Call("DeleteCustom", edit.class, edit.key)
	ns.Print("Custom spec deleted: " .. tostring(label))
	sim.spec = HasSpec(sim.class, edit.base) and edit.base or FirstSpec(sim.class)
	LoadEdit()
	Apply()
end

-- Tab ---------------------------------------------------------------------------------------------

local function Fill()
	if not view.over then return end
	view.class:SetValue(sim.class)
	view.spec:SetValue(sim.spec)
	view.faction:SetValue(sim.faction)
	view.level:SetValue(sim.level)
	local ctx = SimContext()
	view.over:Fill(function(slot) return List("List", slot, ctx, { count = 1 })[1] end)
	local active = Call("Context")
	view.back:SetEnabled(type(active) == "table" and active.preview and true or false)
end

function Apply()
	Call("SetPreview", SimContext())
	Fill()
	S.FillEdit()
end

local applyLater = ns.Debounce(0.25, function() Apply() end)

local function Label(parent, text, x, y)
	local fs = UI.Text(parent, "GameFontHighlightSmall", C.MUTED)
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

local function Build(panel)
	if not sim then Init() end
	LoadEdit()

	view.class = UI.Picker(panel, 130, function()
		local out = {}
		for _, c in ipairs(List("Classes")) do out[#out + 1] = { value = c.key, label = c.label or c.key } end
		return out
	end, function(class)
		sim.class = class
		sim.spec = FirstSpec(class)
		LoadEdit()
		Apply()
	end)
	view.class:SetPoint("TOPLEFT", 0, -6)
	UI.Tip(view.class, "Class")

	view.spec = UI.Picker(panel, 160, function() return ns.Upgrades.SpecChoices(sim.class) end, function(spec)
		sim.spec = spec
		LoadEdit()
		Apply()
	end)
	view.spec:SetPoint("LEFT", view.class, "RIGHT", 4, 0)
	UI.Tip(view.spec, "Spec")

	view.faction = UI.Picker(panel, 100, { { value = "Alliance", label = "Alliance" }, { value = "Horde", label = "Horde" } }, function(faction)
		sim.faction = faction
		Apply()
	end)
	view.faction:SetPoint("LEFT", view.spec, "RIGHT", 4, 0)
	UI.Tip(view.faction, "Faction")

	view.level = UI.Slider(panel, "Level", 1, 60, 1, function(level)
		sim.level = level
		applyLater()
	end, "%d")
	view.level:SetWidth(200)
	view.level:SetPoint("TOPLEFT", 420, 0)

	view.back = UI.Button(panel, "Back to me", 90, 22)
	view.back:SetPoint("TOPRIGHT", 0, -6)
	view.back:SetScript("OnClick", function()
		Call("SetPreview", nil)
		sim = nil
		Init()
		LoadEdit()
		Fill()
		S.FillEdit()
	end)

	local top = -42
	local left = UI.Box(panel)
	left:SetPoint("TOPLEFT", 0, top)
	left:SetPoint("BOTTOMLEFT", 0, 0)
	left:SetWidth(496)
	view.over = ns.Upgrades.Overview(left, 488)
	view.over:SetPoint("TOPLEFT", 4, -4)
	view.over.onPick = function(slot) ns.Upgrades.OpenSlot(slot) end

	local right = UI.Box(panel)
	right:SetPoint("TOPLEFT", 500, top)
	right:SetPoint("BOTTOMRIGHT", 0, 0)
	local head = UI.Heading(right, 16)
	head:SetPoint("TOPLEFT", 10, -8)
	head:SetText("Custom spec")
	view.base = Label(right, "", 10, -32)

	view.name = UI.Edit(right, 170, function(text) if edit then edit.label = text end end)
	view.name:SetPoint("TOPLEFT", 10, -50)
	UI.Tip(view.name, "Name")
	view.save = UI.Button(right, "Save", 60, 22)
	view.save:SetPoint("LEFT", view.name, "RIGHT", 6, 0)
	view.save:SetScript("OnClick", function() S.Save() end)
	view.delete = UI.Button(right, "Delete", 60, 22)
	view.delete:SetPoint("LEFT", view.save, "RIGHT", 4, 0)
	view.delete:SetScript("OnClick", function() S.Delete() end)

	Label(right, "Weapon DPS", 12, -84)
	view.dps = UI.Edit(right, 64, function(text) if edit then edit.dps = Number(text) or 0 end end)
	view.dps:SetPoint("TOPLEFT", 188, -79)
	Label(right, "Ranged DPS", 12, -108)
	view.dpsRanged = UI.Edit(right, 64, function(text) if edit then edit.dpsRanged = Number(text) or 0 end end)
	view.dpsRanged:SetPoint("TOPLEFT", 188, -103)

	view.stats = UI.Scroll(right)
	view.stats:SetPoint("TOPLEFT", 10, -132)
	view.stats:SetPoint("BOTTOMRIGHT", -16, 36)
	view.pool = UI.Pool(StatRow)

	view.add = ns.Filters.ListPicker(right, 110, AddChoices, function(stat)
		if not edit then return end
		edit.shown[stat] = true
		edit.weights[stat] = edit.weights[stat] or 0
		S.FillEdit()
	end, { fixed = "Add stat", up = true, rows = 14 })
	view.add:SetPoint("BOTTOMLEFT", 10, 8)
end

ns.Main.AddTab("simulator", "Simulator", 150, Build, function()
	if not sim then Init() end
	if not edit or edit.class ~= sim.class then LoadEdit() end
	Fill()
	S.FillEdit()
end)

local refresh = ns.Debounce(0.1, function()
	if ns.Main.IsOpen("simulator") then Fill() end
end)
for _, message in ipairs({ "CONTEXT_CHANGED", "GEAR_CHANGED", "HUNTS_CHANGED", "FILTERS_CHANGED" }) do
	ns.Listen(message, refresh)
end

-- Sets the preview from code: S.Preview({ class =, spec =, faction =, level = }) or nil.
function S.Preview(ctx)
	if not ctx then
		Call("SetPreview", nil)
		sim = nil
		Init()
	else
		if not sim then Init() end
		for _, key in ipairs({ "class", "spec", "faction", "level" }) do
			if ctx[key] ~= nil then sim[key] = ctx[key] end
		end
		if not HasSpec(sim.class, sim.spec) then sim.spec = FirstSpec(sim.class) or sim.spec end
		Call("SetPreview", SimContext())
	end
	LoadEdit()
	Fill()
	S.FillEdit()
end

function S.Editing() return edit end

ns.Command("sim", "Simulator", function() ns.Main.Toggle("simulator") end)
