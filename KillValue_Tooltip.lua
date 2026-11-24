-- Adds "what is this enemy worth" lines to enemy tooltips: the expected value
-- of a kill (average coin + each item's vendor value x how often it drops),
-- its most valuable drops, what you've earned from it so far, and the XP a
-- kill gives you with how many more you'd need to level.

local _, ns = ...

local GREY, XPC = "|cff999999", "|cff8080ff"
local QUALITY_COLOR = {
    [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ff1eff00", [3] = "ff0070dd", [4] = "ffa335ee", [5] = "ffff8000",
}

local function ItemText(d)
    local color = QUALITY_COLOR[d.quality or 1] or "ffffffff"
    return ("|c%s%s|r"):format(color, d.name or ("item " .. tostring(d.id)))
end

local function Percent(rate)
    local p = rate * 100
    if p >= 10 then return ("%d%%"):format(p + 0.5) end
    return ("%.1f%%"):format(p)
end

local function AddLines(tooltip, unit)
    local db, Safe = ns.db, ns.Safe
    if not (db and db.tooltip) then return end
    if Safe(UnitIsPlayer, unit) then return end
    if not Safe(UnitCanAttack, "player", unit) then return end
    if ns.IsJunkCreature(unit) then return end

    local name = Safe(UnitName, unit)
    if not name then return end
    local level = Safe(UnitLevel, unit)
    if level and level <= 0 then level = nil end
    local c = Safe(UnitClassification, unit)
    local elite = c == "elite" or c == "rareelite" or c == "worldboss"

    local Money = ns.Money
    local p = ns.Predict(name, level)
    local added = false

    if p and p.source == "mob" then
        tooltip:AddDoubleLine("|cffffd200Kill value|r", Money(p.value) .. GREY .. "  avg of " .. ns.Plural(p.kills, "kill") .. "|r", 1, 1, 1, 1, 1, 1)
        if p.coin > 0 or p.items > 0 then
            tooltip:AddDoubleLine(GREY .. "  coin / items|r", Money(p.coin) .. GREY .. "  +  |r" .. Money(p.items), 1, 1, 1, 1, 1, 1)
        end
        local shown = 0
        for _, d in ipairs(p.drops) do
            if shown >= (db.tooltipDrops or 3) then break end
            if d.expected > 0 then
                shown = shown + 1
                local qty = d.qty > 1.05 and (" x%.1f"):format(d.qty) or ""
                tooltip:AddDoubleLine(("  %s %s%s%s|r"):format(ItemText(d), GREY, Percent(d.rate), qty),
                    "~" .. Money(d.expected), 1, 1, 1, 1, 1, 1)
            end
        end
        tooltip:AddDoubleLine(GREY .. "  earned from these|r", Money(p.total) .. GREY .. "  best " .. "|r" .. Money(p.best), 1, 1, 1, 1, 1, 1)
        added = true
    elseif p and p.source == "level" then
        tooltip:AddDoubleLine("|cffffd200Kill value|r", "~" .. Money(p.value) .. GREY .. "  (level " .. p.level .. " avg)|r", 1, 1, 1, 1, 1, 1)
        added = true
    end

    local need, rested = ns.XPToLevel()
    if need then
        local mob = db.mobs[name]
        local xp, n = ns.MobXP(mob, level, elite)
        if xp and xp > 0 then
            local note = n > 0 and ("avg of " .. n) or "estimate"
            local restedNote = (n == 0 and rested and rested > 0) and " (x2 rested)" or ""
            tooltip:AddDoubleLine(XPC .. "XP per kill|r",
                ("%s%d|r%s  %s|r"):format(XPC, xp + 0.5, GREY, note .. restedNote), 1, 1, 1, 1, 1, 1)
            tooltip:AddDoubleLine(GREY .. "  kills to level|r", tostring(math.ceil(need / xp)), 1, 1, 1, 1, 1, 1)
            added = true
        elseif xp == 0 then
            tooltip:AddDoubleLine(XPC .. "XP per kill|r", GREY .. "none (gray)|r", 1, 1, 1, 1, 1, 1)
            added = true
        end
    end

    if added then tooltip:Show() end
end

local function OnUnitTooltip(tooltip)
    if tooltip ~= GameTooltip then return end
    local unit
    if tooltip.GetUnit then
        local ok, _, u = pcall(tooltip.GetUnit, tooltip)
        unit = ok and ns.Readable(u) or nil
    end
    unit = unit or "mouseover"
    if not ns.Safe(UnitExists, unit) then return end
    pcall(AddLines, tooltip, unit)
end

function ns.OnInit()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
    elseif GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetUnit", OnUnitTooltip)
    end
end
