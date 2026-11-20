local _, ns = ...

-- Wishlist: items the player picked by hand.
--   ns.db.wish[itemID] = link
--   ns.db.wishStats[itemID] = { tries, wins, boss, zone, at, added }
-- Sends "WISHLIST_CHANGED".

local UI = ns.UI
local C = UI.C
local W = {}
ns.Wish = W

ns.Defaults({ wish = {}, wishStats = {} })

local STAR = "|A:auctionhouse-icon-favorite:12:12|a "

local function Info(id)
	if not (C_Item and C_Item.GetItemInfo) then return nil end
	local ok, name, link, quality = pcall(C_Item.GetItemInfo, id)
	if ok then return name, link, quality end
	return nil
end

local function Stats(id)
	local s = ns.db.wishStats[id]
	if type(s) ~= "table" then
		s = { tries = 0, wins = 0 }
		ns.db.wishStats[id] = s
	end
	s.tries, s.wins = s.tries or 0, s.wins or 0
	return s
end

local function Changed()
	ns.Send("WISHLIST_CHANGED")
end

function W.Has(item)
	local id = ns.ItemID(item)
	return id ~= nil and ns.db ~= nil and ns.db.wish[id] ~= nil
end

-- Adds an item (ID or link). Returns the item ID, or nil when it is no item.
function W.Add(item)
	local id = ns.ItemID(item)
	if not id or id <= 0 then return nil end
	local link = type(item) == "string" and item:find("|Hitem:") and item or nil
	if not link then link = select(2, Info(id)) end
	if not link and C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
	local had = ns.db.wish[id]
	ns.db.wish[id] = link or had or ("item:" .. id)
	if not had then Stats(id).added = time() end
	Changed()
	return id
end

function W.Remove(item)
	local id = ns.ItemID(item)
	if not id or ns.db.wish[id] == nil then return false end
	ns.db.wish[id] = nil
	ns.db.wishStats[id] = nil
	Changed()
	return true
end

-- Adds or removes. Returns true when the item is on the list afterwards.
function W.Toggle(item)
	local id = ns.ItemID(item)
	if not id then return false end
	local link = type(item) == "string" and item:find("|H") and item or ns.db.wish[id] or select(2, Info(id)) or ("item " .. id)
	if W.Has(id) then
		W.Remove(id)
		ns.Print("Wishlist: removed " .. link)
		return false
	end
	if not W.Add(item) then return false end
	ns.Print("Wishlist: added " .. link)
	return true
end

-- The list, by name: { id, link, name, quality, tries, wins, boss, zone, at, added, source }.
function W.List()
	local list = {}
	for id, link in pairs(ns.db.wish) do
		local name, _, quality = Info(id)
		name = name or (type(link) == "string" and link:match("%[(.-)%]")) or ("Item " .. id)
		local s = Stats(id)
		local source
		if ns.Gear and ns.Gear.SourceText then
			local ok, text = pcall(ns.Gear.SourceText, id)
			source = ok and type(text) == "string" and text or nil
		end
		list[#list + 1] = {
			id = id, link = link, name = name, quality = quality, tries = s.tries, wins = s.wins,
			boss = s.boss, zone = s.zone, at = s.at, added = s.added, source = source,
		}
	end
	table.sort(list, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return a.id < b.id
	end)
	return list
end

function W.Count()
	local n = 0
	for _ in pairs(ns.db.wish) do n = n + 1 end
	return n
end

-- Item from typed text: a link, "item:123", an ID or a name the game knows.
local function Parse(text)
	if type(text) ~= "string" then return nil end
	text = text:match("^%s*(.-)%s*$")
	if text == "" then return nil end
	local link = text:match("(|c.-|Hitem:.-|h.-|h|r)") or text:match("(|Hitem:.-|h.-|h)")
	if link then return link end
	if ns.ItemID(text) then return ns.ItemID(text) end
	local _, found = Info(text)
	return found
end

-- Loot ----------------------------------------------------------------------------------------

ns.Listen("LOOT_DECIDED", function(drop, run)
	if not drop or not drop.id or not W.Has(drop.id) then return end
	local s = Stats(drop.id)
	s.tries = s.tries + 1
	if drop.me and drop.me.w then s.wins = s.wins + 1 end
	s.boss, s.zone, s.at = drop.boss, drop.zone or (run and run.zone), drop.at
	Changed()
end)

ns.Listen("LOOT_DROPPED", function(link)
	if ns.db.wishAlert == false or not W.Has(link) then return end
	ns.Print("Wishlist drop: " .. tostring(link))
end)

-- A full link replaces a bare "item:123" once the game knows the item.
local refresh = ns.Debounce(0.5, function()
	local any = false
	for id, link in pairs(ns.db.wish) do
		if type(link) ~= "string" or not link:find("|H") then
			local _, full = Info(id)
			if full then
				ns.db.wish[id] = full
				any = true
			end
		end
	end
	if any then Changed() else ns.Main.Refresh("wishlist") end
end)

ns.On("GET_ITEM_INFO_RECEIVED", function(_, id)
	id = ns.Plain(id)
	if id and ns.db and ns.db.wish[id] then refresh() end
end)

-- Tooltip line --------------------------------------------------------------------------------

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
	pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item, function(tooltip, data)
		if not ns.db or ns.db.wishTooltip == false then return end
		if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip and tooltip ~= ShoppingTooltip1 then return end
		local id = type(data) == "table" and ns.Plain(data.id) or nil
		if type(id) ~= "number" or not ns.db.wish[id] then return end
		local s = ns.db.wishStats[id]
		local text = STAR .. "Wishlist"
		if s and (s.tries or 0) > 0 then text = text .. ": seen " .. s.tries end
		tooltip:AddLine(text, C.GOLD[1], C.GOLD[2], C.GOLD[3])
	end)
end

-- Tab -------------------------------------------------------------------------------------------

local view = {}
local STEP = 42

local function AddFromBox()
	local item = Parse(view.box:GetText())
	if not item then
		ns.Print("Wishlist: no item")
		return
	end
	if W.Has(item) then
		ns.Print("Wishlist: already listed")
	elseif W.Add(item) then
		ns.Print("Wishlist: added " .. (ns.db.wish[ns.ItemID(item)] or ""))
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

local function MakeRow(i)
	local row = CreateFrame("Frame", nil, view.scroll.content)
	row:SetHeight(STEP - 2)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * STEP)
	row:SetPoint("TOPRIGHT", 0, -(i - 1) * STEP)
	row.back = UI.Fill(row, "BACKGROUND", C.PANEL, 0.9)
	row.back:SetAllPoints()
	row.icon = UI.Icon(row, 32)
	row.icon:SetPoint("LEFT", 4, 0)
	row.name = UI.Text(row, "GameFontHighlight", C.TEXT)
	row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -2)
	row.name:SetWidth(380)
	row.source = UI.Text(row, "GameFontHighlightSmall", C.MUTED)
	row.source:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 2)
	row.source:SetWidth(380)
	row.remove = UI.Button(row, "x", 22, 22)
	row.remove:SetPoint("RIGHT", -6, 0)
	row.remove:SetScript("OnClick", function() if row.id then W.Remove(row.id) end end)
	UI.Tip(row.remove, "Remove")
	row.count = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
	row.count:SetPoint("TOPRIGHT", row.remove, "TOPLEFT", -12, 1)
	row.count:SetWidth(300)
	row.count:SetJustifyH("RIGHT")
	row.seen = UI.Text(row, "GameFontHighlightSmall", C.MUTED)
	row.seen:SetPoint("BOTTOMRIGHT", row.remove, "BOTTOMLEFT", -12, -1)
	row.seen:SetWidth(300)
	row.seen:SetJustifyH("RIGHT")
	return row
end

local function Fill()
	local list = W.List()
	for i, entry in ipairs(list) do
		local row = view.pool:Get(i)
		row.id = entry.id
		row.icon:SetItem(entry.link or entry.id, entry.quality)
		row.name:SetText(entry.name)
		UI.Color(row.name, entry.quality and UI.QUALITY[entry.quality] or C.TEXT)
		row.source:SetText(entry.source or "")
		row.count:SetText("Seen: " .. entry.tries .. "   Won: " .. UI.Colored(entry.wins, entry.wins > 0 and C.GREEN or C.TEXT))
		if entry.at then
			local parts = {}
			if entry.boss then parts[#parts + 1] = entry.boss end
			if entry.zone then parts[#parts + 1] = entry.zone end
			parts[#parts + 1] = Ago(entry.at)
			row.seen:SetText("Last: " .. table.concat(parts, ", "))
		else
			row.seen:SetText("")
		end
	end
	view.pool:HideFrom(#list + 1)
	view.scroll.content:SetHeight(math.max(1, #list * STEP))
	view.empty:SetShown(#list == 0)
	view.total:SetText("Items: " .. #list)
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

	local add = UI.Button(panel, "Add", 60, 22)
	add:SetPoint("LEFT", view.box, "RIGHT", 6, 0)
	add:SetScript("OnClick", AddFromBox)

	local hint = UI.Text(panel, "GameFontHighlightSmall", C.FAINT)
	hint:SetPoint("LEFT", add, "RIGHT", 12, 0)
	hint:SetText("Shift-click or drop an item, or type an ID")

	view.total = UI.Text(panel, "GameFontHighlightSmall", C.MUTED)
	view.total:SetPoint("TOPRIGHT", -2, -7)

	local box = UI.Box(panel)
	box:SetPoint("TOPLEFT", 0, -32)
	box:SetPoint("BOTTOMRIGHT", 0, 0)
	view.scroll = UI.Scroll(box)
	view.scroll:SetPoint("TOPLEFT", 4, -4)
	view.scroll:SetPoint("BOTTOMRIGHT", -16, 4)
	view.pool = UI.Pool(MakeRow)
	view.empty = UI.Text(box, "GameFontHighlightSmall", C.FAINT)
	view.empty:SetPoint("TOP", 0, -14)
	view.empty:SetText("No items")

	if ChatFrameUtil and ChatFrameUtil.InsertLink then pcall(hooksecurefunc, ChatFrameUtil, "InsertLink", CatchLink) end
	if ChatEdit_InsertLink then pcall(hooksecurefunc, "ChatEdit_InsertLink", CatchLink) end
end

ns.Main.AddTab("wishlist", "Wishlist", 200, BuildTab, Fill)

ns.Listen("WISHLIST_CHANGED", function() ns.Main.Refresh("wishlist") end)

ns.Main.AddOption({ group = "Wishlist", key = "wishTooltip", kind = "check", label = "Mark in tooltips", default = true })
ns.Main.AddOption({ group = "Wishlist", key = "wishAlert", kind = "check", label = "Drop message", default = true, tip = "Chat line when a wishlist item drops." })

ns.Command("wish", "Wishlist. Add or remove: <item link>", function(rest)
	local item = Parse(rest)
	if item then
		W.Toggle(item)
	elseif rest and rest:match("%S") then
		ns.Print("Wishlist: no item")
	else
		ns.Main.Toggle("wishlist")
	end
end)
