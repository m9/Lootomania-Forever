local ADDON, ns = ...

-- Character frame: a small button in the corner of every equipment slot. A click opens a
-- popup with the best upgrades for that slot. The button shows where the slot stands:
--   crown        the equipped item is rank 1 for the slot
--   orange ">"   a better item is known
--   quiet ">"    nothing better in the list
-- Both the mark and the popup look at every zone: the zone picked in the Upgrades tab does not
-- count here. The corners are plain buttons laid over the slots; the game's own slot buttons
-- are not changed, so their clicks work as before.

local UI = ns.UI
local C = UI.C
local P = {}
ns.PaperDoll = P

local TOP = 5 -- items in the popup

-- Slot frame name -> our slot key.
local FRAMES = {
	{ "CharacterHeadSlot", "Head" }, { "CharacterNeckSlot", "Neck" }, { "CharacterShoulderSlot", "Shoulder" },
	{ "CharacterBackSlot", "Back" }, { "CharacterChestSlot", "Chest" }, { "CharacterWristSlot", "Wrist" },
	{ "CharacterHandsSlot", "Hands" }, { "CharacterWaistSlot", "Waist" }, { "CharacterLegsSlot", "Legs" },
	{ "CharacterFeetSlot", "Feet" }, { "CharacterFinger0Slot", "Finger" }, { "CharacterFinger1Slot", "Finger" },
	{ "CharacterTrinket0Slot", "Trinket" }, { "CharacterTrinket1Slot", "Trinket" },
	{ "CharacterMainHandSlot", "MainHand" }, { "CharacterSecondaryHandSlot", "OffHand" },
	{ "CharacterRangedSlot", "Ranged" },
}

local corners = {} -- frame name -> corner button
local popup

local function Call(...) return ns.Upgrades.Call(...) end
local function List(...) return ns.Upgrades.List(...) end

local function Top(slot)
	return List("List", slot, nil, { count = TOP, anyZone = true })
end

-- Popup -----------------------------------------------------------------------------------------

local WIDTH, ROW = 330, 38

local function PopupRow(i)
	local row = CreateFrame("Frame", nil, popup)
	row:SetSize(WIDTH - 12, ROW - 2)
	row:SetPoint("TOPLEFT", 6, -34 - (i - 1) * ROW)
	row.back = UI.Fill(row, "BACKGROUND", C.PANEL, 0.9)
	row.back:SetAllPoints()
	row.icon = UI.Icon(row, 28)
	row.icon:SetPoint("LEFT", 4, 0)
	row.name = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
	row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -1)
	row.name:SetWidth(WIDTH - 12 - 44 - 62)
	row.source = UI.Text(row, "GameFontHighlightSmall", C.MUTED, 11)
	row.source:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 1)
	row.source:SetWidth(WIDTH - 12 - 44 - 8)
	row.delta = UI.Text(row, "GameFontHighlightSmall", C.TEXT)
	row.delta:SetPoint("TOPRIGHT", -6, -4)
	row.delta:SetWidth(56)
	row.delta:SetJustifyH("RIGHT")
	return row
end

local function BuildPopup()
	popup = CreateFrame("Frame", "LootomaniaSlotPopup", UIParent, "BackdropTemplate")
	UI.Panel(popup, C.BLACK, 0.97, C.GOLD_DIM)
	popup:SetFrameStrata("DIALOG")
	popup:SetClampedToScreen(true)
	popup:EnableMouse(true)
	popup:Hide()
	popup.title = UI.Heading(popup, 16)
	popup.title:SetPoint("TOPLEFT", 10, -9)
	local close = UI.Button(popup, "x", 20, 20)
	close:SetPoint("TOPRIGHT", -6, -6)
	close:SetScript("OnClick", function() popup:Hide() end)
	popup.pool = UI.Pool(PopupRow)
	popup.empty = UI.Text(popup, "GameFontHighlightSmall", C.FAINT)
	popup.empty:SetPoint("TOP", 0, -42)
	popup.empty:SetText("No items")
	popup.more = UI.Button(popup, "More", 70, 22)
	popup.more:SetPoint("BOTTOMRIGHT", -6, 6)
	popup.more:SetScript("OnClick", function()
		local slot = popup.slot
		popup:Hide()
		if slot then ns.Upgrades.OpenSlot(slot) end
	end)
	table.insert(UISpecialFrames, "LootomaniaSlotPopup")
end

local function FillPopup()
	local slot = popup.slot
	popup.title:SetText(ns.Upgrades.SlotLabel(slot))
	local list = Top(slot)
	local n = math.min(#list, TOP)
	for i = 1, n do
		local entry = list[i]
		local row = popup.pool:Get(i)
		row.icon:SetItem(entry.link or entry.id, entry.quality)
		row.name:SetText(ns.Upgrades.ItemName(entry))
		UI.Color(row.name, entry.quality and UI.QUALITY[entry.quality] or C.TEXT)
		row.source:SetText(entry.source and ns.Upgrades.SourceLine(entry.source) or "")
		row.delta:SetText(ns.Upgrades.DeltaText(entry))
	end
	popup.pool:HideFrom(n + 1)
	popup.empty:SetShown(n == 0)
	popup:SetSize(WIDTH, 34 + math.max(n, 1) * ROW + 34)
end

-- Shows the popup for a slot key, next to `anchor` (a frame) when given.
function P.Show(slot, anchor)
	if not popup then BuildPopup() end
	popup.slot = slot
	popup.anchor = anchor
	popup:ClearAllPoints()
	if anchor then
		popup:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
	else
		popup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
	FillPopup()
	popup:Show()
end

function P.Hide()
	if popup then popup:Hide() end
end

function P.IsShown()
	return popup ~= nil and popup:IsShown()
end

-- Corners -----------------------------------------------------------------------------------------

local function Enabled()
	return not ns.db or ns.db.paperDoll ~= false
end

local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\" -- drawn by build/media.lua
local ORANGE = { 1.00, 0.55, 0.10 }
local PAIRED = { Finger = true, Trinket = true } -- two frames, one list

local function PaintCorner(corner)
	local best = corner.state == "best"
	local c = best and C.GOLD or (corner.state == "better" and ORANGE or C.GOLD_DIM)
	if corner.over and corner.state ~= "better" then c = C.GOLD end
	corner.mark:SetTexture(MEDIA .. (best and "Crown" or "Chevron"))
	corner.mark:SetVertexColor(c[1], c[2], c[3], 1)
	corner.edge:SetColorTexture(c[1], c[2], c[3], corner.state and 1 or 0.6)
end

local function MakeCorner(slotFrame, slot)
	local corner = CreateFrame("Button", nil, slotFrame)
	corner.slot = slot
	corner.host = slotFrame
	corner:SetSize(14, 14)
	corner:SetPoint("TOPRIGHT", slotFrame, "TOPRIGHT", 1, 1)
	corner:SetFrameLevel((slotFrame:GetFrameLevel() or 1) + 5)
	-- "[>]": a dark box with a thin edge, the mark inside
	corner.edge = UI.Fill(corner, "BACKGROUND", C.GOLD_DIM, 1)
	corner.edge:SetAllPoints()
	corner.fill = UI.Fill(corner, "BORDER", C.BLACK, 1)
	corner.fill:SetPoint("TOPLEFT", 1, -1)
	corner.fill:SetPoint("BOTTOMRIGHT", -1, 1)
	corner.mark = corner:CreateTexture(nil, "ARTWORK")
	corner.mark:SetPoint("TOPLEFT", 1, -1)
	corner.mark:SetPoint("BOTTOMRIGHT", -1, 1)
	corner:SetScript("OnEnter", function(self)
		self.over = true
		PaintCorner(self)
		local lines = self.state == "best" and { "Best item for this slot." }
			or self.better and { "Better items: " .. self.better } or nil
		UI.TextTooltip(self, "Upgrades", lines)
	end)
	corner:SetScript("OnLeave", function(self)
		self.over = false
		PaintCorner(self)
		UI.HideTooltip()
	end)
	corner:SetScript("OnClick", function(self)
		if P.IsShown() and popup.anchor == self then
			P.Hide()
		else
			P.Show(self.slot, self)
		end
	end)
	PaintCorner(corner)
	return corner
end

-- The item in the corner's own slot frame.
local function FrameLink(corner)
	local host = corner.host
	local ok, id = pcall(function() return host.GetID and host:GetID() end)
	if not ok or type(id) ~= "number" or id <= 0 or not GetInventoryItemLink then return nil end
	local link = ns.Plain(GetInventoryItemLink("player", id))
	return type(link) == "string" and link or nil
end

-- "best", "better" (and how many) or nil for one corner.
local function State(corner, list)
	local link = FrameLink(corner)
	if link and Call("Rank", link) == 1 then return "best" end
	local better = 0
	if PAIRED[corner.slot] then
		-- two rings: each frame against its own ring, not against the weaker one
		local score = link and Call("Score", link)
		for _, entry in ipairs(list) do
			if not entry.worn and (type(score) ~= "number" or (entry.score or 0) > score) then better = better + 1 end
		end
	else
		local _, count = ns.Upgrades.Summary(list)
		better = count
	end
	if better > 0 then return "better", better end
	return nil
end

local function Mark()
	local lists = {}
	for _, corner in pairs(corners) do
		lists[corner.slot] = lists[corner.slot] or Top(corner.slot)
		local state, better = State(corner, lists[corner.slot])
		corner.state, corner.better = state, better
		PaintCorner(corner)
	end
end

local function Visible()
	return (PaperDollFrame and PaperDollFrame:IsVisible()) or (CharacterFrame and CharacterFrame:IsVisible()) or false
end

local update = ns.Debounce(0.2, function()
	if not Enabled() or not Visible() then return end
	Mark()
	if P.IsShown() then FillPopup() end
end)

local hooked = false

-- Makes the corners; safe to call again (slot frames can come late).
function P.Attach()
	local on = Enabled()
	for _, pair in ipairs(FRAMES) do
		local name, slot = pair[1], pair[2]
		local slotFrame = _G[name]
		if not corners[name] and on and type(slotFrame) == "table" and slotFrame.GetFrameLevel then
			local ok, corner = pcall(MakeCorner, slotFrame, slot)
			if ok then corners[name] = corner else ns.Debug(corner) end
		end
		if corners[name] then corners[name]:SetShown(on) end
	end
	local host = PaperDollFrame or CharacterFrame
	if not hooked and host and host.HookScript then
		hooked = true
		host:HookScript("OnShow", function()
			P.Attach()
			update()
		end)
		host:HookScript("OnHide", P.Hide)
	end
	if not on then P.Hide() end
end

ns.OnLoad(P.Attach)
ns.On("ADDON_LOADED", function() if ns.db and not hooked then P.Attach() end end)

for _, message in ipairs({ "CONTEXT_CHANGED", "GEAR_CHANGED", "HUNTS_CHANGED", "FILTERS_CHANGED" }) do
	ns.Listen(message, update)
end
ns.Listen("SETTINGS_CHANGED", function(key)
	if key == "paperDoll" then
		P.Attach()
		update()
	elseif key == "huntsPerSlot" then
		update()
	end
end)

ns.Main.AddOption({ group = "Upgrades", key = "paperDoll", kind = "check", label = "Character frame buttons", default = true, tip = "Button on each slot. Crown: best item. Orange: better item known. Click: best upgrades." })
