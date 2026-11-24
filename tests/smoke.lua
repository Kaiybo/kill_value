-- Offline smoke test: loads the addon against a stubbed WoW API, simulates
-- kills, XP and loot, opens every window tab and hovers an enemy.
-- Run from the repo root:  lua5.1 tests/smoke.lua

local failures = 0
local function check(cond, msg)
    if cond then print("ok   " .. msg) else failures = failures + 1; print("FAIL " .. msg) end
end

-- Generic widget: any method is a no-op, scripts are remembered.
local function Widget()
    local w = { scripts = {}, shown = true }
    return setmetatable(w, { __index = function(_, k)
        if k == "SetScript" then return function(self, n, f) self.scripts[n] = f end end
        if k == "HookScript" then return function(self, n, f) self.scripts[n] = f end end
        if k == "GetScript" then return function(self, n) return self.scripts[n] end end
        if k == "IsShown" then return function(self) return self.shown end end
        if k == "SetShown" then return function(self, v) self.shown = v and true or false end end
        if k == "Show" then return function(self) self.shown = true end end
        if k == "Hide" then return function(self) self.shown = false end end
        if k == "GetChecked" then return function() return true end end
        if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
        if k == "RegisterEvent" then return function() return true end end
        if k:match("^Create") then return function() return Widget() end end
        return function() end
    end })
end

local now, clock = 1000, 1700000000
local timers = {}
local events = {}
local lines = {}

GetTime = function() return now end
time = function() return clock end
date = os.date
C_Timer = { After = function(d, f) timers[#timers + 1] = { at = now + d, f = f } end }
local function advance(sec)
    now = now + sec
    local again = true
    while again do
        again = false
        for i, t in ipairs(timers) do
            if t.at <= now then table.remove(timers, i); t.f(); again = true; break end
        end
    end
end

DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) lines[#lines + 1] = m end }
SlashCmdList = {}
UIParent = Widget()
UISpecialFrames = {}
local tooltipLines = {}
GameTooltip = Widget()
GameTooltip.AddDoubleLine = function(_, l, r) tooltipLines[#tooltipLines + 1] = (l or "") .. " | " .. (r or "") end
GameTooltip.GetUnit = function() return "Defias Thug", "target" end
local postCall
TooltipDataProcessor = { AddTooltipPostCall = function(_, f) postCall = f end }
Enum = { TooltipDataType = { Unit = 2 }, LootSlotType = { Item = 1, Money = 2 } }

local mainFrame
CreateFrame = function()
    local w = Widget()
    if not mainFrame then
        mainFrame = w
        w.RegisterEvent = function(_, e) events[e] = true; return true end
        w.RegisterUnitEvent = function(_, e) events[e] = true end
    end
    return w
end

-- Units
local units = { target = { guid = "Creature-0-1-2-3-116-0001", name = "Defias Thug", level = 10, dead = true } }
UnitGUID = function(u) return units[u] and units[u].guid end
UnitName = function(u) if u == "player" then return "Me" end return units[u] and units[u].name end
UnitLevel = function(u) if u == "player" then return 10 end return units[u] and units[u].level end
UnitIsDead = function(u) return units[u] and units[u].dead end
UnitExists = function(u) return u == "mouseover" or units[u] ~= nil end
UnitIsPlayer = function() return false end
UnitCanAttack = function() return true end
UnitClassification = function() return "normal" end
UnitCreatureType = function() return "Humanoid", 7 end
UnitIsTapDenied = function() return false end
UnitXP = function() return 1000 end
UnitXPMax = function() return 7600 end
GetXPExhaustion = function() return nil end
GetMaxPlayerLevel = function() return 60 end
IsInInstance = function() return false, "none" end
IsInGroup = function() return false end
CanLootUnit = function() return true end
GetSpellInfo = function(id) return "Spell" .. id end

-- Loot window contents
local loot = {}
GetNumLootItems = function() return #loot end
GetLootSlotType = function(i) return loot[i].type end
GetLootSlotInfo = function(i) return nil, loot[i].name, loot[i].qty, nil, loot[i].quality end
GetLootSlotLink = function(i) return loot[i].link end
GetLootSourceInfo = function(i) return loot[i].guid, loot[i].qty end
local prices = { [2589] = { "Linen Cloth", 1, 13 }, [1] = { "Shiny Thing", 2, 500 } }
GetItemInfo = function(link)
    local id = tonumber(link:match("item:(%d+)"))
    local p = prices[id]
    if not p then return nil end
    return p[1], link, p[2], nil, nil, nil, nil, nil, nil, nil, p[3]
end

COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
COMBATLOG_XPGAIN_EXHAUSTION1 = "%s dies, you gain %d experience. (%s exp %s bonus)"
LOOT_MONEY_SPLIT = "Your share of the loot is %s."
GOLD_AMOUNT, SILVER_AMOUNT, COPPER_AMOUNT = "%d Gold", "%d Silver", "%d Copper"

-- Load the addon
local ns = {}
local toc = io.open("KillValue.toc"):read("*a")
for file in toc:gmatch("\n([%w_]+%.lua)") do
    local chunk = assert(loadfile(file))
    chunk("KillValue", ns)
end
local function fire(e, ...) mainFrame.scripts.OnEvent(mainFrame, e, ...) end
fire("ADDON_LOADED", "KillValue")
check(ns.db ~= nil, "saved variables initialised")
check(events.PARTY_KILL and events.CHAT_MSG_COMBAT_XP_GAIN and events.LOOT_READY, "events registered")
check(postCall ~= nil, "tooltip hook installed")

-- Parsing
local T = ns._test
local n, xp = T.ParseXPText("Defias Thug dies, you gain 125 experience. (+62 exp Rested bonus)")
check(n == "Defias Thug" and xp == 125, "XP message parsed with rested bonus")
check(T.ParseCoinText("1 Gold\n2 Silver\n3 Copper") == 10203, "coin text parsed")

-- Kill 1: coin + 2 cloth + 1 shiny
local function kill(guid, xpGain, slots)
    units.target.guid = guid
    fire("CHAT_MSG_COMBAT_XP_GAIN", "Defias Thug dies, you gain " .. xpGain .. " experience.")
    fire("PARTY_KILL", "Player-1", guid)
    loot = slots
    for _, s in ipairs(loot) do s.guid = guid end
    fire("LOOT_READY")
    advance(1)
    fire("LOOT_CLOSED")
end

kill("Creature-0-1-2-3-116-0001", 100, {
    { type = 2, name = "25 Copper", qty = 25 },
    { type = 1, name = "Linen Cloth", qty = 2, quality = 1, link = "|Hitem:2589::|h[Linen Cloth]|h" },
    { type = 1, name = "Shiny Thing", qty = 1, quality = 2, link = "|Hitem:1::|h[Shiny Thing]|h" },
})
local db = ns.db
check(db.run.kills == 1 and db.run.value == 25 + 26 + 500, "first kill valued: " .. db.run.value)
check(db.run.xp == 100 and db.run.xpKills == 1, "XP recorded")
check(db.recent[1].xp == 100, "XP attached to the kill")

-- Kill 2: coin only
kill("Creature-0-1-2-3-116-0002", 100, { { type = 2, name = "40 Copper", qty = 40 } })
local mob = db.mobs["Defias Thug"]
check(mob.kills == 2 and mob.drops[1].times == 1 and mob.drops[2589].times == 1, "per-enemy drop counts")

local p = ns.Predict("Defias Thug")
check(math.abs(p.value - (551 + 40) / 2) < 0.01, "expected value = average")
check(math.abs(p.coin + p.items - p.value) < 0.01, "coin + items = expected value")
local sum = 0
for _, d in ipairs(p.drops) do sum = sum + d.expected end
check(math.abs(sum - p.items) < 0.01, "sum of price x rate = item part")

-- Re-opening the same corpse doesn't count twice
kill("Creature-0-1-2-3-116-0002", 0, { { type = 2, name = "40 Copper", qty = 40 } })
check(db.run.kills == 2, "same corpse not counted twice")

-- Dungeon filter
db.includeInstances = false
IsInInstance = function() return true, "party" end
kill("Creature-0-1-2-3-116-0003", 100, { { type = 2, name = "40 Copper", qty = 40 } })
check(db.run.kills == 2 and db.run.xpKills == 2, "dungeon kills excluded when option is off")
IsInInstance = function() return false, "none" end
db.includeInstances = true

-- Group coin share
IsInGroup = function() return true end
units.target.guid = "Creature-0-1-2-3-116-0004"
fire("PARTY_KILL", "Player-1", units.target.guid)
loot = { { type = 2, name = "1 Silver", qty = 100, guid = units.target.guid } }
fire("LOOT_READY")
fire("CHAT_MSG_MONEY", "Your share of the loot is 50 Copper.")
advance(3)
fire("LOOT_CLOSED")
check(db.recent[1].coin == 50, "group share counted: " .. tostring(db.recent[1].coin))
IsInGroup = function() return false end

-- Tooltip
postCall(GameTooltip)
local tip = table.concat(tooltipLines, "\n")
check(tip:find("Kill value"), "tooltip shows kill value")
check(tip:find("XP per kill"), "tooltip shows XP")
check(tip:find("kills to level"), "tooltip shows kills to level")

-- Unknown enemy falls back to level estimate / XP formula
tooltipLines = {}
GameTooltip.GetUnit = function() return "Kobold", "target" end
units.target = { guid = "Creature-0-1-2-3-6-0001", name = "Kobold", level = 9 }
postCall(GameTooltip)
check(table.concat(tooltipLines, "\n"):find("estimate"), "unknown enemy XP is estimated")
check(ns.EstimateXP(10, 10, false) == 95, "XP formula, same level")
check(ns.EstimateXP(10, 2, false) == 0, "XP formula, gray mob")

-- Window: open and visit every tab (detail view needs a known enemy)
units.target = { guid = "Creature-0-1-2-3-116-0009", name = "Defias Thug", level = 10, dead = true }
SlashCmdList.KILLVALUE("")
for _, tab in ipairs({ "overview", "mobs", "detail", "loot", "recent", "options" }) do
    ns._selectTab(tab, "Defias Thug")
end
check(true, "every window tab drawn without errors")
SlashCmdList.KILLVALUE("stats")
SlashCmdList.KILLVALUE("mobs")
SlashCmdList.KILLVALUE("dungeons")
check(db.includeInstances == false, "toggle command works")
SlashCmdList.KILLVALUE("reset mob Defias Thug")
check(db.mobs["Defias Thug"] == nil, "per-enemy reset")
SlashCmdList.KILLVALUE("reset")
check(db.run.kills == 0 and db.total.kills > 0, "since-reset reset keeps all time")
SlashCmdList.KILLVALUE("reset all")
check(db.total.kills == 0, "reset all")

for _, l in ipairs(lines) do print("  chat> " .. l) end
for _, l in ipairs(tooltipLines) do print("  tip> " .. l) end
print(("\n%d lines of chat output; %s"):format(#lines, failures == 0 and "all passed" or (failures .. " failed")))
os.exit(failures == 0 and 0 or 1)
