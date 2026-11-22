local _, ns = ...

-- Unit tooltips: wanted gear a creature drops or sells.

local UI = ns.UI
local C = UI.C
local Mob = {}
ns.MobTips = Mob

ns.Main.AddOption({ group = "Creature tooltips", key = "mobOn", kind = "check", label = "Gear of the creature", default = true,
	tip = "What a creature drops, a vendor sells or a quest giver's quests reward. Upgrades and tracked items first." })
ns.Main.AddOption({ group = "Creature tooltips", key = "mobWanted", kind = "check", label = "Only wanted gear", default = false,
	tip = "Upgrades and tracked items only." })
ns.Main.AddOption({ group = "Creature tooltips", key = "mobChance", kind = "check", label = "Drop chance", default = true,
	tip = "From your own kills: shown once you have looted a creature 10 times. The data has no drop chances." })
ns.Main.AddOption({ group = "Creature tooltips", key = "mobMinChance", kind = "slider", label = "Hide drops below", min = 0, max = 25, step = 1,
	format = "%d%%", default = 0, tip = "Drops with a known chance below this. A drop with no known chance stays." })

local LIMIT = 15

local cache = {} -- npc id -> rows, or false
local done = setmetatable({}, { __mode = "k" })
local hooked = setmetatable({}, { __mode = "k" })

function Mob.Clear() wipe(cache) end

local function Collect(npc)
	local Gear = ns.Gear
	local ctx = Gear.PlayerContext() -- the player's own gear, not a Simulator preview
	local rows, seen = {}, {}
	local function add(list, sold)
		if type(list) ~= "table" then return end
		for _, entry in ipairs(list) do
			local id = entry.id
			local item = id and not seen[id] and Gear.Item(id)
			if item then
				seen[id] = true
				-- the suffix the name shows: the tracked one, else the best for the spec
				local link = Gear.WantedLink(id, ctx)
				local c = Gear.Compare(link, ctx)
				local up = c and c.usable ~= false and type(c.delta) == "number" and c.delta > 0 or false
				local marked = Gear.IsTracked(id) or false
				-- nothing for the spec in use: another spec of the character may want it
				local other = not up and Gear.OtherGains and Gear.OtherGains(link, ctx)[1] or nil
				-- a row with no gain says why
				local why
				if not up and type(c) == "table" then
					if c.isWorn then
						why = "Equipped"
					elseif c.usable == false then
						why = c.reason == "level" and c.atLevel and ("Level " .. c.atLevel) or "Can't use"
					elseif type(c.delta) == "number" then
						why = "No upgrade"
					end
				end
				rows[#rows + 1] = {
					id = id, name = (Gear.Name and Gear.Name(id, ctx)) or item.name or ("item " .. id), quality = item.quality, sold = sold,
					chance = entry.chance, up = up, marked = marked and true or false, req = item.req,
					gain = up and (c.gain or c.delta) or nil,
					-- what the gain is worth on one scale for all slots: the rows are sorted by it
					worth = up and c.delta or nil,
					other = other and type(other.gain) == "number" and { label = other.label, gain = other.gain } or nil,
					why = why,
					-- the reward of a quest this NPC gives
					quest = entry.quest,
					-- a vendor: what the item asks for, the price, limited stock, not confirmed
					need = entry.need, cost = entry.cost, costText = entry.costText, limited = entry.limited, unsure = entry.unsure,
				}
			end
		end
	end
	add(Gear.NpcDrops(npc), false)
	add(Gear.NpcSells(npc), true)
	-- the rewards of the quests it gives, when the quest is a way the character can use (its
	-- faction and class, not done yet): Gear.Sources says so
	local rewards = {}
	for _, questId in ipairs(Gear.NpcQuests and Gear.NpcQuests(npc) or {}) do
		for _, id in ipairs(Gear.QuestRewards and Gear.QuestRewards(questId) or {}) do
			for _, s in ipairs(not seen[id] and Gear.Sources(id, ctx) or {}) do
				if s.kind == "quest" and s.quest == questId then rewards[#rewards + 1] = { id = id, quest = s.name or "?" } end
			end
		end
	end
	add(rewards, false)
	if #rows == 0 then return false end
	-- items of one name (a vendor's level 18 and level 28 "Protector's Sword"): the level tells them apart
	local names = {}
	for _, row in ipairs(rows) do names[row.name] = (names[row.name] or 0) + 1 end
	for _, row in ipairs(rows) do
		if names[row.name] > 1 and row.req and row.req > 1 then row.name = row.name .. " (level " .. row.req .. ")" end
	end
	table.sort(rows, function(a, b)
		local wa, wb = a.up or a.marked, b.up or b.marked
		if wa ~= wb then return wa end
		if (a.other ~= nil) ~= (b.other ~= nil) then return a.other ~= nil end
		local ga, gb = a.worth or 0, b.worth or 0
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
	return ns.ChanceText(chance) or ""
end

-- all: every piece of gear, wanted first (the default; user, 2026-11-21: "always, without Shift").
-- Not all: upgrades and tracked items only.
local function Add(tooltip, rows, all)
	local db = ns.db
	local min = tonumber(db.mobMinChance) or 0
	local shown = {}
	for _, row in ipairs(rows) do
		local keep = all or row.up or row.marked or row.other ~= nil
		if keep and not row.marked and not row.sold and row.chance and row.chance < min then keep = false end
		if keep then shown[#shown + 1] = row end
	end
	if #shown == 0 then return false end
	tooltip:AddLine(all and "Gear" or "Wanted gear", C.GOLD[1], C.GOLD[2], C.GOLD[3])
	local limit = LIMIT
	for i = 1, math.min(#shown, limit) do
		local row = shown[i]
		local icon = C_Item and C_Item.GetItemIconByID and ns.Plain(C_Item.GetItemIconByID(row.id))
		local left = (icon and ("|T" .. icon .. ":14:14|t ") or "") .. UI.Colored(row.name, UI.QUALITY[row.quality or 1] or C.TEXT)
		local right = {}
		if row.sold then
			if row.need then right[#right + 1] = UI.Colored(row.need, C.MUTED) end
			right[#right + 1] = row.costText or (row.cost and UI.Money(row.cost)) or UI.Colored("Sold", C.MUTED)
			if row.limited then right[#right + 1] = UI.Colored("limited stock", C.MUTED) end
			if row.unsure then right[#right + 1] = UI.Colored(ns.Gear.UNSURE, C.FAINT) end
		elseif row.quest then
			right[#right + 1] = UI.Colored("Quest: " .. row.quest, C.MUTED)
		elseif db.mobChance and type(row.chance) == "number" then
			right[#right + 1] = UI.Colored(ChanceText(row.chance), C.MUTED)
		end
		if row.up and ns.Tip then
			right[#right + 1] = ns.Tip.Gain(row.gain)
		elseif row.other then
			right[#right + 1] = UI.Colored(("%s +%d"):format(row.other.label, math.max(1, math.floor(row.other.gain + 0.5))), C.GOLD_SOFT)
		elseif row.why then
			right[#right + 1] = UI.Colored(row.why, C.FAINT)
		end
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
		hooked[tooltip] = pcall(tooltip.HookScript, tooltip, "OnTooltipCleared", function(self) done[self] = nil end) or nil
	end
	if Add(tooltip, rows, not db.mobWanted) and hooked[tooltip] then done[tooltip] = true end
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

for _, message in ipairs({ "CONTEXT_CHANGED", "GEAR_CHANGED", "FILTERS_CHANGED", "HUNTS_CHANGED" }) do
	ns.Listen(message, Mob.Clear)
end
