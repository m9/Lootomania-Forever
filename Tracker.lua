local _, ns = ...

-- Tracker: a small list of tracked upgrades on screen.
--   ns.Tracker.Refresh()
--   ns.Tracker.Check()        looks for tracked items in bags and on the character
--   ns.Tracker.Toast(itemId)  the "Got it" message
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

-- Name with the suffix to look for.
local function Name(id)
	if ns.Gear and ns.Gear.Name then
		local name, quality = ns.Gear.Name(id)
		if name then return name, quality end
	end
	local item = ns.Gear and ns.Gear.Item and ns.Gear.Item(id)
	if item and item.name then return item.name, item.quality end
	local name, _, quality = C_Item.GetItemInfo(id)
	return name or ("Item " .. tostring(id)), quality
end

local function Link(id)
	local _, link = C_Item.GetItemInfo(id)
	return link
end

local function FirstSource(id)
	local sources = ns.Gear and ns.Gear.Sources and ns.Gear.Sources(id)
	return sources and sources[1] or nil
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
		elseif not ns.Guide.SetSource(FirstSource(id), id) then
			ns.Print("No spot known.")
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
	row.name = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
	row.name:SetPoint("TOPLEFT", ROW + 2, -3)
	row.name:SetPoint("RIGHT", -2, 0)
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
		UI.ItemTooltip(self, ns.Gear.Link and ns.Gear.Link(self.id) or self.id, "ANCHOR_LEFT")
		GameTooltip:AddLine("Click: guide", C.GOLD_SOFT[1], C.GOLD_SOFT[2], C.GOLD_SOFT[3])
		GameTooltip:AddLine("Right-click: untrack", C.GOLD_SOFT[1], C.GOLD_SOFT[2], C.GOLD_SOFT[3])
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
	local saved = ns.db.windows.Tracker
	if saved and saved.x then
		frame:SetPoint(saved.point or "CENTER", UIParent, saved.point or "CENTER", saved.x, saved.y)
	else
		frame:SetPoint("RIGHT", UIParent, "RIGHT", -60, 60)
	end
	frame:SetScript("OnDragStart", function(self)
		if not ns.db.trackerLock then self:StartMoving() end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint(1)
		ns.db.windows.Tracker = { point = point, x = x, y = y }
	end)

	frame.title = UI.Heading(frame, 14)
	frame.title:SetPoint("TOPLEFT", 8, -5)
	frame.fold = UI.Button(frame, "-", 18, 16)
	frame.fold:SetPoint("TOPRIGHT", -4, -4)
	frame.fold:SetScript("OnClick", function()
		ns.db.trackerCollapsed = not ns.db.trackerCollapsed
		Tracker.Refresh()
	end)
	frame.more = UI.Text(frame, "GameFontHighlightSmall", C.MUTED, 11)
	frame.more:SetPoint("BOTTOMLEFT", 8, 5)
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

local function Hint(source, here)
	if not (source and type(source.spots) == "table" and ns.Guide) then return nil end
	local near
	for i = 1, #source.spots do
		local spot = source.spots[i]
		if here[spot.map] then
			near = near or {}
			near[#near + 1] = spot
		end
	end
	if not near then return nil end
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
	frame:SetScale((ns.db.trackerScale or 100) / 100)
	frame.title:SetText(("Upgrades: %d"):format(#ids))
	local folded = ns.db.trackerCollapsed
	frame.fold:SetLabel(folded and "+" or "-")
	local n = 0
	if not folded then
		local here = HereMaps()
		local target = ns.Guide and ns.Guide.Target()
		n = math.min(#ids, MAX_ROWS)
		for i = 1, n do
			local id = ids[i]
			local row = pool:Get(i)
			row.id = id
			local name, quality = Name(id)
			local source = FirstSource(id)
			row.icon:SetItem(id, quality)
			if target and target.item == id then row.icon:SetEdge(C.GOLD) end
			row.name:SetText(name)
			UI.Color(row.name, UI.QUALITY[quality or 1] or C.TEXT)
			row.source:SetText(source and (source.text or source.name) or "Source: unknown")
			row.hint:SetText(Hint(source, here) or "")
		end
	end
	pool:HideFrom(n + 1)
	local extra = folded and 0 or #ids - n
	frame.more:SetShown(extra > 0)
	if extra > 0 then frame.more:SetText(("More: %d"):format(extra)) end
	frame:SetHeight(HEAD + n * ROW + (extra > 0 and 18 or 0) + (n > 0 and 4 or 0))
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

function Tracker.Toast(id, shown)
	if not toast then BuildToast() end
	local name, quality = Name(id)
	name = shown or name
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
	local suffix = WantedSuffix(id)
	Gear.SetState(id, "done", suffix)
	Gear.Track(id, false)
	local target = ns.Guide and ns.Guide.Target()
	if target and target.item == id then ns.Guide.Clear() end
	if ns.db.trackerToast then Tracker.Toast(id, name) end
	link = ns.Plain(link)
	ns.Print("Got it: " .. (type(link) == "string" and link or Link(id) or name))
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
	refresh()
	check() -- a newly tracked item may already be in the bags
end)
ns.Listen("GUIDE_CHANGED", refresh)
ns.Listen("SETTINGS_CHANGED", function(key)
	if type(key) == "string" and key:find("^tracker") then Tracker.Refresh() end
end)
ns.On("ZONE_CHANGED_NEW_AREA", refresh)
ns.On("GET_ITEM_INFO_RECEIVED", function()
	if frame and frame:IsShown() then refresh() end
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

ns.Command("track", "Track: <item link>", function(rest)
	local id = ns.ItemID(rest)
	local Gear = ns.Gear
	if not id then
		ns.Print("Use: /lm track <item link>")
		return
	end
	if not (Gear and Gear.Track) then return end
	local suffix = Gear.LinkSuffixID and Gear.LinkSuffixID(rest) or nil
	if Gear.State and Gear.State(id, suffix) then Gear.SetState(id, nil, suffix) end
	Gear.Track(id, true, suffix)
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
	Gear.Track(id, false)
	ns.Print("Untracked: " .. (Link(id) or (Name(id))))
end)
