local _, ns = ...

-- Upgrade arrows on quest reward, loot and merchant buttons.
-- Only reads Blizzard frames and adds textures to them; no scripts are replaced.

local UI = ns.UI
local C = UI.C
local Arrows = {}
ns.Arrows = Arrows

ns.Main.AddOption({ group = "Tooltips", key = "arrowOn", kind = "check", label = "Upgrade arrows", default = true,
	tip = "On quest rewards, loot and merchants." })

local ATLAS = "bags-greenarrow"
local TEXTURE = "Interface\\Buttons\\Arrow-Up-Up"
local SIZE = 16

local gains = {} -- link -> gain (points or score), or false
local overlays = setmetatable({}, { __mode = "k" }) -- button -> { arrow, ring }
local surfaces = {} -- name -> { button = used this pass }

local function On() return ns.db and ns.db.arrowOn and ns.Gear and ns.Gear.Compare and true or false end

-- Gain of an item over worn gear when it is an upgrade, else nil.
function Arrows.Gain(link)
	link = ns.Plain(link)
	if type(link) ~= "string" or link == "" or not ns.Gear or not ns.Gear.Compare then return nil end
	local gain = gains[link]
	if gain == nil then
		gain = false
		local ok, c = pcall(ns.Gear.Compare, link)
		if ok and type(c) == "table" and c.usable ~= false and type(c.delta) == "number" and c.delta > 0 then
			gain = type(c.gain) == "number" and c.gain > 0 and c.gain or c.delta
		end
		gains[link] = gain
	end
	return gain or nil
end

function Arrows.IsUpgrade(link) return Arrows.Gain(link) ~= nil end

local function PaintArrow(t)
	local info
	if C_Texture and C_Texture.GetAtlasInfo then
		local ok, found = pcall(C_Texture.GetAtlasInfo, ATLAS)
		info = ok and found
	end
	if info and t.SetAtlas and pcall(t.SetAtlas, t, ATLAS) then return end
	if t:SetTexture(TEXTURE) == false then
		t:SetColorTexture(C.GREEN[1], C.GREEN[2], C.GREEN[3], 1) -- plain square when the file is missing
	else
		t:SetVertexColor(0.25, 1, 0.25)
	end
end

local function IconOf(button)
	local icon = button.Icon or button.icon or button.IconTexture
	if not icon then
		local name = button.GetName and button:GetName()
		icon = name and (_G[name .. "IconTexture"] or _G[name .. "Icon"])
	end
	if type(icon) == "table" and icon.GetObjectType then return icon end
	return button
end

local function Overlay(button)
	local o = overlays[button]
	if o then return o end
	local icon = IconOf(button)
	o = { ring = {} }
	o.arrow = button:CreateTexture(nil, "OVERLAY", nil, 7)
	o.arrow:SetSize(SIZE, SIZE)
	o.arrow:SetPoint("TOPLEFT", icon, "TOPLEFT", -2, 2)
	PaintArrow(o.arrow)
	o.arrow:Hide()
	-- gold ring: four thin edges around the icon
	for i, edge in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
		local t = button:CreateTexture(nil, "OVERLAY", nil, 6)
		t:SetColorTexture(C.GOLD[1], C.GOLD[2], C.GOLD[3], 1)
		t:SetPoint(edge[1], icon, edge[1], 0, 0)
		t:SetPoint(edge[2], icon, edge[2], 0, 0)
		if i <= 2 then t:SetHeight(2) else t:SetWidth(2) end
		t:Hide()
		o.ring[i] = t
	end
	overlays[button] = o
	return o
end

local function Paint(button, arrow, ring)
	local o = overlays[button]
	if not o then
		if not arrow and not ring then return end
		o = Overlay(button)
	end
	o.arrow:SetShown(arrow and true or false)
	for i = 1, #o.ring do o.ring[i]:SetShown(ring and true or false) end
end

-- Shows or hides the arrow on a button for an item link. ring: gold ring too.
-- Returns the gain when the item is an upgrade.
function Arrows.Mark(button, link, ring)
	if not button then return nil end
	local gain = On() and Arrows.Gain(link) or nil
	Paint(button, gain, ring and gain)
	return gain
end

function Arrows.Hide(button) Paint(button, false, false) end

-- State of a button, for tests and other modules: arrow shown, ring shown.
function Arrows.State(button)
	local o = overlays[button]
	if not o then return false, false end
	return o.arrow:IsShown(), o.ring[1]:IsShown()
end

-- A surface remembers its buttons so that reused ones lose a stale arrow.
local function Begin(name)
	local s = surfaces[name]
	if not s then
		s = setmetatable({}, { __mode = "k" })
		surfaces[name] = s
	end
	for button in pairs(s) do s[button] = false end
	return s
end

local function End(s)
	for button, used in pairs(s) do
		if not used then Arrows.Hide(button) end
	end
end

local function Call(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, value = pcall(fn, ...)
	return ok and ns.Plain(value) or nil
end

local function Shown(frame)
	return frame and frame.IsVisible and frame:IsVisible() or false
end

-- Quest rewards ---------------------------------------------------------------------

local function AddRewardButtons(frame, out, fromLog)
	local list = frame and frame.RewardButtons
	if type(list) ~= "table" then return end
	for i = 1, #list do out[#out + 1] = { button = list[i], log = fromLog } end
end

function Arrows.UpdateQuest()
	local s = Begin("quest")
	if On() then
		local found = {}
		AddRewardButtons(_G.QuestInfoRewardsFrame, found, nil)
		AddRewardButtons(_G.MapQuestInfoRewardsFrame, found, true)
		if #found == 0 then
			-- older frames: named buttons
			for i = 1, 10 do
				if _G["QuestInfoItem" .. i] then found[#found + 1] = { button = _G["QuestInfoItem" .. i] } end
				if _G["QuestLogItem" .. i] then found[#found + 1] = { button = _G["QuestLogItem" .. i], log = true } end
			end
		end
		local inLog = _G.QuestInfoFrame and _G.QuestInfoFrame.questLog
		local best, bestGain, choices = nil, 0, 0
		local marked = {}
		for _, entry in ipairs(found) do
			local button = entry.button
			local kind = button.type
			if Shown(button) and (kind == "choice" or kind == "reward") and (button.objectType == nil or button.objectType == "item") then
				local log = entry.log
				if log == nil then log = inLog and true or false end
				local link = Call(log and GetQuestLogItemLink or GetQuestItemLink, kind, button:GetID())
				local gain = Arrows.Gain(link)
				s[button] = true
				marked[#marked + 1] = { button = button, gain = gain }
				if kind == "choice" then
					choices = choices + 1
					if gain and gain > bestGain then best, bestGain = button, gain end
				end
			end
		end
		for _, m in ipairs(marked) do
			Paint(m.button, m.gain, m.gain and choices > 1 and m.button == best)
		end
	end
	End(s)
end

-- Loot window -----------------------------------------------------------------------

local function LootSlot(row)
	local slot = Call(row.GetSlotIndex, row)
	if type(slot) == "number" and slot >= 1 then return slot end
	local data = Call(row.GetElementData, row)
	slot = type(data) == "table" and ns.Plain(data.slotIndex) or nil
	if type(slot) == "number" and slot >= 1 then return slot end
	return nil
end

function Arrows.UpdateLoot()
	local s = Begin("loot")
	local frame = _G.LootFrame
	if On() and Shown(frame) and GetLootSlotLink then
		local box = frame.ScrollBox
		if box and box.ForEachFrame then
			pcall(box.ForEachFrame, box, function(row)
				local slot = LootSlot(row)
				local button = row.Item or row
				if slot and Shown(row) and button.CreateTexture then
					s[button] = true
					Arrows.Mark(button, Call(GetLootSlotLink, slot))
				end
			end)
		else
			-- older frame: LootButton1..N
			for i = 1, LOOTFRAME_NUMBUTTONS or 4 do
				local button = _G["LootButton" .. i]
				local slot = button and ns.Plain(button.slot)
				if type(slot) == "number" and Shown(button) then
					s[button] = true
					Arrows.Mark(button, Call(GetLootSlotLink, slot))
				end
			end
		end
	end
	End(s)
end

-- Merchant --------------------------------------------------------------------------

function Arrows.UpdateMerchant()
	local s = Begin("merchant")
	local frame = _G.MerchantFrame
	if On() and Shown(frame) and GetMerchantItemLink and frame.selectedTab ~= 2 then
		for i = 1, MERCHANT_ITEMS_PER_PAGE or 10 do
			local button = _G["MerchantItem" .. i .. "ItemButton"]
			if Shown(button) then
				local index = button:GetID()
				if type(index) == "number" and index > 0 then
					s[button] = true
					Arrows.Mark(button, Call(GetMerchantItemLink, index))
				end
			end
		end
	end
	End(s)
end

-- All surfaces ----------------------------------------------------------------------

function Arrows.Refresh()
	ns.Safe(Arrows.UpdateQuest)
	ns.Safe(Arrows.UpdateLoot)
	ns.Safe(Arrows.UpdateMerchant)
	-- other addons that draw their own item buttons
	if _G.EllesmereUI and type(_G.EllesmereUI.RefreshMerchantItems) == "function" then pcall(_G.EllesmereUI.RefreshMerchantItems) end
end

local later = ns.Debounce(0.1, Arrows.Refresh)

local function Reset()
	wipe(gains)
	later()
	local api = _G.Baganator and _G.Baganator.API
	if api and api.IsUpgradePluginActive and api.RequestItemButtonsRefresh then
		local ok, active = pcall(api.IsUpgradePluginActive, "lootomania")
		if ok and active then pcall(api.RequestItemButtonsRefresh) end
	end
end
Arrows.Reset = Reset

local function Hook(name, fn)
	if type(_G[name]) == "function" then
		hooksecurefunc(name, function() ns.Safe(fn) end)
		return true
	end
	return false
end

local hooks = {}
Arrows.hooks = hooks -- what was found on this client, for /lm debug checks

ns.OnLoad(function()
	hooks.questDisplay = Hook("QuestInfo_Display", Arrows.UpdateQuest)
	hooks.questRewards = Hook("QuestInfo_ShowRewards", Arrows.UpdateQuest)
	hooks.lootUpdate = Hook("LootFrame_Update", Arrows.UpdateLoot)
	hooks.merchant = Hook("MerchantFrame_Update", Arrows.UpdateMerchant)

	local box = _G.LootFrame and _G.LootFrame.ScrollBox
	if box and type(box.Update) == "function" then
		hooks.lootBox = pcall(hooksecurefunc, box, "Update", function() ns.Safe(Arrows.UpdateLoot) end)
	end

	-- EllesmereUI draws its own merchant tiles and rows
	local eui = _G.EllesmereUI
	if eui and type(eui.RegisterMerchantItemCallback) == "function" then
		hooks.ellesmere = pcall(eui.RegisterMerchantItemCallback, "Lootomania", function(button, index, _, _, buyback)
			if not button then return end
			Arrows.Mark(button, not buyback and Call(GetMerchantItemLink, index) or nil)
		end)
	end

	-- Baganator: bags show its own upgrade mark from our answer
	local api = _G.Baganator and _G.Baganator.API
	if api and type(api.RegisterUpgradePlugin) == "function" then
		hooks.baganator = pcall(api.RegisterUpgradePlugin, "Lootomania", "lootomania", function(link)
			return On() and Arrows.IsUpgrade(link) or false
		end)
	end
end)

for _, event in ipairs({ "QUEST_DETAIL", "QUEST_COMPLETE", "QUEST_LOG_UPDATE", "LOOT_OPENED", "LOOT_SLOT_CLEARED", "LOOT_SLOT_CHANGED",
	"MERCHANT_SHOW", "MERCHANT_UPDATE", "GET_ITEM_INFO_RECEIVED" }) do
	ns.On(event, later)
end

for _, message in ipairs({ "CONTEXT_CHANGED", "GEAR_CHANGED", "FILTERS_CHANGED" }) do
	ns.Listen(message, Reset)
end
ns.Listen("SETTINGS_CHANGED", function(key)
	if key == "arrowOn" then Reset() end
end)
