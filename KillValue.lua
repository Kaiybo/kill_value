-- KillValue for World of Warcraft: Forever
--
-- When you loot a kill, prints what everything it dropped is worth at a vendor
-- (each item's sell price x quantity, plus the coin) and the experience it
-- gave, and keeps running totals and averages: since your last reset, all
-- time, and per enemy. Hovering an enemy shows what a kill of it is expected
-- to be worth, built from the drops you've seen (coin + each item's value x
-- how often it drops) and the XP it gives.
--
-- Type /kv for the window, /kv help for commands.

local ADDON_NAME, ns = ... -- ns is shared with the other files

local PREFIX = "|cffffd200KillValue:|r "
local DEFAULTS = {
    quiet = false,           -- no per-kill chat message
    countEmpty = true,       -- kills that drop nothing count toward averages (as 0)
    includeInstances = true, -- count dungeon and raid enemies
    includeGroup = true,     -- count kills made while in a party or raid
    groupShare = true,       -- in a group, count only your share of the coin
    tooltip = true,          -- add kill value / XP lines to enemy tooltips
    tooltipDrops = 3,        -- how many top drops to list in the tooltip
    verbose = true,          -- per-kill message also shows this enemy's totals
}

local EMPTY_CHECK_DELAY = 2 -- seconds after a kill before asking "does this corpse have loot?"
local GATHER_WINDOW = 3     -- loot opened this soon after Skinning / Pick Pocket isn't kill loot
local KEEP_SECONDS = 900    -- remember corpses this long so re-opening one isn't counted twice
local ITEM_RETRIES = 10     -- attempts (0.3s apart) to fetch an uncached item's sell price
local RECENT_MAX = 200      -- kills kept for the "Recent kills" tab
local SHARE_WAIT = 2.5      -- seconds to wait for "Your share of the loot is ..." in a group
local XP_LOG_MAX = 50

local db
local runStart -- GetTime() when this login (or the last reset) began
local kills = {}         -- [guid] = { t, name, level, elite, state = "pending" | "valuing" | "done" | "ignored" }
local xpLog = {}         -- recent { name, xp, t, used } from the combat XP message
local lootHandled = false
local lastGather = 0
local gatherSpells = {}
local lastShare          -- { ratio, t } from the most recent coin split message
local lootCoinSeen = 0   -- coin in the loot window currently open
local shareWaiters = {}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local issecret = issecretvalue or function() return false end

-- Forever has Midnight's "secret value" rules: in restricted contexts the
-- game hands addons values that error if compared or used as table keys.
-- Everything read from the game goes through here first.
local function Readable(v)
    if v == nil or issecret(v) then return nil end
    return v
end

local function Safe(fn, ...)
    if not fn then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    return Readable(a), Readable(b)
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

-- Lets the stats window redraw when something changes.
local function Notify()
    if ns.OnStatsChanged then ns.OnStatsChanged() end
end

local function Now() return time and time() or nil end

local GetItemInfoCompat = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RequestItemData = (C_Item and C_Item.RequestLoadItemDataByID) or function() end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    if GetSpellInfo then return (GetSpellInfo(id)) end
end

local function ItemID(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

-- Money ---------------------------------------------------------------

local ICON = "|TInterface\\MoneyFrame\\UI-%sIcon:0:0:2:0|t"
local GOLD_ICON, SILVER_ICON, COPPER_ICON = ICON:format("Gold"), ICON:format("Silver"), ICON:format("Copper")

local function Money(copper)
    copper = math.floor((copper or 0) + 0.5)
    local g = math.floor(copper / 10000)
    local s = math.floor(copper / 100) % 100
    local c = copper % 100
    local out = {}
    if g > 0 then out[#out + 1] = g .. GOLD_ICON end
    if s > 0 then out[#out + 1] = s .. SILVER_ICON end
    if c > 0 or #out == 0 then out[#out + 1] = c .. COPPER_ICON end
    return table.concat(out, " ")
end

-- Escapes a format string and turns %d / %s into captures, so client strings
-- like "%d Gold" or "%s dies, you gain %d experience." can be matched in any
-- locale.
local function FormatPattern(fmt)
    return (fmt:gsub("%%%d?%$?([ds])", "\001%1")
               :gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
               :gsub("\001d", "(%%d+)")
               :gsub("\001s", "(.-)"))
end

local COIN_PATTERNS = {
    { pattern = FormatPattern(GOLD_AMOUNT or "%d Gold"), mult = 10000 },
    { pattern = FormatPattern(SILVER_AMOUNT or "%d Silver"), mult = 100 },
    { pattern = FormatPattern(COPPER_AMOUNT or "%d Copper"), mult = 1 },
}

local function ParseCoinText(text)
    if type(text) ~= "string" then return nil end
    local total, found = 0, false
    for _, cp in ipairs(COIN_PATTERNS) do
        local n = text:match(cp.pattern)
        if n then
            total = total + tonumber(n) * cp.mult
            found = true
        end
    end
    return found and total or nil
end

-- Experience text -----------------------------------------------------

-- "%s dies, you gain %d experience. (+%d exp Rested bonus)" -> we only need
-- the name and the total, so everything from the first " (" on is dropped.
local XP_PATTERNS = {}
for _, fmt in ipairs({
    COMBATLOG_XPGAIN_FIRSTPERSON or "%s dies, you gain %d experience.",
    COMBATLOG_XPGAIN_EXHAUSTION1 or false,
    COMBATLOG_XPGAIN_EXHAUSTION2 or false,
    COMBATLOG_XPGAIN_EXHAUSTION4 or false,
    COMBATLOG_XPGAIN_EXHAUSTION5 or false,
    COMBATLOG_XPGAIN_FIRSTPERSON_GROUP or false,
    COMBATLOG_XPGAIN_FIRSTPERSON_RAID or false,
}) do
    if fmt then
        local head = fmt:match("^(.-)%s*%(") or fmt
        local ps, pd = head:find("%%%d?%$?s"), head:find("%%%d?%$?d")
        if ps and pd then
            XP_PATTERNS[#XP_PATTERNS + 1] = { pattern = "^" .. FormatPattern(head), nameFirst = ps < pd }
        end
    end
end

local function ParseXPText(text)
    if type(text) ~= "string" then return nil end
    for _, p in ipairs(XP_PATTERNS) do
        local a, b = text:match(p.pattern)
        if a and b then
            if p.nameFirst then return a, tonumber(b) end
            return b, tonumber(a)
        end
    end
end

-- Units and GUIDs -----------------------------------------------------

local function IsCreatureGUID(guid)
    if type(guid) ~= "string" then return false end
    local kind = guid:match("^(%a+)%-")
    return kind == "Creature" or kind == "Vehicle"
end

local UNIT_TOKENS = { "target", "mouseover", "softinteract", "softenemy", "focus", "pettarget" }
for i = 1, 4 do UNIT_TOKENS[#UNIT_TOKENS + 1] = "party" .. i .. "target" end
for i = 1, 40 do UNIT_TOKENS[#UNIT_TOKENS + 1] = "nameplate" .. i end

-- Finds a unit token that currently points at this GUID (usually your target).
local function FindUnit(guid)
    for _, unit in ipairs(UNIT_TOKENS) do
        local g = Safe(UnitGUID, unit)
        if g and g == guid then return unit end
    end
end

local function UnitNameSafe(unit)
    if not unit then return nil end
    return (Safe(UnitName, unit))
end

local function IsTapDenied(unit)
    return UnitIsTapDenied and Safe(UnitIsTapDenied, unit) == true
end

local function IsElite(unit)
    local c = Safe(UnitClassification, unit)
    return c == "elite" or c == "rareelite" or c == "worldboss"
end

-- Critters, totems and companion pets never drop anything; counting them
-- would just drag the average down.
local SKIP_TYPE_IDS = { [8] = true, [11] = true, [12] = true }
local SKIP_TYPE_NAMES = { ["Critter"] = true, ["Totem"] = true, ["Non-combat Pet"] = true }

local function IsJunkCreature(unit)
    local typeName, typeID = Safe(UnitCreatureType, unit)
    return (typeID and SKIP_TYPE_IDS[typeID]) or (typeName and SKIP_TYPE_NAMES[typeName]) or false
end

local function ShouldSkipUnit(unit)
    if IsTapDenied(unit) then return true end -- someone else's kill; you get no loot
    return IsJunkCreature(unit)
end

-- Where you are -------------------------------------------------------

local function InInstance()
    if not IsInInstance then return false end
    local inside, kind = Safe(IsInInstance)
    return inside and (kind == "party" or kind == "raid") or false
end

local function InGroup()
    if IsInGroup then return Safe(IsInGroup) and true or false end
    return (GetNumGroupMembers and (Safe(GetNumGroupMembers) or 0) > 0) or false
end

-- Whether a kill made right now should be recorded, given the options.
local function ContextAllowed()
    if InInstance() and not db.includeInstances then return false end
    if InGroup() and not db.includeGroup then return false end
    return true
end

------------------------------------------------------------------------
-- Stats
------------------------------------------------------------------------

-- kills/value/coin/items count kills you looted (or that dropped nothing);
-- xp/xpKills count every kill that gave experience, looted or not.
local function NewStats()
    return { kills = 0, value = 0, coin = 0, items = 0, itemCount = 0, best = 0,
             xp = 0, xpKills = 0, loot = {} }
end

local function Upgrade(s)
    for k, v in pairs(NewStats()) do
        if s[k] == nil then s[k] = v end
    end
    return s
end

-- The "since reset" bucket is saved, so it keeps adding up across logouts
-- and /reloads until you reset it. `played` is in-game seconds.
local function NewRun()
    local r = NewStats()
    r.since = Now()
    r.played = 0
    return r
end

local function NewMob()
    return { kills = 0, value = 0, coin = 0, items = 0, best = 0, drops = {}, xpAt = {} }
end

local function GetMob(name, create)
    local mob = db.mobs[name]
    if not mob and create then
        mob = NewMob()
        db.mobs[name] = mob
    end
    if mob then
        mob.coin, mob.items, mob.best = mob.coin or 0, mob.items or 0, mob.best or 0
        mob.drops, mob.xpAt = mob.drops or {}, mob.xpAt or {}
    end
    return mob
end

local function RunSeconds()
    return db.run.played + (GetTime() - runStart)
end

local function Average(s)
    return s.kills > 0 and s.value / s.kills or 0
end

local function AverageXP(s)
    return (s.xpKills or 0) > 0 and s.xp / s.xpKills or 0
end

local function Plural(n, word)
    return n .. " " .. word .. (n == 1 and "" or "s")
end

local function AddLoot(bucket, item)
    local id = item.id or item.link
    local e = bucket[id]
    if not e then
        e = { name = item.name, quality = item.quality, qty = 0, times = 0, value = 0 }
        bucket[id] = e
    end
    e.name = item.name or e.name
    e.quality = item.quality or e.quality
    e.qty = e.qty + item.qty
    e.times = e.times + 1
    e.value = e.value + (item.price or 0) * item.qty
end

-- Experience ----------------------------------------------------------

local function PlayerLevel()
    return Safe(UnitLevel, "player") or 1
end

local function MaxLevel()
    if GetMaxPlayerLevel then return Safe(GetMaxPlayerLevel) or 60 end
    return MAX_PLAYER_LEVEL or 60
end

local function XPToLevel()
    if PlayerLevel() >= MaxLevel() then return nil end
    local cur, max = Safe(UnitXP, "player"), Safe(UnitXPMax, "player")
    if not (cur and max and max > 0) then return nil end
    return max - cur, Safe(GetXPExhaustion) or 0
end

-- Vanilla's formula, used to estimate XP for enemies you haven't killed at
-- your current level. Solo, unrested.
local function ZeroDifference(pl)
    if pl < 8 then return 5 elseif pl < 10 then return 6 elseif pl < 12 then return 7
    elseif pl < 16 then return 8 elseif pl < 20 then return 9 elseif pl < 30 then return 11
    elseif pl < 40 then return 12 elseif pl < 45 then return 13 elseif pl < 50 then return 14
    elseif pl < 55 then return 15 elseif pl < 60 then return 16 end
    return 17
end

local function GrayLevel(pl)
    if pl <= 5 then return 0 end
    if pl < 40 then return pl - math.floor(pl / 10) - 5 end
    return pl - math.floor(pl / 5) - 1
end

local function EstimateXP(pl, ml, elite)
    if not (pl and ml) or ml <= 0 then return nil end
    local base = pl * 5 + 45
    local xp
    if ml >= pl then
        xp = base * (1 + 0.05 * math.min(ml - pl, 4))
    elseif ml > GrayLevel(pl) then
        xp = base * (1 - (pl - ml) / ZeroDifference(pl))
    else
        xp = 0
    end
    if elite then xp = xp * 2 end
    return math.floor(xp + 0.5)
end

local function RecordXP(name, xp)
    if not (name and xp and xp > 0) then return end
    if not ContextAllowed() then return end
    table.insert(xpLog, 1, { name = name, xp = xp, t = GetTime() })
    while #xpLog > XP_LOG_MAX do table.remove(xpLog) end

    for _, s in ipairs({ db.run, db.total }) do
        s.xp = s.xp + xp
        s.xpKills = s.xpKills + 1
    end
    local mob = GetMob(name, true)
    local key = PlayerLevel()
    local at = mob.xpAt[key] or { xp = 0, n = 0 }
    mob.xpAt[key] = at
    at.xp, at.n = at.xp + xp, at.n + 1
    mob.xpTotal = (mob.xpTotal or 0) + xp
    mob.xpKills = (mob.xpKills or 0) + 1
    Notify()
end

-- Matches a finished kill to the XP message it produced (they arrive
-- separately: XP at death, loot when you open the corpse).
local function ClaimXP(name)
    if not name then return nil end
    local now = GetTime()
    for _, e in ipairs(xpLog) do
        if not e.used and e.name == name and now - e.t <= KEEP_SECONDS then
            e.used = true
            return e.xp
        end
    end
end

-- Average XP this enemy gives you at your current level, from your kills,
-- or the vanilla formula when you haven't killed one at this level yet.
local function MobXP(mob, mobLevel, elite)
    local pl = PlayerLevel()
    local at = mob and mob.xpAt and mob.xpAt[pl]
    if at and at.n > 0 then return at.xp / at.n, at.n end
    return EstimateXP(pl, mobLevel or (mob and mob.level), elite or (mob and mob.elite)), 0
end

------------------------------------------------------------------------
-- Recording a looted kill
------------------------------------------------------------------------

local function MobLine(mob)
    return ("|cff999999this enemy:|r %s |cff999999over %s, avg|r %s"):format(
        Money(mob.value), Plural(mob.kills, "kill"), Money(mob.value / mob.kills))
end

local function FinishKill(rec, coin, itemValue, itemCount, items)
    rec.state = "done"
    if rec.blocked then return end
    local empty = coin == 0 and itemCount == 0
    if empty and not db.countEmpty then return end

    local value = coin + itemValue
    local name = rec.name or "Unknown enemy"
    items = items or {}

    for _, s in ipairs({ db.run, db.total }) do
        s.kills = s.kills + 1
        s.value = s.value + value
        s.coin = s.coin + coin
        s.items = s.items + itemValue
        s.itemCount = s.itemCount + itemCount
        if value > s.best then s.best, s.bestName = value, name end
        for _, item in ipairs(items) do AddLoot(s.loot, item) end
    end

    local mob = GetMob(name, true)
    mob.kills = mob.kills + 1
    mob.value = mob.value + value
    mob.coin = mob.coin + coin
    mob.items = mob.items + itemValue
    if value > mob.best then mob.best = value end
    if rec.level then mob.level = rec.level end
    if rec.elite ~= nil then mob.elite = rec.elite end
    mob.last = Now()
    -- Count each item once per kill for its drop rate, even if it took two slots.
    local seen = {}
    for _, item in ipairs(items) do
        local id = item.id or item.link
        local d = mob.drops[id]
        if not d then
            d = { name = item.name, quality = item.quality, times = 0, qty = 0 }
            mob.drops[id] = d
        end
        d.name, d.quality = item.name or d.name, item.quality or d.quality
        d.price = item.price or d.price
        d.qty = d.qty + item.qty
        if not seen[id] then
            seen[id] = true
            d.times = d.times + 1
        end
    end

    if rec.level then
        local lv = db.levels[rec.level] or { kills = 0, value = 0 }
        db.levels[rec.level] = lv
        lv.kills, lv.value = lv.kills + 1, lv.value + value
    end

    local xp = ClaimXP(name)
    table.insert(db.recent, 1, { name = name, value = value, coin = coin, items = itemCount, xp = xp,
                                 time = Now(), inst = rec.inst or nil, group = rec.group or nil })
    while #db.recent > RECENT_MAX do table.remove(db.recent) end
    Notify()

    if db.quiet then return end

    local detail
    if empty then
        detail = "|cff999999no loot|r"
    elseif coin > 0 and itemCount > 0 then
        detail = ("%s  |cff999999(%s coin + %s in %s)|r"):format(Money(value), Money(coin), Money(itemValue), Plural(itemCount, "item"))
    elseif itemCount > 0 then
        detail = ("%s  |cff999999(%s)|r"):format(Money(value), Plural(itemCount, "item"))
    else
        detail = ("%s  |cff999999(coin)|r"):format(Money(value))
    end
    if xp then detail = detail .. ("  |cff8080ff+%d XP|r"):format(xp) end

    Print(("%s: %s"):format(name, detail))
    if db.verbose then
        Print(("   %s  |cff999999- all kills: total|r %s|cff999999, avg|r %s |cff999999over %s since reset|r"):format(
            MobLine(mob), Money(db.run.value), Money(Average(db.run)), Plural(db.run.kills, "kill")))
    end
end

------------------------------------------------------------------------
-- Kills
------------------------------------------------------------------------

local function Prune()
    local now = GetTime()
    for guid, rec in pairs(kills) do
        if now - rec.t > KEEP_SECONDS and rec.state ~= "valuing" then
            kills[guid] = nil
        end
    end
end

local function NewKill(guid, unit)
    local rec = { t = GetTime(), name = UnitNameSafe(unit), state = "pending",
                  inst = InInstance(), group = InGroup() }
    if unit then
        local lvl = Safe(UnitLevel, unit)
        if lvl and lvl > 0 then rec.level = lvl end
        rec.elite = IsElite(unit)
    end
    rec.blocked = not ContextAllowed()
    kills[guid] = rec
    return rec
end

-- A couple of seconds after a kill, ask the client whether the corpse has
-- loot at all. If it doesn't, it's a zero-value kill. If it does, wait for
-- the player to loot it (a corpse that's never looted isn't counted, since
-- we can't know what was on it). In a group an unlootable corpse may just be
-- someone else's to loot, so this is only done solo.
local function CheckEmpty(guid, rec, attempt)
    if kills[guid] ~= rec or rec.state ~= "pending" or not CanLootUnit then return end
    if rec.group then return end
    local ok, hasLoot = pcall(CanLootUnit, guid)
    if not ok or Readable(hasLoot) ~= false then return end

    local unit = FindUnit(guid)
    if unit and IsTapDenied(unit) then
        rec.state = "ignored"
    elseif attempt < 2 then
        C_Timer.After(EMPTY_CHECK_DELAY, function() CheckEmpty(guid, rec, attempt + 1) end)
    else
        FinishKill(rec, 0, 0, 0)
    end
end

local function OnPartyKill(_, targetGUID)
    local guid = Readable(targetGUID)
    if not IsCreatureGUID(guid) or kills[guid] then return end
    Prune()

    local unit = FindUnit(guid)
    local rec = NewKill(guid, unit)
    if unit and ShouldSkipUnit(unit) then
        rec.state = "ignored"
        return
    end
    C_Timer.After(EMPTY_CHECK_DELAY, function() CheckEmpty(guid, rec, 1) end)
end

------------------------------------------------------------------------
-- Loot
------------------------------------------------------------------------

local SLOT_ITEM = Enum and Enum.LootSlotType and Enum.LootSlotType.Item or 1
local SLOT_MONEY = Enum and Enum.LootSlotType and Enum.LootSlotType.Money or 2

-- GetLootSourceInfo returns guid1, qty1, guid2, qty2, ... (several corpses
-- can share a slot with area loot).
local function PackSources(...)
    local list = {}
    for i = 1, select("#", ...), 2 do
        local guid = Readable((select(i, ...)))
        local qty = Readable((select(i + 1, ...)))
        if type(guid) == "string" then
            list[#list + 1] = { guid = guid, qty = tonumber(qty) }
        end
    end
    return list
end

-- Decides whether loot from this source counts as a kill's drop, and if so
-- returns a fresh accumulator for it.
local function StartEntry(guid, gathering)
    if not IsCreatureGUID(guid) then return nil end -- chests, herbs, ore, fishing, containers
    local rec = kills[guid]

    if gathering then
        -- Skinning a corpse that was never looted means it dropped nothing.
        if rec and rec.state == "pending" then FinishKill(rec, 0, 0, 0) end
        return nil
    end

    if rec and rec.state ~= "pending" then return nil end -- already counted, or ignored

    local unit = FindUnit(guid)
    if not rec then
        -- No kill event seen (e.g. your pet landed the killing blow). Only
        -- count it if it's actually a corpse, never a living target.
        if unit and not Safe(UnitIsDead, unit) then return nil end
        rec = NewKill(guid, unit)
    end
    rec.name = rec.name or UnitNameSafe(unit)
    rec.state = "valuing"
    return { rec = rec, coin = 0, items = {}, count = 0 }
end

-- In a group the corpse's coin is split; once we know the split, scale it.
local function SettleShare(entry, ratio)
    if entry.settled then return end
    entry.settled = true
    for i, w in ipairs(shareWaiters) do
        if w == entry then table.remove(shareWaiters, i) break end
    end
    local coin = math.floor(entry.coin * (ratio or 1) + 0.5)
    FinishKill(entry.rec, coin, entry.total, entry.count, entry.items)
end

local function Complete(entry)
    if entry.coin > 0 and db.groupShare and entry.rec.group then
        if lastShare and GetTime() - lastShare.t <= SHARE_WAIT then
            SettleShare(entry, lastShare.ratio)
            return
        end
        shareWaiters[#shareWaiters + 1] = entry
        C_Timer.After(SHARE_WAIT, function() SettleShare(entry, 1) end)
        return
    end
    FinishKill(entry.rec, entry.coin, entry.total, entry.count, entry.items)
end

local function ValueItems(entry, attempt)
    local total, missing = 0, false
    for _, item in ipairs(entry.items) do
        if not item.price then
            local name, _, quality, _, _, _, _, _, _, _, price = GetItemInfoCompat(item.link)
            if price then
                item.price, item.name, item.quality = price, Readable(name) or item.name, Readable(quality) or item.quality
            else
                missing = true
                if item.id then RequestItemData(item.id) end
            end
        end
        total = total + (item.price or 0) * item.qty
    end

    if missing and attempt < ITEM_RETRIES then
        C_Timer.After(0.3, function() ValueItems(entry, attempt + 1) end)
        return
    end
    entry.total = total
    Complete(entry)
end

local function OnLootReady()
    if lootHandled then return end
    lootHandled = true
    lootCoinSeen = 0
    if IsFishingLoot and Safe(IsFishingLoot) then return end
    Prune()

    local gathering = GetTime() - lastGather <= GATHER_WINDOW
    if gathering then lastGather = 0 end

    local entries, order = {}, {}
    for slot = 1, (GetNumLootItems() or 0) do
        local slotType = GetLootSlotType(slot)
        local _, slotName, slotQty, _, slotQuality = GetLootSlotInfo(slot)
        local sources = PackSources(GetLootSourceInfo(slot))

        for _, src in ipairs(sources) do
            local entry = entries[src.guid]
            if entry == nil then
                entry = StartEntry(src.guid, gathering) or false
                entries[src.guid] = entry
                if entry then order[#order + 1] = entry end
            end

            if entry then
                if slotType == SLOT_MONEY then
                    local copper = src.qty
                    if #sources == 1 then copper = ParseCoinText(Readable(slotName)) or copper end
                    entry.coin = entry.coin + (copper or 0)
                    lootCoinSeen = lootCoinSeen + (copper or 0)
                elseif slotType == SLOT_ITEM then
                    local link = Readable(GetLootSlotLink(slot))
                    if link then
                        local qty = src.qty or tonumber(Readable(slotQty)) or 1
                        entry.items[#entry.items + 1] = {
                            link = link, id = ItemID(link), qty = qty,
                            name = Readable(slotName), quality = Readable(slotQuality),
                        }
                        entry.count = entry.count + qty
                    end
                end
            end
        end
    end

    for _, entry in ipairs(order) do ValueItems(entry, 1) end
end

local SHARE_PATTERN = "^" .. FormatPattern(LOOT_MONEY_SPLIT or "Your share of the loot is %s.")

local function OnMoneyMessage(text)
    text = Readable(text)
    if type(text) ~= "string" then return end
    local amount = text:match(SHARE_PATTERN)
    local share = amount and ParseCoinText(amount)
    if not share or lootCoinSeen <= 0 then return end
    local ratio = math.min(1, share / lootCoinSeen)
    lastShare = { ratio = ratio, t = GetTime() }
    local waiting = {}
    for i, entry in ipairs(shareWaiters) do waiting[i] = entry end
    for _, entry in ipairs(waiting) do SettleShare(entry, ratio) end
end

-- Remember Skinning / Pick Pocket casts so the loot window they open isn't
-- mistaken for a kill's drop.
local function BuildGatherSpells()
    for _, name in ipairs({ "Skinning", "Pick Pocket", "Herb Gathering", "Mining" }) do
        gatherSpells[name] = true
    end
    for _, id in ipairs({ 8613, 8617, 8618, 10768, 921, 2366, 2575 }) do
        local name = Safe(SpellName, id)
        if name then gatherSpells[name] = true end
    end
end

local function OnSpellcast(_, _, spellID)
    spellID = Readable(spellID)
    if not spellID then return end
    local name = Safe(SpellName, spellID)
    if name and gatherSpells[name] then lastGather = GetTime() end
end

------------------------------------------------------------------------
-- Predictions (tooltip and window)
------------------------------------------------------------------------

-- What a kill of this enemy is expected to be worth, broken into coin and
-- each item's value x how often it drops. Falls back to the average of
-- other enemies of the same level when you haven't killed this one.
local function Predict(name, level)
    local mob = name and db.mobs[name]
    if mob and mob.kills > 0 then
        local drops = {}
        for id, d in pairs(mob.drops or {}) do
            local rate = d.times / mob.kills
            local perDrop = d.times > 0 and d.qty / d.times or 1
            local expected = (d.price or 0) * d.qty / mob.kills
            drops[#drops + 1] = { id = id, name = d.name, quality = d.quality, rate = rate,
                                  qty = perDrop, price = d.price or 0, expected = expected }
        end
        table.sort(drops, function(a, b)
            if a.expected == b.expected then return (a.rate or 0) > (b.rate or 0) end
            return a.expected > b.expected
        end)
        return {
            source = "mob", kills = mob.kills, value = mob.value / mob.kills,
            coin = (mob.coin or 0) / mob.kills, items = (mob.items or 0) / mob.kills,
            total = mob.value, best = mob.best, drops = drops,
        }
    end
    level = level or (mob and mob.level)
    local lv = level and db.levels[level]
    if lv and lv.kills >= 3 then
        return { source = "level", kills = lv.kills, value = lv.value / lv.kills, level = level }
    end
end

ns.Predict, ns.MobXP, ns.XPToLevel, ns.EstimateXP = Predict, MobXP, XPToLevel, EstimateXP
ns.Readable, ns.Safe, ns.IsJunkCreature = Readable, Safe, IsJunkCreature

------------------------------------------------------------------------
-- Resets
------------------------------------------------------------------------

local function ResetRun()
    db.run, runStart = NewRun(), GetTime()
    Notify()
end

local function ResetAll()
    db.total, db.mobs, db.recent, db.levels = NewStats(), {}, {}, {}
    ResetRun()
end

local function ResetMob(name)
    if not db.mobs[name] then return false end
    db.mobs[name] = nil
    Notify()
    return true
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

local function StatsLine(label, s)
    if s.kills == 0 and (s.xpKills or 0) == 0 then return label .. ": no kills yet." end
    local line = ("%s: %s, %s total |cff999999(%s coin, %s items)|r - |cffffffffavg %s per kill|r"):format(
        label, Plural(s.kills, "kill"), Money(s.value), Money(s.coin), Money(s.items), Money(Average(s)))
    if (s.xpKills or 0) > 0 then
        line = line .. (" |cff8080ff- %d XP, avg %d per kill|r"):format(s.xp, AverageXP(s))
    end
    return line
end

local function Duration(seconds)
    local h, m = math.floor(seconds / 3600), math.floor(seconds / 60) % 60
    return h > 0 and ("%dh %dm"):format(h, m) or ("%dm"):format(m)
end

local function SinceText()
    local since = db.run.since
    if not (since and date) then return nil end
    -- "Nov 06, 02:37 PM" -> "Nov 6, 2:37 PM"
    return (date("%b %d, %I:%M %p", since):gsub(" 0(%d)", " %1"))
end

local function SinceLabel()
    local since = SinceText()
    return since and ("Since reset (" .. since .. ")") or "Since reset"
end

-- Shared with the stats window and tooltip.
ns.Money, ns.Average, ns.AverageXP, ns.Plural, ns.Duration = Money, Average, AverageXP, Plural, Duration
ns.RunSeconds, ns.SinceText, ns.ResetRun, ns.ResetAll, ns.ResetMob = RunSeconds, SinceText, ResetRun, ResetAll, ResetMob
ns.Print, ns.Notify = Print, Notify

local function PrintSummary()
    Print(StatsLine(SinceLabel(), db.run))
    local seconds = RunSeconds()
    if seconds >= 180 and (db.run.kills > 0 or db.run.xpKills > 0) then
        local hours = seconds / 3600
        Print(("   per hour: %s, %d XP, %.0f kills  |cff999999(%s played)|r"):format(
            Money(db.run.value / hours), db.run.xp / hours, math.max(db.run.kills, db.run.xpKills) / hours, Duration(seconds)))
    end
    local need = XPToLevel()
    local avgXP = AverageXP(db.run)
    if need and avgXP > 0 then
        Print(("   about %d more kills to level (%d XP to go)"):format(math.ceil(need / avgXP), need))
    end
    Print(StatsLine("All time", db.total))
    if db.total.bestName then
        Print(("   best single kill: %s (%s)"):format(Money(db.total.best), db.total.bestName))
    end
end

local function PrintMobs(n)
    local list = {}
    for name, m in pairs(db.mobs) do
        if m.kills > 0 then
            list[#list + 1] = { name = name, kills = m.kills, avg = m.value / m.kills }
        end
    end
    if #list == 0 then
        Print("No kills recorded yet.")
        return
    end

    -- Prefer enemies you've killed a few times, so one lucky drop doesn't top the list.
    local minKills = 3
    local qualifying = 0
    for _, m in ipairs(list) do
        if m.kills >= minKills then qualifying = qualifying + 1 end
    end
    if qualifying == 0 then minKills = 1 end

    table.sort(list, function(a, b) return a.avg > b.avg end)
    Print(("Best-paying enemies, by average per kill%s:"):format(minKills > 1 and (" (" .. minKills .. "+ kills)") or ""))
    local shown = 0
    for _, m in ipairs(list) do
        if m.kills >= minKills then
            shown = shown + 1
            Print(("   %d. %s - %s  |cff999999(%s)|r"):format(shown, m.name, Money(m.avg), Plural(m.kills, "kill")))
            if shown >= n then break end
        end
    end
end

local TOGGLES = {
    quiet = { key = "quiet", on = "Per-kill messages off.", off = "Per-kill messages on." },
    empty = { key = "countEmpty", on = "Kills that drop nothing count toward the average (as 0).", off = "Kills that drop nothing are left out of the average." },
    dungeons = { key = "includeInstances", on = "Dungeon and raid enemies are counted.", off = "Dungeon and raid enemies are no longer counted." },
    group = { key = "includeGroup", on = "Kills while in a party or raid are counted.", off = "Kills while in a party or raid are no longer counted." },
    share = { key = "groupShare", on = "In a group, only your share of the coin is counted.", off = "In a group, the corpse's full coin is counted." },
    tooltip = { key = "tooltip", on = "Enemy tooltips show kill value and XP.", off = "Enemy tooltips left alone." },
    verbose = { key = "verbose", on = "Per-kill messages include this enemy's totals.", off = "Per-kill messages are one line." },
}

local function PrintHelp()
    Print("commands:")
    Print("   /kv - open or close the window")
    Print("   /kv stats - print totals, averages and per-hour rates in chat")
    Print("   /kv mobs [n] - best-paying enemies by average value, in chat")
    Print("   /kv quiet | empty | dungeons | group | share | tooltip | verbose - toggle an option")
    Print("   /kv reset - start the since-reset totals over;  /kv reset all - clear everything")
    Print("   /kv reset mob <name> - forget one enemy's stats")
end

SLASH_KILLVALUE1 = "/kv"
SLASH_KILLVALUE2 = "/killvalue"
SlashCmdList.KILLVALUE = function(msg)
    local cmd, arg = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "show" then
        if ns.ToggleWindow then ns.ToggleWindow() else PrintSummary() end
    elseif cmd == "stats" then
        PrintSummary()
    elseif cmd == "mobs" then
        PrintMobs(tonumber(arg) or 10)
    elseif TOGGLES[cmd] then
        local t = TOGGLES[cmd]
        db[t.key] = not db[t.key]
        Print(db[t.key] and t.on or t.off)
        Notify()
    elseif cmd == "reset" then
        local lower = arg:lower()
        if lower == "all" then
            ResetAll()
            Print("All stats for this character cleared.")
        elseif lower:match("^mob%s") then
            local name = arg:match("^%S+%s+(.+)$")
            if name and ResetMob(name) then
                Print(("Stats for %s cleared."):format(name))
            else
                Print(("No stats recorded for %s."):format(name or "?"))
            end
        else
            ResetRun()
            Print("Since-reset totals started over from 0. All-time stats are kept.")
        end
    else
        PrintHelp()
    end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local frame = CreateFrame("Frame")

local function Init()
    KillValueDB = KillValueDB or {}
    db = KillValueDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    db.total = Upgrade(db.total or NewStats())
    db.run = Upgrade(db.run or NewRun())
    db.run.played = db.run.played or 0
    db.mobs = db.mobs or {}
    db.recent = db.recent or {}
    db.levels = db.levels or {}
    db.version = 2
    runStart = GetTime()
    ns.db = db
    BuildGatherSpells()

    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:RegisterEvent("LOOT_READY")
    frame:RegisterEvent("LOOT_OPENED")
    frame:RegisterEvent("LOOT_CLOSED")
    frame:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
    frame:RegisterEvent("CHAT_MSG_MONEY")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

    local ok, registered = pcall(frame.RegisterEvent, frame, "PARTY_KILL")
    if not ok or registered == false then
        Print("this client has no PARTY_KILL event, so only kills you loot will be counted.")
    end

    if ns.OnInit then ns.OnInit() end
end

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == ADDON_NAME then
            self:UnregisterEvent("ADDON_LOADED")
            Init()
        end
    elseif event == "PARTY_KILL" then
        OnPartyKill(...)
    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
        OnLootReady()
    elseif event == "LOOT_CLOSED" then
        lootHandled = false
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        RecordXP(ParseXPText(Readable((...))))
    elseif event == "CHAT_MSG_MONEY" then
        OnMoneyMessage((...))
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        OnSpellcast(...)
    elseif event == "PLAYER_LOGOUT" then
        -- Fires on logout and /reload, just before saved variables are written.
        db.run.played, runStart = RunSeconds(), GetTime()
    end
end)

-- For the offline test harness.
ns._test = { ParseXPText = ParseXPText, ParseCoinText = ParseCoinText, FormatPattern = FormatPattern }
