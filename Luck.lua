local _, ns = ...

-- Roll luck per character, counted from decided drops ("LOOT_DECIDED").
-- Sends "LUCK_CHANGED".

local UI = ns.UI
local C = UI.C
local L = {}
ns.Luck = L

local EXPECTED = 50.5
local LOST_KEEP = 40 -- names kept in "lost to"

ns.Defaults({ luck = {} })

-- upWins: wins of an item that was an upgrade when it was won
local function Blank()
	return { rolls = 0, wins = 0, upWins = 0, sum = 0, hundreds = 0, ones = 0, need = 0, greed = 0, pass = 0, dry = 0, longestDry = 0,
		lostTo = {} }
end

local ENOUGH = 10 -- rolls before the average is called good or bad

local function Key(key)
	return key or (ns.player and ns.player.full) or "?"
end

local function Stats(key)
	key = Key(key)
	local s = ns.db.luck[key]
	if type(s) ~= "table" then
		s = Blank()
		ns.db.luck[key] = s
	end
	ns.Merge(s, Blank())
	return s
end

-- Stats of a character (this one when key is nil), with avg and rate worked out.
function L.Get(key)
	local s = Stats(key)
	local out = {}
	for k, v in pairs(s) do out[k] = v end
	out.avg = s.rolls > 0 and s.sum / s.rolls or nil
	out.rate = s.rolls > 0 and s.wins / s.rolls or nil
	out.expected = EXPECTED
	return out
end

-- Who won against this character most: list of { name, count }.
function L.LostTo(key, limit)
	local list = {}
	for name, count in pairs(Stats(key).lostTo) do list[#list + 1] = { name = name, count = count } end
	table.sort(list, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.name < b.name
	end)
	for i = #list, (limit or #list) + 1, -1 do list[i] = nil end
	return list
end

function L.Characters()
	local list = {}
	for key in pairs(ns.db.luck) do list[#list + 1] = key end
	table.sort(list)
	return list
end

function L.Reset(key)
	ns.db.luck[Key(key)] = Blank()
	ns.Send("LUCK_CHANGED")
end

local function Count(drop)
	local me = drop and drop.me
	if not me or not me.ch then return end
	local s = Stats()
	if me.ch == "pass" then
		s.pass = s.pass + 1
		ns.Send("LUCK_CHANGED")
		return
	end
	s[me.ch] = (s[me.ch] or 0) + 1
	if type(me.r) == "number" then
		s.rolls = s.rolls + 1
		s.sum = s.sum + me.r
		s.best = math.max(s.best or 0, me.r)
		s.worst = math.min(s.worst or 101, me.r)
		if me.r == 100 then s.hundreds = s.hundreds + 1 end
		if me.r == 1 then s.ones = s.ones + 1 end
	end
	if me.w then
		s.wins = s.wins + 1
		s.dry = 0
		-- an upgrade at the time it was won: the wins that mattered, apart from the rest
		local Gear = ns.Gear
		local item = drop.link or drop.id
		if item and Gear and Gear.Compare and Gear.PlayerContext then
			local ok, c = pcall(Gear.Compare, item, Gear.PlayerContext())
			if ok and type(c) == "table" and type(c.delta) == "number" and c.delta > 0 then s.upWins = s.upWins + 1 end
		end
	else
		s.dry = s.dry + 1
		s.longestDry = math.max(s.longestDry, s.dry)
		local w = drop.winner
		if w and not w.me and w.n and w.n ~= "?" then
			s.lostTo[w.n] = (s.lostTo[w.n] or 0) + 1
			-- keep the list small: forget the rarest names
			local n = 0
			for _ in pairs(s.lostTo) do n = n + 1 end
			if n > LOST_KEEP * 2 then
				local top = L.LostTo(nil, LOST_KEEP)
				s.lostTo = {}
				for _, entry in ipairs(top) do s.lostTo[entry.name] = entry.count end
			end
		end
	end
	ns.Send("LUCK_CHANGED")
end

ns.Listen("LOOT_DECIDED", Count)

-- Tab -------------------------------------------------------------------------------------------

local view = {}

-- { key, label, what it counts }
local TILES = {
	{ "rolls", "Rolls", "Your Need and Greed rolls in group loot." },
	{ "wins", "Wins", "Rolls you won. Upgrades: the wins that were an upgrade when you won them." },
	{ "rate", "Win rate", "Wins out of your rolls, Greed rolls counted." },
	{ "avg", "Average roll", "Even luck is 50.5. Green or red after " .. ENOUGH .. " rolls." },
	{ "hundreds", "100s", "Rolls of 100." }, { "ones", "1s", "Rolls of 1." }, { "best", "Best roll" }, { "worst", "Worst roll" },
	{ "need", "Need", "Times you chose Need." }, { "greed", "Greed", "Times you chose Greed." }, { "pass", "Pass", "Times you passed." },
	{ "dry", "Dry streak", "Rolls since your last win." },
}

local function Tile(parent, label, width, height, tip)
	local box = UI.Box(parent)
	box:SetSize(width, height)
	box.label = UI.Text(box, "GameFontHighlightSmall", C.MUTED)
	box.label:SetPoint("TOPLEFT", 10, -8)
	box.label:SetText(label)
	box.value = UI.Text(box, "GameFontNormalLarge", C.GOLD, 22)
	box.value:SetPoint("BOTTOMLEFT", 10, 10)
	box.note = UI.Text(box, "GameFontHighlightSmall", C.FAINT)
	box.note:SetPoint("BOTTOMRIGHT", -10, 12)
	if tip then
		box:EnableMouse(true)
		box:SetScript("OnEnter", function(self) UI.TextTooltip(self, label, { tip }) end)
		box:SetScript("OnLeave", UI.HideTooltip)
	end
	return box
end

local function Fill()
	local chars = L.Characters()
	local key = view.key
	if not key or not ns.db.luck[key] then key = Key() end
	view.key = key
	local s = L.Get(key)

	view.title:SetText(key)
	view.picker:SetShown(#chars > 1)
	view.picker:SetValue(key)

	local text = {
		rolls = s.rolls, wins = s.wins, hundreds = s.hundreds, ones = s.ones,
		need = s.need, greed = s.greed, pass = s.pass, dry = s.dry,
		rate = s.rate and ("%d%%"):format(s.rate * 100 + 0.5) or "-",
		avg = s.avg and ("%.1f"):format(s.avg) or "-",
		best = s.best or "-", worst = s.worst or "-",
	}
	for id, tile in pairs(view.tiles) do tile.value:SetText(text[id]) end
	view.tiles.dry.note:SetText("Longest: " .. s.longestDry)
	view.tiles.wins.note:SetText(s.wins > 0 and ("Upgrades: " .. (s.upWins or 0)) or "")
	view.tiles.avg.note:SetText("Expected: " .. EXPECTED)
	-- a few rolls say nothing: the colour waits for enough of them
	UI.Color(view.tiles.avg.value, (not s.avg or s.rolls < ENOUGH) and C.GOLD or (s.avg >= EXPECTED and C.GREEN or C.RED))

	view.bar:Set((s.avg or 0) / 100, (not s.avg or s.rolls < ENOUGH) and C.GOLD or (s.avg < EXPECTED and C.RED or C.GREEN))
	view.barText:SetText(s.avg and ("Average roll: %.1f"):format(s.avg) or "Average roll: -")

	local lost = L.LostTo(key, 6)
	for i = 1, 6 do
		local entry = lost[i]
		view.lost[i]:SetText(entry and (ns.History.Short(entry.name) .. ": " .. entry.count) or "")
	end
	view.lostNone:SetShown(#lost == 0)
end

local function BuildTab(panel)
	local width = ns.Main.PANEL_WIDTH
	view.title = UI.Heading(panel, 18)
	view.title:SetPoint("TOPLEFT", 2, -2)

	view.picker = UI.Picker(panel, 200, function()
		local list = {}
		for _, key in ipairs(L.Characters()) do list[#list + 1] = { value = key, label = key } end
		return list
	end, function(key)
		view.key = key
		Fill()
	end)
	view.picker:SetPoint("TOPRIGHT", -84, -2)

	local reset = UI.Button(panel, "Reset", 76, 22)
	reset:SetPoint("TOPRIGHT", 0, -2)
	reset:SetScript("OnClick", function(self)
		-- second click resets
		if not self.armed then
			self.armed = true
			local at = GetTime()
			self.armedAt = at
			self:SetLabel("Sure?")
			C_Timer.After(3, function()
				-- the timer of an earlier click does not disarm a later one
				if self.armedAt ~= at then return end
				self.armed = nil
				self:SetLabel("Reset")
			end)
			return
		end
		self.armedAt = nil
		self.armed = nil
		self:SetLabel("Reset")
		L.Reset(view.key)
	end)

	local gap = 8
	local tileWidth, tileHeight = (width - gap * 3) / 4, 66
	view.tiles = {}
	for i, def in ipairs(TILES) do
		local tile = Tile(panel, def[2], tileWidth, tileHeight, def[3])
		local col, line = (i - 1) % 4, math.floor((i - 1) / 4)
		tile:SetPoint("TOPLEFT", col * (tileWidth + gap), -36 - line * (tileHeight + gap))
		view.tiles[def[1]] = tile
	end

	local y = -36 - 3 * (tileHeight + gap) - 8
	view.barText = UI.Text(panel, "GameFontHighlightSmall", C.TEXT)
	view.barText:SetPoint("TOPLEFT", 2, y)
	local scale = UI.Text(panel, "GameFontHighlightSmall", C.FAINT)
	scale:SetPoint("TOPRIGHT", 0, y)
	scale:SetText("1 to 100")
	view.bar = UI.Bar(panel, width, 8)
	view.bar:SetPoint("TOPLEFT", 0, y - 18)
	-- mark at the expected average
	local mark = UI.Fill(view.bar, "OVERLAY", C.GOLD, 1)
	mark:SetSize(2, 14)
	mark:SetPoint("CENTER", view.bar, "LEFT", width * EXPECTED / 100, 0)

	local lostBox = UI.Box(panel)
	lostBox:SetPoint("TOPLEFT", 0, y - 40)
	lostBox:SetSize(tileWidth * 2 + gap, 150)
	local head = UI.Text(lostBox, "GameFontHighlightSmall", C.GOLD_SOFT)
	head:SetPoint("TOPLEFT", 10, -8)
	head:SetText("Lost to")
	view.lost = {}
	for i = 1, 6 do
		local line = UI.Text(lostBox, "GameFontHighlightSmall", C.TEXT)
		line:SetPoint("TOPLEFT", 10, -10 - i * 18)
		view.lost[i] = line
	end
	view.lostNone = UI.Text(lostBox, "GameFontHighlightSmall", C.FAINT)
	view.lostNone:SetPoint("TOPLEFT", 10, -28)
	view.lostNone:SetText("Nobody")
end

ns.Main.AddTab("luck", "Luck", 400, BuildTab, Fill)

ns.Listen("LUCK_CHANGED", function() ns.Main.Refresh("luck") end)

ns.Command("luck", "Luck. Also: reset", function(rest)
	if (rest or ""):lower() == "reset" then
		L.Reset()
		ns.Print("Luck: reset")
	else
		ns.Main.Toggle("luck")
	end
end)
