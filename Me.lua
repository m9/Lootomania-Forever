local _, ns = ...

-- What the game says about the player's character, for "can I get it now?".
-- Every function returns nil when the game cannot be asked: a missing function, an error, a
-- protected value. A caller shows a mark only for an answer; nil is "nothing to say".
--   Me.Level()                 character level
--   Me.Gold()                  copper
--   Me.Skill(name, id)         skill rank; 0: the character does not have that skill
--   Me.Standing(name, id)      standing with a faction, 0 hated .. 3 neutral .. 7 exalted (as Data.vendorItems)
--   Me.QuestDone(id)           true or false
--   Me.OnQuest(id)             true when the quest is in the quest log
--   Me.PvpRank()               PvP rank 1..14; 0: none
--   Me.Count(kind, id)         how many the character has: kind "c" a currency, "i" an item (bank counted)
--   Me.Knows(spell)            true when the character knows the spell (a craft); never false
--   Me.Report()                lines for /lm me: what each of these reads now
-- The functions of this client were taken from addons that run on it (Questie's compat layer,
-- Attune, NeedRoll): C_SkillInfo, C_Reputation, C_QuestLog, C_CurrencyInfo, C_Item.

local Me = {}
ns.Me = Me

-- Call a game function that may be missing or fail. Protected values come back as nil.
local function Try(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c, d = pcall(fn, ...)
	if not ok then return nil end
	return ns.Plain(a), ns.Plain(b), ns.Plain(c), ns.Plain(d)
end

local function Field(row, key)
	if type(row) ~= "table" then return nil end
	return ns.Plain(row[key])
end

function Me.Level()
	return tonumber(Try(UnitLevel, "player"))
end

function Me.Gold()
	return tonumber(Try(GetMoney))
end

-- Skills ---------------------------------------------------------------------------------

-- The character's skill list: by name and by id. complete: no header is folded and every line
-- could be read, so a skill that is not in the list is a skill the character does not have.
local function SkillList()
	local byName, byId, complete, any = {}, {}, true, false
	local info = C_SkillInfo
	if type(info) == "table" and type(info.GetNumSkillLines) == "function" then
		for index = 1, tonumber(Try(info.GetNumSkillLines)) or 0 do
			local line = Try(info.GetSkillLineInfo, index)
			local name, rank = Field(line, "name"), tonumber(Field(line, "rank"))
			if Field(line, "isHeader") then
				if Field(line, "isCollapsed") then complete = false end
			elseif type(name) == "string" and rank then
				byName[name], any = rank, true
				local id = tonumber(Field(line, "skillID"))
				if id then byId[id] = rank end
			else
				complete = false -- a line the game would not show: it may be the skill asked for
			end
		end
	elseif type(GetNumSkillLines) == "function" then
		-- the older list: name, isHeader, isExpanded, rank
		for index = 1, tonumber(Try(GetNumSkillLines)) or 0 do
			local name, isHeader, isExpanded, rank = Try(GetSkillLineInfo, index)
			if isHeader then
				if not isExpanded then complete = false end
			elseif type(name) == "string" and tonumber(rank) then
				byName[name], any = tonumber(rank), true
			else
				complete = false
			end
		end
	else
		return nil
	end
	return byName, byId, complete and any
end

function Me.Skill(name, id)
	-- asked by id first: that does not depend on what is folded in the skill window
	local info = C_SkillInfo
	if id and type(info) == "table" then
		local rank = tonumber(Field(Try(info.GetSkillLineInfoByID, id), "rank"))
		if rank and rank > 0 then return rank end
	end
	local byName, byId, complete = SkillList()
	if not byName then return nil end
	local rank = (id and byId[id]) or (name and byName[name])
	if rank then return rank end
	return complete and 0 or nil
end

-- Standings --------------------------------------------------------------------------------

function Me.Standing(name, id)
	local ids = ns.Data and ns.Data.factionIds
	id = id or (name and ids and ids[name])
	local rep = C_Reputation
	if id and type(rep) == "table" then
		local reaction = tonumber(Field(Try(rep.GetFactionDataByID, id), "reaction"))
		if reaction then return reaction - 1 end
	end
	if id and type(GetFactionInfoByID) == "function" then
		local _, _, reaction = Try(GetFactionInfoByID, id)
		if tonumber(reaction) then return tonumber(reaction) - 1 end
	end
	return nil
end

-- Quests, rank, things ---------------------------------------------------------------------

-- True when the quest is in the quest log, false when it is not, nil when the game gave no answer.
function Me.OnQuest(id)
	local log = C_QuestLog
	if not id or type(log) ~= "table" or type(log.IsOnQuest) ~= "function" then return nil end
	local on = Try(log.IsOnQuest, id)
	if on == nil then return nil end
	return on and true or false
end

function Me.QuestDone(id)
	if not id then return nil end
	local log = C_QuestLog
	local done
	if type(log) == "table" and type(log.IsQuestFlaggedCompleted) == "function" then
		done = Try(log.IsQuestFlaggedCompleted, id)
	elseif type(IsQuestFlaggedCompleted) == "function" then
		done = Try(IsQuestFlaggedCompleted, id)
	end
	if done == nil then return nil end
	return done and true or false
end

function Me.PvpRank()
	local raw = tonumber(Try(UnitPVPRank, "player"))
	if not raw then return nil end
	-- the game counts from 5: 5 is rank 1
	return raw > 4 and raw - 4 or 0
end

function Me.Count(kind, id)
	if not id then return nil end
	if kind == "c" then
		local info = C_CurrencyInfo
		if type(info) ~= "table" then return nil end
		return tonumber(Field(Try(info.GetCurrencyInfo, id), "quantity"))
	end
	local items = C_Item
	if type(items) == "table" and type(items.GetItemCount) == "function" then
		return tonumber(Try(items.GetItemCount, id, true))
	end
	return tonumber(Try(GetItemCount, id, true))
end

function Me.Knows(spell)
	if not spell then return nil end
	local book = C_SpellBook
	if type(book) == "table" and Try(book.IsSpellKnown, spell) == true then return true end
	if Try(IsPlayerSpell, spell) == true then return true end
	if Try(IsSpellKnown, spell) == true then return true end
	return nil
end

-- /lm me ------------------------------------------------------------------------------------

local STANDING = { [0] = "Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted" }
Me.STANDING = STANDING

local function Say(value, text)
	if value == nil then return "the game did not say" end
	return text or tostring(value)
end

function Me.Report()
	local lines = {}
	local level, gold, rank = Me.Level(), Me.Gold(), Me.PvpRank()
	lines[#lines + 1] = "Level: " .. Say(level)
	lines[#lines + 1] = "Gold: " .. Say(gold, gold and ns.UI and ns.UI.Money and ns.UI.Money(gold) or tostring(gold))
	lines[#lines + 1] = "PvP rank: " .. Say(rank, rank == 0 and "none" or tostring(rank))
	local byName, _, complete = SkillList()
	if not byName then
		lines[#lines + 1] = "Skills: the game did not say"
	else
		local names = {}
		for name in pairs(byName) do names[#names + 1] = name end
		table.sort(names)
		for i, name in ipairs(names) do names[i] = name .. " " .. byName[name] end
		lines[#lines + 1] = "Skills: " .. (#names > 0 and table.concat(names, ", ") or "none listed")
			.. (complete and "" or " (a part of the skill window is folded: the list may be short)")
	end
	local factions = {}
	for name in pairs(ns.Data and ns.Data.factionIds or {}) do factions[#factions + 1] = name end
	table.sort(factions)
	local known = {}
	for _, name in ipairs(factions) do
		local standing = Me.Standing(name)
		if standing then known[#known + 1] = name .. ": " .. (STANDING[standing] or standing) end
	end
	lines[#lines + 1] = "Standings: " .. (#known > 0 and table.concat(known, ", ") or "the game did not say")
	return lines
end

ns.Command("me", "What the addon reads about this character. Also: quest <id>, spell <id>, item <id>, currency <id>", function(rest)
	local what, id = (rest or ""):match("^%s*(%a+)%s+(%d+)")
	id = tonumber(id)
	if what == "quest" then
		local done = Me.QuestDone(id)
		ns.Print("Quest " .. id .. ": " .. Say(done, done and "done" or "not done"))
	elseif what == "spell" then
		ns.Print("Spell " .. id .. ": " .. (Me.Knows(id) and "known" or "not known, or the game did not say"))
	elseif what == "item" or what == "currency" then
		ns.Print(what .. " " .. id .. ": " .. Say(Me.Count(what == "currency" and "c" or "i", id)))
	else
		for _, line in ipairs(Me.Report()) do ns.Print(line) end
	end
end, true)
