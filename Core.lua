local ADDON, ns = ...

-- Lootomania: gear upgrades, loot sources and loot rolls.
-- This file holds what every other file leans on: saved settings, game events, messages
-- between modules, slash commands and chat output.

ns.ICON = "Interface\\Icons\\INV_Misc_Bag_10_Green"
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "dev"

-- Saved settings ------------------------------------------------------------------

-- Modules add their own defaults with ns.Defaults before login.
local accountDefaults = {
	minimap = { angle = 215 },
	windows = {}, -- saved window places, by window name
}
local charDefaults = {}

local function Merge(into, from)
	for k, v in pairs(from) do
		if type(v) == "table" then
			if type(into[k]) ~= "table" then into[k] = {} end
			Merge(into[k], v)
		elseif into[k] == nil then
			into[k] = v
		end
	end
	return into
end
ns.Merge = Merge

-- Adds default settings. scope is "account" (default) or "char".
function ns.Defaults(values, scope)
	Merge(scope == "char" and charDefaults or accountDefaults, values)
	-- a module that loads on demand, after login: fill the live tables too
	if ns.db then Merge(scope == "char" and ns.char or ns.db, values) end
end

-- Chat ----------------------------------------------------------------------------

local PREFIX = "|cffffd100Lootomania|r: "

function ns.Print(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do parts[i] = tostring((select(i, ...))) end
	(DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage(PREFIX .. table.concat(parts, " "))
end

function ns.Debug(...)
	if ns.db and ns.db.debug then ns.Print("|cff888888debug|r", ...) end
end

-- Runs fn and reports an error in chat instead of breaking the caller.
function ns.Safe(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then ns.Debug(err) end
	return ok, err
end

-- Values the game hides from addons in combat ("secret values") cannot be compared or
-- used as table keys. plain(v) gives v, or nil when v is hidden.
function ns.Plain(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

-- Game events ---------------------------------------------------------------------

local frame = CreateFrame("Frame")
local handlers = {} -- event -> list of functions

-- Calls fn(event, ...) on a game event. Some events do not exist on this client, so
-- registering is guarded.
function ns.On(event, fn)
	local list = handlers[event]
	if not list then
		list = {}
		handlers[event] = list
		if not pcall(frame.RegisterEvent, frame, event) then
			ns.noEvent = ns.noEvent or {}
			table.insert(ns.noEvent, event)
		end
	end
	list[#list + 1] = fn
end

frame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do
		local ok, err = pcall(list[i], event, ...)
		if not ok and ns.db and ns.db.debug then ns.Print("|cffff6060" .. event .. "|r", err) end
	end
end)

-- Messages between modules ----------------------------------------------------------
-- Known messages:
--   "CONTEXT_CHANGED"   class, spec, level or faction used for ranking changed
--   "GEAR_CHANGED"      the player's equipped gear changed
--   "HUNTS_CHANGED"     tracked, completed or removed upgrades changed
--   "SETTINGS_CHANGED"  key: a setting changed
--   "HISTORY_CHANGED"   loot history got a new run, drop or roll
--   "FILTERS_CHANGED"   a filter of the Upgrades tab changed
--   "GUIDE_CHANGED"     target: the guide arrow points somewhere new, or nowhere
--   "LOOT_DROPPED"      link, boss: a tracked or wanted item dropped
--   "LOOT_DECIDED"      drop, run: the roll for a drop is decided
--   "LUCK_CHANGED"      the luck figures changed

local listeners = {}

function ns.Listen(message, fn)
	listeners[message] = listeners[message] or {}
	table.insert(listeners[message], fn)
end

function ns.Send(message, ...)
	local list = listeners[message]
	if not list then return end
	for i = 1, #list do
		local ok, err = pcall(list[i], ...)
		if not ok and ns.db and ns.db.debug then ns.Print("|cffff6060" .. message .. "|r", err) end
	end
end

-- Settings: one way to change them, so the UI can refresh.
function ns.Set(key, value)
	if ns.db[key] == value then return end
	ns.db[key] = value
	ns.Send("SETTINGS_CHANGED", key, value)
end

-- Start-up --------------------------------------------------------------------------

local onLoad = {}
local loaded = false

-- Runs fn once settings are loaded and the player is in the world (PLAYER_LOGIN).
function ns.OnLoad(fn)
	if loaded then ns.Safe(fn) else onLoad[#onLoad + 1] = fn end
end

ns.On("ADDON_LOADED", function(_, name)
	if name ~= ADDON then return end
	LootomaniaDB = LootomaniaDB or {}
	LootomaniaCharDB = LootomaniaCharDB or {}
	ns.db = Merge(LootomaniaDB, accountDefaults)
	ns.char = Merge(LootomaniaCharDB, charDefaults)
end)

ns.On("PLAYER_LOGIN", function()
	ns.player = {
		name = UnitName("player"),
		realm = GetRealmName and GetRealmName() or "",
		class = select(2, UnitClass("player")), -- "WARRIOR"
		faction = UnitFactionGroup("player"), -- "Alliance" or "Horde"
		race = select(2, UnitRace("player")),
	}
	ns.player.full = ns.player.name .. "-" .. ns.player.realm
	loaded = true
	for i = 1, #onLoad do
		local ok, err = pcall(onLoad[i])
		if not ok then ns.Print("|cffff6060load error|r", err) end
	end
	onLoad = nil
end)

-- Slash commands ----------------------------------------------------------------------
-- ns.commands[word] = { run = function(rest) end, help = "short text" }

ns.commands = {}

-- tool: a command for testing or for making the data, left out of the short help.
function ns.Command(word, help, run, tool)
	ns.commands[word] = { run = run, help = help, tool = tool or nil }
end

SLASH_LOOTOMANIA1 = "/lm"
SLASH_LOOTOMANIA2 = "/lootomania"
SlashCmdList.LOOTOMANIA = function(text)
	text = (text or ""):match("^%s*(.-)%s*$")
	local word, rest = text:match("^(%S+)%s*(.*)$")
	if not word then
		if ns.Main then ns.Main.Toggle() end
		return
	end
	local command = ns.commands[word:lower()]
	if command then
		command.run(rest or "")
	else
		ns.Print("Unknown command. Try /lm help")
	end
end

ns.Command("help", "List commands. Also: all", function(rest)
	local all = (rest or ""):lower():match("^all") ~= nil
	local words = {}
	for word in pairs(ns.commands) do words[#words + 1] = word end
	table.sort(words)
	ns.Print("Commands")
	ns.Print("/lm - open or close")
	for _, word in ipairs(words) do
		if all or not ns.commands[word].tool then ns.Print("/lm " .. word .. " - " .. (ns.commands[word].help or "")) end
	end
	if not all then ns.Print("Testing and data commands: /lm help all") end
end)

ns.Command("debug", "Debug messages on/off", function()
	ns.db.debug = not ns.db.debug
	ns.Print("Debug: " .. (ns.db.debug and "on" or "off"))
	-- events this client does not have
	if ns.db.debug and ns.noEvent then ns.Print("No event: " .. table.concat(ns.noEvent, ", ")) end
end, true)

-- Small helpers -----------------------------------------------------------------------

-- Item ID from an item link, an "item:123" string or a number.
function ns.ItemID(item)
	if type(item) == "number" then return item end
	if type(item) ~= "string" then return nil end
	return tonumber(item:match("item:(%d+)")) or tonumber(item)
end

-- Random suffix ID from an item link (0 or nil when it has none).
function ns.SuffixID(link)
	if type(link) ~= "string" then return nil end
	local suffix = link:match("item:%d+:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%-?%d+)")
	suffix = tonumber(suffix)
	if suffix and suffix ~= 0 then return math.abs(suffix) end
	return nil
end

-- A drop chance as text: "13%", "5%", "6.5%", "<0.1%". One wording in every file.
function ns.ChanceText(chance)
	if type(chance) ~= "number" then return nil end
	if chance >= 10 then return ("%d%%"):format(math.floor(chance + 0.5)) end
	if chance < 0.1 then return "<0.1%" end
	return (("%.1f"):format(chance):gsub("%.0$", "")) .. "%"
end

-- A game text with %s and %d (a loot or roll line) as a pattern that matches the finished line.
function ns.ToPattern(text)
	text = text:gsub("%%%d+%$", "%%")
	text = text:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
	text = text:gsub("%%s", ".+"):gsub("%%d", "%%d+")
	return "^" .. text .. "$"
end

-- NPC ID from a unit GUID.
function ns.NpcID(guid)
	guid = ns.Plain(guid)
	if type(guid) ~= "string" then return nil end
	local kind, _, _, _, _, id = strsplit("-", guid)
	if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
	return nil
end

-- Runs fn `delay` seconds after the first call. Calls in between are dropped.
function ns.Debounce(delay, fn)
	local pending = false
	return function()
		if pending then return end
		pending = true
		C_Timer.After(delay, function()
			pending = false
			ns.Safe(fn)
		end)
	end
end

