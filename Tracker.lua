local _, ns = ...

-- Tracker: a small list of tracked upgrades on screen.
--   ns.Tracker.Refresh()
--   ns.Tracker.Check()        looks for tracked items in bags and on the character
--   ns.Tracker.Toast(itemId, name, head)  a message on screen: "Got it", or the head given
--   ns.Tracker.Worth(itemId)  -> text, delta: what the item is worth to the player against what is
--                             worn ("+12", "No upgrade", "Equipped", "Level 31", "Can't use"); nil
--                             when it cannot be said. The other lists of items use it too.
-- Click a row: guide. Right-click: untrack. Shift-click: link.

local UI = ns.UI
local C = UI.C
local Tracker = {}
ns.Tracker = Tracker

local WIDTH, HEAD, ROW = 230, 24, 32
local MAX_ROWS = 10
local TOAST_HOLD, TOAST_FADE = 4, 1.5

ns.Defaults({ trackerCollapsed = false })
ns.Main.AddOption({ group = "Tracker", key = "trackerShow", kind = "check", label = "Show tracker", default = true })
ns.Main.AddOption({ group = "Tracker", key = "trackerLock", kind = "check", label = "Lock place", default = false })
ns.Main.AddOption({ group = "Tracker", key = "trackerToast", kind = "check", label = "Got it message", default = true })
ns.Main.AddOption({ group = "Tracker", key = "trackerScale", kind = "slider", label = "Size", min = 50, max = 150, step = 5,
	format = "%d%%", default = 100 })

local frame, pool, toast

-- Name with the suffix to look for, for the player (not a Simulator preview).
local function Name(id)
	if ns.Gear and ns.Gear.Name then
		local name, quality = ns.Gear.Name(id, ns.Gear.PlayerContext())
		if name then return name, quality end
	end
	local item = ns.Gear and ns.Gear.Item and ns.Gear.Item(id)
	if item and item.name then return item.name, item.quality end
	local name, _, quality = C_Item.GetItemInfo(id)
	return name or ("Item " .. tostring(id)), quality
end

-- Chat link with the suffix to look for; the plain item when the game has no link for that.
local function Link(id)
	local Gear = ns.Gear
	local wanted = Gear and Gear.WantedLink and Gear.WantedLink(id, Gear.PlayerContext())
	local _, link = C_Item.GetItemInfo(wanted or id)
	if not link and wanted then _, link = C_Item.GetItemInfo(id) end
	return link
end

-- Where to go for a tracked item: its sources with a place on the map, the recipe's or the box's
-- when the item's own have none (Gear.Ways). Each: { source, via }, via "recipe" or "box" then.
local function Ways(id)
	local Gear = ns.Gear
	if Gear and Gear.Ways then return Gear.Ways(id) end
	local way, via
	if Gear and Gear.WayTo then
		way, via = Gear.WayTo(id)
	else
		local sources = Gear and Gear.Sources and Gear.Sources(id)
		way = sources and sources[1] or nil
	end
	return way and { { source = way, via = via } } or {}
end

-- One line that says how to get it, as the tooltip and the lists say it.
local function Summary(id)
	local Gear = ns.Gear
	if Gear and Gear.SourceSummary then return (Gear.SourceSummary(id)) end
	local sources = Gear and Gear.Sources and Gear.Sources(id)
	local first = sources and sources[1]
	return first and (first.text or first.name) or "Source unknown"
end

local VIA = { recipe = "Recipe: ", box = "Box: " }

-- What the item is worth against what is worn: { text, delta }. Kept until gear, spec or the
-- tracked list changes: a row is drawn again every two seconds.
local worth = {}

-- link: an item in hand (a drop); else the suffix to look for.
local function Make(id, link)
	local Gear = ns.Gear
	local known = {}
	if not (Gear and Gear.Compare and Gear.WantedLink and Gear.PlayerContext) then return known end
	local ctx = Gear.PlayerContext()
	local ok, c = pcall(Gear.Compare, link or Gear.WantedLink(id, ctx), ctx)
	if not ok or type(c) ~= "table" or c.known == false then return known end
	if c.isWorn then
		known.text, known.delta = UI.Colored("Equipped", C.GOLD_SOFT), 0
	elseif c.usable == false then
		if c.reason == "level" and c.atLevel then
			known.text = UI.Colored("Level " .. c.atLevel, C.MUTED)
		else
			known.text = UI.Colored("Can't use", C.RED)
		end
	elseif type(c.delta) == "number" then
		known.delta = c.delta
		if c.delta > 0 then
			known.text = ns.Tip and ns.Tip.Gain and ns.Tip.Gain(c.gain) or UI.Colored(("+%d"):format(c.gain or 0), C.GREEN)
		else
			-- still tracked, no longer better than what is worn
			known.text = UI.Colored("No upgrade", C.FAINT)
		end
	end
	return known
end

local function Worth(id)
	local known = worth[id]
	if not known then
		known = Make(id)
		worth[id] = known
	end
	return known
end

function Tracker.Worth(id, link)
	local Gear = ns.Gear
	-- the link of a drop with its own suffix is worth what that suffix is worth
	local known = type(link) == "string" and Gear and Gear.LinkSuffixID and Gear.LinkSuffixID(link) and Make(id, link) or Worth(id)
	return known.text, known.delta
end

-- The dungeon or raid the player is in, by name; nil in the open world.
local function Inside()
	if not GetInstanceInfo then return nil end
	local ok, name, kind = pcall(GetInstanceInfo)
	name, kind = ok and ns.Plain(name) or nil, ok and ns.Plain(kind) or nil
	if type(name) ~= "string" or kind == nil or kind == "none" then return nil end
	return name
end

-- The plan of an item's best source when it takes several steps (Upgrades.Plan), as a tooltip line.
local function NextStep(id)
	local plan = ns.Upgrades and ns.Upgrades.Plan and ns.Upgrades.Plan(id)
	if type(plan) ~= "table" then return nil end
	for i, step in ipairs(plan) do
		if step.done ~= true then return ("Next step, %d of %d: %s"):format(i, #plan, step.text) end
	end
	return ("All %d steps done"):format(#plan)
end

-- Rows --------------------------------------------------------------------------------

local function RowClick(self, button)
	local id = self.id
	if not id then return end
	if IsShiftKeyDown and IsShiftKeyDown() then
		local link = Link(id)
		if not link then return end
		local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
		if not (insert and insert(link)) then ns.Print(link) end
	elseif button == "RightButton" then
		ns.Gear.Track(id, false)
	elseif ns.Guide then
		local target = ns.Guide.Target()
		if target and target.item == id then
			ns.Guide.Clear()
		else
			-- the nearest of all its places; the best source when none can be measured from here
			local ways = Ways(id)
			local way, best = ways[1], nil
			for _, other in ipairs(ways) do
				local _, yards = ns.Guide.Nearest(other.source.spots)
				if yards and (not best or yards < best) then way, best = other, yards end
			end
			local label = way and way.via and (VIA[way.via] .. (way.source.name or way.source.text or "")) or nil
			if not (way and ns.Guide.SetSource(way.source, id, label)) then
				-- nowhere to point at: say what is known instead of only "no"
				ns.Print(("%s: %s. No place on the map for it."):format(Name(id) or "Item", Summary(id)))
			end
		end
	end
end

local function MakeRow(i)
	local row = CreateFrame("Button", nil, frame)
	row:SetHeight(ROW)
	row:SetPoint("TOPLEFT", 4, -HEAD - (i - 1) * ROW)
	row:SetPoint("TOPRIGHT", -4, -HEAD - (i - 1) * ROW)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row.hi = UI.Fill(row, "BACKGROUND", C.LINE, 0.5)
	row.hi:SetAllPoints()
	row.hi:Hide()
	row.icon = UI.Icon(row, ROW - 6)
	row.icon:SetPoint("LEFT", 2, 0)
	row.icon:EnableMouse(false) -- the row takes the clicks
	row.gain = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
	row.gain:SetPoint("TOPRIGHT", -2, -3)
	row.gain:SetJustifyH("RIGHT")
	row.name = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
	row.name:SetPoint("TOPLEFT", ROW + 2, -3)
	row.name:SetPoint("RIGHT", row.gain, "LEFT", -4, 0)
	row.hint = UI.Text(row, "GameFontHighlightSmall", C.GOLD_SOFT, 11)
	row.hint:SetPoint("BOTTOMRIGHT", -2, 3)
	row.hint:SetJustifyH("RIGHT")
	row.source = UI.Text(row, "GameFontHighlightSmall", C.MUTED, 11)
	row.source:SetPoint("BOTTOMLEFT", ROW + 2, 3)
	row.source:SetPoint("RIGHT", row.hint, "LEFT", -4, 0)
	row:SetScript("OnClick", RowClick)
	row:SetScript("OnEnter", function(self)
		self.hi:Show()
		if not self.id then return end
		local Gear = ns.Gear
		UI.ItemTooltip(self, Gear.WantedLink and Gear.WantedLink(self.id, Gear.PlayerContext()) or self.id, "ANCHOR_LEFT")
		local step = NextStep(self.id)
		if step then GameTooltip:AddLine(step, C.TEXT[1], C.TEXT[2], C.TEXT[3], true) end
		GameTooltip:AddLine("Click: guide", C.GOLD_SOFT[1], C.GOLD_SOFT[2], C.GOLD_SOFT[3])
		GameTooltip:AddLine("Right-click: untrack", C.GOLD_SOFT[1], C.GOLD_SOFT[2], C.GOLD_SOFT[3])
		GameTooltip:AddLine("Shift-click: link", C.GOLD_SOFT[1], C.GOLD_SOFT[2], C.GOLD_SOFT[3])
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function(self)
		self.hi:Hide()
		UI.HideTooltip()
	end)
	return row
end

local function Build()
	frame = UI.Box(UIParent, C.BLACK, 0.8, C.GOLD_DIM)
	frame:SetWidth(WIDTH)
	frame:SetFrameStrata("LOW")
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	-- The window hangs by its top left corner, so that a change of height (folding, a row more)
	-- moves its bottom edge and the fold button stays under the mouse. An older saved place (any
	-- anchor the game picked) is used as it is and pinned at the first change of height.
	-- The place is in the window's own scale units, saved with that scale (as UI.Window does).
	local saved = ns.db.windows.Tracker
	local scale = (ns.db.trackerScale or 100) / 100
	frame:SetScale(scale)
	if saved and saved.x then
		local k = saved.scale and saved.scale / scale or 1
		frame:SetPoint(saved.point or "CENTER", UIParent, saved.rel or saved.point or "CENTER", saved.x * k, saved.y * k)
	else
		frame:SetPoint("TOPRIGHT", UIParent, "RIGHT", -60, 150)
	end
	frame:SetScript("OnDragStart", function(self)
		if not ns.db.trackerLock then self:StartMoving() end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local left, top = self:GetLeft(), self:GetTop()
		if left and top then ns.db.windows.Tracker = { point = "TOPLEFT", rel = "BOTTOMLEFT", x = left, y = top, scale = self:GetScale() } end
	end)

	frame.title = UI.Heading(frame, 14)
	frame.title:SetPoint("TOPLEFT", 8, -5)
	frame.fold = UI.Button(frame, "-", 18, 16)
	frame.fold:SetPoint("TOPRIGHT", -4, -4)
	frame.fold:SetScript("OnClick", function()
		ns.db.trackerCollapsed = not ns.db.trackerCollapsed
		Tracker.Refresh()
	end)
	-- the items that do not fit: a click opens the whole list
	frame.more = CreateFrame("Button", nil, frame)
	frame.more:SetSize(WIDTH - 16, 16)
	frame.more:SetPoint("BOTTOMLEFT", 8, 3)
	frame.more.text = UI.Text(frame.more, "GameFontHighlightSmall", C.MUTED, 11)
	frame.more.text:SetPoint("LEFT", 0, 0)
	frame.more:SetScript("OnClick", function() ns.Main.Open("tracked") end)
	frame.more:SetScript("OnEnter", function(self) UI.Color(self.text, C.GOLD) end)
	frame.more:SetScript("OnLeave", function(self) UI.Color(self.text, C.MUTED) end)
	pool = UI.Pool(MakeRow)
end

-- Maps a spot may be on to count as "here": the player's map and its parent.
local function HereMaps()
	local here = {}
	local map = ns.Guide and ns.Guide.PlayerMap()
	if not map then return here end
	here[map] = true
	local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(map)
	if info and info.parentMapID and info.parentMapID > 0 then here[info.parentMapID] = true end
	return here
end

-- Where the item is from here: "120 yd NE" for the nearest of all its spots on the player's maps,
-- "Here" in the dungeon it drops in. nil: not around.
local function Hint(ways, here, inside)
	local near
	for _, way in ipairs(ways) do
		local source = way.source
		if inside and source.inst == inside then return "Here" end
		for i = 1, #(source.spots or {}) do
			local spot = source.spots[i]
			if here[spot.map] then
				near = near or {}
				near[#near + 1] = spot
			end
		end
	end
	if not (near and ns.Guide) then return nil end
	return ns.Guide.Hint((ns.Guide.Nearest(near)))
end

function Tracker.Refresh()
	local Gear = ns.Gear
	local ids = Gear and Gear.Tracked and Gear.Tracked() or {}
	if not ns.db or not ns.db.trackerShow or #ids == 0 then
		if frame then frame:Hide() end
		return
	end
	if not frame then Build() end
	local scale, old = (ns.db.trackerScale or 100) / 100, frame:GetScale()
	if math.abs(scale - old) > 0.001 then
		-- a new size keeps the top left corner where it is on screen
		local left, top = frame:GetLeft(), frame:GetTop()
		frame:SetScale(scale)
		if left and top then
			frame:ClearAllPoints()
			frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * old / scale, top * old / scale)
			if ns.db.windows.Tracker then
				ns.db.windows.Tracker = { point = "TOPLEFT", rel = "BOTTOMLEFT", x = left * old / scale, y = top * old / scale, scale = scale }
			end
		end
	end
	frame.title:SetText(("Tracked: %d"):format(#ids))
	local folded = ns.db.trackerCollapsed
	frame.fold:SetLabel(folded and "+" or "-")
	local n = 0
	if not folded then
		local here, inside = HereMaps(), Inside()
		local target = ns.Guide and ns.Guide.Target()
		-- what can be had around here first, then the biggest gain
		local rows = {}
		for i = 1, #ids do
			local id = ids[i]
			local hint = Hint(Ways(id), here, inside)
			rows[i] = { id = id, hint = hint, worth = Worth(id) }
		end
		table.sort(rows, function(a, b)
			if (a.hint ~= nil) ~= (b.hint ~= nil) then return a.hint ~= nil end
			local da, db = a.worth.delta or -math.huge, b.worth.delta or -math.huge
			if da ~= db then return da > db end
			return a.id < b.id
		end)
		n = math.min(#rows, MAX_ROWS)
		for i = 1, n do
			local entry = rows[i]
			local id = entry.id
			local row = pool:Get(i)
			row.id = id
			local name, quality = Name(id)
			row.icon:SetItem(id, quality)
			if target and target.item == id then row.icon:SetEdge(C.GOLD) end
			row.gain:SetText(entry.worth.text or "")
			row.name:SetText(name)
			UI.Color(row.name, UI.QUALITY[quality or 1] or C.TEXT)
			row.source:SetText(Summary(id))
			row.hint:SetText(entry.hint or "")
		end
	end
	pool:HideFrom(n + 1)
	local extra = folded and 0 or #ids - n
	frame.more:SetShown(extra > 0)
	if extra > 0 then frame.more.text:SetText(("More: %d"):format(extra)) end
	local height = HEAD + n * ROW + (extra > 0 and 18 or 0) + (n > 0 and 4 or 0)
	if math.abs((frame:GetHeight() or 0) - height) > 0.5 then
		local left, top = frame:GetLeft(), frame:GetTop()
		if left and top then
			frame:ClearAllPoints()
			frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
		end
		frame:SetHeight(height)
	end
	frame:Show()
end

-- Got it ------------------------------------------------------------------------------

local function BuildToast()
	toast = UI.Box(UIParent, C.BLACK, 0.92, C.GOLD)
	toast:SetSize(250, 50)
	toast:SetFrameStrata("HIGH")
	toast:SetPoint("TOP", UIParent, "TOP", 0, -220)
	toast.icon = UI.Icon(toast, 36)
	toast.icon:SetPoint("LEFT", 7, 0)
	toast.icon:EnableMouse(false)
	toast.head = UI.Heading(toast, 16)
	toast.head:SetPoint("TOPLEFT", 52, -7)
	toast.head:SetText("Got it")
	toast.name = UI.Text(toast, "GameFontHighlightSmall", C.TEXT)
	toast.name:SetPoint("BOTTOMLEFT", 52, 9)
	toast.name:SetPoint("RIGHT", -8, 0)
	toast:SetScript("OnUpdate", function(self, elapsed)
		self.age = (self.age or 0) + elapsed
		if self.age < TOAST_HOLD then return end
		local left = 1 - (self.age - TOAST_HOLD) / TOAST_FADE
		if left <= 0 then
			self:Hide()
		else
			self:SetAlpha(left)
		end
	end)
	toast:Hide()
end

function Tracker.Toast(id, shown, head)
	if not toast then BuildToast() end
	local name, quality = Name(id)
	name = shown or name
	toast.head:SetText(head or "Got it")
	toast.icon:SetItem(id, quality)
	toast.name:SetText(name)
	UI.Color(toast.name, UI.QUALITY[quality or 1] or C.TEXT)
	toast.age = 0
	toast:SetAlpha(1)
	toast:Show()
end

local function WantedSuffix(id)
	local hunts = ns.char and ns.char.hunts
	return hunts and hunts.suffix and hunts.suffix[id] or nil
end

-- The item in hand counts when it has the tracked suffix. An unreadable suffix counts too.
local function Fits(id, link)
	local wanted = WantedSuffix(id)
	local Gear = ns.Gear
	if not wanted or not Gear.LinkSuffixID then return true end
	link = ns.Plain(link)
	local has = type(link) == "string" and Gear.LinkSuffixID(link) or nil
	return has == nil or has == wanted
end

local function Got(id, link)
	local Gear = ns.Gear
	local name = Name(id) -- before the hunt and its suffix are cleared
	link = ns.Plain(link)
	local shown = type(link) == "string" and link or Link(id) or name
	local suffix = WantedSuffix(id) or (type(link) == "string" and Gear.LinkSuffixID and Gear.LinkSuffixID(link)) or nil
	Gear.SetState(id, "done", suffix)
	Gear.Track(id, false)
	local target = ns.Guide and ns.Guide.Target()
	if target and target.item == id then ns.Guide.Clear() end
	if ns.db.trackerToast then Tracker.Toast(id, name) end
	ns.Print("Got it: " .. shown)
end

-- Marks tracked items the player now has.
function Tracker.Check()
	local Gear = ns.Gear
	if not (Gear and Gear.Tracked and Gear.SetState and Gear.Track) then return end
	local ids = Gear.Tracked()
	if not ids or #ids == 0 then return end
	local want = {}
	for i = 1, #ids do want[ids[i]] = true end
	local have = {}
	for slot = 1, 19 do
		local id = GetInventoryItemID and GetInventoryItemID("player", slot)
		if id and want[id] and not have[id] then
			local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
			if Fits(id, link) then have[id] = link or true end
		end
	end
	if C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemID then
		for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4 do
			for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
				local id = C_Container.GetContainerItemID(bag, slot)
				if id and want[id] and not have[id] then
					local link = C_Container.GetContainerItemLink and C_Container.GetContainerItemLink(bag, slot)
					if Fits(id, link) then have[id] = link or true end
				end
			end
		end
	end
	for i = 1, #ids do
		if have[ids[i]] then ns.Safe(Got, ids[i], have[ids[i]]) end
	end
end

-- Events ------------------------------------------------------------------------------

local check = ns.Debounce(0.3, Tracker.Check)
ns.On("BAG_UPDATE_DELAYED", check)
ns.On("PLAYER_EQUIPMENT_CHANGED", check)

local refresh = ns.Debounce(0.1, Tracker.Refresh)
ns.Listen("HUNTS_CHANGED", function()
	worth = {}
	refresh()
	check() -- a newly tracked item may already be in the bags
end)
-- what an item is worth changes with what is worn and with the spec
for _, message in ipairs({ "GEAR_CHANGED", "CONTEXT_CHANGED" }) do
	ns.Listen(message, function()
		worth = {}
		refresh()
	end)
end
ns.Listen("GUIDE_CHANGED", refresh)
ns.Listen("SETTINGS_CHANGED", function(key)
	if type(key) == "string" and key:find("^tracker") then Tracker.Refresh() end
end)
ns.On("ZONE_CHANGED_NEW_AREA", refresh)
-- Item data comes for every item any addon asks about, in bursts (an auction scan): only a
-- tracked item's name can change a row.
ns.On("GET_ITEM_INFO_RECEIVED", function(_, id)
	id = ns.Plain(id)
	local Gear = ns.Gear
	if frame and frame:IsShown() and (type(id) ~= "number" or not (Gear and Gear.IsTracked) or Gear.IsTracked(id)) then refresh() end
end)

ns.OnLoad(function()
	Tracker.Refresh()
	check()
	-- distance hints
	C_Timer.NewTicker(2, function()
		if frame and frame:IsShown() and not ns.db.trackerCollapsed then ns.Safe(Tracker.Refresh) end
	end)
end)

-- Slash -------------------------------------------------------------------------------

ns.Command("track", "Tracked items. Track: <item link or name>", function(rest)
	-- a link, an id or a name of the data (Wanted.Find)
	local item = ns.Wanted and ns.Wanted.Find and ns.Wanted.Find(rest) or rest
	local id = ns.ItemID(item)
	local Gear = ns.Gear
	if not id then
		if rest and rest:match("%S") then
			ns.Print("Use: /lm track <item link or name>")
		else
			ns.Main.Toggle("tracked")
		end
		return
	end
	if not (Gear and Gear.Track) then return end
	if ns.Wanted and ns.Wanted.Add then
		-- the tracked list's own way in: an id neither the data nor the game knows is refused
		if not ns.Wanted.Add(item) then
			ns.Print("Track: no such item")
			return
		end
	else
		local suffix = type(item) == "string" and Gear.LinkSuffixID and Gear.LinkSuffixID(item) or nil
		Gear.Track(id, true, suffix)
	end
	ns.Print("Tracked: " .. (Link(id) or (Name(id))))
end)

ns.Command("untrack", "Untrack: <item link> or all", function(rest)
	local Gear = ns.Gear
	if not (Gear and Gear.Track) then return end
	if rest:lower() == "all" then
		local ids = Gear.Tracked() or {}
		local copy = {}
		for i = 1, #ids do copy[i] = ids[i] end
		for i = 1, #copy do Gear.Track(copy[i], false) end
		ns.Print(("Untracked: %d"):format(#copy))
		return
	end
	local id = ns.ItemID(rest)
	if not id then
		ns.Print("Use: /lm untrack <item link> or all")
		return
	end
	local shown = Link(id) or (Name(id)) -- before the hunt and its suffix are cleared
	if not Gear.IsTracked(id) then
		ns.Print("Not tracked: " .. shown)
		return
	end
	Gear.Track(id, false)
	ns.Print("Untracked: " .. shown)
end)
