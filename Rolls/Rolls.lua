local ADDON, ns = ...

-- Loot roll window. Lists every active group loot roll with Need / Greed / Pass buttons,
-- who chose what, and an upgrade hint. Takes the place of Blizzard's roll frames.
--
-- This folder is kept apart from the rest: it may ship as an addon of its own that needs
-- Lootomania. No other file calls into it. All it takes from the main addon goes through `LM`:
--   core      On, Listen, OnLoad, Command, Print, Debug, Safe, Plain, ItemID, Debounce, db, player
--   widgets   UI
--   settings  Main.AddOption (keys start with "roll"); the window's place is db.windows.Rolls
--   optional  Gear.Compare, Gear.IsTracked, Wish.Has: hints and marks, left out when missing
-- Today LM is the shared addon table. As a separate addon it would be a table the main addon exports.
-- Bindings.xml in the addon root belongs here too; the game only reads it from the root.
local LM = ns

local UI = LM.UI
local C = UI.C
local Plain = LM.Plain

local Rolls = {}
LM.Rolls = Rolls

-- Settings ----------------------------------------------------------------------------

local GROUP = "Roll window"
-- Off until the player turns it on: it takes rolls away from Blizzard's frames.
LM.Main.AddOption({ group = GROUP, key = "rollWindow", kind = "check", label = "Enabled", default = false,
	tip = "Off: Blizzard roll frames." })
LM.Main.AddOption({ group = GROUP, key = "rollLock", kind = "check", label = "Lock window", default = false })
LM.Main.AddOption({ group = GROUP, key = "rollHidePassed", kind = "check", label = "Hide passed items", default = false })
LM.Main.AddOption({ group = GROUP, key = "rollSoundStart", kind = "check", label = "Sound: roll start", default = false })
LM.Main.AddOption({ group = GROUP, key = "rollSoundWarn", kind = "check", label = "Sound: 5 s left", default = false })
LM.Main.AddOption({ group = GROUP, key = "rollQuietChat", kind = "check", label = "Hide roll chat lines", default = false })
LM.Main.AddOption({ group = GROUP, key = "rollScale", kind = "slider", label = "Scale", min = 60, max = 160, step = 5,
	format = "%d%%", default = 100 })
LM.Main.AddOption({ group = GROUP, key = "rollAlpha", kind = "slider", label = "Opacity", min = 30, max = 100, step = 5,
	format = "%d%%", default = 100 })
LM.Main.AddOption({ group = GROUP, key = "rollLinger", kind = "slider", label = "Show winner", min = 0, max = 60, step = 5,
	format = "%d s", default = 15 })

-- Choices -----------------------------------------------------------------------------

local S = (Enum and Enum.EncounterLootDropRollState) or {}
local ST_NEED, ST_OFF = S.NeedMainSpec or 0, S.NeedOffSpec or 1
local ST_NONE, ST_PASS = S.NoRoll or 4, S.Pass or 5

-- RollOnLoot types
local KIND_PASS, KIND_NEED, KIND_GREED, KIND_MOG = 0, 1, 2, 4
local KIND_CHOICE = { [KIND_PASS] = "pass", [KIND_NEED] = "need", [KIND_GREED] = "greed", [3] = "greed", [KIND_MOG] = "greed" }

local ORDER = { "need", "greed", "pass" }
local CHOICE = {
	need = { label = "Need", color = C.GREEN },
	greed = { label = "Greed", color = C.GOLD },
	pass = { label = "Pass", color = C.MUTED },
}

-- Loot history state -> "need", "greed", "pass" or nil (not chosen yet).
-- Off-spec counts as Need, Transmog as Greed.
local function ChoiceOf(state)
	state = Plain(state)
	if state == nil or state == ST_NONE then return nil end
	if state == ST_PASS then return "pass" end
	if state == ST_NEED or state == ST_OFF then return "need" end
	return "greed"
end

-- State -------------------------------------------------------------------------------

local rolls = {} -- roll ID -> roll
local list = {} -- rolls, oldest first
local drops = {} -- "encounter:key" -> { id, info, roll, old }; our copy of the loot history
local open = {} -- drops not paired with a roll and not finished
local window, pool, emptyText, moreText, driver
local pinned = false -- opened by hand: stays when empty
local wantShow = false
local gaveUp = false -- the game blocked a roll: Blizzard frames for this session
local nextFake = 0
local Draw, Queue

local function Active()
	return LM.db and LM.db.rollWindow and not gaveUp
end

local function Now() return GetTime() end

-- Loot history clock, the one drop start times use.
local function HistoryNow()
	if not (C_LootHistory and C_LootHistory.GetLootHistoryTime) then return nil end
	local ok, t = pcall(C_LootHistory.GetLootHistoryTime)
	t = ok and Plain(t)
	return type(t) == "number" and t or nil
end

local function Payload(link)
	if type(link) ~= "string" then return nil end
	return link:match("|H(item:[^|]+)|h") or link:match("^(item:[%d:%-]+)$")
end

local function SameItem(a, b)
	local pa, pb = Payload(a), Payload(b)
	if pa and pb then return pa == pb end
	local ia, ib = LM.ItemID(a), LM.ItemID(b)
	return ia ~= nil and ia == ib
end

local function IsDone(info)
	return info ~= nil and (info.winner ~= nil or Plain(info.allPassed) == true)
end

-- Item of a roll ------------------------------------------------------------------------

local function Reason(code)
	code = Plain(code)
	local text = code and _G["LOOT_ROLL_INELIGIBLE_REASON" .. tostring(code)]
	if type(text) == "string" and text ~= "" and not text:find("%%") then return text end
	return "Not allowed"
end

local function ReadItem(r)
	if r.fake or r.read then return end
	if GetLootRollItemInfo then
		local ok, texture, name, count, quality, bop, canNeed, canGreed, _, whyNeed, whyGreed, _, _, canMog = pcall(GetLootRollItemInfo, r.id)
		if ok and Plain(name) then
			r.texture, r.name, r.count, r.quality = Plain(texture), Plain(name), Plain(count), Plain(quality)
			r.bop = Plain(bop) and true or false
			r.canNeed, r.canGreed, r.canMog = Plain(canNeed), Plain(canGreed), Plain(canMog) and true or false
			r.whyNeed = r.canNeed == false and Reason(whyNeed) or nil
			r.whyGreed = r.canGreed == false and Reason(whyGreed) or nil
		end
	end
	if not r.link and GetLootRollItemLink then
		local ok, link = pcall(GetLootRollItemLink, r.id)
		link = ok and Plain(link)
		if type(link) == "string" then
			r.link = link
			r.itemID = LM.ItemID(link)
			r.name = r.name or link:match("%[(.-)%]")
		end
	end
	r.read = r.link ~= nil and r.name ~= nil
end

-- Time ----------------------------------------------------------------------------------

-- Seconds left to choose.
local function TimeLeft(r)
	local left
	if not r.fake and not r.closed and GetLootRollTimeLeft then
		local ok, v = pcall(GetLootRollTimeLeft, r.id)
		v = ok and Plain(v)
		if type(v) == "number" then left = r.inMs and v / 1000 or v end
	end
	if not left then left = r.started + r.duration - Now() end
	return math.max(0, left)
end

-- Upgrade hint --------------------------------------------------------------------------

local SLOTS = {
	INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 }, INVTYPE_CHEST = { 5 },
	INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 },
	INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
	INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 },
	INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
}
local RANGED = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true, INVTYPE_RELIC = true }
local rangedSlots

local function SlotsFor(equipLoc)
	if SLOTS[equipLoc] then return SLOTS[equipLoc] end
	if not RANGED[equipLoc] then return nil end
	if not rangedSlots then
		-- the ranged slot exists on old rule sets only
		local ok, slot = pcall(GetInventorySlotInfo, "RangedSlot")
		rangedSlots = { ok and type(slot) == "number" and slot or 16 }
	end
	return rangedSlots
end

local function ItemLevel(link)
	local ok, level = pcall(C_Item.GetDetailedItemLevelInfo, link)
	level = ok and Plain(level)
	if type(level) == "number" then return level end
	local ok2, _, _, _, base = pcall(C_Item.GetItemInfo, link)
	base = ok2 and Plain(base)
	return type(base) == "number" and base or nil
end

-- Item level against the weaker worn item. Returns hint, or nil with true when the item
-- is not loaded yet.
local function LevelHint(link)
	local ok, name, _, _, _, _, _, _, _, equipLoc = pcall(C_Item.GetItemInfo, link)
	if not ok then return nil end
	if Plain(name) == nil then return nil, true end
	local slots = SlotsFor(Plain(equipLoc) or "")
	if not slots then return nil end
	local new = ItemLevel(link)
	if not new then return nil, true end
	local worn
	for _, slot in ipairs(slots) do
		local wornLink = GetInventoryItemLink and Plain(GetInventoryItemLink("player", slot))
		local level = wornLink and ItemLevel(wornLink) or 0
		if not worn or level < worn then worn = level end
	end
	local delta = new - (worn or 0)
	if delta > 0 then return { text = "+" .. delta .. " ilvl", color = C.GREEN } end
	return { text = "No upgrade", color = C.FAINT }
end

-- Hint for a roll: { text, color }, or false when there is nothing to say.
local function Hint(r)
	if r.hint ~= nil then return r.hint end
	if not r.link then return false end
	local hint, waiting
	local compare = LM.Gear and LM.Gear.Compare
	local known = false
	if compare then
		local ok, result = pcall(compare, r.link)
		if ok and result == nil then
			known, hint = true, false -- not gear
		elseif ok and type(result) == "table" then
			if result.usable == false then
				known, hint = true, { text = "Can't use", color = C.RED }
			elseif result.known ~= false and type(result.delta) == "number" then
				known = true
				if result.delta > 0 then
					local gain = result.gain
					local text = type(gain) == "number" and ("Upgrade +%d"):format(math.max(1, math.floor(gain + 0.5))) or "Upgrade"
					if result.rank then text = text .. ", rank " .. result.rank end
					hint = { text = text, color = C.GREEN }
				else
					hint = { text = "No upgrade", color = C.FAINT }
				end
			end
		end
	end
	if not known then
		hint, waiting = LevelHint(r.link)
		if waiting then return false end -- item not loaded: try again later
		hint = hint or false
	end
	r.hint = hint
	return hint
end

local function Flag(module, method, itemID)
	local fn = itemID and LM[module] and LM[module][method]
	if not fn then return false end
	local ok, result = pcall(fn, itemID)
	return ok and result and true or false
end

-- Loot history ----------------------------------------------------------------------------

local function Link(r, rec)
	rec.roll, r.rec, r.info = r, rec, rec.info
	rec.info = nil
	open[rec.id] = nil
	-- my choice, when the game already knows it
	if not r.mine and not r.confirming then r.mine = ChoiceOf(r.info.playerRollState) end
end

-- Can this history drop be the item of this roll?
local function Fits(r, info, strict)
	if r.rec or r.fake or not r.link then return false end
	local link = Plain(info.itemHyperlink)
	if type(link) ~= "string" or not SameItem(r.link, link) then return false end
	local start, length = Plain(info.startTime), Plain(info.duration)
	local timed = r.histStart and type(start) == "number" and type(length) == "number"
	if strict then return timed and start >= r.histStart - length / 4 or false end
	-- over before the roll began: an older copy of the item
	if timed and start + length < r.histStart then return false end
	return true
end

-- Takes one drop from the game into our copy.
local function StoreDrop(eid, info)
	if type(info) ~= "table" then return end
	local key = Plain(info.lootListKey or info.lootListID) -- Forever: lootListKey
	if key == nil then return end
	local id = tostring(eid) .. ":" .. tostring(key)
	local rec = drops[id]
	if not rec then
		rec = { id = id }
		drops[id] = rec
	end
	if rec.old then return end
	if rec.roll then
		local r = rec.roll
		r.info = info
		if not r.mine and not r.confirming then r.mine = ChoiceOf(info.playerRollState) end
		return true
	end
	rec.info = info
	local done = IsDone(info)
	for _, r in ipairs(list) do
		if Fits(r, info, done) then
			Link(r, rec)
			return true
		end
	end
	if done then
		rec.old, rec.info = true, nil
		open[id] = nil
	else
		open[id] = rec
	end
end

-- Pairs a roll with a drop we already hold.
local function FindDrop(r)
	if r.rec or r.fake or not r.link then return end
	local best
	for _, rec in pairs(open) do
		if rec.info and Fits(r, rec.info) and (not best or rec.id < best.id) then best = rec end
	end
	if best then Link(r, best) end
end

local function ReadDrop(eid, key)
	if not (C_LootHistory and C_LootHistory.GetSortedInfoForDrop) then return end
	local ok, info = pcall(C_LootHistory.GetSortedInfoForDrop, eid, key)
	if ok then return StoreDrop(eid, info) end
end

local function ReadEncounter(eid)
	if not (C_LootHistory and C_LootHistory.GetSortedDropsForEncounter) then return end
	local ok, found = pcall(C_LootHistory.GetSortedDropsForEncounter, eid)
	if not ok or type(found) ~= "table" then return end
	for _, info in ipairs(found) do StoreDrop(eid, info) end
end

-- Whole history. Only when a roll stays without its drop.
local function ReadAll()
	if not (C_LootHistory and C_LootHistory.GetAllEncounterInfos) then return end
	local ok, encounters = pcall(C_LootHistory.GetAllEncounterInfos)
	if not ok or type(encounters) ~= "table" then return end
	for _, encounter in ipairs(encounters) do
		local eid = Plain(encounter.encounterID)
		if eid ~= nil then ReadEncounter(eid) end
	end
end

local function Unpaired()
	for _, r in ipairs(list) do
		if not r.fake and not r.rec and not r.done then return true end
	end
	return false
end

-- Rolls: add, end, remove ------------------------------------------------------------------

local function Sound(key, kit, fallback)
	if not LM.db[key] or not PlaySound then return end
	pcall(PlaySound, (SOUNDKIT and SOUNDKIT[kit]) or fallback, "Master")
end

local function Remove(r)
	rolls[r.id] = nil
	for i = #list, 1, -1 do
		if list[i] == r then table.remove(list, i) end
	end
	if r.rec then
		r.rec.roll, r.rec.info, r.rec.old = nil, nil, true
	end
end

local function Finish(r)
	if r.done then return end
	r.done, r.closed, r.confirming = true, true, nil
	r.doneAt = Now()
end

local function Insert(r)
	rolls[r.id] = r
	list[#list + 1] = r
	wantShow = true
	if driver then driver:Show() end
end

local function AddRoll(id, duration)
	id = Plain(id)
	if type(id) ~= "number" or rolls[id] then return end
	duration = Plain(duration)
	if type(duration) ~= "number" and C_Loot and C_Loot.GetLootRollDuration then
		local ok, value = pcall(C_Loot.GetLootRollDuration, id)
		duration = ok and Plain(value) or nil
	end
	local r = { id = id, started = Now(), histStart = HistoryNow() }
	-- the game counts roll time in milliseconds
	r.inMs = type(duration) ~= "number" or duration > 600
	r.duration = type(duration) == "number" and duration > 0 and (r.inMs and duration / 1000 or duration) or nil
	if GetLootRollTimeLeft then
		local ok, left = pcall(GetLootRollTimeLeft, id)
		left = ok and Plain(left)
		if type(left) == "number" then
			left = r.inMs and left / 1000 or left
			r.duration = r.duration or math.max(left, 1)
			-- a roll already running when we first see it
			r.started = Now() - math.max(0, r.duration - left)
		end
	end
	r.duration = r.duration or 60
	ReadItem(r)
	Insert(r)
	FindDrop(r)
	return r
end

-- Rolls the game still has open (after login, reload or a loading screen).
local function LoadActive()
	if not Active() or not GetActiveLootRollIDs then return end
	local ok, ids = pcall(GetActiveLootRollIDs)
	if not ok or type(ids) ~= "table" then return end
	local live, added = {}, false
	for _, id in ipairs(ids) do
		id = Plain(id)
		if id then
			live[id] = true
			if AddRoll(id) then added = true end
		end
	end
	for _, r in ipairs(list) do
		if not r.fake and not live[r.id] and not r.closed then
			r.closed, r.closedAt = true, Now()
		end
	end
	if added and Unpaired() then ReadAll() end
end

-- Blizzard's roll frames ---------------------------------------------------------------------

local taken = false

-- Blizzard frames that showed anyway go away again. Out of combat only.
local function HideBlizzard()
	if not taken or (InCombatLockdown and InCombatLockdown()) then return end
	for i = 1, 20 do
		local frame = _G["GroupLootFrame" .. i]
		if not frame then break end
		local id = Plain(frame.rollID)
		if frame:IsShown() and id and rolls[id] then pcall(frame.Hide, frame) end
	end
end

-- on: our window handles rolls. off: Blizzard's frames do.
local function Takeover(on)
	on = on and true or false
	if on == taken then return end
	taken = on
	if not UIParent then return end
	if on then
		pcall(UIParent.UnregisterEvent, UIParent, "START_LOOT_ROLL")
		return
	end
	pcall(UIParent.RegisterEvent, UIParent, "START_LOOT_ROLL")
	-- hand open rolls back
	local openFrame = _G.GroupLootFrame_OpenNewFrame
	if type(openFrame) ~= "function" or (InCombatLockdown and InCombatLockdown()) then return end
	for _, r in ipairs(list) do
		if not r.fake and not r.closed and not r.mine then
			local left = TimeLeft(r)
			pcall(openFrame, r.id, r.inMs and left * 1000 or left)
		end
	end
end

local function GiveUp(why)
	if gaveUp then return end
	gaveUp = true
	Takeover(false)
	for i = #list, 1, -1 do
		if not list[i].fake then Remove(list[i]) end
	end
	LM.Print("Rolls: blocked. Blizzard frames until reload.")
	LM.Debug(why)
end

-- Test rolls -----------------------------------------------------------------------------

local FAKE_ITEMS = {
	{ id = 18805, name = "Core Hound Tooth", quality = 4, wish = true, hint = { text = "+12%, rank 3", color = C.GREEN } },
	{ id = 12940, name = "Dal'Rend's Sacred Charge", quality = 3, tracked = true, hint = { text = "No upgrade", color = C.FAINT } },
	{ id = 16866, name = "Helm of Might", quality = 4, bop = true, canNeed = false, whyNeed = "Not allowed",
		hint = { text = "Can't use", color = C.RED } },
}
local FAKE_PARTY = {
	{ "Brannok", "WARRIOR", ST_NEED }, { "Sylwen", "HUNTER", S.Greed or 3 },
	{ "Mirelle", "PRIEST", ST_PASS }, { "Tobbin", "ROGUE", ST_NEED },
}

local function FakeEnd(r)
	local best
	for _, p in ipairs(r.info.rollInfos) do
		if p.state < ST_NONE and p.roll and (not best or p.state < best.state or (p.state == best.state and p.roll > best.roll)) then
			best = p
		end
	end
	if best then
		best.isWinner = true
		r.info.winner = best
	else
		r.info.allPassed = true
	end
end

-- Lets the fake party choose, one by one.
local function FakeStep(r, now)
	local waiting = false
	for _, p in ipairs(r.info.rollInfos) do
		if p.state == ST_NONE then
			if p.at and now >= p.at then
				p.state = p.plan
				if p.state ~= ST_PASS then p.roll = math.random(1, 100) end
				r.dirty = true
			else
				waiting = true
			end
		end
	end
	if not IsDone(r.info) and (not waiting or now >= r.started + r.duration) then
		FakeEnd(r)
		r.dirty = true
	end
end

function Rolls.Test()
	for i = #list, 1, -1 do
		if list[i].fake then Remove(list[i]) end
	end
	local me = LM.player or {}
	for n, item in ipairs(FAKE_ITEMS) do
		nextFake = nextFake - 1
		local color = UI.Code(UI.QUALITY[item.quality])
		local r = {
			id = nextFake, fake = true, started = Now(), duration = 30, read = true,
			itemID = item.id, name = item.name, quality = item.quality, count = 1, bop = item.bop,
			link = ("%s|Hitem:%d::::::::60:::::::::|h[%s]|h|r"):format(color, item.id, item.name),
			canNeed = item.canNeed, whyNeed = item.whyNeed, hint = item.hint, wish = item.wish, tracked = item.tracked,
			info = { rollInfos = {}, allPassed = false },
		}
		r.info.itemHyperlink = r.link
		r.info.rollInfos[1] = { playerName = me.name or "You", playerClass = me.class, isSelf = true, state = ST_NONE }
		for i, p in ipairs(FAKE_PARTY) do
			r.info.rollInfos[i + 1] = { playerName = p[1], playerClass = p[2], isSelf = false, state = ST_NONE, plan = p[3],
				at = Now() + 2 * i + n }
		end
		Insert(r)
	end
	Rolls.Show()
end

-- Choosing -------------------------------------------------------------------------------

local function MyRow(r)
	for _, p in ipairs(r.info and r.info.rollInfos or {}) do
		if Plain(p.isSelf) then return p end
	end
end

local function CanChoose(r)
	return r and not r.done and not r.closed and (not r.mine or r.confirming) and true or false
end

-- Rolls for an item. choice: "need", "greed" or "pass". Needs a click or a key press.
function Rolls.Choose(r, choice)
	if not CanChoose(r) or not CHOICE[choice] then return false end
	if choice == "need" and r.canNeed == false then return false end
	if choice == "greed" and r.canGreed == false and not r.canMog then return false end
	local kind = KIND_PASS
	if choice == "need" then
		kind = KIND_NEED
	elseif choice == "greed" then
		kind = r.canGreed == false and KIND_MOG or KIND_GREED
	end
	-- set first: a bind confirmation (CONFIRM_LOOT_ROLL) takes it back
	r.mine, r.confirming = choice, nil
	if r.fake then
		local p = MyRow(r)
		if p then
			p.state = choice == "need" and ST_NEED or choice == "greed" and (S.Greed or 3) or ST_PASS
			if choice ~= "pass" then p.roll = math.random(1, 100) end
		end
	else
		local ok, err = pcall(RollOnLoot, r.id, kind)
		if not ok then
			r.mine = nil
			GiveUp(err)
			Draw()
			return false
		end
	end
	if r.mine == "pass" and LM.db.rollHidePassed then r.hidden = true end
	Draw()
	return true
end

local function Visible()
	local out = {}
	for _, r in ipairs(list) do
		if not r.hidden then out[#out + 1] = r end
	end
	return out
end

-- Key bindings: the first item still waiting for a choice.
function Rolls.Key(choice)
	for _, r in ipairs(list) do
		if not r.hidden and CanChoose(r) then return Rolls.Choose(r, choice) end
	end
	return false
end

-- Called from Bindings.xml.
function Lootomania_Roll(choice) Rolls.Key(choice) end

BINDING_HEADER_LOOTOMANIA = "Lootomania"
BINDING_NAME_LOOTOMANIA_ROLL_NEED = "Need: top item"
BINDING_NAME_LOOTOMANIA_ROLL_GREED = "Greed: top item"
BINDING_NAME_LOOTOMANIA_ROLL_PASS = "Pass: top item"

-- Window ---------------------------------------------------------------------------------

local WIDTH = 384
local ROW_WIDTH = WIDTH - 24
local MAX_ROWS = 8
local GAP = 4
local BUTTON_W, BUTTON_H = 52, 20
local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local DIAMOND = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3"

local function PlayerName(p)
	local name = Plain(p.playerName)
	if type(name) ~= "string" then return "?" end
	if Ambiguate then name = Ambiguate(name, "short") or name end
	local class = Plain(p.playerClass)
	local text = UI.Colored(name, UI.ClassColor(type(class) == "string" and class or nil))
	local roll = Plain(p.roll)
	if type(roll) == "number" then text = text .. " " .. UI.Colored(roll, C.TEXT) end
	return text
end

local function ByRoll(a, b) return (Plain(a.roll) or 0) > (Plain(b.roll) or 0) end

-- Who chose what, one line per choice.
local function Who(r)
	local info = r.info
	if not info or type(info.rollInfos) ~= "table" then return "" end
	local groups = { need = {}, greed = {}, pass = {} }
	local waiting = 0
	for _, p in ipairs(info.rollInfos) do
		local choice = ChoiceOf(p.state)
		if choice then
			table.insert(groups[choice], p)
		else
			waiting = waiting + 1
		end
	end
	local lines = {}
	for _, choice in ipairs(ORDER) do
		local group = groups[choice]
		if #group > 0 then
			table.sort(group, ByRoll)
			local names = {}
			for i = 1, math.min(#group, 8) do names[i] = PlayerName(group[i]) end
			if #group > 8 then names[#names + 1] = "+" .. (#group - 8) end
			lines[#lines + 1] = UI.Colored(CHOICE[choice].label .. ":", CHOICE[choice].color) .. " " .. table.concat(names, ", ")
		end
	end
	if waiting > 0 and not r.done then lines[#lines + 1] = UI.Colored("Waiting: " .. waiting, C.FAINT) end
	return table.concat(lines, "\n")
end

-- Text in place of the buttons: my choice, the winner. nil: show the buttons.
local function Status(r)
	local info = r.info
	if r.done then
		local winner = info and info.winner
		if type(winner) == "table" then
			local roll = Plain(winner.roll)
			roll = type(roll) == "number" and (" " .. roll) or ""
			if Plain(winner.isSelf) then return UI.Colored("You won" .. roll, C.GREEN) end
			return UI.Colored("Winner: ", C.GOLD) .. PlayerName(winner)
		end
		if info and Plain(info.allPassed) == true then return UI.Colored("All passed", C.MUTED) end
	end
	if r.mine and not r.confirming then
		local mine = CHOICE[r.mine]
		local p = MyRow(r)
		local roll = p and Plain(p.roll)
		return "You: " .. UI.Colored(mine.label .. (type(roll) == "number" and (" " .. roll) or ""), mine.color)
	end
	if r.done or r.closed then return UI.Colored("Ended", C.MUTED) end
	return nil
end

local function MakeRow()
	local row = UI.Box(window.body, C.PANEL, 0.9, C.LINE)
	row:SetWidth(ROW_WIDTH)

	row.icon = UI.Icon(row, 36)
	row.icon:SetPoint("TOPLEFT", 6, -6)
	row.icon:SetScript("OnEnter", function(self)
		local r = row.roll
		if not r then return end
		-- the roll's own tooltip shows the exact item (random suffix)
		if not r.fake and not r.closed and GameTooltip.SetLootRollItem then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if pcall(GameTooltip.SetLootRollItem, GameTooltip, r.id) then
				GameTooltip:Show()
				return
			end
		end
		if self.item then UI.ItemTooltip(self, self.item) end
	end)
	row.count = UI.Text(row.icon, "GameFontHighlightSmall", C.TEXT)
	row.count:SetPoint("BOTTOMRIGHT", -2, 2)

	row.star = row:CreateTexture(nil, "OVERLAY")
	row.star:SetSize(14, 14)
	row.star:SetTexture(STAR)
	row.mark = row:CreateTexture(nil, "OVERLAY")
	row.mark:SetSize(14, 14)
	row.mark:SetTexture(DIAMOND)

	row.name = UI.Text(row, "GameFontHighlight", C.TEXT)
	row.time = UI.Text(row, "GameFontHighlightSmall", C.MUTED)
	row.time:SetPoint("TOPRIGHT", -8, -8)
	row.time:SetJustifyH("RIGHT")

	row.hint = UI.Text(row, "GameFontHighlightSmall", C.MUTED)
	row.hint:SetPoint("TOPLEFT", 48, -28)
	row.status = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
	row.status:SetPoint("TOPRIGHT", -8, -28)
	row.status:SetJustifyH("RIGHT")

	row.buttons = {}
	local last
	for i = #ORDER, 1, -1 do
		local choice = ORDER[i]
		local b = UI.Button(row, CHOICE[choice].label, BUTTON_W, BUTTON_H)
		if last then b:SetPoint("RIGHT", last, "LEFT", -3, 0) else b:SetPoint("TOPRIGHT", -6, -24) end
		last = b
		if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
		b:SetScript("OnClick", function() Rolls.Choose(row.roll, choice) end)
		b:HookScript("OnEnter", function(self)
			if self.why then UI.TextTooltip(self, CHOICE[choice].label, { self.why }) end
		end)
		b:HookScript("OnLeave", UI.HideTooltip)
		row.buttons[choice] = b
	end

	row.bar = UI.Bar(row, ROW_WIDTH - 12, 3)
	row.bar:SetPoint("TOPLEFT", 6, -48)

	row.who = UI.Text(row, "GameFontHighlightSmall", C.MUTED)
	row.who:SetPoint("TOPLEFT", 7, -56)
	row.who:SetWidth(ROW_WIDTH - 14)
	row.who:SetWordWrap(true)
	if row.who.SetSpacing then row.who:SetSpacing(2) end
	return row
end

local function Apply()
	if not window then return end
	window.locked = LM.db.rollLock and true or false
	window:SetAlpha(math.max(0.1, math.min(1, (tonumber(LM.db.rollAlpha) or 100) / 100)))
end

local function Build()
	if window then return end
	window = UI.Window("Rolls", "Rolls", WIDTH, 120, { escape = false, strata = "HIGH", y = 120, scaleKey = "rollScale" })
	pool = UI.Pool(MakeRow)
	emptyText = UI.Text(window.body, "GameFontHighlightSmall", C.FAINT)
	emptyText:SetPoint("TOPLEFT", 2, -4)
	emptyText:SetText("No rolls")
	moreText = UI.Text(window.body, "GameFontHighlightSmall", C.MUTED)
	window:HookScript("OnHide", function() pinned = false end)
	Apply()
end

-- Height changes keep the top edge where it is.
local function SetHeight(height)
	if math.abs((window:GetHeight() or 0) - height) < 0.5 then return end
	local left, top = window:GetLeft(), window:GetTop()
	if left and top then
		window:ClearAllPoints()
		window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
	end
	window:SetHeight(height)
end

local BAR_COLOR = { C.RED, C.GOLD_SOFT, C.GOLD }

local function DrawTime(row)
	local r = row.roll
	if not r or r.done then return end
	local left = TimeLeft(r)
	row.bar:Set(left / r.duration, left <= 5 and BAR_COLOR[1] or left <= 15 and BAR_COLOR[2] or BAR_COLOR[3])
	row.time:SetText(left > 0 and (math.ceil(left) .. " s") or "")
end

local function DrawRow(row, r)
	row.roll = r
	local wish = r.wish or Flag("Wish", "Has", r.itemID)
	local tracked = r.tracked or Flag("Gear", "IsTracked", r.itemID)

	local fill, edge = wish and C.PANEL_HI or C.PANEL, wish and C.GOLD or C.LINE
	row:SetBackdropColor(fill[1], fill[2], fill[3], 0.92)
	row:SetBackdropBorderColor(edge[1], edge[2], edge[3], 1)

	row.icon:SetItem(r.link or r.itemID, r.quality)
	if r.texture then row.icon.icon:SetTexture(r.texture) end
	row.count:SetText(type(r.count) == "number" and r.count > 1 and r.count or "")

	-- marks, then the name
	local x = 48
	row.star:SetShown(wish)
	if wish then
		row.star:ClearAllPoints()
		row.star:SetPoint("TOPLEFT", x, -7)
		x = x + 17
	end
	row.mark:SetShown(tracked)
	if tracked then
		row.mark:ClearAllPoints()
		row.mark:SetPoint("TOPLEFT", x, -7)
		x = x + 17
	end
	row.name:ClearAllPoints()
	row.name:SetPoint("TOPLEFT", x, -7)
	row.name:SetWidth(ROW_WIDTH - x - 46)
	row.name:SetText(r.name or "...")
	UI.Color(row.name, UI.QUALITY[r.quality or 1] or C.TEXT)

	local status = Status(r)
	local buttons = status == nil
	row.status:SetText(status or "")
	for _, choice in ipairs(ORDER) do
		local b = row.buttons[choice]
		b:SetShown(buttons)
		local allowed, why = true, nil
		if choice == "need" and r.canNeed == false then
			allowed, why = false, r.whyNeed
		elseif choice == "greed" and r.canGreed == false and not r.canMog then
			allowed, why = false, r.whyGreed
		end
		b.why = why or (not allowed and "Not allowed") or nil
		b:SetEnabled(allowed)
		b:Paint()
	end

	local hint = Hint(r)
	row.hint:SetWidth(buttons and (ROW_WIDTH - 48 - 3 * BUTTON_W - 18) or 130)
	row.hint:SetText(hint and hint.text or "")
	if hint then UI.Color(row.hint, hint.color) end

	if r.done then
		row.bar:Set(0)
		row.time:SetText("")
	else
		DrawTime(row)
	end

	local who = Who(r)
	row.who:SetText(who)
	row.who:SetShown(who ~= "")
	local height = 56
	if who ~= "" then height = 60 + math.max(12, row.who:GetStringHeight() or 12) end
	row:SetHeight(height)
	return height
end

-- Shows or hides the window as rolls come and go.
local function Sync(count)
	if wantShow then
		wantShow = false
		if count > 0 and (Active() or pinned or nextFake < 0) then
			Build()
			window:Show()
		end
	end
	if window and window:IsShown() and count == 0 and not pinned then window:Hide() end
	if driver then driver:SetShown(#list > 0) end
end

Draw = function()
	if not LM.db then return end
	local visible = Visible()
	Sync(#visible)
	if not window or not window:IsShown() then return end
	local y = 0
	local shown = math.min(#visible, MAX_ROWS)
	for i = 1, shown do
		local row = pool:Get(i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, -y)
		y = y + DrawRow(row, visible[i]) + GAP
	end
	pool:HideFrom(shown + 1)
	for i = shown + 1, #pool.rows do pool.rows[i].roll = nil end
	emptyText:SetShown(shown == 0)
	if shown == 0 then y = 24 end
	local more = #visible - shown
	moreText:SetShown(more > 0)
	if more > 0 then
		moreText:ClearAllPoints()
		moreText:SetPoint("TOPLEFT", 2, -y)
		moreText:SetText("More: " .. more)
		y = y + 18
	end
	SetHeight(46 + y + 8)
end

-- For bursts of events (a raid's loot history): one draw.
Queue = LM.Debounce(0.05, function() Draw() end)

function Rolls.Show()
	if not LM.db then return end
	Build()
	pinned = true
	window:Show()
	pinned = true
	Draw()
end

function Rolls.Hide()
	if window then window:Hide() end
end

function Rolls.Toggle()
	if window and window:IsShown() then Rolls.Hide() else Rolls.Show() end
end

function Rolls.IsShown()
	return window ~= nil and window:IsShown() or false
end

-- Number of rolls still waiting for my choice.
function Rolls.Count()
	local n = 0
	for _, r in ipairs(list) do
		if CanChoose(r) then n = n + 1 end
	end
	return n
end

-- The rolls on show, oldest first. Read only.
function Rolls.List() return list end

-- The window's rows (tests).
function Rolls.Rows() return pool and pool.rows or {} end

-- Upkeep -----------------------------------------------------------------------------------

local sweepAt, syncAt = 0, 0

-- Ends, expires and removes rolls. True when something changed.
local function Sweep(now)
	local changed = false
	local linger = tonumber(LM.db.rollLinger) or 15
	for i = #list, 1, -1 do
		local r = list[i]
		if r.fake then FakeStep(r, now) end
		if r.dirty then
			r.dirty = nil
			changed = true
		end
		if not r.read then
			ReadItem(r)
			if r.read then
				FindDrop(r)
				changed = true
			end
		end
		if not r.done then
			local over = now >= r.started + r.duration
			if IsDone(r.info) then
				Finish(r)
				changed = true
			elseif r.closed and not r.rec and not r.fake and now - (r.closedAt or now) >= 3 then
				-- ended and the loot history never listed it
				Finish(r)
				changed = true
			elseif now >= r.started + r.duration + 12 then
				Finish(r)
				changed = true
			elseif over and not r.closed then
				r.closed, r.closedAt = true, now
				changed = true
			end
		end
		if (r.done and now - r.doneAt >= linger) or (r.hidden and r.closed) then
			Remove(r)
			changed = true
		end
	end
	-- a roll the history events never gave a drop for: read the history once
	if now >= syncAt then
		for _, r in ipairs(list) do
			if not r.fake and not r.rec and not r.done and not r.synced and r.link and now - r.started >= 1.5 then
				for _, other in ipairs(list) do other.synced = true end
				syncAt = now + 3
				ReadAll()
				changed = true
				break
			end
		end
	end
	return changed
end

local function OnUpdate(_, elapsed)
	local now = Now()
	if now >= sweepAt then
		sweepAt = now + 0.25
		if Sweep(now) then Draw() end
		HideBlizzard()
	end
	for _, r in ipairs(list) do
		if not r.warned and not r.fake and CanChoose(r) and r.duration > 8 then
			local left = TimeLeft(r)
			if left <= 5 and left > 0 then
				r.warned = true
				Sound("rollSoundWarn", "RAID_WARNING", 8959)
			end
		end
	end
	if window and window:IsShown() then
		for _, row in ipairs(pool.rows) do
			if row:IsShown() then DrawTime(row) end
		end
	end
end

driver = CreateFrame("Frame")
driver:Hide()
do
	local wait = 0
	driver:SetScript("OnUpdate", function(self, elapsed)
		wait = wait + (elapsed or 0)
		if wait < 0.1 then return end
		wait = 0
		LM.Safe(OnUpdate, self, elapsed)
	end)
end

-- Chat filter --------------------------------------------------------------------------------

local quiet -- patterns of roll lines; nil until first needed

-- Game text with %s and %d -> a pattern that matches the finished line.
local function ToPattern(text)
	text = text:gsub("%%%d+%$", "%%")
	text = text:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
	text = text:gsub("%%s", ".+"):gsub("%%d", "%%d+")
	return "^" .. text .. "$"
end

local QUIET_KEYS = { "NEED", "GREED", "PASSED", "PASSED_AUTO", "PASSED_AUTO_FEMALE", "NEED_SELF", "GREED_SELF", "PASSED_SELF",
	"PASSED_SELF_AUTO", "ROLLED_NEED", "ROLLED_GREED", "ROLLED_NEED_ROLE_BONUS", "DISENCHANT", "DISENCHANT_SELF", "ROLLED_DE",
	"TRANSMOG", "TRANSMOG_SELF", "ROLLED_TRANSMOG" }

local function QuietFilter(_, _, message)
	if not (LM.db and LM.db.rollQuietChat) then return false end
	message = Plain(message)
	if type(message) ~= "string" then return false end
	for i = 1, #quiet do
		if message:find(quiet[i]) then return true end
	end
	return false
end

local function SetupQuiet()
	if quiet or not LM.db.rollQuietChat then return end
	quiet = {}
	for _, key in ipairs(QUIET_KEYS) do
		local text = _G["LOOT_ROLL_" .. key]
		if type(text) == "string" and text ~= "" then quiet[#quiet + 1] = ToPattern(text) end
	end
	local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or _G.ChatFrame_AddMessageEventFilter
	if add then pcall(add, "CHAT_MSG_LOOT", QuietFilter) end
end
Rolls.ToPattern = ToPattern

-- Events -----------------------------------------------------------------------------------

LM.On("START_LOOT_ROLL", function(_, id, duration)
	if not Active() then return end
	Takeover(true)
	-- again, in case Blizzard's loot code registered after us
	if UIParent then pcall(UIParent.UnregisterEvent, UIParent, "START_LOOT_ROLL") end
	if AddRoll(id, duration) then
		Sound("rollSoundStart", "TELL_MESSAGE", 3081)
		Draw()
	end
end)

local function Cancel(id)
	local r = rolls[id]
	if not r or r.fake or r.closed then return end
	r.closed, r.closedAt, r.confirming = true, Now(), nil
end

LM.On("CANCEL_LOOT_ROLL", function(_, id)
	id = Plain(id)
	if id == nil then return end
	Cancel(id)
	Queue()
end)

LM.On("CANCEL_ALL_LOOT_ROLLS", function()
	for _, r in ipairs(list) do Cancel(r.id) end
	Queue()
end)

-- Bind on pickup: the game asks first. Its own dialog stays in charge; a cancelled
-- dialog leaves the roll open, so our buttons come back.
LM.On("CONFIRM_LOOT_ROLL", function(_, id, kind)
	local r = rolls[Plain(id) or false]
	if not r then return end
	r.mine, r.hidden, r.confirming = nil, nil, true
	r.asked = KIND_CHOICE[Plain(kind) or false]
	Queue()
end)

LM.On("LOOT_HISTORY_UPDATE_DROP", function(_, eid, key)
	eid, key = Plain(eid), Plain(key)
	if eid == nil or key == nil or #list == 0 then return end
	if ReadDrop(eid, key) then Queue() end
end)

LM.On("LOOT_HISTORY_UPDATE_ENCOUNTER", function(_, eid)
	eid = Plain(eid)
	if eid == nil or not Unpaired() then return end
	ReadEncounter(eid)
	Queue()
end)

LM.On("LOOT_HISTORY_CLEAR_HISTORY", function()
	for id, rec in pairs(drops) do
		if not rec.roll then drops[id] = nil end
	end
	wipe(open)
end)

LM.On("PLAYER_ENTERING_WORLD", function()
	if not LM.db then return end
	LoadActive()
	Draw()
end)

LM.On("GET_ITEM_INFO_RECEIVED", function()
	if #list > 0 then Queue() end
end)

LM.On("ADDON_ACTION_BLOCKED", function(_, addon, what)
	if addon == ADDON and type(what) == "string" and what:find("Roll") then GiveUp(what) end
end)
LM.On("ADDON_ACTION_FORBIDDEN", function(_, addon, what)
	if addon == ADDON and type(what) == "string" and what:find("Roll") then GiveUp(what) end
end)

local function ForgetHints()
	for _, r in ipairs(list) do
		if not r.fake then r.hint = nil end
	end
	if #list > 0 then Queue() end
end
LM.Listen("GEAR_CHANGED", ForgetHints)
LM.Listen("CONTEXT_CHANGED", ForgetHints)
LM.Listen("HUNTS_CHANGED", function() if #list > 0 then Queue() end end)
LM.Listen("WISHLIST_CHANGED", function() if #list > 0 then Queue() end end)

LM.Listen("SETTINGS_CHANGED", function(key)
	if type(key) ~= "string" or key:sub(1, 4) ~= "roll" then return end
	if key == "rollWindow" then
		if LM.db.rollWindow then
			Takeover(Active())
			LoadActive()
		else
			Takeover(false)
			for i = #list, 1, -1 do
				if not list[i].fake then Remove(list[i]) end
			end
		end
	elseif key == "rollQuietChat" then
		SetupQuiet()
	elseif key == "rollHidePassed" and not LM.db.rollHidePassed then
		for _, r in ipairs(list) do r.hidden = nil end
	end
	Apply()
	Draw()
end)

LM.OnLoad(function()
	Takeover(Active())
	SetupQuiet()
	-- accepting the game's bind dialog is when the roll really happens
	if hooksecurefunc and ConfirmLootRoll then
		hooksecurefunc("ConfirmLootRoll", function(id, kind)
			local r = rolls[Plain(id) or false]
			if not r then return end
			r.confirming = nil
			r.mine = KIND_CHOICE[Plain(kind) or false] or r.asked or "need"
			if r.mine == "pass" and LM.db.rollHidePassed then r.hidden = true end
			Queue()
		end)
	end
end)

LM.Command("rolls", "Roll window. Also: test", function(rest)
	if (rest or ""):lower():match("^test") then
		Rolls.Test()
	else
		Rolls.Toggle()
	end
end)
