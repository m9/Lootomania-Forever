local ADDON, ns = ...

-- Item tooltips, in blocks with an empty line between them:
--   rank line for the spec in use, then one small grey line per other spec
--   recommended enchant
--   random suffix and its stats (above the game's "Requires Level" line when the client lets us in there)
--   stat changes against the worn item
--   source, tracked mark
-- All numbers come from ns.Gear; nothing is shown when that module is missing.

local UI = ns.UI
local C = UI.C
local Tip = {}
ns.Tip = Tip

ns.Main.AddOption({ group = "Tooltips", key = "tipOn", kind = "check", label = "Item score", default = true })
ns.Main.AddOption({ group = "Tooltips", key = "tipSource", kind = "check", label = "Item source", default = true })
ns.Main.AddOption({ group = "Tooltips", key = "tipEnchant", kind = "check", label = "Best enchant", default = true })
ns.Main.AddOption({ group = "Tooltips", key = "tipSuffix", kind = "check", label = "Suffix stats", default = true })
ns.Main.AddOption({ group = "Tooltips", key = "tipOtherSpecs", kind = "check", label = "Ranks for other specs", default = true })
ns.Main.AddOption({ group = "Tooltips", key = "tipStats", kind = "check", label = "Stat changes", default = true })
ns.Main.AddOption({ group = "Tooltips", key = "tipHideDelta", kind = "check", label = "Hide the game's stat changes", default = true,
	tip = "The \"If you replace this item\" lines of the compare tooltip." })

local REASON = { class = "class", armor = "armor type", weapon = "weapon type", faction = "faction" }
local CACHE_MAX = 300

local cache = {} -- key -> list of { left, right, small = true, blank = true }, or false for "no block"
local cached = 0
local done = setmetatable({}, { __mode = "k" }) -- tooltip -> true once our block is on it
local hooked = setmetatable({}, { __mode = "k" }) -- tooltip -> true once OnTooltipCleared is hooked
local shrunk = setmetatable({}, { __mode = "k" }) -- tooltip -> font strings we made small
local inlined = setmetatable({}, { __mode = "k" }) -- tooltip -> true once the suffix lines sit above "Requires Level"

function Tip.Clear()
	wipe(cache)
	cached = 0
end

local function Label(text) return UI.Colored(text .. ": ", C.GOLD) end

local function Round(n) return math.floor(n + 0.5) end

-- The green arrow of the bag upgrade mark, when this client has it.
-- It sits after the number, at the right edge, so numbers and arrows line up from row to row.
-- Rows without an arrow get a gap of the same width.
local arrow, down, gap
-- kind: "up", "down" or nil for the gap
local function Mark(kind)
	if arrow == nil then
		arrow, down, gap = "", "", ""
		if C_Texture and C_Texture.GetAtlasInfo then
			local ok, info = pcall(C_Texture.GetAtlasInfo, "bags-greenarrow")
			if ok and info then
				arrow = " |A:bags-greenarrow:12:12|a"
				down = " |TInterface\\AddOns\\" .. ADDON .. "\\Media\\ArrowDown:12:12|t" -- our own, drawn by build/media.lua
				gap = " |TInterface\\Common\\spacer:12:12|t"
			end
		end
	end
	if kind == "up" then return arrow end
	if kind == "down" then return down end
	return gap
end

-- A gain in points (Gear.Compare's gain: 100 is the best item of the slot at this level).
-- "+25" in green with an arrow, "-8" in red, "Same" in grey. A real change never reads as 0.
function Tip.Gain(gain)
	if type(gain) ~= "number" then return nil end
	if gain == 0 then return UI.Colored("Same", C.MUTED) .. Mark() end
	local n = Round(math.abs(gain))
	if n < 1 then n = 1 end
	if gain > 0 then return UI.Colored("+" .. n, C.GREEN) .. Mark("up") end
	return UI.Colored("-" .. n, C.RED) .. Mark("down")
end

local function SpecIcon(Gear, class, spec)
	local icon = Gear.SpecIcon and class and spec and Gear.SpecIcon(class, spec)
	if not icon then return "" end
	return "|T" .. icon .. ":14:14:0:0:64:64:5:59:5:59|t "
end

-- "Rank #3 @ Level 26", and the gain on the right.
local function RankLine(Gear, ctx, c, color, indent)
	local text = (c.rank and ("Rank #" .. c.rank) or "Not ranked") .. " @ Level " .. tostring(ctx.level or "?")
	local right = c.isWorn and (UI.Colored("Equipped", C.GREEN) .. Mark()) or Tip.Gain(c.gain)
	return { (indent or "") .. SpecIcon(Gear, ctx.class, ctx.spec) .. UI.Colored(text, color), right }
end

-- Random suffix: the best one for this spec, then a line per stat, like the game's own stat lines.
-- Only for an item whose link has no suffix yet. An item with a suffix of its own gets nothing,
-- also when a better one exists: every suffix is ranked as an item of its own, so the rank line
-- already speaks for it.
local function SuffixBlock(Gear, link)
	local list = Gear.Suffixes and Gear.Suffixes(link)
	local best = type(list) == "table" and list[1]
	if not best then return nil end
	for i = 1, #list do
		if list[i].current then return nil end
	end
	local block = { { Label("Suffix") .. UI.Colored(best.name, C.SUFFIX) } }
	for _, stat in ipairs(best.lines or {}) do block[#block + 1] = { stat } end
	return block
end

local ATTR = { str = "Strength", agi = "Agility", sta = "Stamina", int = "Intellect", spi = "Spirit" }

local function SignedText(v)
	if math.abs(v) < 0.05 and math.abs(v) >= 0.005 then return ("%+.2f"):format(v) end -- too small for one decimal
	-- one decimal, like the character sheet: the rates behind crit and dodge are not exact enough for two
	if math.abs(v - Round(v)) < 0.05 then return ("%+d"):format(Round(v)) end
	return ("%+.1f"):format(v)
end

local function StatValue(v, unit)
	return UI.Colored(SignedText(v) .. (unit or ""), v > 0 and C.GREEN or v < 0 and C.RED or C.MUTED)
end

-- Stat changes against the worn item, gains first. The random suffix is counted.
local function StatBlock(Gear, link)
	local diff = Gear.StatDiff and Gear.StatDiff(link)
	if type(diff) ~= "table" then return nil end
	local names = {}
	for _, old in ipairs(diff.vs or {}) do
		names[#names + 1] = UI.Colored(old.name or "?", UI.QUALITY[old.quality or 1] or C.TEXT)
	end
	-- "Compared to: Worn Helm"
	local head = Label("Compared to") .. (#names > 0 and table.concat(names, UI.Colored(" + ", C.MUTED)) or UI.Colored("empty slot", C.MUTED))
	local block = { { head } }
	-- Two columns, not linked row by row: what the item gives in the end on the left
	-- ("+28 Attack Power"), the attribute changes behind it on the right ("Strength +10":
	-- the number last, so the numbers line up at the right edge).
	local attrs, stats = {}, {}
	for _, attr in ipairs(diff.attrs or {}) do
		attrs[#attrs + 1] = (ATTR[attr.key] or attr.label) .. " " .. StatValue(attr.value)
	end
	for _, row in ipairs(diff.rows or {}) do
		if not ATTR[row.key] then
			local percent = row.unit == "%"
			local text = StatValue(row.value, percent and "%" or nil) .. " " .. row.label
			if row.unit and not percent then text = text .. " " .. row.unit end
			stats[#stats + 1] = text
		end
	end
	for i = 1, math.max(#attrs, #stats) do
		block[#block + 1] = { stats[i] or " ", attrs[i] or " " }
	end
	if #block == 1 then block[2] = { UI.Colored("Same stats", C.MUTED) } end
	return block
end

-- The lines for one item, or false when it is not gear. short: rank line only.
local function Build(link, short)
	local Gear = ns.Gear
	local c = Gear.Compare(link)
	if type(c) ~= "table" then return false end
	local id = ns.ItemID(link)
	local db = ns.db
	local ctx = Gear.Context() or {}
	local tracked = id and Gear.IsTracked(id, Gear.LinkSuffixID and Gear.LinkSuffixID(link) or nil)

	local reason = c.usable == false and (c.reason or "other") or nil
	if reason and reason ~= "level" then
		local lines = { { Label("Can't use") .. UI.Colored(REASON[reason] or "this item", C.RED) } }
		if tracked and not short then lines[2] = { UI.Colored("Tracked", C.GOLD) } end
		return lines
	end

	-- rank: the spec in use, then the other specs
	local blocks = {}
	local head = {}
	if c.score then head[1] = RankLine(Gear, ctx, c, C.GOLD) end
	if reason == "level" then
		local item = Gear.Item(id)
		head[#head + 1] = { Label("Needs") .. UI.Colored(item and item.req and ("level " .. item.req) or "more levels", C.RED) }
	end
	if short then return #head > 0 and head or false end
	if db.tipOtherSpecs and ctx.class then
		local others = {} -- best rank first; spec order breaks ties
		for order, spec in ipairs(Gear.Specs(ctx.class) or {}) do
			if spec.key ~= ctx.spec then
				local other = {}
				for k, v in pairs(ctx) do other[k] = v end
				other.spec = spec.key
				local oc = Gear.Compare(link, other)
				if type(oc) == "table" and oc.rank then
					local line = RankLine(Gear, other, oc, C.MUTED, "  ")
					line.small = true
					others[#others + 1] = { line = line, rank = oc.rank, order = order }
				end
			end
		end
		table.sort(others, function(a, b)
			if a.rank ~= b.rank then return a.rank < b.rank end
			return a.order < b.order
		end)
		for _, other in ipairs(others) do head[#head + 1] = other.line end
	end
	if #head > 0 then blocks[#blocks + 1] = head end

	local worn = c.isWorn
	if db.tipEnchant and c.slot and (worn or c.usable ~= false) then
		local enchant = Gear.BestEnchant(c.slot)
		local text = enchant and (enchant.text or enchant.name)
		if text then blocks[#blocks + 1] = { { Label("Recommended enchant") .. text } } end
	end
	local suffix = db.tipSuffix and SuffixBlock(Gear, link) or nil
	if suffix then blocks[#blocks + 1] = suffix end
	if db.tipStats and not worn then blocks[#blocks + 1] = StatBlock(Gear, link) end
	local last = {}
	if db.tipSource and id then
		local source = Gear.SourceText(id)
		if source then last[#last + 1] = { Label("Source") .. source } end
		-- a vendor whose price or requirements we have not confirmed: say so in small print
		if source and Gear.SourceUnsure and Gear.SourceUnsure(id) then
			last[#last + 1] = { UI.Colored(Gear.UNSURE_NOTE or "Vendor details are not confirmed yet.", C.FAINT), small = true }
		end
	end
	if tracked then last[#last + 1] = { UI.Colored("Tracked", C.GOLD) } end
	if #last > 0 then blocks[#blocks + 1] = last end

	-- blocks, with an empty line between them
	-- lines.suffix: the suffix block by itself; its lines here are marked, so they can be left out
	local lines = { suffix = suffix }
	for i, block in ipairs(blocks) do
		if i > 1 then lines[#lines + 1] = { blank = true, suffix = block == suffix or nil } end
		for _, line in ipairs(block) do
			if block == suffix then line.suffix = true end
			lines[#lines + 1] = line
		end
	end
	return #lines > 0 and lines or false
end

-- Cached lines for a link. Public for other modules and tests.
function Tip.Lines(link, short)
	local key = short and (link .. "#") or link
	local lines = cache[key]
	if lines == nil then
		if cached >= CACHE_MAX then Tip.Clear() end
		lines = Build(link, short)
		cache[key] = lines
		cached = cached + 1
	end
	return lines
end

local function LinkOf(tooltip, data)
	local link
	if tooltip.GetItem then
		local ok, _, shown = pcall(tooltip.GetItem, tooltip)
		if ok then link = ns.Plain(shown) end
	end
	if type(link) ~= "string" or not link:find("item:", 1, true) then
		link = type(data) == "table" and ns.Plain(data.hyperlink) or nil
	end
	if type(link) ~= "string" or not link:find("item:", 1, true) then
		local id = type(data) == "table" and ns.Plain(data.id) or nil
		link = type(id) == "number" and ("item:" .. id) or nil
	end
	return link
end

-- Not gear by the game's own quick check. Unknown counts as gear.
local function NotGear(link)
	local id = ns.ItemID(link)
	if not id or not C_Item or not C_Item.GetItemInfoInstant then return false end
	local _, _, _, equip = C_Item.GetItemInfoInstant(id)
	equip = ns.Plain(equip)
	return equip == "" or equip == "INVTYPE_NON_EQUIP_IGNORE" or equip == "INVTYPE_BAG" or equip == "INVTYPE_QUIVER"
		or equip == "INVTYPE_AMMO" or equip == "INVTYPE_TABARD" or equip == "INVTYPE_BODY"
end

local function Kind(tooltip)
	if tooltip == GameTooltip or tooltip == ItemRefTooltip then return "full" end
	if tooltip == ShoppingTooltip1 or tooltip == ShoppingTooltip2
		or tooltip == ItemRefShoppingTooltip1 or tooltip == ItemRefShoppingTooltip2 then
		return "short"
	end
	return nil
end

-- Hooks the tooltip's clear, once. Our per-tooltip flags only make sense when this worked.
local function Hook(tooltip)
	if not hooked[tooltip] then
		hooked[tooltip] = pcall(tooltip.HookScript, tooltip, "OnTooltipCleared", function(self)
			done[self] = nil
			inlined[self] = nil
			-- the game reuses the lines: give them their font back
			local list = shrunk[self]
			if list then
				for i = 1, #list do pcall(list[i].SetFontObject, list[i], GameTooltipText) end
				shrunk[self] = nil
			end
		end) or nil
	end
	return hooked[tooltip]
end

local function Add(tooltip, line)
	local text = C.TEXT
	if line[2] then
		tooltip:AddDoubleLine(line[1], line[2], text[1], text[2], text[3], text[1], text[2], text[3])
	else
		tooltip:AddLine(line[1], text[1], text[2], text[3])
	end
end

-- "Requires Level 20" of the game, up to the number.
local LEVEL_PREFIX = type(ITEM_MIN_LEVEL) == "string" and ITEM_MIN_LEVEL:match("^(.-)%%d") or nil
if LEVEL_PREFIX == "" then LEVEL_PREFIX = nil end

-- Called by the game before it adds a line of its own. On the "Requires Level" line of an item
-- the suffix lines go in first, so they sit with the item's stats. Returns nothing: the game's
-- line is added as usual.
local function BeforeLine(tooltip, line)
	if not tooltip or inlined[tooltip] or done[tooltip] or type(line) ~= "table" or Kind(tooltip) ~= "full" then return end
	local kinds = Enum and Enum.TooltipDataLineType
	local isLevel = kinds and kinds.RestrictedLevel ~= nil and ns.Plain(line.type) == kinds.RestrictedLevel
	if not isLevel and LEVEL_PREFIX then
		local text = ns.Plain(line.leftText)
		isLevel = type(text) == "string" and text:sub(1, #LEVEL_PREFIX) == LEVEL_PREFIX
	end
	if not isLevel then return end
	local db, Gear = ns.db, ns.Gear
	if not db or not db.tipOn or not db.tipSuffix or not Gear or not Gear.Compare then return end
	local data = tooltip.GetPrimaryTooltipData and tooltip:GetPrimaryTooltipData()
		or tooltip.processingInfo and tooltip.processingInfo.tooltipData or nil
	if type(data) == "table" and Enum and Enum.TooltipDataType and ns.Plain(data.type) ~= Enum.TooltipDataType.Item then return end
	local link = LinkOf(tooltip, data)
	if not link or NotGear(link) then return end
	local lines = Tip.Lines(link, false)
	if not lines or not lines.suffix or not Hook(tooltip) then return end
	inlined[tooltip] = true
	for _, suffixLine in ipairs(lines.suffix) do Add(tooltip, suffixLine) end
end

function Tip.BeforeLine(tooltip, line)
	local ok, err = pcall(BeforeLine, tooltip, line)
	if not ok then ns.Debug("tooltip line", err) end
end

local function Fill(tooltip, data)
	local kind = tooltip and Kind(tooltip)
	if not kind or done[tooltip] then return end
	local db, Gear = ns.db, ns.Gear
	if not db or not db.tipOn or not Gear or not Gear.Compare then return end
	local link = LinkOf(tooltip, data)
	if not link or NotGear(link) then return end
	local lines = Tip.Lines(link, kind == "short")
	if not lines then return end
	-- without the clear hook the flag would never go away
	if Hook(tooltip) then done[tooltip] = true end
	local skip = inlined[tooltip] -- the suffix lines are already up with the stats
	local any = false
	for i = 1, #lines do
		local line = lines[i]
		if not (skip and line.suffix) and not (line.blank and not any) then
			if not any then tooltip:AddLine(" ") end -- our block stands apart from what other addons add
			any = true
			if line.blank then tooltip:AddLine(" ") else Add(tooltip, line) end
			if line.small and hooked[tooltip] then Tip.Shrink(tooltip) end
		end
	end
end

-- Makes the last line of a tooltip small. The font goes back when the tooltip is cleared.
function Tip.Shrink(tooltip)
	local name = tooltip.GetName and tooltip:GetName()
	local n = tooltip.NumLines and tooltip:NumLines()
	if not name or not n or not GameTooltipTextSmall then return end
	for _, side in ipairs({ "TextLeft", "TextRight" }) do
		local text = _G[name .. side .. n]
		if text and text.SetFontObject and pcall(text.SetFontObject, text, GameTooltipTextSmall) then
			shrunk[tooltip] = shrunk[tooltip] or {}
			table.insert(shrunk[tooltip], text)
		end
	end
end

-- The tooltip handler. Never lets an error out.
function Tip.OnItem(tooltip, data)
	local ok, err = pcall(Fill, tooltip, data)
	if not ok then ns.Debug("tooltip", err) end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
	pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item, Tip.OnItem)
	-- Line hook, for the suffix lines. Without it they stay in our block at the bottom.
	if TooltipDataProcessor.AddLinePreCall then
		local kinds = Enum.TooltipDataLineType
		for _, kind in ipairs({ TooltipDataProcessor.AllTypes or false, kinds and kinds.RestrictedLevel or false }) do
			if kind and pcall(TooltipDataProcessor.AddLinePreCall, kind, Tip.BeforeLine) then Tip.lineHook = true end
		end
	end
else
	ns.OnLoad(function()
		for _, name in ipairs({ "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2" }) do
			local tooltip = _G[name]
			if tooltip and tooltip.HookScript then
				pcall(tooltip.HookScript, tooltip, "OnTooltipSetItem", function(self) Tip.OnItem(self) end)
			end
		end
	end)
end

-- The game's own stat changes ---------------------------------------------------------------
-- The compare tooltip ends with "If you replace this item, the following stat changes will
-- occur:" and a line per stat. Our block says the same with more in it, so that part is taken out.
--
-- The game adds it in TooltipComparisonManager:SetItemTooltip, after every tooltip hook has run.
-- A hook on that function is no use: checked in game, the client also runs it on a path that
-- skips addon hooks on the manager. Hooks on the tooltip frame itself do fire, so we wait for
-- the frame call that comes right after the lines (SetShown) and then fill the tooltip again
-- the way the game does, without the stat changes. Emptying the lines in place would leave gaps.

local DELTA_HEADS -- header text -> true, from the game's own strings
local function IsDeltaHead(text)
	if not DELTA_HEADS then
		DELTA_HEADS = {}
		for _, name in ipairs({ "ITEM_DELTA_DESCRIPTION", "ITEM_DELTA_MULTIPLE_COMPARISON_DESCRIPTION" }) do
			if type(_G[name]) == "string" then DELTA_HEADS[_G[name]] = true end
		end
	end
	return DELTA_HEADS[text] or false
end

local function Blank(text) return text == nil or text == "" or text == " " end

-- Where the block is: the header's line number, and the game's hint about cycling items when
-- one follows the block ({ text, r, g, b }). nil when the tooltip has no such block.
function Tip.FindDelta(tooltip)
	local name = tooltip.GetName and tooltip:GetName()
	local n = tooltip.NumLines and tooltip:NumLines()
	if not name or type(n) ~= "number" then return nil end
	local function text(i)
		local line = _G[name .. "TextLeft" .. i]
		return line and ns.Plain(line:GetText()) or nil
	end
	local head
	for i = n, 2, -1 do
		if IsDeltaHead(text(i)) then head = i break end
	end
	if not head then return nil end
	-- header, (gap, paired item,) stats, then maybe a gap and the hint
	local hint
	if n - 1 > head + 1 and Blank(text(n - 1)) then
		local line = _G[name .. "TextLeft" .. n]
		local r, g, b = 0.5, 0.5, 0.5
		if line.GetTextColor then r, g, b = line:GetTextColor() end
		hint = { text(n), r, g, b }
	end
	return head, hint
end

-- Fills a compare tooltip again without the block. True when it did.
local busy = false
local function Rebuild(tooltip)
	if busy or not ns.db or not ns.db.tipHideDelta then return false end
	local manager = TooltipComparisonManager
	local owner = type(manager) == "table" and manager.tooltip
	local pair = owner and owner.shoppingTooltips
	if not pair or (tooltip ~= pair[1] and tooltip ~= pair[2]) then return false end
	local head, hint = Tip.FindDelta(tooltip)
	if not head then return false end
	local item
	if tooltip == pair[1] then item = manager.compareInfo and manager.compareInfo.item else item = manager:GetSecondaryItem() end
	local data = item and manager:GetComparisonItemData(item)
	if not data then return false end
	busy = true
	tooltip:ClearLines()
	if tooltip.CompareHeader then tooltip.CompareHeader:Show() end -- clearing hides the "Equipped" tab
	tooltip:ProcessInfo({ tooltipData = data, append = true })
	if hint and hint[1] then
		tooltip:AddLine(" ")
		tooltip:AddLine(hint[1], hint[2], hint[3], hint[4], true)
	end
	if tooltip:IsShown() then tooltip:Show() end
	busy = false
	Tip.deltaRebuilds = (Tip.deltaRebuilds or 0) + 1
	return true
end

function Tip.CleanCompare(tooltip)
	local ok, result = pcall(Rebuild, tooltip)
	if not ok then
		busy = false
		ns.Debug("compare tooltip", result)
	end
	return ok and result or false
end

ns.OnLoad(function()
	ns.db.tipTrace = nil -- left by an earlier test build
	if not hooksecurefunc or type(TooltipComparisonManager) ~= "table" then return end
	for _, name in ipairs({ "ShoppingTooltip1", "ShoppingTooltip2", "ItemRefShoppingTooltip1", "ItemRefShoppingTooltip2" }) do
		local tooltip = _G[name]
		if tooltip and tooltip.SetShown and tooltip.AddLine then
			local waiting = false
			-- the game shows the tooltip right after it has added the block
			local shown = pcall(hooksecurefunc, tooltip, "SetShown", function(self, show)
				waiting = false
				if show then Tip.CleanCompare(self) end
			end)
			-- in case that call does not come: next frame
			local added = pcall(hooksecurefunc, tooltip, "AddLine", function(self, text)
				if busy or waiting or not C_Timer or ns.Plain(text) == nil or not IsDeltaHead(text) then return end
				waiting = true
				C_Timer.After(0, function()
					if not waiting then return end
					waiting = false
					Tip.CleanCompare(self)
				end)
			end)
			if shown or added then Tip.deltaHook = true end
		end
	end
end)

ns.Command("tip", "Tooltip: are the hooks there", function()
	ns.Print("Tooltip line hook: " .. (Tip.lineHook and "on" or "off"))
	ns.Print("Compare tooltip hook: " .. (Tip.deltaHook and "on" or "off") .. ", cleaned: " .. tostring(Tip.deltaRebuilds or 0))
end)

for _, message in ipairs({ "CONTEXT_CHANGED", "GEAR_CHANGED", "FILTERS_CHANGED", "HUNTS_CHANGED", "SETTINGS_CHANGED" }) do
	ns.Listen(message, Tip.Clear)
end
