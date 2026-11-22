local _, ns = ...

-- Collector: records what the player sees, to fill gaps in the build data.
-- The build reads it from WTF\Account\<ACCOUNT>\SavedVariables\Lootomania.lua:
--
-- LootomaniaDB.collected = {
--   v = 1,
--   loot = {                      -- by source: NPC id (number) or "o<id>" for a game object
--     [key] = {
--       n = corpses or objects looted (each counted once; kills without loot are not seen),
--       zone = uiMapId, inst = instance map id (only in an instance),
--       items = { [itemId] = times seen },   -- gear and anything uncommon or better
--     },
--   },
--   vendors = { [npcId] = { map = uiMapId, x =, y = (0-100), items = { [itemId] = copper, or -1 for a special cost } } },
--   quests = { [questId] = { giver = npcId, ender = npcId, choice = { itemIds }, fixed = { itemIds } } },
--   items = {                     -- equippable items the client has and our data does not
--     [itemId] = { name =, q = quality, ilvl =, req = level, loc = "INVTYPE_HEAD", class =, sub =, bind =,
--                  stats = { ITEM_MOD_X = value },
--                  suffixes = { [suffixId] = { ITEM_MOD_X = value } } },  -- stats of a random-suffix link
--   },
--   noItem = { [itemId] = true }, -- asked by /lm scan, the server has no such item
-- }
--
-- What the build reads today: loot by creature (not objects), vendors, quests' choice and fixed rewards.
-- Kept for the developer, read by no build stage yet: items, noItem (also the scan's own list of
-- ids already asked), loot of objects, a quest's giver and ender.
--
--   ns.Collector.See(link)   notes an item when our data lacks it
--   ns.Collector.Counts()    loot, vendors, quests, items, noItem

local Collector = {}
ns.Collector = Collector

-- most entries of each kind; new ones are dropped past this
local CAP = { loot = 6000, vendors = 2500, quests = 6000, items = 4000, noItem = 60000 }
local CAP_PER_SOURCE = 250 -- items of one NPC or vendor
local SCAN_BATCH, SCAN_EVERY, SCAN_REPORT = 20, 0.5, 500

ns.Defaults({
	collected = { v = 1, loot = {}, vendors = {}, quests = {}, items = {}, noItem = {} },
	scanAt = 0, -- ids of ns.Data.missing already asked
	scanSize = 0,
})
ns.Main.AddOption({ group = "Collector", key = "collect", kind = "check", label = "Remember what you see", default = true,
	tip = "Drops, vendor prices and quest rewards, for the drop chances and prices in tooltips. Also items the data lacks. Stays on this computer." })

local function Data() return ns.db and ns.db.collected end
local function On() return ns.db and ns.db.collect and ns.db.collected and true or false end

local sizes = {}

local function Size(kind)
	if not sizes[kind] then
		local n = 0
		for _ in pairs(Data()[kind]) do n = n + 1 end
		sizes[kind] = n
	end
	return sizes[kind]
end

-- The entry of a kind, made when there is room.
local function Entry(kind, key)
	local all = Data()[kind]
	local entry = all[key]
	if entry == nil then
		if Size(kind) >= CAP[kind] then return nil end
		entry = {}
		all[key] = entry
		sizes[kind] = sizes[kind] + 1
	end
	return entry
end

local function Count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function Place()
	local map = C_Map and C_Map.GetBestMapForUnit and ns.Plain(C_Map.GetBestMapForUnit("player"))
	if not map then return nil end
	local x, y
	if C_Map.GetPlayerMapPosition then
		local ok, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
		if ok and pos then
			if pos.GetXY then x, y = pos:GetXY() else x, y = pos.x, pos.y end
			x, y = ns.Plain(x), ns.Plain(y)
		end
	end
	if type(x) == "number" and type(y) == "number" and (x ~= 0 or y ~= 0) then
		return map, math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
	end
	return map
end

local function Instance()
	if not (IsInInstance and IsInInstance()) or not GetInstanceInfo then return nil end
	return (select(8, GetInstanceInfo()))
end

-- Items our data lacks ----------------------------------------------------------------

local NOT_GEAR = { [""] = true, INVTYPE_NON_EQUIP = true, INVTYPE_NON_EQUIP_IGNORE = true, INVTYPE_BAG = true,
	INVTYPE_QUIVER = true, INVTYPE_AMMO = true, INVTYPE_TABARD = true, INVTYPE_BODY = true }

local checked = {} -- "id:suffix" looked at this session
local waiting = {} -- id -> link, item data not in the cache yet
local late, asked = {}, {} -- id -> link of an item the game did not know at all; key -> asked for once

local function Instant(id)
	if not (C_Item and C_Item.GetItemInfoInstant) then return nil end
	local _, _, _, loc, _, class, sub = C_Item.GetItemInfoInstant(id)
	return loc, class, sub
end

local function Stats(link)
	local get = (C_Item and C_Item.GetItemStats) or GetItemStats
	if not get then return nil end
	local ok, stats = pcall(get, link)
	if not ok or type(stats) ~= "table" then return nil end
	local out = {}
	for key, value in pairs(stats) do
		if type(key) == "string" and type(value) == "number" then out[key] = value end
	end
	return out
end

local function Store(id, link)
	local name, _, quality, ilvl, req, _, _, _, loc, _, _, class, sub, bind = C_Item.GetItemInfo(link)
	if not name then return false end
	local entry = Entry("items", id)
	if not entry then return true end
	entry.name, entry.q, entry.ilvl, entry.req = name, quality, ilvl, req
	entry.loc, entry.class, entry.sub, entry.bind = loc, class, sub, bind
	local stats = Stats(link)
	local suffix = ns.SuffixID(link)
	if suffix then
		entry.suffixes = entry.suffixes or {}
		if stats and Count(entry.suffixes) < 60 then entry.suffixes[suffix] = stats end
	elseif stats then
		entry.stats = stats
	end
	return true
end

function Collector.See(link)
	if not On() or type(link) ~= "string" then return end
	local Gear = ns.Gear
	if not (Gear and Gear.Item) then return end
	local id = ns.ItemID(link)
	if not id then return end
	local key = id .. ":" .. (ns.SuffixID(link) or 0)
	if checked[key] then return end
	checked[key] = true
	if Gear.Ready and not Gear.Ready() then
		checked[key] = nil
		return
	end
	if Gear.Item(id) ~= nil then return end
	local loc = Instant(id)
	if not loc then
		-- The game does not know the item yet (a server-only item, seen for the first time): it is
		-- asked for and looked at again when its data comes. Once: an item the game never learns
		-- stays marked.
		if not asked[key] and C_Item.RequestLoadItemDataByID then
			asked[key] = true
			checked[key] = nil
			late[id] = link
			C_Item.RequestLoadItemDataByID(id)
		end
		return
	end
	if NOT_GEAR[loc] then return end
	if not Store(id, link) then
		waiting[id] = link
		if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
	end
end

-- Loot --------------------------------------------------------------------------------

local looted = {} -- corpse or object GUID -> true, this session
local lootedCount = 0

local function SourceKey(guid)
	local npc = ns.NpcID(guid)
	if npc then return npc end
	guid = ns.Plain(guid)
	if type(guid) ~= "string" then return nil end
	local kind, _, _, _, _, id = strsplit("-", guid)
	id = tonumber(id)
	if kind == "GameObject" and id then return "o" .. id end
	return nil
end

-- Gear, or uncommon and better.
local function Wanted(id, link, slotQuality)
	local _, class = Instant(id)
	if class == 2 or class == 4 then return true end
	local quality = slotQuality
	if type(quality) ~= "number" then
		quality = select(3, C_Item.GetItemInfo(link))
	end
	return type(quality) == "number" and quality >= 2
end

-- Loot that is not a kill's. What Pick Pocket or Skinning takes off a creature comes in a loot
-- window with that creature as its source: counted as a looted corpse, it lowers every chance of
-- the creature, and after Pick Pocket the real corpse was skipped as "seen". The spell names hold
-- for every rank, in the client's language.
local SIDE_SPELLS = { 921, 8613 } -- Pick Pocket, Skinning
local sideNames, sideAt
local function SpellName(id)
	if type(id) ~= "number" then return nil end
	if C_Spell and C_Spell.GetSpellName then return ns.Plain(C_Spell.GetSpellName(id)) end
	if GetSpellInfo then return ns.Plain((GetSpellInfo(id))) end
	return nil
end
ns.On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
	if ns.Plain(unit) ~= "player" then return end
	if not sideNames then
		sideNames = {}
		for _, id in ipairs(SIDE_SPELLS) do
			local name = SpellName(id)
			if name then sideNames[name] = true end
		end
	end
	local name = SpellName(ns.Plain(spellID))
	if name and sideNames[name] then sideAt = GetTime() end
end)

local function ReadLoot()
	if not On() or not (GetNumLootItems and GetLootSourceInfo) then return end
	if IsFishingLoot and IsFishingLoot() then return end
	-- the loot window that follows the player's Pick Pocket or Skinning: creatures are left alone
	local side = sideAt ~= nil and GetTime() - sideAt < 2
	local item = (Enum and Enum.LootSlotType and Enum.LootSlotType.Item) or 1
	local sources = {} -- guid -> { itemId = true }
	for slot = 1, GetNumLootItems() or 0 do
		local info = { GetLootSourceInfo(slot) } -- guid, amount, guid, amount, ...
		local link = (not GetLootSlotType or GetLootSlotType(slot) == item) and ns.Plain(GetLootSlotLink(slot)) or nil
		local id = link and ns.ItemID(link)
		if id then
			Collector.See(link)
			local quality = GetLootSlotInfo and ns.Plain((select(5, GetLootSlotInfo(slot))))
			if not Wanted(id, link, quality) then id = nil end
		end
		for i = 1, #info, 2 do
			local guid = ns.Plain(info[i])
			if type(guid) == "string" then
				sources[guid] = sources[guid] or {}
				if id then sources[guid][id] = true end
			end
		end
	end
	local zone, inst
	for guid, items in pairs(sources) do
		local key = SourceKey(guid)
		if key and not looted[guid] and not (side and type(key) == "number") then
			if lootedCount > 4000 then looted, lootedCount = {}, 0 end
			looted[guid] = true
			lootedCount = lootedCount + 1
			local entry = Entry("loot", key)
			if entry then
				entry.n = (entry.n or 0) + 1
				if not entry.zone then
					if zone == nil then zone, inst = Place() or false, Instance() end
					entry.zone, entry.inst = zone or nil, inst
				end
				entry.items = entry.items or {}
				for id in pairs(items) do
					if entry.items[id] or Count(entry.items) < CAP_PER_SOURCE then
						entry.items[id] = (entry.items[id] or 0) + 1
					end
				end
				if ns.Gear and ns.Gear.SourcesChanged then ns.Gear.SourcesChanged() end
			end
		end
	end
end

-- LOOT_READY comes first; with fast auto loot the window may be empty by LOOT_OPENED.
ns.On("LOOT_READY", function() ns.Safe(ReadLoot) end)
ns.On("LOOT_OPENED", function() ns.Safe(ReadLoot) end)

-- Vendors -----------------------------------------------------------------------------

local function MerchantItem(index)
	local id = GetMerchantItemID and GetMerchantItemID(index)
	local link = GetMerchantItemLink and GetMerchantItemLink(index)
	id = id or (link and ns.ItemID(link))
	local price, special
	if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
		local info = C_MerchantFrame.GetItemInfo(index)
		if info then price, special = info.price, info.hasExtendedCost end
	elseif GetMerchantItemInfo then
		local _, _, cost, _, _, _, _, extended = GetMerchantItemInfo(index)
		price, special = cost, extended
	end
	return id, link, price, special
end

local function ReadMerchant()
	if not On() or not GetMerchantNumItems then return end
	local npc = ns.NpcID(UnitGUID("npc")) or ns.NpcID(UnitGUID("target"))
	if not npc then return end
	local count = GetMerchantNumItems() or 0
	if count == 0 then return end
	local entry = Entry("vendors", npc)
	if not entry then return end
	local map, x, y = Place()
	if map and x then entry.map, entry.x, entry.y = map, x, y end
	entry.items = entry.items or {}
	for index = 1, count do
		local id, link, price, special = MerchantItem(index)
		if id and (entry.items[id] or Count(entry.items) < CAP_PER_SOURCE) then
			-- price of the stack the vendor sells; a special cost wins over copper
			if special then
				entry.items[id] = -1
			elseif type(price) == "number" then
				entry.items[id] = price
			end
			if link then Collector.See(link) end
		end
	end
	if ns.Gear and ns.Gear.SourcesChanged then ns.Gear.SourcesChanged() end
end

-- MERCHANT_UPDATE comes in bursts
local readMerchant = ns.Debounce(0.3, ReadMerchant)
ns.On("MERCHANT_SHOW", readMerchant)
ns.On("MERCHANT_UPDATE", readMerchant)

-- Quest rewards -----------------------------------------------------------------------

local function QuestItems(kind, count)
	local ids, complete = {}, true
	for i = 1, count or 0 do
		local link = GetQuestItemLink(kind, i)
		local id = link and ns.ItemID(link)
		if id then
			ids[#ids + 1] = id
			Collector.See(link)
		else
			complete = false -- not in the cache yet
		end
	end
	return ids, complete
end

local function ReadQuest(event, tries)
	if not On() or not (GetQuestID and GetQuestItemLink) then return end
	local quest = GetQuestID()
	if not quest or quest == 0 then return end
	local choice, okChoice = QuestItems("choice", GetNumQuestChoices and GetNumQuestChoices())
	local fixed, okFixed = QuestItems("reward", GetNumQuestRewards and GetNumQuestRewards())
	if not (okChoice and okFixed) and (tries or 0) < 3 then
		C_Timer.After(0.7, function()
			if GetQuestID() == quest then ns.Safe(ReadQuest, event, (tries or 0) + 1) end
		end)
	end
	if #choice == 0 and #fixed == 0 then return end
	local entry = Entry("quests", quest)
	if not entry then return end
	local npc = ns.NpcID(UnitGUID("questnpc")) or ns.NpcID(UnitGUID("npc"))
	if npc then
		if event == "QUEST_COMPLETE" then entry.ender = npc else entry.giver = npc end
	end
	if #choice >= #(entry.choice or {}) then entry.choice = choice end
	if #fixed >= #(entry.fixed or {}) then entry.fixed = fixed end
end

ns.On("QUEST_DETAIL", function(event) ns.Safe(ReadQuest, event) end)
ns.On("QUEST_COMPLETE", function(event) ns.Safe(ReadQuest, event) end)

-- Tooltips ----------------------------------------------------------------------------

local function TooltipItem(tooltip)
	if not On() or (tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip) then return end
	local link
	if TooltipUtil and TooltipUtil.GetDisplayedItem then
		local ok, _, found = pcall(TooltipUtil.GetDisplayedItem, tooltip)
		link = ok and found or nil
	elseif tooltip.GetItem then
		local ok, _, found = pcall(tooltip.GetItem, tooltip)
		link = ok and found or nil
	end
	link = ns.Plain(link)
	if type(link) == "string" then Collector.See(link) end
end

ns.OnLoad(function()
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip) ns.Safe(TooltipItem, tooltip) end)
	elseif GameTooltip and GameTooltip.HookScript then
		pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetItem", function(tooltip) ns.Safe(TooltipItem, tooltip) end)
	end
end)

-- Item cache scan ---------------------------------------------------------------------
-- Asks the server for the items of ns.Data.missing so the client caches them.

local scan -- { list, ticker, asked = { [id] = true }, reported }

local function NoItem(id)
	local noItem = Data().noItem
	if noItem[id] == nil and Size("noItem") < CAP.noItem then
		noItem[id] = true
		sizes.noItem = sizes.noItem + 1
	end
end

local function StopScan()
	if scan and scan.ticker then scan.ticker:Cancel() end
	scan = nil
end

local function FinishScan()
	StopScan()
	ns.db.scanAt = 0
	ns.Print("Scan done. Log out, then run the build.")
end

local function ScanStep()
	if not scan then return end
	if InCombatLockdown and InCombatLockdown() then return end
	local list, total = scan.list, #scan.list
	local at = ns.db.scanAt
	if at >= total then
		-- give the last answers a moment
		scan.wait = (scan.wait or 0) + 1
		if scan.wait * SCAN_EVERY >= 3 then FinishScan() end
		return
	end
	local noItem = Data().noItem
	local sent = 0
	while at < total and sent < SCAN_BATCH do
		at = at + 1
		local id = tonumber(list[at])
		if id and not noItem[id] then
			if C_Item.DoesItemExistByID and C_Item.DoesItemExistByID(id) == false then
				NoItem(id)
			else
				scan.asked[id] = true
				C_Item.RequestLoadItemDataByID(id)
				sent = sent + 1
			end
		end
	end
	ns.db.scanAt = at
	if math.floor(at / SCAN_REPORT) > scan.reported or at >= total then
		scan.reported = math.floor(at / SCAN_REPORT)
		ns.Print(("Scan: %d/%d"):format(at, total))
	end
end

ns.On("GET_ITEM_INFO_RECEIVED", function(_, id, success)
	id = ns.Plain(id)
	if not id then return end
	if scan and scan.asked[id] then
		scan.asked[id] = nil
		if not success then NoItem(id) end
	end
	local link = waiting[id]
	if link then
		waiting[id] = nil
		if success then Store(id, link) end
	end
	local again = late[id]
	if again then
		late[id] = nil
		if success then Collector.See(again) end
	end
end)

ns.Command("scan", "Cache missing items. Also: stop", function(rest)
	local list = ns.Data and ns.Data.missing
	if rest:lower() == "stop" then
		if scan then
			StopScan()
			ns.Print(("Scan stopped: %d/%d"):format(ns.db.scanAt, type(list) == "table" and #list or 0))
		else
			ns.Print("Scan: not running")
		end
		return
	end
	if type(list) ~= "table" or #list == 0 or not (C_Item and C_Item.RequestLoadItemDataByID) then
		ns.Print("Scan: nothing to do")
		return
	end
	if scan then
		ns.Print(("Scan: %d/%d"):format(ns.db.scanAt, #list))
		return
	end
	-- a new list starts from the top
	if ns.db.scanSize ~= #list or ns.db.scanAt >= #list then
		ns.db.scanAt, ns.db.scanSize = 0, #list
	end
	scan = { list = list, asked = {}, reported = math.floor(ns.db.scanAt / SCAN_REPORT) }
	ns.Print(("Scan: started at %d/%d"):format(ns.db.scanAt, #list))
	scan.ticker = C_Timer.NewTicker(SCAN_EVERY, function() ns.Safe(ScanStep) end)
end, true)

-- Counts ------------------------------------------------------------------------------

function Collector.Counts()
	local data = Data()
	if not data then return 0, 0, 0, 0, 0 end
	return Count(data.loot), Count(data.vendors), Count(data.quests), Count(data.items), Count(data.noItem)
end

ns.Command("collect", "Collected data counts", function()
	ns.Print(("Collected. Loot: %d, Vendors: %d, Quests: %d, Items: %d, No item: %d"):format(Collector.Counts()))
	ns.Print("Collecting: " .. (ns.db.collect and "on" or "off"))
end, true)

