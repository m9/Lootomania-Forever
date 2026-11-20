local _, ns = ...

-- Gear: reads the generated data (Data\*.lua), scores items and builds the ranked lists.
-- The contract every other module codes against is in build\notes\gear-api.md.
--
-- Generated data, all under ns.Data (see build\pack.lua for the writer):
--   statKeys, statLabels, weightKey   stat names
--   weights                           stat weights per class and spec, as the scorer reads them
--   classes                           what each class can wear and wield
--   itemsPacked                       one line per item
--   suffixSets                        random suffix sets, shared between items
--   ranks[CLASS][spec][slot]          "id:score:req:suffix;..." best first
--   srcItems, npcs, objects, quests, areas, instAreas   where items come from
--   crafts, enchants, instances, missing

local Gear = {}
ns.Gear = Gear
ns.Data = ns.Data or {}
local Data = ns.Data

ns.Defaults({ huntsPerSlot = 5, customSpecs = {} })
ns.Defaults({ hunts = { tracked = {}, state = {}, suffix = {} } }, "char")

-- Slots --------------------------------------------------------------------------------

Gear.SLOTS = {
	{ key = "Head", label = "Head", inv = { 1 } },
	{ key = "Neck", label = "Neck", inv = { 2 } },
	{ key = "Shoulder", label = "Shoulders", inv = { 3 } },
	{ key = "Back", label = "Back", inv = { 15 } },
	{ key = "Chest", label = "Chest", inv = { 5 } },
	{ key = "Wrist", label = "Wrists", inv = { 9 } },
	{ key = "Hands", label = "Hands", inv = { 10 } },
	{ key = "Waist", label = "Waist", inv = { 6 } },
	{ key = "Legs", label = "Legs", inv = { 7 } },
	{ key = "Feet", label = "Feet", inv = { 8 } },
	{ key = "Finger", label = "Rings", inv = { 11, 12 } },
	{ key = "Trinket", label = "Trinkets", inv = { 13, 14 } },
	{ key = "MainHand", label = "Main hand", inv = { 16 } },
	{ key = "OffHand", label = "Off hand", inv = { 17 } },
	{ key = "Ranged", label = "Ranged", inv = { 18 } },
}
local SLOT = {} -- key -> slot
local SLOT_INDEX = {} -- key -> number, as packed
local INV_SLOT = {} -- inventory slot id -> key
for i, slot in ipairs(Gear.SLOTS) do
	SLOT[slot.key] = slot
	SLOT_INDEX[slot.key] = i
	for _, inv in ipairs(slot.inv) do INV_SLOT[inv] = slot.key end
end

function Gear.SlotOfInv(inv) return INV_SLOT[inv] end

-- Packed numbers for hand and armor, shared with build\pack.lua.
local HANDS = { "two", "one", "main", "off", "shield", "held", "ranged", "wand", "thrown", "relic" }
local ARMORS = { "Cloth", "Leather", "Mail", "Plate" }

-- equipLoc from the game -> our slot, for items we have no data for
local EQUIP_SLOT = {
	INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulder", INVTYPE_CLOAK = "Back",
	INVTYPE_CHEST = "Chest", INVTYPE_ROBE = "Chest", INVTYPE_WRIST = "Wrist", INVTYPE_HAND = "Hands",
	INVTYPE_WAIST = "Waist", INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Feet", INVTYPE_FINGER = "Finger",
	INVTYPE_TRINKET = "Trinket", INVTYPE_WEAPON = "MainHand", INVTYPE_2HWEAPON = "MainHand",
	INVTYPE_WEAPONMAINHAND = "MainHand", INVTYPE_WEAPONOFFHAND = "OffHand", INVTYPE_SHIELD = "OffHand",
	INVTYPE_HOLDABLE = "OffHand", INVTYPE_RANGED = "Ranged", INVTYPE_RANGEDRIGHT = "Ranged",
	INVTYPE_THROWN = "Ranged", INVTYPE_RELIC = "Ranged",
}

-- Small text helpers ---------------------------------------------------------------------

local function split(text, sep)
	local out = {}
	if not text or text == "" then return out end
	for part in (text .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end
	return out
end

local function num(text)
	if text == nil or text == "" then return nil end
	return tonumber(text)
end

-- Index of a packed block: id -> its line. Built the first time it is asked for.
local function Index(field)
	local index
	return function(id)
		if not index then
			index = {}
			local packed = Data[field]
			if packed then
				for key, line in packed:gmatch("(%d+)%^([^\n]*)\n") do index[tonumber(key)] = line end
			end
		end
		return index[id], index
	end
end

-- "3=7,1=8" -> { sta = 7, str = 8 }
local function Stats(text)
	local stats = {}
	if not text or text == "" then return stats end
	local keys = Data.statKeys
	for k, v in text:gmatch("(%d+)=([%-%d%.]+)") do
		local key = keys[tonumber(k)]
		if key then stats[key] = tonumber(v) end
	end
	return stats
end

-- Items ------------------------------------------------------------------------------------

local itemLine = Index("itemsPacked")
local items = {} -- decoded items, by id
local suffixSets = {} -- decoded suffix sets, by number

local function SuffixSet(n)
	local set = suffixSets[n]
	if set then return set end
	set = {}
	local packed = Data.suffixSets and Data.suffixSets[n]
	for _, part in ipairs(split(packed, ";")) do
		local id, name, stats = part:match("^(%d+)~([^~]*)~(.*)$")
		if id then set[#set + 1] = { id = tonumber(id), name = name, stats = Stats(stats) } end
	end
	suffixSets[n] = set
	return set
end

-- "d:40:2;s:3:50:0.1;h:30:2;p:12" -> procs as the scorer reads them
local function Procs(text)
	if not text or text == "" then return nil end
	local procs = {}
	for _, part in ipairs(split(text, ";")) do
		local f = split(part, ":")
		if f[1] == "d" then
			procs[#procs + 1] = { kind = "damage", amount = num(f[2]), ppm = num(f[3]) }
		elseif f[1] == "s" then
			procs[#procs + 1] = { kind = "stat", stat = Data.statKeys[num(f[2]) or 0], amount = num(f[3]), uptime = num(f[4]) }
		elseif f[1] == "h" then
			procs[#procs + 1] = { kind = "health", amount = num(f[2]), ppm = num(f[3]) }
		elseif f[1] == "p" then
			procs[#procs + 1] = { kind = "points", points = num(f[2]) }
		end
	end
	return #procs > 0 and procs or nil
end

-- Line: name^quality^ilvl^req^slot^hand^armor^bind^flags^classMask^stats^weapon^suffixSet^procs^wtype
-- flags: 1 unique, 2 Alliance only, 4 Horde only, 8 relic
function Gear.Item(id)
	local item = items[id]
	if item ~= nil then return item or nil end
	local line = id and itemLine(id)
	if not line then
		if id then items[id] = false end
		return nil
	end
	local f = split(line, "^")
	local flags = num(f[9]) or 0
	item = {
		id = id,
		name = f[1],
		quality = num(f[2]) or 1,
		ilvl = num(f[3]) or 0,
		req = num(f[4]) or 0,
		slot = Gear.SLOTS[num(f[5]) or 0] and Gear.SLOTS[num(f[5])].key,
		hand = HANDS[num(f[6]) or 0],
		armor = ARMORS[num(f[7]) or 0],
		bind = num(f[8]),
		unique = bit.band(flags, 1) ~= 0 or nil,
		side = (bit.band(flags, 2) ~= 0 and "A") or (bit.band(flags, 4) ~= 0 and "H") or nil,
		relic = bit.band(flags, 8) ~= 0 or nil,
		classMask = num(f[10]),
		stats = Stats(f[11]),
		procs = Procs(f[14]),
		wtype = f[15] ~= "" and f[15] or nil,
	}
	if f[12] and f[12] ~= "" then
		local w = split(f[12], ",")
		item.weapon = { min = num(w[1]), max = num(w[2]), speed = num(w[3]), dps = num(w[4]), hand = item.hand }
	end
	if num(f[13]) then item.suffixes = SuffixSet(num(f[13])) end
	if item.classMask then
		item.classes = {}
		for i, class in ipairs(Data.classOrder or {}) do
			if bit.band(item.classMask, bit.lshift(1, i - 1)) ~= 0 then item.classes[#item.classes + 1] = class end
		end
	end
	items[id] = item
	return item
end

function Gear.Link(id, suffixId)
	if suffixId then return ("item:%d::::::%d"):format(id, suffixId) end
	return "item:" .. id
end

-- Numbers in an item link that may name a random suffix: the suffix field and the bonus ids.
local function LinkSuffix(link, item)
	if type(link) ~= "string" or not item.suffixes then return nil end
	local body = link:match("item:([%-%d:]+)")
	if not body then return nil end
	local seen = {}
	local n = 0
	for field in (body .. ":"):gmatch("([^:]*):") do
		n = n + 1
		local value = tonumber(field)
		if value and n > 1 and value ~= 0 then seen[math.abs(value)] = true end
	end
	for _, suffix in ipairs(item.suffixes) do
		if seen[suffix.id] then return suffix end
	end
	return nil
end

-- False until the generated data is loaded.
function Gear.Ready()
	return Data.itemsPacked ~= nil and Data.weights ~= nil
end

function Gear.StatKeys() return Data.statKeys or {} end

-- Shorter names for labels the build cuts off or makes long.
local STAT_LABEL = {
	apVs = "Attack power vs creature type", spVs = "Spell damage vs creature type", feralAp = "Feral attack power",
	expertise = "Expertise", haste = "Haste %", crit = "Crit chance %", spellCrit = "Spell crit chance %",
}

function Gear.StatLabel(key)
	return STAT_LABEL[key] or (Data.statLabels and Data.statLabels[key]) or key
end

-- Classes and specs -----------------------------------------------------------------------

local CLASS_LABEL = {
	WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
	SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}

function Gear.Classes()
	local out = {}
	for _, class in ipairs(Data.classOrder or {}) do
		out[#out + 1] = { key = class, label = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or CLASS_LABEL[class] or class }
	end
	return out
end

local function Pretty(key)
	return (key:gsub("_", " "):gsub("^%l", string.upper))
end

-- Icon per spec. Custom specs and unknown ones get the class's first icon.
local ICONS = "Interface\\Icons\\"
local SPEC_ICON = {
	WARRIOR = { arms = "Ability_Warrior_SavageBlow", fury = "Ability_Warrior_InnerRage", protection = "Ability_Warrior_DefensiveStance" },
	PALADIN = { holy = "Spell_Holy_HolyBolt", protection = "Spell_Holy_DevotionAura", retribution = "Spell_Holy_AuraOfLight",
		shockadin = "Spell_Holy_SearingLight" },
	HUNTER = { beast_mastery = "Ability_Hunter_BeastTaming", marksmanship = "Ability_Marksmanship", survival = "Ability_Hunter_SwiftStrike" },
	ROGUE = { assassination = "Ability_Rogue_Eviscerate", combat = "Ability_BackStab", subtlety = "Ability_Stealth" },
	PRIEST = { discipline = "Spell_Holy_WordFortitude", holy = "Spell_Holy_Heal", shadow = "Spell_Shadow_ShadowWordPain" },
	SHAMAN = { elemental = "Spell_Nature_Lightning", enhancement = "Spell_Nature_LightningShield",
		enhancement_tank = "Spell_Nature_StoneSkinTotem", restoration = "Spell_Nature_MagicImmunity" },
	MAGE = { arcane = "Spell_Holy_MagicalSentry", fire = "Spell_Fire_FlameBolt", frost = "Spell_Frost_FrostBolt02",
		battlemage_arcane = "Spell_Nature_WispSplode", battlemage_fire = "Spell_Fire_Fireball", battlemage_frost = "Spell_Frost_FrostNova" },
	WARLOCK = { affliction = "Spell_Shadow_DeathCoil", demonology = "Spell_Shadow_Metamorphosis", destruction = "Spell_Shadow_RainOfFire" },
	DRUID = { balance = "Spell_Nature_StarFall", bear = "Ability_Racial_BearForm", feral = "Ability_Druid_CatForm",
		restoration = "Spell_Nature_HealingTouch" },
}

function Gear.SpecIcon(class, spec)
	local icons = SPEC_ICON[class]
	local name = icons and icons[spec]
	if not name and icons then
		local order = Data.specOrder and Data.specOrder[class]
		local first = order and order[1]
		name = first and icons[first]
	end
	return ICONS .. (name or "INV_Misc_QuestionMark")
end

-- The record of one spec in the weights data.
local function SpecRecord(class, spec)
	local classes = Data.weights and Data.weights.classes
	local byClass = classes and classes[class:lower()] or classes and classes[class]
	return byClass and byClass[spec], byClass
end

function Gear.Specs(class)
	local out = {}
	local order = Data.specOrder and Data.specOrder[class] or {}
	for _, key in ipairs(order) do
		local rec = SpecRecord(class, key)
		out[#out + 1] = { key = key, label = (rec and (rec.label or rec.name)) or Pretty(key), icon = Gear.SpecIcon(class, key) }
	end
	for _, custom in ipairs(Gear.CustomSpecs(class)) do
		out[#out + 1] = { key = custom.key, label = custom.label, custom = true, icon = Gear.SpecIcon(class, custom.key) }
	end
	return out
end

-- Talent tree with the most points -> spec key. Nil when no points are spent or nothing can be read.
--
-- Forever has one specialization per class and the three old talent trees as groups of one
-- trait tree, so the tree with the most points is read from the trait API, the way the game's
-- own talent window fills its three headers. The groups' order is the old tab order
-- (Data.talentSpecs). GetTalentTabInfo is kept for clients that still have it.
local function TraitPoints()
	if not C_Traits or not C_Traits.GetGroupDisplayInfoByTreeID or not C_Traits.GetGroupCurrencyInfo or not C_Traits.GetConfigInfo then return nil end
	local config
	if C_SpecializationInfo and C_SpecializationInfo.GetCombatConfigIDForSpecGroup and C_SpecializationInfo.GetActiveSpecGroup then
		config = C_SpecializationInfo.GetCombatConfigIDForSpecGroup(C_SpecializationInfo.GetActiveSpecGroup())
	end
	if not config and C_ClassTalents and C_ClassTalents.GetActiveConfigID then config = C_ClassTalents.GetActiveConfigID() end
	if type(config) ~= "number" then return nil end
	local info = C_Traits.GetConfigInfo(config)
	local tree = type(info) == "table" and type(info.treeIDs) == "table" and info.treeIDs[1]
	if not tree then return nil end
	local groups = C_Traits.GetGroupDisplayInfoByTreeID(tree)
	if type(groups) ~= "table" or #groups == 0 then return nil end
	local ids, tabOf = {}, {}
	for i, group in ipairs(groups) do
		ids[i] = group.groupID
		tabOf[group.groupID] = (type(group.orderIndex) == "number" and group.orderIndex or i - 1) + 1
	end
	local points = {} -- tab -> points spent
	for _, spent in ipairs(C_Traits.GetGroupCurrencyInfo(config, ids) or {}) do
		local tab = tabOf[spent.traitNodeGroupID]
		local currency = type(spent.currencyInfos) == "table" and spent.currencyInfos[1]
		local n = currency and ns.Plain(currency.spent)
		if tab and type(n) == "number" then points[tab] = n end
	end
	return points
end

local function TabPoints()
	local ok, points = pcall(TraitPoints)
	if ok and points then return points end
	if not GetTalentTabInfo then return nil end
	points = {}
	for tab = 1, 3 do
		local ok2, a, _, c, d, e = pcall(GetTalentTabInfo, tab)
		if ok2 then
			-- points spent moved between returns over the years: take the number that fits
			local n = (type(e) == "number" and e) or (type(c) == "number" and c) or (type(d) == "number" and d) or 0
			if type(a) == "number" and type(c) == "string" and type(e) == "number" then n = e end
			points[tab] = n
		end
	end
	return points
end

local function TalentSpec(class)
	local tabs = Data.talentSpecs and Data.talentSpecs[class]
	local points = tabs and TabPoints()
	if not points then return nil end
	local best, bestPoints = nil, 0
	for tab = 1, #tabs do
		if (points[tab] or 0) > bestPoints then best, bestPoints = tabs[tab], points[tab] end
	end
	return best
end

-- Context ----------------------------------------------------------------------------------

local preview

function Gear.PlayerContext()
	local player = ns.player
	if not player then return nil end
	local class = player.class
	local spec = ns.char.spec
	if not spec or not SpecRecord(class, spec) then
		spec = TalentSpec(class) or (Data.specOrder and Data.specOrder[class] and Data.specOrder[class][1])
	end
	return { class = class, spec = spec, faction = player.faction, level = UnitLevel("player") or 1 }
end

function Gear.Context()
	return preview or Gear.PlayerContext()
end

local function Ctx(ctx)
	local base = Gear.Context()
	if not ctx then return base end
	if not base then return ctx end
	-- a partial context ({ spec = "fury" }) is filled from the active one
	return {
		class = ctx.class or base.class,
		spec = ctx.spec or base.spec,
		faction = ctx.faction or base.faction,
		level = ctx.level or base.level,
		preview = ctx.preview,
	}
end

local caches = {} -- tables to empty when the context or gear changes
local function Cache()
	local cache = {}
	caches[#caches + 1] = cache
	return cache
end
local function Wipe()
	for _, cache in ipairs(caches) do
		for k in pairs(cache) do cache[k] = nil end
	end
end

local function ContextChanged()
	Wipe()
	ns.Send("CONTEXT_CHANGED")
end

function Gear.SetPreview(ctx)
	if ctx then
		preview = { class = ctx.class, spec = ctx.spec, faction = ctx.faction, level = ctx.level, preview = true }
		if not SpecRecord(preview.class, preview.spec or "") then
			preview.spec = Data.specOrder and Data.specOrder[preview.class] and Data.specOrder[preview.class][1]
		end
	else
		preview = nil
	end
	ContextChanged()
end

function Gear.SetSpec(spec)
	ns.char.spec = spec
	ContextChanged()
end

-- Usability ---------------------------------------------------------------------------------

-- Data.classes[class] = { armor = { Cloth = true }, armorAt = { Mail = 40 }, weapons = { Sword = true },
-- shield = bool, dual = bool }. Mail and plate come at level 40.
function Gear.Usable(id, ctx)
	ctx = Ctx(ctx)
	local item = type(id) == "table" and id or Gear.Item(id)
	if not item or not ctx then return true end
	local rules = Data.classes and Data.classes[ctx.class]
	if item.classMask and Data.classBit and Data.classBit[ctx.class] then
		if bit.band(item.classMask, Data.classBit[ctx.class]) == 0 then return false, "class" end
	end
	if item.side and ctx.faction and item.side ~= ctx.faction:sub(1, 1) then return false, "faction" end
	if rules then
		if item.armor and item.slot ~= "Back" then
			if not rules.armor[item.armor] then return false, "armor" end
			local at = rules.armorAt and rules.armorAt[item.armor]
			if at and ctx.level < at then return false, "armor" end
		end
		if item.hand == "shield" and not rules.shield then return false, "armor" end
		if item.hand == "relic" and item.wtype and not rules.weapons[item.wtype] then return false, "class" end
		if item.wtype and item.hand ~= "relic" and item.hand ~= "shield" and item.hand ~= "held" then
			if not rules.weapons[item.wtype] then return false, "weapon" end
			if item.hand == "two" and rules.oneOnly and rules.oneOnly[item.wtype] then return false, "weapon" end
		end
		if item.hand == "off" and item.wtype and not rules.dual then return false, "weapon" end
	end
	if item.req and item.req > ctx.level then return false, "level" end
	return true
end

local REASON = { class = "Wrong class", armor = "Can't wear", weapon = "Can't wield", faction = "Other faction", level = "Level too low" }
function Gear.ReasonText(reason) return REASON[reason] or "Can't use" end

-- Scores ------------------------------------------------------------------------------------

local scoreCache = Cache()

local function CtxKey(ctx)
	return ctx.class .. "/" .. tostring(ctx.spec) .. "/" .. tostring(ctx.level)
end

-- What the scorer wants to know about an item.
local function ScoreItem(item, suffix, ctx)
	local Scorer = ns.Scorer
	if not Scorer or not Data.weights then return nil end
	local shaped = {
		stats = item.stats,
		slot = item.slot,
		armorType = item.slot ~= "Back" and item.armor or nil,
		weapon = item.weapon,
		suffixes = suffix and { suffix } or item.suffixes,
		procs = item.procs,
		relic = item.relic,
		ilvl = item.ilvl,
	}
	local class = Data.weights.classes[ctx.class] and ctx.class or ctx.class:lower()
	local ok, score, best = pcall(Scorer.score, shaped, class, ctx.spec, Data.weights, ctx.level)
	if not ok then
		ns.Debug("score", item.id, score)
		return nil
	end
	return score, best
end

function Gear.Score(what, ctx)
	ctx = Ctx(ctx)
	local id = ns.ItemID(what)
	local item = id and Gear.Item(id)
	if not item or not ctx or not ctx.spec then return nil end
	local suffix = LinkSuffix(what, item)
	local key = CtxKey(ctx) .. "/" .. id .. "/" .. (suffix and suffix.id or 0)
	local score = scoreCache[key]
	if score == nil then
		score = ScoreItem(item, suffix, ctx) or false
		scoreCache[key] = score
	end
	return score or nil
end

-- "+4 Agility, +4 Strength": biggest first. Second result: the parts as a list.
local function StatsText(stats)
	local parts = {}
	for key, value in pairs(stats or {}) do parts[#parts + 1] = { label = Gear.StatLabel(key), value = value } end
	table.sort(parts, function(a, b)
		if a.value ~= b.value then return a.value > b.value end
		return a.label < b.label
	end)
	for i, part in ipairs(parts) do parts[i] = ("%+d %s"):format(part.value, part.label) end
	return table.concat(parts, ", "), parts
end

local suffixCache = Cache()

-- The random suffixes an item can have, best first for ctx. nil when it has none.
-- Each: { id, name, stats, text, lines (one per stat), score, place, current (the suffix of the link, when it has one) }.
function Gear.Suffixes(what, ctx)
	ctx = Ctx(ctx)
	local id = ns.ItemID(what)
	local item = id and Gear.Item(id)
	if not item or not item.suffixes or #item.suffixes == 0 or not ctx or not ctx.spec then return nil end
	local current = LinkSuffix(what, item)
	local key = CtxKey(ctx) .. "/" .. id .. "/" .. (current and current.id or 0)
	local list = suffixCache[key]
	if list then return list end
	list = {}
	for _, suffix in ipairs(item.suffixes) do
		local text, lines = StatsText(suffix.stats)
		list[#list + 1] = {
			id = suffix.id, name = suffix.name, stats = suffix.stats, text = text, lines = lines,
			score = ScoreItem(item, suffix, ctx) or 0, current = current and current.id == suffix.id or nil,
		}
	end
	table.sort(list, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return a.name < b.name
	end)
	for place, suffix in ipairs(list) do suffix.place = place end
	suffixCache[key] = list
	return list
end

-- Worn gear ----------------------------------------------------------------------------------

local wornCache = Cache()

function Gear.Worn(slotKey)
	local worn = wornCache[slotKey]
	if worn then return worn end
	worn = {}
	local slot = SLOT[slotKey]
	if slot then
		for _, inv in ipairs(slot.inv) do
			local link = GetInventoryItemLink("player", inv)
			if link then
				worn[#worn + 1] = { link = link, id = ns.ItemID(link), inv = inv, score = Gear.Score(link, Gear.PlayerContext()) }
			end
		end
	end
	wornCache[slotKey] = worn
	return worn
end

-- Score to beat in a slot: the weaker worn item, 0 when a slot is empty.
-- A preview context compares with nothing.
local function WornScore(slotKey, ctx, hand)
	if ctx.preview then return nil end
	local slot = SLOT[slotKey]
	if not slot then return nil end
	local worn = Gear.Worn(slotKey)
	-- a two-hander replaces both hands; a one-hander replaces a worn two-hander
	if slotKey == "MainHand" and hand == "two" then
		local total = 0
		for _, w in ipairs(worn) do total = total + (Gear.Score(w.link, ctx) or 0) end
		for _, w in ipairs(Gear.Worn("OffHand")) do total = total + (Gear.Score(w.link, ctx) or 0) end
		return total
	end
	if #worn < #slot.inv then return 0 end
	local low
	for _, w in ipairs(worn) do
		local score = Gear.Score(w.link, ctx) or 0
		if not low or score < low then low = score end
	end
	return low or 0
end

-- Random suffix id of a link, nil when it has none we know.
function Gear.LinkSuffixID(link)
	local id = ns.ItemID(link)
	local item = id and Gear.Item(id)
	local suffix = item and LinkSuffix(link, item)
	return suffix and suffix.id or nil
end

-- The random suffix must match too ("of the Bear" is not "of the Monkey").
-- suffixId: the suffix to look for; false: any.
local function IsWorn(slotKey, id, suffixId)
	for _, w in ipairs(Gear.Worn(slotKey)) do
		if w.id == id and (suffixId == false or Gear.LinkSuffixID(w.link) == suffixId) then return true end
	end
	return false
end

-- Hunts ----------------------------------------------------------------------------------------

-- An item is tracked once, with the suffix that was picked (none: any suffix).
-- suffixId: ask about one suffix of a random-suffix item.
function Gear.IsTracked(id, suffixId)
	local hunts = ns.char and ns.char.hunts
	if not hunts or not hunts.tracked[id] then return false end
	local wanted = hunts.suffix[id]
	return suffixId == nil or wanted == nil or wanted == suffixId
end

function Gear.Track(id, on, suffixId)
	if on == nil then on = true end
	ns.char.hunts.tracked[id] = on and true or nil
	ns.char.hunts.suffix[id] = on and suffixId or nil
	ns.Send("HUNTS_CHANGED")
end

-- The suffix to look for on an item: the tracked one, else the best for ctx.
-- { id, name, text, score } or nil when the item has no random suffixes.
function Gear.WantedSuffix(id, ctx)
	local list = Gear.Suffixes(id, ctx)
	if not list then return nil end
	local wanted = ns.char and ns.char.hunts.tracked[id] and ns.char.hunts.suffix[id]
	if wanted then
		for _, suffix in ipairs(list) do
			if suffix.id == wanted then return suffix end
		end
	end
	return list[1]
end

-- Item name with the suffix to look for: "Cerulean Talisman of the Tiger".
function Gear.Name(id, ctx)
	local item = Gear.Item(id)
	if not item then return nil end
	local suffix = Gear.WantedSuffix(id, ctx)
	if suffix and suffix.name ~= "" then return item.name .. " " .. suffix.name, item.quality end
	return item.name, item.quality
end

function Gear.Tracked()
	local out = {}
	for id in pairs(ns.char.hunts.tracked) do out[#out + 1] = id end
	table.sort(out)
	return out
end

-- Done and removed are kept per suffix.
local function StateKey(id, suffixId) return suffixId and (id .. ":" .. suffixId) or id end

function Gear.State(id, suffixId) return ns.char and ns.char.hunts.state[StateKey(id, suffixId)] or nil end

function Gear.SetState(id, state, suffixId)
	ns.char.hunts.state[StateKey(id, suffixId)] = state
	if state and Gear.IsTracked(id, suffixId) then
		ns.char.hunts.tracked[id] = nil
		ns.char.hunts.suffix[id] = nil
	end
	ns.Send("HUNTS_CHANGED")
end

-- Lists ------------------------------------------------------------------------------------------

local pools = {} -- class/spec/slot -> { { id, score, req, suffix }, ... } best first
local SUFFIX_KEEP = 3 -- suffixes of one item that get their own row (same number as in build/pack.lua)

-- Every item of a slot, for specs that have no generated list (custom specs).
local bySlot
local function SlotItems(slotKey)
	if not bySlot then
		bySlot = {}
		local _, index = itemLine(0)
		for id, line in pairs(index) do
			local n = tonumber(line:match("^[^%^]*%^[^%^]*%^[^%^]*%^[^%^]*%^(%d+)"))
			local hand = tonumber(line:match("^[^%^]*%^[^%^]*%^[^%^]*%^[^%^]*%^[^%^]*%^(%d+)"))
			local key = n and Gear.SLOTS[n] and Gear.SLOTS[n].key
			if key then
				bySlot[key] = bySlot[key] or {}
				table.insert(bySlot[key], id)
				-- one-hand weapons also go in the off hand
				if key == "MainHand" and HANDS[hand or 0] == "one" then
					bySlot.OffHand = bySlot.OffHand or {}
					table.insert(bySlot.OffHand, id)
				end
			end
		end
	end
	return bySlot[slotKey] or {}
end

local function Pool(class, spec, slotKey)
	local key = class .. "/" .. spec .. "/" .. slotKey
	local pool = pools[key]
	if pool then return pool end
	pool = {}
	local packed = Data.ranks and Data.ranks[class] and Data.ranks[class][spec] and Data.ranks[class][spec][slotKey]
	if packed then
		for id, score, req, suffix in packed:gmatch("(%d+):([%-%d%.]+):(%d*):(%d*);") do
			pool[#pool + 1] = { id = tonumber(id), score = tonumber(score), req = tonumber(req) or 0, suffix = tonumber(suffix) }
		end
	elseif SpecRecord(class, spec) then
		-- no generated list: score every item of the slot now
		local ctx = { class = class, spec = spec, level = 60 }
		local rules = Data.classes and Data.classes[class]
		for _, id in ipairs(SlotItems(slotKey)) do
			local item = Gear.Item(id)
			local fits = item and (slotKey ~= "OffHand" or item.slot == "OffHand" or (rules and rules.dual))
			local usable = fits and Gear.Usable(item, ctx) -- level 60: only class, armor and weapon rules can fail
			if usable then
				if item.suffixes and #item.suffixes > 0 then
					local list = Gear.Suffixes(id, ctx)
					for i = 1, math.min(SUFFIX_KEEP, #list) do
						if list[i].score > 0 then pool[#pool + 1] = { id = id, score = list[i].score, req = item.req, suffix = list[i].id } end
					end
				else
					local score = ScoreItem(item, nil, ctx)
					if score and score > 0 then pool[#pool + 1] = { id = id, score = score, req = item.req } end
				end
			end
		end
		table.sort(pool, function(a, b)
			if a.score ~= b.score then return a.score > b.score end
			if a.id ~= b.id then return a.id < b.id end
			return (a.suffix or 0) < (b.suffix or 0)
		end)
	end
	pools[key] = pool
	return pool
end

local listCache = Cache()

-- The whole usable list of a slot for a context, before counts and filters.
local function FullList(slotKey, ctx)
	local key = CtxKey(ctx) .. "/" .. tostring(ctx.faction) .. "/" .. slotKey
	local list = listCache[key]
	if list then return list end
	list = {}
	local side = ctx.faction and ctx.faction:sub(1, 1)
	local rules = Data.classes and Data.classes[ctx.class]
	for _, row in ipairs(Pool(ctx.class, ctx.spec, slotKey)) do
		if row.req <= ctx.level then
			local item = Gear.Item(row.id)
			if item and (not item.side or item.side == side) then
				local at = item.armor and item.slot ~= "Back" and rules and rules.armorAt and rules.armorAt[item.armor]
				if not at or ctx.level >= at then
					list[#list + 1] = row
				end
			end
		end
	end
	listCache[key] = list
	return list
end

local function SuffixOf(item, id)
	if not id or not item.suffixes then return nil end
	for _, suffix in ipairs(item.suffixes) do
		if suffix.id == id then return suffix end
	end
	return nil
end

function Gear.List(slotKey, ctx, opts)
	ctx = Ctx(ctx)
	opts = opts or {}
	local out = {}
	if not ctx or not ctx.spec or not SLOT[slotKey] then return out end
	local count = opts.count or ns.db.huntsPerSlot or 5
	local full = FullList(slotKey, ctx)
	local top = full[1] and full[1].score or 0
	local filter = not opts.all and ns.Filters and ns.Filters.Pass
	for rank, row in ipairs(full) do
		if #out >= count then break end
		local item = Gear.Item(row.id)
		local state = Gear.State(row.id, row.suffix)
		local keep = opts.states or not state
		if opts.state then keep = state == opts.state end
		local sources
		if keep and filter then
			sources = Gear.Sources(row.id)
			keep = filter({ id = row.id, score = row.score, req = row.req, item = item }, sources, ctx)
		end
		if keep then
			local suffix = SuffixOf(item, row.suffix)
			local worn = not ctx.preview and IsWorn(slotKey, row.id, row.suffix)
			local toBeat = WornScore(slotKey, ctx, item.hand)
			sources = sources or Gear.Sources(row.id)
			out[#out + 1] = {
				id = row.id,
				key = suffix and (row.id .. ":" .. suffix.id) or row.id,
				link = Gear.Link(row.id, suffix and suffix.id),
				name = suffix and (item.name .. " " .. suffix.name) or item.name,
				quality = item.quality,
				ilvl = item.ilvl,
				req = item.req,
				score = row.score,
				rank = rank,
				index = top > 0 and math.floor(row.score / top * 100 + 0.5) or 0,
				delta = toBeat and (row.score - toBeat) or nil,
				gain = toBeat and top > 0 and math.max(-100, math.min(100, (row.score - toBeat) / top * 100)) or nil,
				worn = worn or nil,
				suffix = suffix and { id = suffix.id, name = suffix.name } or nil,
				hand = item.hand,
				bind = item.bind,
				tracked = Gear.IsTracked(row.id, row.suffix) or nil,
				state = state,
				source = sources[1],
			}
		end
	end
	return out
end

function Gear.Rank(what, ctx)
	ctx = Ctx(ctx)
	local id = ns.ItemID(what)
	local item = id and Gear.Item(id)
	if not item or not ctx or not ctx.spec then return nil end
	-- a link with a suffix is that row; a bare item is its best row
	local suffix = LinkSuffix(what, item)
	suffix = suffix and suffix.id
	local full = FullList(item.slot, ctx)
	for rank, row in ipairs(full) do
		if row.id == id and (not suffix or row.suffix == suffix) then return rank, #full end
	end
	if item.slot == "MainHand" and item.hand == "one" then
		local off = FullList("OffHand", ctx)
		for rank, row in ipairs(off) do
			if row.id == id and (not suffix or row.suffix == suffix) then return rank, #off end
		end
	end
	return nil
end

-- "twohand" when the best two-hander beats the best main hand and off hand together.
function Gear.Route(ctx)
	ctx = Ctx(ctx)
	if not ctx or not ctx.spec then return "onehand" end
	local two, one = 0, 0
	for _, row in ipairs(FullList("MainHand", ctx)) do
		local item = Gear.Item(row.id)
		if item.hand == "two" then
			if row.score > two then two = row.score end
		elseif row.score > one then
			one = row.score
		end
		if two > 0 and one > 0 then break end
	end
	local off = FullList("OffHand", ctx)[1]
	return two > one + (off and off.score or 0) and "twohand" or "onehand"
end

-- Scores on a scale a player can read: 100 is the best item of the slot for this spec at this
-- level, so a gain of 25 means "a quarter of the way from nothing to the best item".
-- The scoring itself is not touched. Gains stay inside -100..100.
local function Points(slotKey, ctx, value, signed)
	if type(value) ~= "number" then return nil end
	local full = FullList(slotKey, ctx)
	local top = full[1] and full[1].score or 0
	if top <= 0 then return nil end
	local points = value / top * 100
	if signed then return math.max(-100, math.min(100, points)) end
	return math.max(0, math.min(100, points))
end

function Gear.Compare(link, ctx)
	ctx = Ctx(ctx)
	local id = ns.ItemID(link)
	if not id or not ctx then return nil end
	local item = Gear.Item(id)
	if not item then
		-- not in our data: say only what the game knows
		local _, _, _, equipLoc = C_Item.GetItemInfoInstant(id)
		local slot = equipLoc and EQUIP_SLOT[equipLoc]
		if not slot then return nil end
		return { slot = slot, usable = true, known = false }
	end
	local usable, reason = Gear.Usable(item, ctx)
	local score = Gear.Score(link, ctx)
	local result = { slot = item.slot, score = score, usable = usable, reason = reason, known = true }
	result.rank = Gear.Rank(link, ctx)
	result.index = score and Points(item.slot, ctx, score) or nil
	if not score or ctx.preview then return result end
	-- a one-hander may go in either hand: take the better swap
	local slots = { item.slot }
	local rules = Data.classes and Data.classes[ctx.class]
	if item.slot == "MainHand" and item.hand == "one" and rules and rules.dual then slots[2] = "OffHand" end
	for _, slotKey in ipairs(slots) do
		local toBeat = WornScore(slotKey, ctx, item.hand)
		if toBeat then
			local delta = score - toBeat
			if not result.delta or delta > result.delta then
				result.delta = delta
				result.slot = slotKey
				result.percent = toBeat > 0 and (delta / toBeat * 100) or nil
				result.gain = Points(slotKey, ctx, delta, true)
				result.index = Points(slotKey, ctx, score)
				local worn = Gear.Worn(slotKey)
				local low
				for _, w in ipairs(worn) do
					if not low or (w.score or 0) < (low.score or 0) then low = w end
				end
				result.worn = low and #worn >= #SLOT[slotKey].inv and { link = low.link, score = Gear.Score(low.link, ctx) } or nil
			end
		end
	end
	-- a link names its suffix; a bare id is any suffix
	local wornSuffix = false
	if type(link) == "string" then wornSuffix = Gear.LinkSuffixID(link) end
	if IsWorn(result.slot, id, wornSuffix) then
		result.isWorn = true
		result.delta = 0
		result.percent = 0
		result.gain = 0
	end
	return result
end

-- Stat changes --------------------------------------------------------------------------------

local STAT_ORDER = {}
for i, key in ipairs({ "ap", "rap", "feralAp", "health", "mana", "armor", "sp", "heal", "crit", "hit", "spellCrit",
	"spellHit", "haste", "defense", "dodge", "parry", "block", "blockValue", "mp5", "manaRegen", "hp5", "healthRegen", "str", "agi", "sta", "int", "spi" }) do
	STAT_ORDER[key] = i
end

-- What the primary attributes turn into (vanilla rules). Players read attack power, health,
-- mana and armor; the attributes behind them are kept as small print.
local SHORT = { str = "STR", agi = "AGI", sta = "STA", int = "INT", spi = "SPR" }
local ATTRS = { "str", "agi", "sta", "int", "spi" }
local AP_PER_STR = { WARRIOR = 2, PALADIN = 2, SHAMAN = 2, DRUID = 2 } -- others 1
local AP_PER_AGI = { ROGUE = 1, HUNTER = 1 } -- and a druid in cat form
local MELEE = { WARRIOR = true, ROGUE = true, PALADIN = true, SHAMAN = true, DRUID = true }
local NO_MANA = { WARRIOR = true, ROGUE = true }
local HEALTH_PER_STA, MANA_PER_INT, ARMOR_PER_AGI, RAP_PER_AGI_HUNTER = 10, 15, 2, 2
-- Spirit: mana back per 5 seconds while not casting (vanilla: spirit / 4 or / 5 per 2-second tick).
-- Classes without mana: health back per 5 seconds out of combat.
local MANA_REGEN_PER_SPI = { PRIEST = 0.625, MAGE = 0.625, WARLOCK = 0.5, DRUID = 0.5, SHAMAN = 0.5, PALADIN = 0.5, HUNTER = 0.5 }
local HEALTH_REGEN_PER_SPI = { WARRIOR = 2, ROGUE = 1.25 }
-- Attribute points for 1% at level 60 (vanilla). Below 60 it takes fewer points: scaled by level.
local AGI_PER_CRIT = { WARRIOR = 20, PALADIN = 20, SHAMAN = 20, DRUID = 20, ROGUE = 29, HUNTER = 53, MAGE = 20, PRIEST = 20, WARLOCK = 20 }
local AGI_PER_DODGE = { WARRIOR = 20, PALADIN = 20, SHAMAN = 20, DRUID = 20, ROGUE = 14.5, HUNTER = 26.5, MAGE = 20, PRIEST = 20, WARLOCK = 20 }
local INT_PER_SPELL_CRIT = { MAGE = 59.5, PRIEST = 59.2, WARLOCK = 60.6, DRUID = 60, SHAMAN = 59.5, PALADIN = 54 }
local CLOTH_CASTER = { MAGE = true, PRIEST = true, WARLOCK = true }

-- Percent one attribute point gives, by class and level.
--   1. The client's game table packed by the build (Data.rates[kind][class], levels 1 to 60).
--   2. The game's own number for the player, when this client has the call.
--   3. The level 60 table above, scaled by level: a rough guess, used only when 1 and 2 are missing.
local rateLists = {}
local function TableRate(kind, class, level)
	local key = kind .. class
	local list = rateLists[key]
	if list == nil then
		list = false
		local packed = Data.rates and Data.rates[kind] and Data.rates[kind][class]
		if type(packed) == "string" then
			list = {}
			for value in packed:gmatch("[^,]+") do list[#list + 1] = tonumber(value) or 0 end
		end
		rateLists[key] = list
	end
	if not list then return nil end
	local rate = list[math.max(1, math.min(#list, level or #list))]
	return rate and rate > 0 and rate or nil
end

local function PercentPerPoint(kind, per60, class, level, api, statIndex)
	local rate = kind and TableRate(kind, class, level)
	if rate then return rate end
	local fn = api and _G[api]
	if type(fn) == "function" and UnitStat and ns.player and ns.player.class == class then
		local ok, part = pcall(fn, "player")
		local ok2, _, total = pcall(UnitStat, "player", statIndex)
		part, total = ns.Plain(part), ns.Plain(total)
		if ok and ok2 and type(part) == "number" and type(total) == "number" and part > 0 and total > 0 then return part / total end
	end
	local per = per60[class]
	if not per then return nil end
	return 1 / (per * math.max(1, math.min(60, level or 60)) / 60)
end

-- Dodge has no table of its own: vanilla gives rogues and hunters twice the dodge per agility
-- that they get crit, and every other class the same as crit.
local DODGE_PER_CRIT = { ROGUE = 2, HUNTER = 2 }

-- Turns a table of stat changes into rows. Attributes that feed a row are listed in its parts
-- and taken out of diff; an attribute that feeds nothing gets a row of its own ("SPR +4").
local function DerivedRows(diff, ctx)
	local class = ctx.class
	local rec = SpecRecord(class, ctx.spec or "")
	local role = rec and rec.role
	local casting = role == "caster" or role == "healer"
	local str, agi, sta, int, spi = diff.str or 0, diff.agi or 0, diff.sta or 0, diff.int or 0, diff.spi or 0
	local rows, used = {}, {}
	local function add(key, label, value, parts, unit)
		local list = {}
		for _, part in ipairs(parts) do
			if part[2] ~= 0 then list[#list + 1] = { key = part[1], label = SHORT[part[1]], value = part[2] } end
		end
		if math.abs(value) < 0.005 and #list == 0 then return end
		for _, part in ipairs(list) do used[part.key] = true end
		rows[#rows + 1] = { key = key, label = label, value = value, parts = #list > 0 and list or nil, unit = unit }
	end

	add("armor", "Armor", (diff.armor or 0) + agi * ARMOR_PER_AGI, { { "agi", agi } })
	diff.armor = nil
	if class == "HUNTER" then
		add("rap", "Ranged Attack Power", agi * RAP_PER_AGI_HUNTER + (diff.ap or 0) + (diff.rap or 0), { { "agi", agi } })
		diff.ap, diff.rap = nil, nil
	elseif MELEE[class] and not casting then
		local cat = class == "DRUID" and ctx.spec ~= "bear"
		local perAgi = AP_PER_AGI[class] or (cat and 1) or 0
		local total = str * (AP_PER_STR[class] or 1) + agi * perAgi + (diff.ap or 0)
		if class == "DRUID" then
			total = total + (diff.feralAp or 0)
			diff.feralAp = nil
		end
		add("ap", "Attack Power", total, { { "str", str }, { "agi", perAgi ~= 0 and agi or 0 } })
		diff.ap = nil
	end
	add("health", "Health", sta * (Data.rates and Data.rates.healthPerSta or HEALTH_PER_STA) + (diff.health or 0), { { "sta", sta } })
	diff.health = nil
	if not NO_MANA[class] then
		add("mana", "Mana", int * MANA_PER_INT + (diff.mana or 0), { { "int", int } })
		diff.mana = nil
	end
	-- crit and dodge: the item's own percent plus what agility or intellect adds
	local flatCrit = diff.crit or 0
	if class == "HUNTER" or (MELEE[class] and not casting) then
		local per = PercentPerPoint("crit", AGI_PER_CRIT, class, ctx.level, "GetCritChanceFromAgility", 2)
		if per then
			add("crit", "Crit chance", flatCrit + agi * per, { { "agi", agi } }, "%")
			diff.crit = nil
		end
	end
	if (casting or CLOTH_CASTER[class]) and INT_PER_SPELL_CRIT[class] then
		local per = PercentPerPoint("spellCrit", INT_PER_SPELL_CRIT, class, ctx.level, "GetSpellCritChanceFromIntellect", 4)
		if per then
			-- one crit stat on an item counts for spells too
			add("spellCrit", "Spell crit", (diff.spellCrit or flatCrit) + int * per, { { "int", int } }, "%")
			diff.spellCrit, diff.crit = nil, nil
		end
	end
	local critRate = TableRate("crit", class, ctx.level)
	local perDodge = critRate and critRate * (DODGE_PER_CRIT[class] or 1) or PercentPerPoint(nil, AGI_PER_DODGE, class, ctx.level)
	if perDodge then
		add("dodge", "Dodge", (diff.dodge or 0) + agi * perDodge, { { "agi", agi } }, "%")
		diff.dodge = nil
	end
	local manaRegen = Data.rates and Data.rates.manaRegen and Data.rates.manaRegen[class] or MANA_REGEN_PER_SPI[class]
	if manaRegen then
		add("manaRegen", "Mana regen", spi * manaRegen, { { "spi", spi } }, "per 5 sec")
	elseif HEALTH_REGEN_PER_SPI[class] then
		add("healthRegen", "Health regen", spi * HEALTH_REGEN_PER_SPI[class], { { "spi", spi } }, "per 5 sec")
	end
	for key, short in pairs(SHORT) do
		local value = diff[key]
		if used[key] then
			diff[key] = nil
		elseif value and math.abs(value) >= 0.005 then
			rows[#rows + 1] = { key = key, label = short, value = value }
			diff[key] = nil
		end
	end
	return rows
end

-- Stats of an item with its random suffix: the one in the link, or (best = true) the best for ctx.
local function LinkStats(link, ctx, best)
	local id = ns.ItemID(link)
	local item = id and Gear.Item(id)
	if not item then return nil end
	local stats = {}
	for key, value in pairs(item.stats or {}) do stats[key] = value end
	local suffix = LinkSuffix(link, item)
	if not suffix and best and item.suffixes then
		local list = Gear.Suffixes(id, ctx)
		suffix = list and list[1]
	end
	if suffix then
		for key, value in pairs(suffix.stats or {}) do stats[key] = (stats[key] or 0) + value end
	end
	return stats, item, suffix
end

-- What changes when the item replaces the worn one. The random suffix counts on both sides.
-- { vs = { { id, link, name, quality } }, rows (gains first), attrs, suffix = { id, name } or nil }
-- attrs: the raw attribute changes, gains first: { { key = "str", label = "STR", value } }.
-- A row: { key, label, value, parts = { { key, label = "STR", value } } or nil, unit = "per 5 sec" or nil }. Attributes are folded into what
-- they give: "+28 Attack Power (+10 STR, +8 AGI)", "+50 Health (+5 STA)".
-- vs is empty for an empty slot. nil: nothing to compare (unknown item, preview, the worn item itself).
function Gear.StatDiff(link, ctx)
	ctx = Ctx(ctx)
	if not ctx or ctx.preview then return nil end
	local c = Gear.Compare(link, ctx)
	if not c or not c.known or not c.slot or c.isWorn or c.usable == false and c.reason ~= "level" then return nil end
	local stats, item, suffix = LinkStats(link, ctx, true)
	if not stats then return nil end
	local diff = {}
	for key, value in pairs(stats) do diff[key] = value end
	local dps = item.weapon and item.weapon.dps or nil

	-- what it replaces: both hands for a two-hander, else the weaker item of the slot
	local old = {}
	if c.slot == "MainHand" and item.hand == "two" then
		for _, w in ipairs(Gear.Worn("MainHand")) do old[#old + 1] = w end
		for _, w in ipairs(Gear.Worn("OffHand")) do old[#old + 1] = w end
	elseif #Gear.Worn(c.slot) >= #SLOT[c.slot].inv then
		local low
		for _, w in ipairs(Gear.Worn(c.slot)) do
			if not low or (Gear.Score(w.link, ctx) or 0) < (Gear.Score(low.link, ctx) or 0) then low = w end
		end
		old[1] = low
	end
	local vs = {}
	for i, w in ipairs(old) do
		local wornStats, wornItem, wornSuffix = LinkStats(w.link, ctx, false)
		if not wornStats then return nil end
		for key, value in pairs(wornStats) do diff[key] = (diff[key] or 0) - value end
		if i == 1 and (dps or wornItem.weapon) then dps = (dps or 0) - (wornItem.weapon and wornItem.weapon.dps or 0) end
		vs[i] = {
			id = wornItem.id, link = w.link, quality = wornItem.quality,
			name = wornSuffix and (wornItem.name .. " " .. wornSuffix.name) or wornItem.name,
		}
	end

	-- hit and crit are one stat for melee and spells: show it once
	if diff.spellHit and diff.spellHit == diff.hit then diff.spellHit = nil end
	if diff.spellCrit and diff.spellCrit == diff.crit then diff.spellCrit = nil end
	-- the raw attribute changes, before they are folded into what they give
	local attrs = {}
	for _, key in ipairs(ATTRS) do
		local value = diff[key]
		if value and math.abs(value) >= 0.005 then attrs[#attrs + 1] = { key = key, label = SHORT[key], value = value } end
	end
	local rows = DerivedRows(diff, ctx)
	if dps and math.abs(dps) >= 0.05 then rows[#rows + 1] = { key = "dps", label = "Weapon DPS", value = dps } end
	for key, value in pairs(diff) do
		if math.abs(value) >= 0.005 then rows[#rows + 1] = { key = key, label = Gear.StatLabel(key), value = value } end
	end
	local function order(a, b)
		if (a.value > 0) ~= (b.value > 0) then return a.value > 0 end
		local oa, ob = a.key == "dps" and 0 or STAT_ORDER[a.key] or 99, b.key == "dps" and 0 or STAT_ORDER[b.key] or 99
		if oa ~= ob then return oa < ob end
		return a.label < b.label
	end
	table.sort(rows, order)
	table.sort(attrs, order)
	return { vs = vs, rows = rows, attrs = attrs, suffix = suffix and { id = suffix.id, name = suffix.name } or nil }
end

-- Sources ----------------------------------------------------------------------------------------

local srcLine = Index("srcItems")
local npcLine = Index("npcs")
local objectLine = Index("objects")
local questLine = Index("quests")
local areaLine = Index("areas")
local instLine = Index("instAreas")

local KIND_LABEL = {
	boss = "Boss", drop = "Drop", rare = "Rare", object = "Chest", container = "Container", quest = "Quest",
	vendor = "Vendor", craft = "Craft", world = "World drop", unknown = "Unknown",
}
local KIND_ORDER = { boss = 1, quest = 2, vendor = 3, craft = 4, rare = 5, drop = 6, object = 7, container = 8, world = 9, unknown = 10 }

function Gear.KindLabel(kind) return KIND_LABEL[kind] or kind end

-- "map:x:y:n;map:x:y" -> spots
local function Spots(text)
	local spots = {}
	for _, part in ipairs(split(text, ";")) do
		local f = split(part, ":")
		if num(f[1]) then spots[#spots + 1] = { map = num(f[1]), x = num(f[2]), y = num(f[3]), n = num(f[4]) } end
	end
	return spots
end

local areas = {}
local function Area(id)
	if not id then return nil end
	local area = areas[id]
	if area == nil then
		local line = areaLine(id)
		if line then
			local f = split(line, "^")
			area = { name = f[1], map = num(f[2]), parent = num(f[3]) }
		else
			area = false
		end
		areas[id] = area
	end
	return area or nil
end

-- Instance by its area id: name, map id and entrances.
local insts = {}
local function Inst(id)
	if not id then return nil end
	local inst = insts[id]
	if inst == nil then
		local line = instLine(id)
		if line then
			local f = split(line, "^")
			inst = { name = f[1], mapId = num(f[2]), parent = num(f[3]), spots = Spots(f[4]) }
		else
			inst = false
		end
		insts[id] = inst
	end
	return inst or nil
end

-- Line: name^min^max^rank^flags^side^area^inst^spots     flags: 1 boss, 2 vendor
local npcs = {}
local function Npc(id)
	local npc = npcs[id]
	if npc == nil then
		local line = npcLine(id)
		if line then
			local f = split(line, "^")
			local flags = num(f[5]) or 0
			npc = {
				id = id, name = f[1], min = num(f[2]), max = num(f[3]), rank = num(f[4]) or 0,
				boss = bit.band(flags, 1) ~= 0, vendor = bit.band(flags, 2) ~= 0,
				side = f[6] ~= "" and f[6] or nil, area = num(f[7]), inst = num(f[8]), spots = Spots(f[9]),
			}
		else
			npc = false
		end
		npcs[id] = npc
	end
	return npc or nil
end
Gear.Npc = Npc

-- Line: name^area^inst^many^spots
local function Object(id)
	local line = objectLine(id)
	if not line then return nil end
	local f = split(line, "^")
	return { id = id, name = f[1], area = num(f[2]), inst = num(f[3]), many = f[4] == "1", spots = Spots(f[5]) }
end

-- Line: name^level^req^side^classMask^startKind:startId^area^dungeon^prev^next
local function Quest(id)
	local line = questLine(id)
	if not line then return nil end
	local f = split(line, "^")
	local kind, start = (f[6] or ""):match("^(%a):(%d+)$")
	return {
		id = id, name = f[1], level = num(f[2]), req = num(f[3]), side = f[4] ~= "" and f[4] or nil,
		classMask = num(f[5]), startKind = kind, start = num(start), area = num(f[7]), dungeon = f[8] == "1",
		prev = f[9], next = num(f[10]),
	}
end
Gear.Quest = Quest

-- Where a thing is: zone name, instance name, spots (the instance entrance when inside one).
local function Place(source, area, instArea, spots)
	local inst = Inst(instArea)
	if inst then
		source.inst = inst.name
		source.instMap = inst.mapId
		local known = Data.instances and Data.instances[inst.mapId]
		source.raid = known and known.kind == "raid" or false
		source.zone = (Area(inst.parent) or {}).name or inst.name
		source.spots = inst.spots
	else
		source.zone = (Area(area) or {}).name
		source.spots = spots or {}
	end
end

-- Drop chance from the player's own loot records, once there are enough kills.
local function SeenChance(key, itemId)
	local loot = ns.db and ns.db.collected and ns.db.collected.loot
	local record = loot and loot[key]
	if not record or (record.n or 0) < 10 then return nil end
	local seen = record.items and record.items[itemId] or 0
	return math.floor(seen / record.n * 1000 + 0.5) / 10
end

local function PercentText(chance)
	if not chance then return "" end
	if chance >= 10 then return (", %d%%"):format(chance + 0.5) end
	return (", %.1f%%"):format(chance)
end

local function Join(first, second)
	if first and second and second ~= "" and second ~= first then return first .. ", " .. second end
	return first or second or ""
end

local sourceCache = {}

-- srcItems line: fields "n:4831@16.5,123" "o:22" "c:500" "v:2679@3612" "q:6" "w:" (world drop)
function Gear.Sources(id)
	local cached = sourceCache[id]
	if cached then return cached end
	local out = {}
	local line = srcLine(id)
	for _, field in ipairs(split(line, "^")) do
		local kind, list = field:match("^(%a):(.*)$")
		if kind == "w" then
			out[#out + 1] = { kind = "world", name = "World drop", text = "World drop" }
		elseif kind then
			for _, entry in ipairs(split(list, ",")) do
				local ref, extra = entry:match("^(%d+)@?([%d%.]*)$")
				ref, extra = tonumber(ref), tonumber(extra)
				if kind == "n" then
					local npc = ref and Npc(ref)
					if npc then
						local source = {
							kind = npc.boss and "boss" or ((npc.rank == 2 or npc.rank == 4) and "rare") or "drop",
							name = npc.name, npc = ref, level = npc.max, side = npc.side,
							chance = SeenChance(ref, id) or extra,
						}
						Place(source, npc.area, npc.inst, npc.spots)
						source.text = Join(npc.name, source.inst or source.zone) .. PercentText(source.chance)
						out[#out + 1] = source
					end
				elseif kind == "o" then
					local object = ref and Object(ref)
					if object then
						local source = { kind = "object", name = object.name, object = ref, chance = SeenChance("o" .. ref, id) or extra }
						Place(source, object.area, object.inst, object.spots)
						source.text = Join(object.name, source.inst or source.zone) .. PercentText(source.chance)
						out[#out + 1] = source
					end
				elseif kind == "c" then
					local name = ref and (Data.containerNames and Data.containerNames[ref]) or (ref and C_Item.GetItemInfo(ref)) or "Container"
					out[#out + 1] = { kind = "container", name = name, container = ref, text = "In: " .. name }
				elseif kind == "v" then
					local npc = ref and Npc(ref)
					if npc then
						local seen = ns.db and ns.db.collected and ns.db.collected.vendors and ns.db.collected.vendors[ref]
						local cost = (seen and seen.items and seen.items[id]) or extra
						if cost and cost < 0 then cost = nil end
						local source = { kind = "vendor", name = npc.name, npc = ref, side = npc.side, cost = cost }
						Place(source, npc.area, npc.inst, npc.spots)
						source.text = Join(npc.name, source.zone)
						out[#out + 1] = source
					end
				elseif kind == "q" then
					local quest = ref and Quest(ref)
					if quest then
						local source = { kind = "quest", name = quest.name, quest = ref, level = quest.level, side = quest.side, dungeon = quest.dungeon }
						local giver = quest.startKind == "n" and Npc(quest.start) or (quest.startKind == "o" and Object(quest.start)) or nil
						if giver then
							Place(source, giver.area, giver.inst, giver.spots)
							source.giver = giver.name
						else
							source.zone = (Area(quest.area) or {}).name
							source.spots = {}
						end
						source.text = Join("Quest: " .. quest.name, source.zone)
						out[#out + 1] = source
					end
				end
			end
		end
	end
	local craft = Data.crafts and Data.crafts[id]
	if craft then
		-- "spell^profession^skill^recipeItem^id:count,id:count"
		local f = split(craft, "^")
		local reagents = {}
		for reagent, count in (f[5] or ""):gmatch("(%d+):(%d+)") do
			reagents[#reagents + 1] = { id = tonumber(reagent), count = tonumber(count) }
		end
		out[#out + 1] = {
			kind = "craft", name = f[2], prof = f[2], skill = num(f[3]), spell = num(f[1]), recipe = num(f[4]),
			reagents = reagents, spots = {}, text = f[2] .. (num(f[3]) and (" " .. f[3]) or ""),
		}
	end
	-- what the player has seen that the build does not know yet
	local collected = ns.db and ns.db.collected
	if collected and #out == 0 then
		for questId, quest in pairs(collected.quests or {}) do
			for _, list in ipairs({ quest.choice or {}, quest.fixed or {} }) do
				for _, itemId in ipairs(list) do
					if itemId == id then
						local name = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questId) or ("Quest " .. questId)
						out[#out + 1] = { kind = "quest", name = name, quest = questId, spots = {}, text = "Quest: " .. name }
					end
				end
			end
		end
	end
	if #out == 0 then
		out[1] = { kind = "unknown", name = "Unknown", spots = {}, text = "Source unknown" }
	end
	-- best first; keep the order of the data inside one kind
	for i, source in ipairs(out) do source.order = i end
	table.sort(out, function(a, b)
		local ka, kb = KIND_ORDER[a.kind] or 99, KIND_ORDER[b.kind] or 99
		if ka ~= kb then return ka < kb end
		if (a.chance or 0) ~= (b.chance or 0) then return (a.chance or 0) > (b.chance or 0) end
		return a.order < b.order
	end)
	sourceCache[id] = out
	return out
end

-- Names of every zone and instance that holds a source, sorted.
function Gear.Zones()
	local seen, out = {}, {}
	for _, lineOf in ipairs({ areaLine, instLine }) do
		local _, index = lineOf(0)
		for _, line in pairs(index) do
			local name = line:match("^([^%^]*)")
			if name and name ~= "" and not seen[name] then
				seen[name] = true
				out[#out + 1] = name
			end
		end
	end
	table.sort(out)
	return out
end

function Gear.SourceText(id)
	local first = Gear.Sources(id)[1]
	if not first or first.kind == "unknown" then return nil end
	return first.text
end

-- Collected data changes what sources say.
function Gear.ForgetSources()
	sourceCache = {}
end

-- Who drops, sells or rewards what: built from the item lines the first time it is asked.
local reverse
local function Reverse()
	if reverse then return reverse end
	reverse = { n = {}, v = {}, q = {} }
	local _, index = srcLine(0)
	for id, line in pairs(index) do
		for kind, list in line:gmatch("(%a):([^%^]*)") do
			local into = reverse[kind]
			if into then
				for ref, extra in list:gmatch("(%d+)@?([%d%.]*)") do
					ref = tonumber(ref)
					into[ref] = into[ref] or {}
					table.insert(into[ref], { id = id, extra = tonumber(extra) })
				end
			end
		end
	end
	return reverse
end

function Gear.NpcDrops(npcId)
	local list = npcId and Reverse().n[npcId]
	if not list then return nil end
	local out = {}
	for _, row in ipairs(list) do
		out[#out + 1] = { id = row.id, chance = SeenChance(npcId, row.id) or row.extra }
	end
	return out
end

function Gear.NpcSells(npcId)
	local list = npcId and Reverse().v[npcId]
	if not list then return nil end
	local out = {}
	for _, row in ipairs(list) do out[#out + 1] = { id = row.id, cost = row.extra } end
	return out
end

function Gear.QuestRewards(questId)
	local list = questId and Reverse().q[questId]
	if not list then return nil end
	local out = {}
	for _, row in ipairs(list) do out[#out + 1] = row.id end
	return out
end

-- Enchants -----------------------------------------------------------------------------------------

local enchantCache = Cache()

-- Data.enchants: list of { id, name, spell, item, slots = { Head = true }, hand, stats = {}, req }
function Gear.BestEnchant(slotKey, ctx)
	ctx = Ctx(ctx)
	if not ctx or not ctx.spec or not Data.enchants or not ns.Scorer then return nil end
	local key = CtxKey(ctx) .. "/" .. slotKey
	local best = enchantCache[key]
	if best ~= nil then return best or nil end
	best = false
	local rec = SpecRecord(ctx.class, ctx.spec)
	local ok, weights = pcall(ns.Scorer.effective, rec, Data.weights, ctx.level)
	local wornHand
	local worn = not ctx.preview and Gear.Worn(slotKey)[1]
	local wornItem = worn and Gear.Item(worn.id)
	if wornItem then wornHand = wornItem.hand end
	if rec and ok and weights then
		local weightKey = Data.weightKey or {}
		for _, enchant in ipairs(Data.enchants) do
			local fits = enchant.slots[slotKey] and (not enchant.req or enchant.req <= ctx.level)
			if fits and enchant.hand then fits = wornHand == enchant.hand end
			if fits then
				local score = 0
				for stat, amount in pairs(enchant.stats) do
					score = score + amount * (weights[weightKey[stat] or stat] or 0)
				end
				if enchant.dmg then score = score + enchant.dmg / 2.4 * (rec.dps or 0) end
				if score > 0 and (not best or score > best.score) then
					best = { id = enchant.id, name = enchant.name, spell = enchant.spell, item = enchant.item, score = score, text = enchant.text or enchant.name }
				end
			end
		end
	end
	enchantCache[key] = best
	return best or nil
end

-- Custom specs ---------------------------------------------------------------------------------------

local function ClassWeights(class)
	local classes = Data.weights and Data.weights.classes
	if not classes then return nil end
	return classes[class] or classes[class:lower()]
end

function Gear.CustomSpecs(class)
	local saved = ns.db and ns.db.customSpecs and ns.db.customSpecs[class]
	local out = {}
	for _, spec in pairs(saved or {}) do out[#out + 1] = spec end
	table.sort(out, function(a, b) return a.label < b.label end)
	return out
end

function Gear.Weights(class, specKey)
	local rec = SpecRecord(class, specKey)
	if not rec then return nil end
	local copy = { weights = {}, dps = rec.dps or 0, dpsRanged = rec.dpsRanged or 0 }
	for k, v in pairs(rec.weights) do copy.weights[k] = v end
	return copy
end

-- Puts a saved custom spec where the scorer finds it. It keeps its base spec's armour
-- rules and flags.
local function Install(class, spec)
	local byClass = ClassWeights(class)
	if not byClass then return end
	local base = byClass[spec.base] or {}
	byClass[spec.key] = {
		label = spec.label, custom = true, weights = spec.weights, dps = spec.dps, dpsRanged = spec.dpsRanged,
		armorMult = base.armorMult, flags = base.flags, speed = base.speed,
	}
end

function Gear.SaveCustom(class, spec)
	if not spec.key then spec.key = "custom_" .. spec.label:lower():gsub("[^%w]+", "_") end
	ns.db.customSpecs[class] = ns.db.customSpecs[class] or {}
	ns.db.customSpecs[class][spec.key] = spec
	Install(class, spec)
	for key in pairs(pools) do
		if key:find(class .. "/" .. spec.key .. "/", 1, true) == 1 then pools[key] = nil end
	end
	if ns.Scorer and ns.Scorer.forget then ns.Scorer.forget() end
	ContextChanged()
	return spec.key
end

function Gear.DeleteCustom(class, key)
	if ns.db.customSpecs[class] then ns.db.customSpecs[class][key] = nil end
	local byClass = ClassWeights(class)
	if byClass and byClass[key] and byClass[key].custom then byClass[key] = nil end
	if ns.char.spec == key then ns.char.spec = nil end
	ContextChanged()
end

-- Start-up and events ------------------------------------------------------------------------------------

ns.OnLoad(function()
	for class, specs in pairs(ns.db.customSpecs) do
		for _, spec in pairs(specs) do Install(class, spec) end
	end
end)

local gearChanged = ns.Debounce(0.3, function()
	Wipe()
	ns.Send("GEAR_CHANGED")
end)
ns.On("PLAYER_EQUIPMENT_CHANGED", gearChanged)
ns.On("PLAYER_LEVEL_UP", function() C_Timer.After(0.5, ContextChanged) end)
ns.On("CHARACTER_POINTS_CHANGED", ns.Debounce(1, ContextChanged))
-- talents: points spent, another build loaded, the other spec activated. At login the talents
-- come after the addon, so the first of these also sets the spec right.
do
	local changed = ns.Debounce(0.5, ContextChanged)
	for _, event in ipairs({ "TRAIT_CONFIG_UPDATED", "TRAIT_CONFIG_LIST_UPDATED", "PLAYER_TALENT_UPDATE", "ACTIVE_COMBAT_CONFIG_CHANGED",
		"ACTIVE_TALENT_GROUP_CHANGED" }) do
		ns.On(event, changed)
	end
end
ns.Listen("FILTERS_CHANGED", Wipe)
ns.Listen("HUNTS_CHANGED", Wipe)

-- "/lm spec" is in Upgrades.lua.
