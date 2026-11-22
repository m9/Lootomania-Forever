local _, ns = ...

-- The "Simulator" tab: best pick per slot for any class, spec, faction and level
-- (Gear.SetPreview). Custom specs are made and changed from its spec list, in the spec
-- editor pop-up (SpecEditor.lua).

local UI = ns.UI
local C = UI.C
local S = {}
ns.Simulator = S

local function Call(...) return ns.Upgrades.Call(...) end
local function List(...) return ns.Upgrades.List(...) end

local view = {}
local sim -- { class, spec, faction, level }

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

-- Tab ---------------------------------------------------------------------------------------------

local function Fill()
	if not view.over then return end
	view.class:SetValue(sim.class)
	view.spec:SetValue(sim.spec)
	view.faction:SetValue(sim.faction)
	view.level:SetValue(sim.level)
	local ctx = SimContext()
	-- the filters of the Upgrades tab are the player's own and have no bar here: left out
	view.over:Fill(function(slot) return List("List", slot, ctx, { count = 1, plain = true })[1] end, true)
	local active = Call("Context")
	view.back:SetEnabled(type(active) == "table" and active.preview and true or false)
	-- the player's own class at another level or spec: the gains are against what is worn now
	view.note:SetShown(ns.player ~= nil and sim.class == ns.player.class)
end

local function Apply()
	Call("SetPreview", SimContext())
	Fill()
end

local applyLater = ns.Debounce(0.25, function() Apply() end)

local function Build(panel)
	if not sim then Init() end

	view.class = UI.Picker(panel, 130, function()
		local out = {}
		for _, c in ipairs(List("Classes")) do out[#out + 1] = { value = c.key, label = c.label or c.key } end
		return out
	end, function(class)
		sim.class = class
		sim.spec = FirstSpec(class)
		if ns.SpecEditor then ns.SpecEditor.Close() end -- it was for the other class
		Apply()
	end)
	view.class:SetPoint("TOPLEFT", 0, -6)
	UI.Tip(view.class, "Class")

	local function pick(spec)
		sim.spec = spec or FirstSpec(sim.class)
		Apply()
	end
	local after = {
		save = pick, -- a saved spec becomes the previewed one
		-- the previewed spec was deleted: back to its base; another one: nothing changes
		delete = function(key, base) pick(sim.spec == key and base or sim.spec) end,
	}
	view.spec = UI.Picker(panel, 170, function() return ns.Upgrades.SpecChoices(sim.class, after) end, function(spec)
		if ns.Upgrades.SpecCommand(spec, sim.class, sim.spec, pick) then return end
		pick(spec)
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
		Fill()
	end)

	view.note = UI.Text(panel, "GameFontHighlightSmall", C.FAINT, 11)
	view.note:SetPoint("TOPLEFT", 2, -30)
	view.note:SetText("Gains: against what you wear now. Click a slot for its list.")

	local top = -44
	local box = UI.Box(panel)
	box:SetPoint("TOPLEFT", 0, top)
	box:SetPoint("BOTTOMRIGHT", 0, 0)
	view.over = ns.Upgrades.Overview(box, ns.Main.PANEL_WIDTH - 8)
	view.over:SetPoint("TOPLEFT", 4, -4)
	view.over.onPick = function(slot) ns.Upgrades.OpenSlot(slot) end
end

ns.Main.AddTab("simulator", "Simulator", 150, Build, function()
	if not sim then Init() end
	Fill()
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
	Fill()
end

ns.Command("sim", "Simulator", function() ns.Main.Toggle("simulator") end)
