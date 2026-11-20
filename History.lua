local _, ns = ...

-- Loot history. One record per run (a stay in a dungeon or raid, or an open-world
-- session), filled from the game's loot history as each drop is decided.
-- Messages sent:
--   "HISTORY_CHANGED"            runs or drops changed
--   "LOOT_DROPPED" link, boss    a new drop is being rolled on
--   "LOOT_DECIDED" drop, run     a drop got its winner (or everyone passed)

local UI = ns.UI
local C = UI.C
local H = {}
ns.History = H

local MAX_ROWS = 10 -- rolls kept per drop
local WORLD_DROPS = 60 -- drops kept per open-world run
local WORLD_GAP = 1800 -- seconds without loot that end an open-world run
local REJOIN = 600 -- back in the same instance within this: same run
local RESUME = 3600 -- same, for a run cut off by a reload or logout
local LEAVE_WAIT = 20 -- seconds outside before a run ends
local POLL = 5 -- seconds between looks at drops still being rolled on
local POLL_MAX = 60 -- looks before an open drop is given up
local NAME_TRIES = 12 -- looks before a decided drop is recorded with hidden names
local FINAL_WAIT = 120 -- longest wait for the final boss's loot
local POST_COOLDOWN = 30
local POST_LINES = 10
local SEEN_AGE = 2 * 86400
local PRIME_WINDOW = 8 -- seconds after login in which old history is not recorded

ns.Defaults({ history = { runs = {}, seen = {} } })

local S = (Enum and Enum.EncounterLootDropRollState)
	or { NeedMainSpec = 0, NeedOffSpec = 1, Transmog = 2, Greed = 3, NoRoll = 4, Pass = 5 }

local LABEL = { need = "Need", greed = "Greed", pass = "Pass" }
H.LABEL = LABEL

local db -- ns.db.history
local current -- the run being recorded
local open = {} -- drops still being rolled on: "encounter:key" -> { eid, id, tries }
local dirtyDrops, dirtyEncs, dirtyAll = {}, {}, false
local bossNames = {}
local priming = false
local primeUntil = 0
local changed = false
local polling = false
local lastPost = -math.huge

local function Now() return time() end

local function Hidden(v) return (issecretvalue and issecretvalue(v)) and true or false end

local function Choice(state)
	state = ns.Plain(state)
	if state == nil then return nil end
	if state == S.NeedMainSpec or state == S.NeedOffSpec then return "need" end
	if state == S.Greed or state == S.Transmog then return "greed" end
	if state == S.Pass then return "pass" end
	return nil
end

local function Short(name)
	if type(name) ~= "string" then return "?" end
	return name:match("^([^%-]+)") or name
end
H.Short = Short

local function Plural(n, one, many)
	return n .. " " .. (n == 1 and one or many)
end

local function Touch()
	changed = true
end

local function Announce() end -- set below

-- Runs --------------------------------------------------------------------------------

local function InstanceNow()
	if not GetInstanceInfo then return nil end
	local ok, name, kind, _, _, _, _, _, id = pcall(GetInstanceInfo)
	if not ok then return nil end
	kind = ns.Plain(kind)
	if kind == "party" or kind == "raid" then return ns.Plain(name) or "?", kind, ns.Plain(id) end
	return nil
end

local function ZoneNow()
	local zone = GetRealZoneText and ns.Plain(GetRealZoneText())
	return (zone and zone ~= "") and zone or "World"
end

local function Empty(run)
	return #run.drops == 0 and #run.kills == 0
end

local function Trim()
	local keep = math.max(1, tonumber(ns.db.historyKeep) or 20)
	local i = 1
	while #db.runs > keep and i <= #db.runs do
		if db.runs[i] == current then i = i + 1 else table.remove(db.runs, i) end
	end
end

-- Ends every run but `except`; empty ones are dropped.
local function CloseOthers(except)
	for i = #db.runs, 1, -1 do
		local run = db.runs[i]
		if run ~= except then
			if not run.stop then run.stop = run.act or run.start end
			run.left = nil
			if Empty(run) then table.remove(db.runs, i) end
		end
	end
end

local function Start(zone, kind, id)
	local run = { zone = zone, kind = kind, id = id, start = Now(), kills = {}, drops = {}, players = {} }
	current = run
	CloseOthers(run)
	db.runs[#db.runs + 1] = run
	Trim()
	Touch()
	return run
end

local function Close(run, announce)
	if not run or run.stop then return end
	run.stop = run.left or Now()
	run.left = nil
	if current == run then current = nil end
	if announce and #run.drops > (run.told or 0) then Announce(run) end
	if Empty(run) then
		for i = #db.runs, 1, -1 do
			if db.runs[i] == run then table.remove(db.runs, i) end
		end
	end
	Touch()
end

local function Resume(run)
	run.stop, run.left = nil, nil
	current = run
	CloseOthers(run)
	Touch()
end

-- The newest instance run, when it can go on.
local function Resumable(id)
	for i = #db.runs, 1, -1 do
		local run = db.runs[i]
		if run.kind ~= "world" then
			if run.id ~= id or run.final then return nil end
			local idle = Now() - (run.stop or run.act or run.start)
			if idle < (run.stop and REJOIN or RESUME) then return run end
			return nil
		end
	end
	return nil
end

local flushSoon

local function Leave(run, tries)
	run.left = run.left or Now()
	C_Timer.After(LEAVE_WAIT, function()
		if current ~= run or not run.left then return end
		-- rolls still going: wait for them
		if next(open) and (tries or 0) < 5 then
			Leave(run, (tries or 0) + 1)
			return
		end
		Close(run, true)
		flushSoon()
	end)
end

local function OnZone()
	if not db then return end
	local zone, kind, id = InstanceNow()
	if zone then
		if current and current.kind ~= "world" and current.id == id then
			current.left = nil
			return
		end
		local old = Resumable(id)
		if current then Close(current, true) end
		if old then Resume(old) else Start(zone, kind, id) end
	elseif current and current.kind ~= "world" and not current.left then
		Leave(current)
	end
	flushSoon()
end

-- The run a new drop belongs to.
local function RunFor()
	if current then
		if current.kind ~= "world" or Now() - (current.act or current.start) <= WORLD_GAP then return current end
		Close(current)
	end
	local zone, kind, id = InstanceNow()
	if zone then return Resumable(id) and (Resume(Resumable(id)) or current) or Start(zone, kind, id) end
	if ns.db.historyWorld == false then return nil end
	local last = db.runs[#db.runs]
	if last and last.kind == "world" and Now() - (last.act or last.start) <= WORLD_GAP then
		Resume(last)
		return last
	end
	return Start(ZoneNow(), "world")
end

-- Reading the game's loot history ---------------------------------------------------------

local function Ready()
	return db and C_LootHistory and C_LootHistory.GetAllEncounterInfos and C_LootHistory.GetSortedDropsForEncounter and true or false
end

local function BossName(eid, info)
	if eid == 0 then return "Trash" end
	if bossNames[eid] then return bossNames[eid] end
	if not info and C_LootHistory.GetInfoForEncounter then
		local ok, got = pcall(C_LootHistory.GetInfoForEncounter, eid)
		info = ok and type(got) == "table" and got or nil
	end
	local name = info and ns.Plain(info.encounterName)
	if type(name) == "string" and name ~= "" then
		bossNames[eid] = name
		return name
	end
	return "Trash"
end

local function Row(r)
	if type(r) ~= "table" then return nil end
	local name = ns.Plain(r.playerName)
	local roll = ns.Plain(r.roll)
	return {
		n = type(name) == "string" and name or "?",
		c = ns.Plain(r.playerClass),
		ch = Choice(r.state),
		r = type(roll) == "number" and roll or nil,
		w = ns.Plain(r.isWinner) == true or nil,
		me = ns.Plain(r.isSelf) == true or nil,
	}
end

local function Record(eid, d, link, info)
	local run = RunFor()
	if not run then return end
	local drop = { link = link, id = ns.ItemID(link), at = Now(), boss = BossName(eid, info) }
	if eid ~= 0 then drop.eid = eid end
	if run.kind == "world" then drop.zone = ZoneNow() end

	local rows, byName = {}, {}
	for _, r in ipairs(type(d.rollInfos) == "table" and d.rollInfos or {}) do
		local row = Row(r)
		-- "?" is a hidden name: each one is its own player
		if row and (row.n == "?" or not byName[row.n]) then
			rows[#rows + 1] = row
			if row.n ~= "?" then byName[row.n] = row end
		end
	end
	local win = Row(d.winner)
	if win then
		local listed = byName[win.n]
		if not listed and win.n == "?" then
			for _, row in ipairs(rows) do
				if row.w then listed = row break end
			end
		end
		if listed then
			listed.w = true
			win = listed
		else
			win.w = true
			rows[#rows + 1] = win
		end
		drop.winner = { n = win.n, c = win.c, ch = win.ch, r = win.r, me = win.me }
	else
		for _, row in ipairs(rows) do row.w = nil end
		drop.passed = true
	end

	for _, row in ipairs(rows) do
		local p = run.players[row.n]
		if not p then
			p = { c = row.c, won = 0, need = 0, greed = 0, pass = 0 }
			run.players[row.n] = p
		end
		p.c = p.c or row.c
		if row.ch then p[row.ch] = p[row.ch] + 1 end
		if row.w then p.won = p.won + 1 end
		if row.me then
			p.me = true
			drop.me = { ch = row.ch, r = row.r, w = row.w }
		end
	end

	-- mine and the winner's first, then the highest rolls
	local score = {}
	for _, row in ipairs(rows) do
		score[row] = (row.me and 2000 or 0) + (row.w and 1000 or 0) + (row.r or (row.ch == "pass" and -1 or 0))
	end
	table.sort(rows, function(a, b)
		if score[a] ~= score[b] then return score[a] > score[b] end
		return a.n < b.n
	end)
	for i = #rows, MAX_ROWS + 1, -1 do rows[i] = nil end
	drop.rolls = rows

	run.drops[#run.drops + 1] = drop
	run.act = drop.at
	if run.kind == "world" then
		while #run.drops > WORLD_DROPS do table.remove(run.drops, 1) end
	end
	Touch()
	ns.Send("LOOT_DECIDED", drop, run)
end

-- True when a player name of the drop is hidden.
local function NamesHidden(d)
	if type(d.winner) == "table" and Hidden(d.winner.playerName) then return true end
	for _, r in ipairs(type(d.rollInfos) == "table" and d.rollInfos or {}) do
		if type(r) == "table" and Hidden(r.playerName) then return true end
	end
	return false
end

local function Consider(eid, d, info)
	if type(d) ~= "table" then return end
	local rawKey = d.lootListKey
	if rawKey == nil then rawKey = d.lootListID end
	local id = ns.Plain(rawKey)
	if id == nil then return end
	local slot = eid .. ":" .. tostring(id)
	local link = ns.Plain(d.itemHyperlink)
	local waiting = open[slot]
	if type(link) ~= "string" or Hidden(d.startTime) then
		-- hidden for now: look again later
		open[slot] = waiting or { eid = eid, id = id, tries = 0 }
		return
	end
	local key = slot .. ":" .. tostring(ns.Plain(d.startTime) or 0) .. ":" .. tostring(ns.ItemID(link) or 0)
	if db.seen[key] then
		open[slot] = nil
		return
	end
	if current and current.final and current.finalID == eid then current.finalSeen = true end
	local done = d.winner ~= nil or ns.Plain(d.allPassed) == true
	if not done then
		waiting = waiting or { eid = eid, id = id, tries = 0 }
		open[slot] = waiting
		if not waiting.told then
			waiting.told = true
			if not priming then ns.Send("LOOT_DROPPED", link, BossName(eid, info)) end
		end
		return
	end
	-- names hidden for now (combat): look again later, then record them as "?"
	if not priming and NamesHidden(d) and (not waiting or waiting.tries < NAME_TRIES) then
		open[slot] = waiting or { eid = eid, id = id, tries = 0 }
		return
	end
	open[slot] = nil
	db.seen[key] = Now()
	if priming then return end
	Record(eid, d, link, info)
end

local function ReadEncounter(eid, info)
	local ok, drops = pcall(C_LootHistory.GetSortedDropsForEncounter, eid)
	if not ok or type(drops) ~= "table" then return end
	for _, d in ipairs(drops) do Consider(eid, d, info) end
end

local function ReadDrop(eid, id)
	if C_LootHistory.GetSortedInfoForDrop then
		local ok, d = pcall(C_LootHistory.GetSortedInfoForDrop, eid, id)
		if ok and type(d) == "table" then
			Consider(eid, d)
			return
		end
	end
	ReadEncounter(eid)
end

local function ReadAll()
	local ok, encounters = pcall(C_LootHistory.GetAllEncounterInfos)
	if not ok or type(encounters) ~= "table" then return end
	for _, enc in ipairs(encounters) do
		local eid = ns.Plain(enc.encounterID)
		if eid ~= nil then ReadEncounter(eid, enc) end
	end
end

local CheckSummary, Poll

local function Flush()
	if not Ready() then return end
	priming = GetTime() < primeUntil
	local encs, drops, all = dirtyEncs, dirtyDrops, dirtyAll
	dirtyEncs, dirtyDrops, dirtyAll = {}, {}, false
	if all then
		ReadAll()
	else
		for eid in pairs(encs) do ReadEncounter(eid) end
		for _, v in pairs(drops) do
			if not encs[v.eid] then ReadDrop(v.eid, v.id) end
		end
	end
	priming = false
	if next(open) and not polling then
		polling = true
		C_Timer.After(POLL, Poll)
	end
	CheckSummary()
	if changed then
		changed = false
		ns.Send("HISTORY_CHANGED")
	end
end

flushSoon = ns.Debounce(0.5, Flush)

-- Safety net: drops still open are read again now and then.
Poll = function()
	polling = false
	if not Ready() then return end
	for slot, v in pairs(open) do
		v.tries = (v.tries or 0) + 1
		if v.tries > POLL_MAX then open[slot] = nil else dirtyDrops[slot] = v end
	end
	Flush()
end

ns.On("LOOT_HISTORY_UPDATE_DROP", function(_, eid, id)
	eid, id = ns.Plain(eid), ns.Plain(id)
	if eid == nil then
		dirtyAll = true
	elseif id == nil then
		dirtyEncs[eid] = true
	else
		dirtyDrops[eid .. ":" .. tostring(id)] = { eid = eid, id = id }
	end
	flushSoon()
end)

ns.On("LOOT_HISTORY_UPDATE_ENCOUNTER", function(_, eid)
	eid = ns.Plain(eid)
	if eid == nil then dirtyAll = true else dirtyEncs[eid] = true end
	flushSoon()
end)

-- Boss kills and the summary ----------------------------------------------------------------

local function IsFinal(instanceID, eid)
	local data = ns.Data and ns.Data.instances and instanceID and ns.Data.instances[instanceID]
	local final = data and data.final
	if type(final) == "table" then
		for _, id in pairs(final) do
			if id == eid then return true end
		end
		return false
	end
	return final ~= nil and final == eid
end

ns.On("ENCOUNTER_END", function(_, eid, name, _, _, success)
	eid, name, success = ns.Plain(eid), ns.Plain(name), ns.Plain(success)
	if not db or eid == nil or not (success == 1 or success == true) then return end
	if type(name) == "string" and name ~= "" then bossNames[eid] = name end
	if not current or current.kind == "world" then OnZone() end
	local run = current
	if not run or run.kind == "world" then return end
	for _, kill in ipairs(run.kills) do
		if kill.id == eid then return end
	end
	run.kills[#run.kills + 1] = { id = eid, name = bossNames[eid] or "?", at = Now() }
	run.act = Now()
	if IsFinal(run.id, eid) then
		run.final, run.finalID, run.finalSeen = Now(), eid, nil
		C_Timer.After(FINAL_WAIT + 1, function() CheckSummary() end)
	end
	Touch()
	flushSoon()
end)

local function Minutes(run)
	return math.max(1, math.floor(((run.stop or run.final or Now()) - run.start) / 60 + 0.5))
end

-- Summary lines. plain: no colours (for group chat). limit: most drop lines.
function H.Lines(run, plain, limit)
	local lines = {}
	local head = (run.zone or "?") .. ": " .. Minutes(run) .. " min"
	if run.kind ~= "world" then head = head .. ", " .. Plural(#run.kills, "boss", "bosses") end
	lines[1] = head .. ", " .. Plural(#run.drops, "drop", "drops")
	local shown = math.min(#run.drops, limit or #run.drops)
	for i = 1, shown do
		local drop = run.drops[i]
		local text
		local w = drop.winner
		if w then
			local who = plain and Short(w.n) or UI.Colored(Short(w.n), UI.ClassColor(w.c))
			text = who
			if w.ch then text = text .. ", " .. LABEL[w.ch] .. (w.r and (" " .. w.r) or "") end
		else
			text = "All passed"
		end
		lines[#lines + 1] = (drop.link or "?") .. ": " .. text
	end
	if shown < #run.drops then lines[#lines + 1] = "+" .. (#run.drops - shown) .. " more" end
	return lines
end

local function Channel()
	if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
	if IsInRaid and IsInRaid() then return "RAID" end
	if IsInGroup and IsInGroup() then return "PARTY" end
	return nil
end

-- Seconds until the summary can be posted again.
function H.PostWait()
	return math.max(0, math.ceil(lastPost + POST_COOLDOWN - GetTime()))
end

-- Posts a run's summary to the group. Returns true, or false and why.
function H.Post(run)
	run = run or current or H.Runs()[1]
	if not run then return false, "No run" end
	if H.PostWait() > 0 then return false, "Wait " .. H.PostWait() .. " s" end
	local channel = Channel()
	if not channel then return false, "No group" end
	local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
	if not send then return false, "No chat" end
	lastPost = GetTime()
	local lines = H.Lines(run, true, POST_LINES)
	lines[1] = "Lootomania: " .. lines[1]
	for _, line in ipairs(lines) do
		if not pcall(send, line, channel) then return false, "Blocked" end
	end
	return true
end

Announce = function(run)
	run.told = #run.drops
	if ns.db.historySummary ~= false then
		for _, line in ipairs(H.Lines(run)) do ns.Print(line) end
	end
	if ns.db.historyAutoPost then H.Post(run) end
end

-- After the final boss: tell once its loot is decided.
CheckSummary = function()
	local run = current
	if not run or not run.final or run.told then return end
	local age = Now() - run.final
	if (run.finalSeen and not next(open)) or age >= FINAL_WAIT then
		Announce(run)
		Touch()
	end
end

-- Public --------------------------------------------------------------------------------------

-- Saved runs, newest first.
function H.Runs()
	local list = {}
	if not db then return list end
	for i = #db.runs, 1, -1 do list[#list + 1] = db.runs[i] end
	return list
end

function H.Current() return current end

-- Players of a run: list of { name, class, won, need, greed, pass, me }, most wins first.
function H.Players(run)
	local list = {}
	for name, p in pairs(run and run.players or {}) do
		list[#list + 1] = { name = name, class = p.c, won = p.won or 0, need = p.need or 0, greed = p.greed or 0, pass = p.pass or 0, me = p.me }
	end
	table.sort(list, function(a, b)
		if a.won ~= b.won then return a.won > b.won end
		return a.name < b.name
	end)
	return list
end

function H.Delete(run)
	for i = #db.runs, 1, -1 do
		if db.runs[i] == run then table.remove(db.runs, i) end
	end
	if current == run then current = nil end
	ns.Send("HISTORY_CHANGED")
end

function H.Clear()
	db.runs = {}
	current = nil
	OnZone()
	changed = false
	ns.Send("HISTORY_CHANGED")
end

-- Start-up ------------------------------------------------------------------------------------

local first = true

ns.On("PLAYER_ENTERING_WORLD", function(_, isLogin, isReload)
	if not db then return end
	OnZone()
	if first then
		first = false
		-- history left from before a login is old: mark it seen, do not record it
		if ns.Plain(isLogin) ~= false and ns.Plain(isReload) ~= true then primeUntil = GetTime() + PRIME_WINDOW end
		dirtyAll = true
		Flush()
	end
	C_Timer.After(2, OnZone)
end)

ns.On("ZONE_CHANGED_NEW_AREA", function() OnZone() end)

ns.OnLoad(function()
	db = ns.db.history
	db.runs = db.runs or {}
	db.seen = db.seen or {}
	local now = Now()
	for key, at in pairs(db.seen) do
		if type(at) ~= "number" or now - at > SEEN_AGE then db.seen[key] = nil end
	end
	for _, run in ipairs(db.runs) do
		run.kills, run.drops, run.players = run.kills or {}, run.drops or {}, run.players or {}
		run.left = nil
	end
	Trim()
end)

ns.Listen("SETTINGS_CHANGED", function(key)
	if key == "historyKeep" and db then
		Trim()
		ns.Send("HISTORY_CHANGED")
	end
end)

ns.Main.AddOption({ group = "History", key = "historyKeep", kind = "slider", label = "Keep runs", min = 5, max = 50, step = 1, format = "%d", default = 20 })
ns.Main.AddOption({ group = "History", key = "historyWorld", kind = "check", label = "Record open world", default = true })
ns.Main.AddOption({ group = "History", key = "historySummary", kind = "check", label = "Summary in chat", default = true, tip = "After the final boss or on leaving." })
ns.Main.AddOption({ group = "History", key = "historyAutoPost", kind = "check", label = "Post summary to group", default = false })

-- Tab -------------------------------------------------------------------------------------------

local view = {}
local LEFT = 236
local DROP_STEP, RUN_STEP, PLAYER_STEP = 38, 42, 18

local function ItemName(drop)
	local name = type(drop.link) == "string" and drop.link:match("%[(.-)%]")
	if not name and drop.id and C_Item and C_Item.GetItemInfo then name = C_Item.GetItemInfo(drop.id) end
	return name or ("Item " .. tostring(drop.id or "?"))
end

local function RollText(row)
	local text = row.ch and LABEL[row.ch] or "No roll"
	if row.r then text = text .. " " .. row.r end
	return text
end

local function Select(run)
	view.selected = run
	view.Fill()
end

local function RunRow(i)
	local row = CreateFrame("Button", nil, view.runs.content)
	row:SetHeight(RUN_STEP - 2)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * RUN_STEP)
	row:SetPoint("TOPRIGHT", 0, -(i - 1) * RUN_STEP)
	row.on = UI.Fill(row, "BACKGROUND", C.LINE, 0.7)
	row.on:SetAllPoints()
	row.over = UI.Fill(row, "BORDER", C.PANEL_HI, 0.9)
	row.over:SetAllPoints()
	row.over:Hide()
	row.zone = UI.Text(row, "GameFontHighlight", C.GOLD_SOFT)
	row.zone:SetPoint("TOPLEFT", 8, -4)
	row.zone:SetPoint("RIGHT", -6, 0)
	row.info = UI.Text(row, "GameFontHighlightSmall", C.MUTED)
	row.info:SetPoint("BOTTOMLEFT", 8, 5)
	row.info:SetPoint("RIGHT", -6, 0)
	row:SetScript("OnEnter", function(self) self.over:Show() end)
	row:SetScript("OnLeave", function(self) self.over:Hide() end)
	row:SetScript("OnClick", function(self) Select(self.run) end)
	return row
end

local function DropRow(i)
	local row = CreateFrame("Frame", nil, view.drops.content)
	row:SetHeight(DROP_STEP - 2)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * DROP_STEP)
	row:SetPoint("TOPRIGHT", 0, -(i - 1) * DROP_STEP)
	row.over = UI.Fill(row, "BACKGROUND", C.PANEL_HI, 0.9)
	row.over:SetAllPoints()
	row.over:Hide()
	row.icon = UI.Icon(row, 30)
	row.icon:SetPoint("LEFT", 3, 0)
	row.icon:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row.icon.onClick = function(self, button)
		if button == "RightButton" and ns.Wish and self.item then ns.Wish.Toggle(self.item) end
	end
	row.name = UI.Text(row, "GameFontHighlight", C.TEXT)
	row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
	row.name:SetWidth(290)
	row.boss = UI.Text(row, "GameFontHighlightSmall", C.MUTED)
	row.boss:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
	row.boss:SetWidth(290)
	row.win = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
	row.win:SetPoint("TOPRIGHT", -8, -4)
	row.win:SetWidth(210)
	row.win:SetJustifyH("RIGHT")
	row.mine = UI.Text(row, "GameFontHighlightSmall", C.MUTED)
	row.mine:SetPoint("BOTTOMRIGHT", -8, 4)
	row.mine:SetWidth(210)
	row.mine:SetJustifyH("RIGHT")
	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self)
		self.over:Show()
		local drop = self.drop
		if not drop then return end
		local lines = {}
		for _, r in ipairs(drop.rolls or {}) do
			local line = UI.Colored(Short(r.n), UI.ClassColor(r.c)) .. ": " .. RollText(r)
			if r.w then line = line .. UI.Colored(", won", C.GOLD) end
			lines[#lines + 1] = line
		end
		if #lines == 0 then lines[1] = "No rolls" end
		UI.TextTooltip(self, ItemName(drop), lines)
	end)
	row:SetScript("OnLeave", function(self)
		self.over:Hide()
		UI.HideTooltip()
	end)
	return row
end

local COLUMNS = { { "won", "Won" }, { "need", "Need" }, { "greed", "Greed" }, { "pass", "Pass" } }

local function PlayerRow(i)
	local row = CreateFrame("Frame", nil, view.players.content)
	row:SetHeight(PLAYER_STEP)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * PLAYER_STEP)
	row:SetPoint("TOPRIGHT", 0, -(i - 1) * PLAYER_STEP)
	row.name = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
	row.name:SetPoint("LEFT", 8, 0)
	row.name:SetWidth(180)
	row.cells = {}
	for n, column in ipairs(COLUMNS) do
		local cell = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
		cell:SetPoint("LEFT", 200 + (n - 1) * 80, 0)
		cell:SetWidth(70)
		row.cells[column[1]] = cell
	end
	return row
end

function view.Fill()
	local runs = H.Runs()
	local found = false
	for _, run in ipairs(runs) do
		if run == view.selected then found = true end
	end
	if not found then view.selected = current or runs[1] end
	local run = view.selected

	for i, r in ipairs(runs) do
		local row = view.runPool:Get(i)
		row.run = r
		row.on:SetShown(r == run)
		row.zone:SetText(r.zone or "?")
		UI.Color(row.zone, r == current and C.GOLD or C.GOLD_SOFT)
		row.info:SetText(date("%d %b %H:%M", r.start) .. ", " .. Minutes(r) .. " min, " .. Plural(#r.drops, "drop", "drops"))
	end
	view.runPool:HideFrom(#runs + 1)
	view.runs.content:SetHeight(math.max(1, #runs * RUN_STEP))
	view.none:SetShown(#runs == 0)

	view.post:SetShown(run ~= nil)
	view.delete:SetShown(run ~= nil)
	view.playerBox:SetShown(run ~= nil)
	if not run then
		view.title:SetText("")
		view.info:SetText("")
		view.dropPool:HideFrom(1)
		view.playerPool:HideFrom(1)
		return
	end

	view.title:SetText(run.zone or "?")
	local info = date("%d %b %H:%M", run.start) .. ", " .. Minutes(run) .. " min"
	if run.kind ~= "world" then info = info .. ", " .. Plural(#run.kills, "boss", "bosses") end
	view.info:SetText(info .. ", " .. Plural(#run.drops, "drop", "drops"))

	-- newest drop first
	local n = 0
	for i = #run.drops, 1, -1 do
		local drop = run.drops[i]
		n = n + 1
		local row = view.dropPool:Get(n)
		row.drop = drop
		row.icon:SetItem(drop.link or drop.id)
		local quality = drop.id and C_Item.GetItemQualityByID(drop.id)
		row.name:SetText(ItemName(drop))
		UI.Color(row.name, quality and UI.QUALITY[quality] or C.TEXT)
		row.boss:SetText(drop.boss or "Trash")
		local w = drop.winner
		if w then
			row.win:SetText(UI.Colored(Short(w.n), UI.ClassColor(w.c)) .. "  " .. RollText(w))
		else
			row.win:SetText(UI.Colored("All passed", C.FAINT))
		end
		local me = drop.me
		if me and me.w then
			row.mine:SetText(UI.Colored("Won", C.GREEN))
		elseif me and me.ch then
			row.mine:SetText("You: " .. RollText(me))
		else
			row.mine:SetText("")
		end
	end
	view.dropPool:HideFrom(n + 1)
	view.drops.content:SetHeight(math.max(1, n * DROP_STEP))
	view.empty:SetShown(n == 0)

	local players = H.Players(run)
	for i, p in ipairs(players) do
		local row = view.playerPool:Get(i)
		row.name:SetText(UI.Colored(Short(p.name), UI.ClassColor(p.class)))
		for _, column in ipairs(COLUMNS) do
			local value = p[column[1]]
			row.cells[column[1]]:SetText(value)
			UI.Color(row.cells[column[1]], value > 0 and (column[1] == "won" and C.GOLD or C.TEXT) or C.FAINT)
		end
	end
	view.playerPool:HideFrom(#players + 1)
	view.players.content:SetHeight(math.max(1, #players * PLAYER_STEP))
end

local function BuildTab(panel)
	local width, height = ns.Main.PANEL_WIDTH, ns.Main.PANEL_HEIGHT
	local right = width - LEFT - 12

	local runBox = UI.Box(panel)
	runBox:SetPoint("TOPLEFT", 0, 0)
	runBox:SetSize(LEFT, height)
	view.runs = UI.Scroll(runBox)
	view.runs:SetPoint("TOPLEFT", 4, -4)
	view.runs:SetPoint("BOTTOMRIGHT", -16, 4)
	view.runPool = UI.Pool(RunRow)
	view.none = UI.Text(runBox, "GameFontHighlightSmall", C.FAINT)
	view.none:SetPoint("TOP", 0, -14)
	view.none:SetText("No runs")

	view.title = UI.Heading(panel, 18)
	view.title:SetPoint("TOPLEFT", LEFT + 12, -2)
	view.title:SetWidth(right - 170)
	view.info = UI.Text(panel, "GameFontHighlightSmall", C.MUTED)
	view.info:SetPoint("TOPLEFT", LEFT + 12, -26)

	view.post = UI.Button(panel, "Post", 70, 22)
	view.post:SetPoint("TOPRIGHT", 0, -4)
	view.post:SetScript("OnClick", function(self)
		local ok, why = H.Post(view.selected)
		if not ok then
			ns.Print("Post: " .. tostring(why))
			return
		end
		self:Disable()
		C_Timer.After(POST_COOLDOWN, function() self:Enable() end)
	end)
	UI.Tip(view.post, "Post", { "Summary to group chat" })
	view.delete = UI.Button(panel, "Delete", 70, 22)
	view.delete:SetPoint("RIGHT", view.post, "LEFT", -6, 0)
	view.delete:SetScript("OnClick", function(self)
		-- second click deletes
		if self.armed ~= view.selected then
			self.armed = view.selected
			self:SetLabel("Sure?")
			C_Timer.After(3, function()
				self.armed = nil
				self:SetLabel("Delete")
			end)
			return
		end
		self.armed = nil
		self:SetLabel("Delete")
		if view.selected then H.Delete(view.selected) end
	end)

	local playersHeight = 150
	local dropBox = UI.Box(panel)
	dropBox:SetPoint("TOPLEFT", LEFT + 12, -46)
	dropBox:SetSize(right, height - 46 - playersHeight - 8)
	view.drops = UI.Scroll(dropBox)
	view.drops:SetPoint("TOPLEFT", 4, -4)
	view.drops:SetPoint("BOTTOMRIGHT", -16, 4)
	view.dropPool = UI.Pool(DropRow)
	view.empty = UI.Text(dropBox, "GameFontHighlightSmall", C.FAINT)
	view.empty:SetPoint("TOP", 0, -14)
	view.empty:SetText("No drops")

	local playerBox = UI.Box(panel)
	view.playerBox = playerBox
	playerBox:SetPoint("BOTTOMLEFT", LEFT + 12, 0)
	playerBox:SetSize(right, playersHeight)
	local head = UI.Text(playerBox, "GameFontHighlightSmall", C.GOLD_SOFT)
	head:SetPoint("TOPLEFT", 12, -8)
	head:SetText("Player")
	for n, column in ipairs(COLUMNS) do
		local label = UI.Text(playerBox, "GameFontHighlightSmall", C.GOLD_SOFT)
		label:SetPoint("TOPLEFT", 204 + (n - 1) * 80, -8)
		label:SetText(column[2])
	end
	view.players = UI.Scroll(playerBox)
	view.players:SetPoint("TOPLEFT", 4, -26)
	view.players:SetPoint("BOTTOMRIGHT", -16, 4)
	view.playerPool = UI.Pool(PlayerRow)

	local hint = UI.Text(panel, "GameFontHighlightSmall", C.FAINT)
	hint:SetPoint("LEFT", view.info, "RIGHT", 14, 0)
	hint:SetText("Right-click item: wishlist")
end

ns.Main.AddTab("history", "History", 300, BuildTab, function() view.Fill() end)

ns.Listen("HISTORY_CHANGED", function() ns.Main.Refresh("history") end)

ns.Command("history", "History. Also: post, clear", function(rest)
	rest = (rest or ""):lower()
	if rest == "post" then
		local ok, why = H.Post()
		if not ok then ns.Print("Post: " .. tostring(why)) end
	elseif rest == "clear" then
		H.Clear()
		ns.Print("History: cleared")
	else
		ns.Main.Toggle("history")
	end
end)
