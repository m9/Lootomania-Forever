local _, ns = ...

-- Unit tooltips: wanted gear a creature drops or sells.

local UI = ns.UI
local C = UI.C
local Mob = {}
ns.MobTips = Mob

ns.Main.AddOption({ group = "Tooltips", key = "mobOn", kind = "check", label = "Gear on creatures", default = true })
ns.Main.AddOption({ group = "Tooltips", key = "mobAll", kind = "check", label = "All gear, not only wanted", default = false,
	tip = "Hold Shift to see all gear." })
ns.Main.AddOption({ group = "Tooltips", key = "mobChance", kind = "check", label = "Drop chance", default = true })
ns.Main.AddOption({ group = "Tooltips", key = "mobMinChance", kind = "slider", label = "Lowest drop chance", min = 0, max = 25, step = 1,
	format = "%d%%", default = 0 })

local LIMIT, LIMIT_ALL = 5, 15

local cache = {} -- npc id -> rows, or false
local done = setmetatable({}, { __mode = "k" })
local hooked = setmetatable({}, { __mode = "k" })
local hover -- npc id of the unit tooltip on screen, when it has gear

function Mob.Clear() wipe(cache) end

local function Collect(npc)
	local Gear = ns.Gear
	local rows, seen = {}, {}
	local function add(list, sold)
		if type(list) ~= "table" then return end
		for _, entry in ipairs(list) do
			local id = entry.id
			local item = id and not seen[id] and Gear.Item(id)
			if item then
				seen[id] = true
				local c = Gear.Compare(Gear.Link(id))
				local up = c and c.usable ~= false and type(c.delta) == "number" and c.delta > 0 or false
				local marked = Gear.IsTracked(id) or (ns.Wish and ns.Wish.Has and ns.Wish.Has(id)) or false
				rows[#rows + 1] = {
					id = id, name = (Gear.Name and Gear.Name(id)) or item.name or ("item " .. id), quality = item.quality, sold = sold,
					chance = entry.chance, cost = entry.cost, up = up, marked = marked and true or false,
					gain = up and (c.gain or c.delta) or nil,
				}
			end
		end
	end
	add(Gear.NpcDrops(npc), false)
	add(Gear.NpcSells(npc), true)
	if #rows == 0 then return false end
	table.sort(rows, function(a, b)
		local wa, wb = a.up or a.marked, b.up or b.marked
		if wa ~= wb then return wa end
		local ga, gb = a.gain or 0, b.gain or 0
		if ga ~= gb then return ga > gb end
		local ca, cb = a.chance or 0, b.chance or 0
		if ca ~= cb then return ca > cb end
		return a.name < b.name
	end)
	return rows
end

-- Rows for an NPC, wanted gear first. Cached.
function Mob.Rows(npc)
	local rows = cache[npc]
	if rows == nil then
		rows = Collect(npc)
		cache[npc] = rows
	end
	return rows
end

local function ChanceText(chance)
	if chance >= 10 then return ("%d%%"):format(math.floor(chance + 0.5)) end
	if chance < 0.1 then return "<0.1%" end
	return (("%.1f"):format(chance):gsub("%.0$", "")) .. "%"
end

local function Add(tooltip, rows, all)
	local db = ns.db
	local min = tonumber(db.mobMinChance) or 0
	local shown = {}
	for _, row in ipairs(rows) do
		local keep = all or row.up or row.marked
		if keep and not all and not row.marked and not row.sold and row.chance and row.chance < min then keep = false end
		if keep then shown[#shown + 1] = row end
	end
	if #shown == 0 then return false end
	tooltip:AddLine(all and "Gear" or "Wanted gear", C.GOLD[1], C.GOLD[2], C.GOLD[3])
	local limit = all and LIMIT_ALL or LIMIT
	for i = 1, math.min(#shown, limit) do
		local row = shown[i]
		local icon = C_Item and C_Item.GetItemIconByID and ns.Plain(C_Item.GetItemIconByID(row.id))
		local left = (icon and ("|T" .. icon .. ":14:14|t ") or "") .. UI.Colored(row.name, UI.QUALITY[row.quality or 1] or C.TEXT)
		local right = {}
		if row.sold then
			right[#right + 1] = row.cost and UI.Money(row.cost) or UI.Colored("Sold", C.MUTED)
		elseif db.mobChance and type(row.chance) == "number" then
			right[#right + 1] = UI.Colored(ChanceText(row.chance), C.MUTED)
		end
		if row.up and ns.Tip then right[#right + 1] = ns.Tip.Gain(row.gain) end
		tooltip:AddDoubleLine(left, table.concat(right, "  "), 1, 1, 1, 1, 1, 1)
	end
	if #shown > limit then
		tooltip:AddLine("+" .. (#shown - limit) .. " more", C.MUTED[1], C.MUTED[2], C.MUTED[3])
	end
	return true
end

local function Npc(data)
	local npc = type(data) == "table" and ns.NpcID(data.guid) or nil
	if npc then return npc end
	local ok, guid = pcall(UnitGUID, "mouseover")
	return ok and ns.NpcID(guid) or nil
end

local function Fill(tooltip, data)
	if tooltip ~= GameTooltip or done[tooltip] then return end
	local db, Gear = ns.db, ns.Gear
	if not db or not db.mobOn or not Gear or not Gear.NpcDrops then return end
	local npc = Npc(data)
	if not npc then return end
	local rows = Mob.Rows(npc)
	if not rows then return end
	if not hooked[tooltip] then
		hooked[tooltip] = pcall(tooltip.HookScript, tooltip, "OnTooltipCleared", function(self)
			done[self] = nil
			hover = nil
		end) or nil
	end
	hover = npc
	local all = db.mobAll or (IsShiftKeyDown and IsShiftKeyDown()) or false
	if Add(tooltip, rows, all) and hooked[tooltip] then done[tooltip] = true end
end

-- The tooltip handler. Never lets an error out.
function Mob.OnUnit(tooltip, data)
	local ok, err = pcall(Fill, tooltip, data)
	if not ok then ns.Debug("mob tooltip", err) end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
	pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Unit, Mob.OnUnit)
else
	ns.OnLoad(function()
		if GameTooltip and GameTooltip.HookScript then
			pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", function(self) Mob.OnUnit(self) end)
		end
	end)
end

-- Shift pressed or let go: build the unit tooltip again.
ns.On("MODIFIER_STATE_CHANGED", function(_, key)
	key = ns.Plain(key)
	if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
	if not hover or not ns.db or not ns.db.mobOn or ns.db.mobAll then return end
	if InCombatLockdown and InCombatLockdown() then return end
	local tooltip = GameTooltip
	if not tooltip or not tooltip:IsShown() then return end
	if tooltip.RefreshData then
		pcall(tooltip.RefreshData, tooltip)
	elseif tooltip.SetUnit and UnitExists then
		local ok, exists = pcall(UnitExists, "mouseover")
		if ok and ns.Plain(exists) == true then pcall(tooltip.SetUnit, tooltip, "mouseover") end
	end
end)

for _, message in ipairs({ "CONTEXT_CHANGED", "GEAR_CHANGED", "FILTERS_CHANGED", "HUNTS_CHANGED", "WISHLIST_CHANGED" }) do
	ns.Listen(message, Mob.Clear)
end
