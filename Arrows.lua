local _, ns = ...

-- Upgrade arrows on quest reward, loot and merchant buttons.
-- Only reads Blizzard frames and adds textures to them; no scripts are replaced.

local UI = ns.UI
local C = UI.C
local Arrows = {}
ns.Arrows = Arrows

ns.Main.AddOption({ group = "Upgrades", key = "arrowOn", kind = "check", label = "Upgrade arrows", default = true,
	tip = "On quest rewards, loot and at vendors. Green: for your spec. Gold: for another spec of yours." })

local ATLAS = "bags-greenarrow"
local TEXTURE = "Interface\\Buttons\\Arrow-Up-Up"
local SIZE = 16

local gains = {} -- link -> gain (points or score), or false
local overlays = setmetatable({}, { __mode = "k" }) -- button -> { arrow, ring }
local surfaces = {} -- name -> { button = used this pass }

local function On() return ns.db and ns.db.arrowOn and ns.Gear and ns.Gear.Compare and true or false end

-- Gain of an item over worn gear when it is an upgrade, else nil. Always the player's own gain,
-- also while the Simulator previews another character.
-- Returns two numbers: the gain as shown ("+89": points on the scale of the item's own slot),
-- and the worth of that gain on one scale for all slots. Compare items of different slots by
-- the second: +100 on a trinket can be worth a third of +89 on a chest.
function Arrows.Gain(link)
	link = ns.Plain(link)
	if type(link) ~= "string" or link == "" or not ns.Gear or not ns.Gear.Compare then return nil end
	local gain = gains[link]
	if gain == nil then
		gain = false
		local ok, c = pcall(ns.Gear.Compare, link, ns.Gear.PlayerContext())
		if ok and type(c) == "table" and c.usable ~= false and type(c.delta) == "number" and c.delta > 0 then
			gain = { type(c.gain) == "number" and c.gain > 0 and c.gain or c.delta, c.delta }
		end
		gains[link] = gain
	end
	if not gain then return nil end
	return gain[1], gain[2]
end

function Arrows.IsUpgrade(link) return Arrows.Gain(link) ~= nil end

-- An item that is no upgrade for the spec in use and is one for another spec of the character:
-- that spec's gain and its name. nil otherwise.
local others = {} -- link -> { gain, label }, or false
function Arrows.OtherGain(link)
	link = ns.Plain(link)
	if type(link) ~= "string" or link == "" or not ns.Gear or not ns.Gear.OtherGains then return nil end
	local other = others[link]
	if other == nil then
		other = false
		if not Arrows.Gain(link) then
			local ok, list = pcall(ns.Gear.OtherGains, link, ns.Gear.PlayerContext())
			local best = ok and type(list) == "table" and list[1]
			if best and type(best.gain) == "number" then other = { best.gain, best.label } end
		end
		others[link] = other
	end
	if not other then return nil end
	return other[1], other[2]
end

-- Returns how the arrow was made, for Tint: "atlas", "texture" or "plain".
local function PaintArrow(t)
	local info
	if C_Texture and C_Texture.GetAtlasInfo then
		local ok, found = pcall(C_Texture.GetAtlasInfo, ATLAS)
		info = ok and found
	end
	if info and t.SetAtlas and pcall(t.SetAtlas, t, ATLAS) then return "atlas" end
	if t:SetTexture(TEXTURE) == false then
		t:SetColorTexture(C.GREEN[1], C.GREEN[2], C.GREEN[3], 1) -- plain square when the file is missing
		return "plain"
	end
	t:SetVertexColor(0.25, 1, 0.25)
	return "texture"
end

-- Green for the spec in use, gold for another spec of the character.
local function Tint(o, other)
	other = other and true or false
	if o.other == other then return end
	o.other = other
	local t, gold = o.arrow, C.GOLD
	if o.made == "atlas" then
		if t.SetDesaturated then t:SetDesaturated(other) end
		if other then t:SetVertexColor(gold[1], gold[2], gold[3]) else t:SetVertexColor(1, 1, 1) end
	elseif o.made == "texture" then
		if other then t:SetVertexColor(gold[1], gold[2], gold[3]) else t:SetVertexColor(0.25, 1, 0.25) end
	else
		local c = other and gold or C.GREEN
		t:SetColorTexture(c[1], c[2], c[3], 1)
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
	o.made = PaintArrow(o.arrow)
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

-- arrow: an upgrade for the spec in use. other: for another spec (a gold arrow). ring: gold ring too.
local function Paint(button, arrow, ring, other)
	local o = overlays[button]
	if not o then
		if not arrow and not ring and not other then return end
		o = Overlay(button)
	end
	o.arrow:SetShown((arrow or other) and true or false)
	Tint(o, other and not arrow)
	for i = 1, #o.ring do o.ring[i]:SetShown(ring and true or false) end
end

-- Shows or hides the arrow on a button for an item link. ring: gold ring too.
-- Returns the gain when the item is an upgrade for the spec in use.
function Arrows.Mark(button, link, ring)
	if not button then return nil end
	local on = On()
	local gain = on and Arrows.Gain(link) or nil
	Paint(button, gain, ring and gain, on and not gain and Arrows.OtherGain(link))
	return gain
end

function Arrows.Hide(button) Paint(button, false, false) end

-- State of a button, for tests and other modules: arrow shown, ring shown, the arrow is for
-- another spec.
function Arrows.State(button)
	local o = overlays[button]
	if not o then return false, false, false end
	return o.arrow:IsShown(), o.ring[1]:IsShown(), o.arrow:IsShown() and o.other or false
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
		-- the ring goes to the choice that is worth most, on the scale that is the same for all slots
		local best, bestWorth, choices = nil, 0, 0
		local marked = {}
		for _, entry in ipairs(found) do
			local button = entry.button
			local kind = button.type
			if Shown(button) and (kind == "choice" or kind == "reward") and (button.objectType == nil or button.objectType == "item") then
				local log = entry.log
				if log == nil then log = inLog and true or false end
				local link = Call(log and GetQuestLogItemLink or GetQuestItemLink, kind, button:GetID())
				local gain, worth = Arrows.Gain(link)
				s[button] = true
				marked[#marked + 1] = { button = button, gain = gain, other = not gain and Arrows.OtherGain(link) }
				if kind == "choice" then
					choices = choices + 1
					if worth and worth > bestWorth then best, bestWorth = button, worth end
				end
			end
		end
		for _, m in ipairs(marked) do
			Paint(m.button, m.gain, m.gain and choices > 1 and m.button == best, m.other)
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
	wipe(others)
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

-- Looted upgrades -------------------------------------------------------------------------------
-- A chat line when the player picks up an item that is better than what is worn: with auto-loot
-- the loot window and its arrows are never seen, and the bags show no mark of their own.

ns.Main.AddOption({ group = "Upgrades", key = "lootNote", kind = "check", label = "Looted upgrade message", default = true,
	tip = "Chat line when you pick up an item that is better than what you wear." })

-- The game's own lines for loot the player gets ("You receive loot: %s."), as patterns.
local selfLoot
local function SelfLoot()
	if selfLoot then return selfLoot end
	selfLoot = {}
	for _, key in ipairs({ "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE" }) do
		local text = _G[key]
		if type(text) == "string" and text ~= "" then
			selfLoot[#selfLoot + 1] = ns.ToPattern(text)
		end
	end
	return selfLoot
end

ns.On("CHAT_MSG_LOOT", function(_, message)
	if not (ns.db and ns.db.lootNote and ns.Gear and ns.Gear.Compare) then return end
	message = ns.Plain(message)
	if type(message) ~= "string" then return end
	local mine = false
	for _, pattern in ipairs(SelfLoot()) do
		if message:find(pattern) then
			mine = true
			break
		end
	end
	if not mine then return end
	local link = message:match("(|c.-|Hitem:.-|h.-|h|r)") or message:match("(|Hitem:.-|h.-|h)")
	if not link then return end
	-- a tracked item has its own "Got it" message
	local id = ns.ItemID(link)
	if id and ns.Gear.IsTracked and ns.Gear.IsTracked(id, ns.Gear.LinkSuffixID and ns.Gear.LinkSuffixID(link) or nil) then return end
	local gain = Arrows.Gain(link)
	if gain then
		ns.Print(("Upgrade looted: %s +%d"):format(link, math.max(1, math.floor(gain + 0.5))))
		return
	end
	local other, label = Arrows.OtherGain(link)
	if other then ns.Print(("Upgrade looted for %s: %s +%d"):format(label, link, math.max(1, math.floor(other + 0.5)))) end
end)
