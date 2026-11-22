local _, ns = ...

-- Tracked items: the character's one list of wanted items.
-- The list is Gear's (ns.char.hunts, Gear.Track, Gear.IsTracked). The tracker window, the guide
-- and the map pins work from it (Tracker.lua, Pins.lua). This file adds the rest:
--   the "Tracked" tab, with an item box to add anything by link or id
--   roll statistics per item: ns.char.hunts.stats[itemID] = { tries, wins, boss, zone, at, added }
--   a chat line when a tracked item comes up for a roll
-- There was an account-wide wishlist beside the tracked list (ns.db.wish). The user's decision of
-- 2026-11-21: one list, per character. Each character takes over the wishlist items it can use,
-- once; ns.db.wish stays as it was for the characters that have not logged in yet.

local UI = ns.UI
local C = UI.C
local W = {}
ns.Wanted = W

local function Info(id)
	if not (C_Item and C_Item.GetItemInfo) then return nil end
	local ok, name, link, quality = pcall(C_Item.GetItemInfo, id)
	if ok then return name, link, quality end
	return nil
end

local function Hunts() return ns.char and ns.char.hunts end

local function Stats(id)
	local hunts = Hunts()
	hunts.stats = hunts.stats or {}
	local s = hunts.stats[id]
	if type(s) ~= "table" then
		s = { tries = 0, wins = 0 }
		hunts.stats[id] = s
	end
	s.tries, s.wins = s.tries or 0, s.wins or 0
	return s
end

function W.Has(item)
	local id = ns.ItemID(item)
	local Gear = ns.Gear
	return id ~= nil and Gear ~= nil and Gear.IsTracked ~= nil and Gear.IsTracked(id) or false
end

local function Suffix(item)
	local Gear = ns.Gear
	return type(item) == "string" and Gear.LinkSuffixID and Gear.LinkSuffixID(item) or nil
end

-- Tracks an item (ID or link; a link's random suffix is the one to look for). Returns the item
-- ID, or nil when it is no item.
function W.Add(item)
	local id = ns.ItemID(item)
	local Gear = ns.Gear
	if not id or id <= 0 or not (Gear and Gear.Track and Hunts()) then return nil end
	-- an id neither the data nor the game knows is a typo, not an item
	if not (Gear.Item and Gear.Item(id)) and C_Item and C_Item.GetItemInfoInstant then
		local ok, known = pcall(C_Item.GetItemInfoInstant, id)
		if ok and ns.Plain(known) == nil then return nil end
	end
	if not Info(id) and C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
	local suffix = Suffix(item)
	local had = Gear.IsTracked(id)
	Gear.Track(id, true, suffix) -- a done or removed mark goes with it
	if not had then Stats(id).added = time() end
	return id
end

function W.Remove(item)
	local id = ns.ItemID(item)
	if not id or not W.Has(id) then return false end
	ns.Gear.Track(id, false)
	local hunts = Hunts()
	if hunts.stats then hunts.stats[id] = nil end
	return true
end

local function LinkOf(item, id)
	if type(item) == "string" and item:find("|H") then return item end
	return select(2, Info(id)) or ("item " .. id)
end

-- Tracks or untracks, with a chat line. Returns true when the item is tracked afterwards.
function W.Toggle(item)
	local id = ns.ItemID(item)
	if not id then return false end
	local link = LinkOf(item, id)
	if W.Has(id) then
		W.Remove(id)
		ns.Print("Untracked: " .. link)
		return false
	end
	if not W.Add(item) then return false end
	ns.Print("Tracked: " .. link)
	return true
end

local function SourceText(id)
	local Gear = ns.Gear
	if not (Gear and Gear.SourceText) then return nil end
	local ok, text = pcall(Gear.SourceText, id)
	return ok and type(text) == "string" and text or nil
end

-- What the item is worth against what is worn ("+12", "No upgrade"), as the tracker says it.
local function Worth(id)
	return ns.Tracker and ns.Tracker.Worth and (ns.Tracker.Worth(id)) or nil
end

-- The list, by name: { id, link, name, quality, worth, tries, wins, boss, zone, at, added, source }.
function W.List()
	local list = {}
	local Gear = ns.Gear
	if not (Gear and Gear.Tracked and Hunts()) then return list end
	local player = Gear.PlayerContext and Gear.PlayerContext() or nil
	for _, id in ipairs(Gear.Tracked()) do
		local name, link, quality = Info(id)
		if Gear.Name then
			local wanted, itemQuality = Gear.Name(id, player) -- with the suffix to look for
			name, quality = wanted or name, itemQuality or quality
		end
		local s = Stats(id)
		list[#list + 1] = {
			id = id, link = (Gear.WantedLink and Gear.WantedLink(id, player)) or link, name = name or ("Item " .. id), quality = quality,
			worth = Worth(id),
			tries = s.tries, wins = s.wins, boss = s.boss, zone = s.zone, at = s.at, added = s.added, source = SourceText(id),
		}
	end
	table.sort(list, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return a.id < b.id
	end)
	return list
end

-- What was marked done or removed in the Upgrades tab, by name:
-- { id, suffix, state ("done" | "removed"), link, name, quality, source }.
function W.Marked()
	local list = {}
	local Gear = ns.Gear
	if not (Gear and Gear.States) then return list end
	for _, mark in ipairs(Gear.States()) do
		local id = mark.id
		local item = Gear.Item and Gear.Item(id)
		local name, link, quality = Info(id)
		name, quality = item and item.name or name, item and item.quality or quality
		for _, suffix in ipairs(mark.suffix and item and item.suffixes or {}) do
			if suffix.id == mark.suffix and suffix.name and suffix.name ~= "" then name = (name or "") .. " " .. suffix.name end
		end
		list[#list + 1] = {
			id = id, suffix = mark.suffix, state = mark.state, link = Gear.Link and Gear.Link(id, mark.suffix) or link,
			name = name or ("Item " .. id), quality = quality, source = SourceText(id),
		}
	end
	table.sort(list, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return a.id < b.id
	end)
	return list
end

-- Item from typed text: a link, "item:123", an ID, or a name the data or the game knows.
local function Parse(text)
	if type(text) ~= "string" then return nil end
	text = text:match("^%s*(.-)%s*$")
	if text == "" then return nil end
	local link = text:match("(|c.-|Hitem:.-|h.-|h|r)") or text:match("(|Hitem:.-|h.-|h)")
	if link then return link end
	if ns.ItemID(text) then return ns.ItemID(text) end
	-- by name. Several items can share one (a vendor's level 18 and level 28 sword): the best the
	-- character has the level for, else the lowest
	local Gear = ns.Gear
	local ids = Gear and Gear.FindItems and Gear.FindItems(text)
	if ids and Gear.Item then
		local ctx = Gear.PlayerContext and Gear.PlayerContext() or nil
		local level = ctx and ctx.level or 60
		local best, bestReq, low, lowReq
		for _, id in ipairs(ids) do
			local req = (Gear.Item(id) or {}).req or 1
			if req <= level and (not bestReq or req > bestReq) then best, bestReq = id, req end
			if not lowReq or req < lowReq then low, lowReq = id, req end
		end
		return best or low
	end
	local _, found = Info(text)
	return found
end
W.Find = Parse

-- The old wishlist ------------------------------------------------------------------------------

-- Once per character: the wishlist items this character can use become tracked items, with
-- their roll counts. An item its class can never use is left out.
local function TakeWishlist()
	local hunts, Gear = Hunts(), ns.Gear
	if not hunts or hunts.wishTaken or not (Gear and Gear.Track) then return end
	hunts.wishTaken = true
	local old = ns.db and ns.db.wish
	if type(old) ~= "table" then return end
	local player = Gear.PlayerContext and Gear.PlayerContext() or nil
	local taken = 0
	for id in pairs(old) do
		local fits = true
		if type(id) ~= "number" then
			fits = false
		elseif Gear.Item and Gear.Item(id) and Gear.Usable and player then
			local usable, reason = Gear.Usable(id, player)
			fits = usable or reason == "level"
		end
		if fits and not hunts.tracked[id] and not hunts.state[id] then
			hunts.tracked[id] = true
			local was = type(ns.db.wishStats) == "table" and ns.db.wishStats[id]
			local s = Stats(id)
			if type(was) == "table" then
				s.tries, s.wins, s.boss, s.zone, s.at, s.added = was.tries or 0, was.wins or 0, was.boss, was.zone, was.at, was.added
			end
			taken = taken + 1
		end
	end
	if taken > 0 then
		ns.Send("HUNTS_CHANGED")
		ns.Print(("Wishlist items now tracked: %d. See the Tracked tab."):format(taken))
	end
end

ns.OnLoad(function() ns.Safe(TakeWishlist) end)

-- Loot ----------------------------------------------------------------------------------------

ns.Listen("LOOT_DECIDED", function(drop, run)
	if not drop or not drop.id or not W.Has(drop.id) then return end
	local s = Stats(drop.id)
	s.tries = s.tries + 1
	if drop.me and drop.me.w then s.wins = s.wins + 1 end
	s.boss, s.zone, s.at = drop.boss, drop.zone or (run and run.zone), drop.at
	ns.Main.Refresh("tracked")
end)

ns.Listen("LOOT_DROPPED", function(link)
	if ns.db.trackAlert == false or not W.Has(link) then return end
	ns.Print("Tracked item dropped: " .. tostring(link))
	-- on screen too: a chat line is easy to miss while a roll timer runs
	local id = ns.ItemID(link)
	if id and ns.Tracker and ns.Tracker.Toast then ns.Tracker.Toast(id, nil, "Tracked item dropped") end
end)

-- Tab -------------------------------------------------------------------------------------------

local view = {}
local STEP = 42

local function AddFromBox()
	local item = Parse(view.box:GetText())
	if not item then
		ns.Print("Tracked: no item")
		return
	end
	if W.Has(item) then
		ns.Print("Tracked: already listed")
	elseif W.Add(item) then
		ns.Print("Tracked: " .. LinkOf(item, ns.ItemID(item)))
	end
	view.box:SetText("")
	view.box:ClearFocus()
end

local function Ago(at)
	if not at then return nil end
	local days = math.floor((time() - at) / 86400)
	if days <= 0 then return "today" end
	return days .. " d ago"
end

-- A click on a row: how to get the item, in the side panel.
local function Details(id)
	if id and ns.Side and ns.Side.Item then ns.Side.Item(id) end
end

local function MakeRow()
	local row = CreateFrame("Button", nil, view.scroll.content)
	row:SetHeight(STEP - 2)
	row.back = UI.Fill(row, "BACKGROUND", C.PANEL, 0.9)
	row.back:SetAllPoints()
	row.over = UI.Fill(row, "BORDER", C.GOLD, 0.06)
	row.over:SetAllPoints()
	row.over:Hide()
	row.icon = UI.Icon(row, 32)
	row.icon:SetPoint("LEFT", 4, 0)
	row.icon.onClick = function() Details(row.id) end
	row.name = UI.Text(row, "GameFontHighlight", C.TEXT)
	row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -2)
	row.name:SetWidth(380)
	row.source = UI.Text(row, "GameFontHighlightSmall", C.MUTED)
	row.source:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 2)
	row.source:SetWidth(380)
	-- untrack, or for a done or removed item: back to the lists
	row.remove = UI.Button(row, "x", 22, 22)
	row.remove:SetPoint("RIGHT", -6, 0)
	row.remove:SetScript("OnClick", function()
		if not row.id then return end
		if row.state then
			ns.Gear.SetState(row.id, nil, row.suffix)
		else
			W.Remove(row.id)
		end
	end)
	row.remove:HookScript("OnEnter", function(self)
		UI.TextTooltip(self, row.state and "Restore" or "Untrack", row.state and { "Back to the lists of the Upgrades tab." } or nil)
	end)
	row.remove:HookScript("OnLeave", UI.HideTooltip)
	row.count = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
	row.count:SetPoint("TOPRIGHT", row.remove, "TOPLEFT", -12, 1)
	row.count:SetWidth(300)
	row.count:SetJustifyH("RIGHT")
	row.seen = UI.Text(row, "GameFontHighlightSmall", C.MUTED)
	row.seen:SetPoint("BOTTOMRIGHT", row.remove, "BOTTOMLEFT", -12, -1)
	row.seen:SetWidth(300)
	row.seen:SetJustifyH("RIGHT")
	row:SetScript("OnClick", function(self) Details(self.id) end)
	row:SetScript("OnEnter", function(self) self.over:Show() end)
	row:SetScript("OnLeave", function(self) self.over:Hide() end)
	return row
end

local HEAD = 26 -- a heading between the parts of the list
local STATE_HEAD = { done = "Done", removed = "Removed" }

local function Fill()
	local list, marked = W.List(), W.Marked()
	local y, n = 0, 0
	local function Put(entry)
		n = n + 1
		local row = view.pool:Get(n)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, -y)
		row:SetPoint("TOPRIGHT", 0, -y)
		y = y + STEP
		row.id, row.state, row.suffix = entry.id, entry.state, entry.suffix
		row.icon:SetItem(entry.link or entry.id, entry.quality)
		row.name:SetText(entry.name)
		UI.Color(row.name, entry.quality and UI.QUALITY[entry.quality] or C.TEXT)
		row.source:SetText(entry.source or "")
		row.remove:SetWidth(entry.state and 62 or 22)
		row.remove:SetLabel(entry.state and "Restore" or "x")
		return row
	end
	for _, entry in ipairs(list) do
		local row = Put(entry)
		-- what it is worth; rolls in a group: how often it came up, how often it was won
		local parts = {}
		if entry.worth then parts[1] = entry.worth end
		if entry.tries > 0 then
			parts[#parts + 1] = "Rolled for: " .. entry.tries
			parts[#parts + 1] = "Won: " .. UI.Colored(entry.wins, entry.wins > 0 and C.GREEN or C.TEXT)
		end
		row.count:SetText(table.concat(parts, "   "))
		if entry.at then
			local last = {}
			if entry.boss then last[#last + 1] = entry.boss end
			if entry.zone then last[#last + 1] = entry.zone end
			last[#last + 1] = Ago(entry.at)
			row.seen:SetText("Last: " .. table.concat(last, ", "))
		else
			row.seen:SetText("")
		end
	end
	-- what was marked done or removed in the Upgrades tab: here it can be found and put back
	for _, state in ipairs({ "done", "removed" }) do
		local head, count = view.heads[state], 0
		for _, entry in ipairs(marked) do
			if entry.state == state then
				if count == 0 then
					head:ClearAllPoints()
					head:SetPoint("TOPLEFT", 6, -y - 8)
					y = y + HEAD
				end
				count = count + 1
				local row = Put(entry)
				row.count:SetText("")
				row.seen:SetText("")
			end
		end
		head:SetShown(count > 0)
		head:SetText(STATE_HEAD[state] .. ": " .. count)
	end
	view.pool:HideFrom(n + 1)
	view.scroll.content:SetHeight(math.max(1, y))
	view.empty:SetShown(n == 0)
	view.total:SetText("Tracked: " .. #list)
end

-- Shift-clicked links go to our box while it has the focus.
local function CatchLink(link)
	if view.box and view.box:HasFocus() and type(link) == "string" and link:find("item:") then
		view.box:SetText(link)
	end
end

local function BuildTab(panel)
	view.box = UI.Edit(panel, 320, nil, AddFromBox)
	view.box:SetPoint("TOPLEFT", 0, -2)
	local function drop()
		if not GetCursorInfo then return end
		local kind, id, link = GetCursorInfo()
		if kind == "item" and (link or id) then
			view.box:SetText(link or tostring(id))
			if ClearCursor then ClearCursor() end
			AddFromBox()
		end
	end
	view.box:SetScript("OnReceiveDrag", drop)
	view.box:HookScript("OnMouseDown", drop)

	local add = UI.Button(panel, "Track", 60, 22)
	add:SetPoint("LEFT", view.box, "RIGHT", 6, 0)
	add:SetScript("OnClick", AddFromBox)

	local hint = UI.Text(panel, "GameFontHighlightSmall", C.FAINT)
	hint:SetPoint("LEFT", add, "RIGHT", 12, 0)
	hint:SetText("Shift-click or drop an item, or type its name or ID")

	view.total = UI.Text(panel, "GameFontHighlightSmall", C.MUTED)
	view.total:SetPoint("TOPRIGHT", -2, -7)

	local box = UI.Box(panel)
	box:SetPoint("TOPLEFT", 0, -32)
	box:SetPoint("BOTTOMRIGHT", 0, 0)
	view.scroll = UI.Scroll(box)
	view.scroll:SetPoint("TOPLEFT", 4, -4)
	view.scroll:SetPoint("BOTTOMRIGHT", -16, 4)
	view.pool = UI.Pool(MakeRow)
	view.heads = {}
	for _, state in ipairs({ "done", "removed" }) do
		view.heads[state] = UI.Text(view.scroll.content, "GameFontNormalSmall", C.GOLD_SOFT)
		view.heads[state]:Hide()
	end
	view.empty = UI.Text(box, "GameFontHighlightSmall", C.FAINT)
	view.empty:SetPoint("TOP", 0, -14)
	view.empty:SetText("Nothing tracked. Track an item in Upgrades, or add one here.")

	if ChatFrameUtil and ChatFrameUtil.InsertLink then pcall(hooksecurefunc, ChatFrameUtil, "InsertLink", CatchLink) end
	if ChatEdit_InsertLink then pcall(hooksecurefunc, "ChatEdit_InsertLink", CatchLink) end
end

ns.Main.AddTab("tracked", "Tracked", 200, BuildTab, Fill)

ns.Listen("HUNTS_CHANGED", function() ns.Main.Refresh("tracked") end)

-- names and links come late for items the game has not seen
local refresh = ns.Debounce(0.5, function() ns.Main.Refresh("tracked") end)
ns.On("GET_ITEM_INFO_RECEIVED", function(_, id)
	id = ns.Plain(id)
	if id and W.Has(id) then refresh() end
end)

ns.Main.AddOption({ group = "Tracked items", key = "trackAlert", kind = "check", label = "Drop message", default = true,
	tip = "Chat line when a tracked item comes up for a roll." })
