-- KillValue window. Open it with /kv, or from the addons menu by the minimap.

local _, ns = ...

local WIDTH, HEIGHT = 610, 510
local ROWS, ROW_H = 17, 18
local GREY, XPC = "|cff999999", "|cff8080ff"
local QUALITY_COLOR = {
    [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ff1eff00", [3] = "ff0070dd", [4] = "ffa335ee", [5] = "ffff8000",
}

local window
local panels, tabButtons = {}, {}
local activeTab = "overview"
local Refresh -- defined below

local state = {
    mobSort = "avg", mobDesc = true, mobOffset = 0,
    lootSort = "value", lootDesc = true, lootOffset = 0, lootAll = false,
    zoneSort = "perHour", zoneDesc = true, zoneOffset = 0,
    recentOffset = 0,
    detail = nil, dropOffset = 0,
}

------------------------------------------------------------------------
-- Small widget helpers
------------------------------------------------------------------------

local function Text(parent, font, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    if text then fs:SetText(text) end
    return fs
end

local function CheckBox(parent, y, label, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", 8, y)
    local fs = Text(parent, "GameFontHighlight", label)
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        if ns.Notify then ns.Notify() end
    end)
    cb.Refresh = function(self) self:SetChecked(get() and true or false) end
    return cb
end

local function Button(parent, label, w, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 120, 22)
    b:SetText(label)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

-- A button that asks for a second click before doing anything destructive.
local function ConfirmButton(parent, label, onConfirm, w)
    local b = Button(parent, label, w or 170)
    b:SetScript("OnClick", function(self)
        if self.armed then
            self.armed = nil
            self:SetText(label)
            onConfirm()
        else
            self.armed = true
            self:SetText("Click again to confirm")
            C_Timer.After(3, function()
                if self.armed then
                    self.armed = nil
                    self:SetText(label)
                end
            end)
        end
    end)
    return b
end

local function Clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function Ago(t)
    if not (t and time) then return "" end
    local s = math.max(0, time() - t)
    if s < 60 then return "just now" end
    if s < 3600 then return math.floor(s / 60) .. "m ago" end
    if s < 86400 then return math.floor(s / 3600) .. "h ago" end
    return math.floor(s / 86400) .. "d ago"
end

local function ItemText(e)
    local color = QUALITY_COLOR[e.quality or 1] or "ffffffff"
    return ("|c%s%s|r"):format(color, e.name or "?")
end

local function Percent(rate)
    local p = rate * 100
    if p >= 10 then return ("%d%%"):format(p + 0.5) end
    return ("%.1f%%"):format(p)
end

local function XPText(xp)
    if not xp or xp <= 0 then return GREY .. "-|r" end
    return XPC .. math.floor(xp + 0.5) .. "|r"
end

local function Sort(list, key, desc, tiebreak)
    table.sort(list, function(a, b)
        local x, y = a[key], b[key]
        if x == y then return a[tiebreak] < b[tiebreak] end
        if desc then return x > y end
        return x < y
    end)
end

-- A table of rows: column headers, `rows` lines of cells, mouse-wheel scrolling.
local function BuildTable(panel, columns, opts)
    local rows = opts.rows or ROWS
    panel.columns, panel.rowCount = columns, rows
    panel.headers = {}
    for i, col in ipairs(columns) do
        local b = CreateFrame("Button", nil, panel)
        b:SetSize(col.w, ROW_H)
        b:SetPoint("TOPLEFT", col.x, 0)
        b.label = Text(b, "GameFontNormal", col.label)
        b.label:SetAllPoints()
        b.label:SetJustifyH(col.justify)
        if opts.onHeaderClick and col.key then
            b:SetScript("OnClick", function() opts.onHeaderClick(col) end)
        end
        panel.headers[i] = b
    end

    local line = panel:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.15)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 0, -ROW_H - 1)
    line:SetPoint("TOPRIGHT", 0, -ROW_H - 1)

    panel.rows = {}
    for r = 1, rows do
        local y = -ROW_H - 4 - (r - 1) * ROW_H
        local row = { cells = {} }
        if r % 2 == 0 then
            local shade = panel:CreateTexture(nil, "BACKGROUND")
            shade:SetColorTexture(1, 1, 1, 0.04)
            shade:SetHeight(ROW_H)
            shade:SetPoint("TOPLEFT", 0, y + 2)
            shade:SetPoint("TOPRIGHT", 0, y + 2)
        end
        if opts.onRowClick then
            local hit = CreateFrame("Button", nil, panel)
            hit:SetHeight(ROW_H)
            hit:SetPoint("TOPLEFT", 0, y + 2)
            hit:SetPoint("TOPRIGHT", 0, y + 2)
            local hl = hit:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 0.82, 0, 0.12)
            hit:SetScript("OnClick", function() if row.item then opts.onRowClick(row.item) end end)
            row.hit = hit
        end
        for c, col in ipairs(columns) do
            local fs = Text(panel, "GameFontHighlight")
            fs:SetWidth(col.w)
            fs:SetPoint("TOPLEFT", col.x, y)
            fs:SetJustifyH(col.justify)
            fs:SetWordWrap(false)
            row.cells[c] = fs
        end
        panel.rows[r] = row
    end

    panel.footer = Text(panel, "GameFontDisableSmall")
    panel.footer:SetPoint("TOPLEFT", 2, -ROW_H - 8 - rows * ROW_H)
    panel.empty = Text(panel, "GameFontDisable", opts.emptyText or "No kills recorded yet.")
    panel.empty:SetPoint("TOP", 0, -ROW_H * 4)

    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta) opts.onScroll(delta) end)
end

local function SortArrows(panel, key, desc)
    for i, col in ipairs(panel.columns) do
        local arrow = (col.key and col.key == key) and (desc and " v" or " ^") or ""
        panel.headers[i].label:SetText(col.label .. arrow)
    end
end

local function FillRows(panel, list, offset, cellsFor)
    for r = 1, panel.rowCount do
        local item = list[offset + r]
        local values = item and cellsFor(item) or nil
        local row = panel.rows[r]
        row.item = item
        if row.hit then row.hit:SetShown(item ~= nil) end
        for c, fs in ipairs(row.cells) do
            fs:SetText(values and values[c] or "")
        end
    end
    panel.empty:SetShown(#list == 0)
end

local function Footer(panel, list, offset, noun, hint)
    local n = panel.rowCount
    if #list > n then
        panel.footer:SetText(("%d-%d of %d %s - scroll for more%s"):format(
            offset + 1, math.min(#list, offset + n), #list, noun, hint and (", " .. hint) or ""))
    elseif #list > 0 then
        panel.footer:SetText(#list .. " " .. noun .. (hint and (" - " .. hint) or ""))
    else
        panel.footer:SetText("")
    end
end

local function HeaderToggle(stateKey, descKey, offsetKey, ascendingKeys)
    return function(col)
        if state[stateKey] == col.key then
            state[descKey] = not state[descKey]
        else
            state[stateKey], state[descKey] = col.key, not ascendingKeys[col.key]
        end
        state[offsetKey] = 0
        Refresh()
    end
end

------------------------------------------------------------------------
-- Overview tab
------------------------------------------------------------------------

local function BuildOverview(panel)
    local rows, y = {}, 0

    local function Header(label)
        local h = Text(panel, "GameFontNormalLarge", label)
        h:SetPoint("TOPLEFT", 4, y)
        y = y - 24
        return h
    end

    local function Row(key, label)
        Text(panel, "GameFontNormal", label):SetPoint("TOPLEFT", 16, y)
        local v = Text(panel, "GameFontHighlight")
        v:SetPoint("TOPLEFT", 170, y)
        v:SetJustifyH("LEFT")
        rows[key] = v
        y = y - ROW_H
    end

    local runHeader = Header("Since reset")
    panel.since = Text(panel, "GameFontDisableSmall")
    panel.since:SetPoint("LEFT", runHeader, "RIGHT", 8, -1)
    Row("runKills", "Kills")
    Row("runTotal", "Total value")
    Row("runAvg", "Average per kill")
    Row("runSplit", "Coin / items")
    Row("runHour", "Per hour played")
    Row("runFight", "Per hour fighting")
    Row("runXP", "Experience")
    Row("runLevel", "To next level")
    Row("runBest", "Best kill")
    Row("goal", "Gold goal")

    y = y - 10
    Header("All time")
    Row("allKills", "Kills")
    Row("allTotal", "Total value")
    Row("allAvg", "Average per kill")
    Row("allXP", "Experience")
    Row("allBest", "Best kill")

    y = y - 14
    local resetRun = ConfirmButton(panel, "Reset since-reset totals", ns.ResetRun, 200)
    resetRun:SetPoint("TOPLEFT", 10, y)
    local resetAll = ConfirmButton(panel, "Reset everything", ns.ResetAll)
    resetAll:SetPoint("LEFT", resetRun, "RIGHT", 12, 0)

    panel.values = rows
end

local function BestText(s)
    if not s.bestName then return GREY .. "-|r" end
    return ns.Money(s.best) .. "  " .. GREY .. s.bestName .. "|r"
end

local function XPLine(s)
    if (s.xpKills or 0) == 0 then return GREY .. "-|r" end
    return ("%s%d XP|r  %s(avg %d over %s)|r"):format(XPC, s.xp, GREY, ns.AverageXP(s) + 0.5, ns.Plural(s.xpKills, "kill"))
end

local function RefreshOverview(panel)
    local run, all, v = ns.db.run, ns.db.total, panel.values
    local Money, Average = ns.Money, ns.Average

    local since = ns.SinceText()
    panel.since:SetText(since and ("(" .. since .. ")") or "")

    v.runKills:SetText(run.kills .. ((run.xpKills or 0) > run.kills and (GREY .. "  (" .. run.xpKills .. " gave XP)|r") or ""))
    v.runTotal:SetText(Money(ns.StatsValue(run)) .. (ns.UseAuction() and (GREY .. "  (auction prices)|r") or ""))
    v.runAvg:SetText(Money(Average(run)))
    v.runSplit:SetText(Money(run.coin) .. GREY .. "  /  |r" .. Money(ns.StatsItems(run)) ..
        GREY .. "  (" .. ns.Plural(run.itemCount or 0, "item") .. ")|r")
    local seconds = ns.RunSeconds()
    local hours = seconds / 3600
    if (run.kills > 0 or run.xpKills > 0) and seconds >= 180 then
        v.runHour:SetText(("%s  %s%d XP|r  %s%.0f kills  (%s played)|r"):format(
            Money(ns.StatsValue(run) / hours), XPC, run.xp / hours, GREY,
            math.max(run.kills, run.xpKills) / hours, ns.Duration(seconds)))
    else
        v.runHour:SetText(("%s-  (%s played)|r"):format(GREY, ns.Duration(seconds)))
    end
    if (run.combat or 0) >= 60 then
        v.runFight:SetText(("%s  %s%d XP|r  %s(%s in combat, %d%% of played)|r"):format(
            Money(ns.StatsValue(run) * 3600 / run.combat), XPC, run.xp * 3600 / run.combat, GREY,
            ns.Duration(run.combat), math.min(100, run.combat / math.max(1, seconds) * 100)))
    else
        v.runFight:SetText(GREY .. "-|r")
    end
    v.runXP:SetText(XPLine(run))

    local need = ns.XPToLevel()
    local avgXP = ns.AverageXP(run)
    if not need then
        v.runLevel:SetText(GREY .. "max level|r")
    elseif avgXP > 0 then
        local text = ("%d XP  %s~%d kills|r"):format(need, GREY, math.ceil(need / avgXP))
        if seconds >= 180 and run.xp > 0 then
            text = text .. GREY .. (", ~%s at this pace|r"):format(ns.Duration(need / (run.xp / seconds)))
        end
        v.runLevel:SetText(text)
    else
        v.runLevel:SetText(need .. " XP")
    end
    v.runBest:SetText(BestText(run))
    v.goal:SetText(ns.GoalText() or (GREY .. "none - set one on the Options tab or with /kv goal 100g|r"))

    v.allKills:SetText(tostring(all.kills))
    v.allTotal:SetText(Money(ns.StatsValue(all)))
    v.allAvg:SetText(Money(Average(all)))
    v.allXP:SetText(XPLine(all))
    v.allBest:SetText(BestText(all))
end

------------------------------------------------------------------------
-- Enemies tab (and the per-enemy detail view)
------------------------------------------------------------------------

local MOB_COLUMNS = {
    { key = "name",    label = "Enemy",      x = 4,   w = 160, justify = "LEFT" },
    { key = "level",   label = "Lvl",        x = 166, w = 28,  justify = "RIGHT" },
    { key = "kills",   label = "Kills",      x = 198, w = 40,  justify = "RIGHT" },
    { key = "avg",     label = "Avg / kill", x = 242, w = 88,  justify = "RIGHT" },
    { key = "xp",      label = "XP",         x = 334, w = 40,  justify = "RIGHT" },
    { key = "perHour", label = "/ fight hr", x = 378, w = 92,  justify = "RIGHT" },
    { key = "total",   label = "Total",      x = 474, w = 100, justify = "RIGHT" },
}

local function MobList()
    local list = {}
    for name, m in pairs(ns.db.mobs) do
        if m.kills > 0 or (m.xpKills or 0) > 0 then
            local xp = ns.MobXP(m)
            local total = ns.MobValue(m)
            local avg = m.kills > 0 and total / m.kills or 0
            local kt = (m.timed or 0) >= ns.MIN_TIMED and ns.MobKillTime(m)
            list[#list + 1] = { name = name, kills = m.kills, total = total, level = m.level or 0,
                                avg = avg, xp = xp or 0, perHour = (kt and kt > 0) and avg * 3600 / kt or 0 }
        end
    end
    Sort(list, state.mobSort, state.mobDesc, "name")
    return list
end

local function RefreshMobs(panel)
    SortArrows(panel, state.mobSort, state.mobDesc)
    local list = MobList()
    state.mobOffset = Clamp(state.mobOffset, 0, math.max(0, #list - panel.rowCount))
    FillRows(panel, list, state.mobOffset, function(m)
        return { m.name, m.level > 0 and tostring(m.level) or "", tostring(m.kills),
                 m.kills > 0 and ns.Money(m.avg) or GREY .. "-|r", XPText(m.xp),
                 m.perHour > 0 and ns.Money(m.perHour) or GREY .. "-|r", ns.Money(m.total) }
    end)
    Footer(panel, list, state.mobOffset, #list == 1 and "enemy" or "enemies", "click one for its drops")
end

local SelectTab -- forward

local function BuildMobs(panel)
    BuildTable(panel, MOB_COLUMNS, {
        onHeaderClick = HeaderToggle("mobSort", "mobDesc", "mobOffset", { name = true }),
        onScroll = function(delta)
            state.mobOffset = state.mobOffset - delta * 3
            Refresh()
        end,
        onRowClick = function(m)
            state.detail, state.dropOffset = m.name, 0
            SelectTab("detail")
        end,
    })
end

local DROP_COLUMNS = {
    { label = "Drop",       x = 4,   w = 210, justify = "LEFT" },
    { label = "Chance",     x = 218, w = 60,  justify = "RIGHT" },
    { label = "Qty",        x = 282, w = 40,  justify = "RIGHT" },
    { label = "Each",       x = 326, w = 90,  justify = "RIGHT" },
    { label = "Per kill",   x = 420, w = 150, justify = "RIGHT" },
}
local DETAIL_ROWS = 9

local function BuildDetail(panel)
    panel.title = Text(panel, "GameFontNormalLarge")
    panel.title:SetPoint("TOPLEFT", 4, 0)
    panel.title:SetPoint("RIGHT", panel, "RIGHT", -100, 0)
    panel.title:SetJustifyH("LEFT")

    local back = Button(panel, "< Back", 80, function() SelectTab("mobs") end)
    back:SetPoint("TOPRIGHT", 0, 2)

    panel.lines = {}
    for i = 1, 6 do
        local fs = Text(panel, "GameFontHighlight")
        fs:SetPoint("TOPLEFT", 8, -24 - (i - 1) * ROW_H)
        fs:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
        fs:SetJustifyH("LEFT")
        panel.lines[i] = fs
    end

    local tbl = CreateFrame("Frame", nil, panel)
    tbl:SetPoint("TOPLEFT", 0, -24 - 6 * ROW_H - 8)
    tbl:SetPoint("BOTTOMRIGHT", 0, 30)
    BuildTable(tbl, DROP_COLUMNS, {
        rows = DETAIL_ROWS,
        emptyText = "No item drops seen from this enemy yet.",
        onScroll = function(delta)
            state.dropOffset = state.dropOffset - delta * 3
            Refresh()
        end,
    })
    panel.table = tbl

    panel.reset = ConfirmButton(panel, "Reset this enemy", function()
        ns.ResetMob(state.detail)
        SelectTab("mobs")
    end)
    panel.reset:SetPoint("BOTTOMLEFT", 6, 2)
end

local function RefreshDetail(panel)
    local name = state.detail
    local mob = name and ns.db.mobs[name]
    if not mob then
        SelectTab("mobs")
        return
    end
    local Money = ns.Money
    panel.title:SetText(name .. (mob.level and (GREY .. "  level " .. mob.level .. (mob.elite and " elite" or "") .. "|r") or "") ..
        (mob.zone and (GREY .. "  " .. mob.zone .. "|r") or ""))

    local p = ns.Predict(name)
    local l = panel.lines
    if p and p.source == "mob" then
        l[1]:SetText(("Expected per kill: %s  %s= %s coin + %s items, from %s|r"):format(
            Money(p.value), GREY, Money(p.coin), Money(p.items), ns.Plural(p.kills, "looted kill")))
        l[2]:SetText(("Earned from this enemy: %s   %sbest single kill|r %s"):format(Money(p.total), GREY, Money(p.best)))
    else
        l[1]:SetText(GREY .. "No looted kills yet.|r")
        l[2]:SetText("")
    end

    local xp, n = ns.MobXP(mob)
    if xp and xp > 0 then
        l[3]:SetText(("XP per kill at your level: %s  %s(%s)|r"):format(XPText(xp), GREY,
            n > 0 and ("avg of " .. n) or "estimate"))
        local need = ns.XPToLevel()
        l[4]:SetText(need and ("Kills of this enemy to level: %d   %s(%d XP to go)|r"):format(
            math.ceil(need / xp), GREY, need) or "")
    else
        l[3]:SetText(XPC .. "XP:|r " .. GREY .. ((mob.xpKills or 0) > 0 and "none at your level" or "-") .. "|r")
        l[4]:SetText("")
    end
    local kt = ns.MobKillTime(mob)
    if kt then
        local xph = ns.MobXPPerHour(mob, xp)
        l[6]:SetText(("Fighting: ~%ds per kill  %s(%s)|r   %s%s|r"):format(kt + 0.5, GREY, ns.Plural(mob.timed, "timed kill"),
            p and p.perHour and (Money(p.perHour) .. GREY .. " per fight hour|r") or "",
            xph and ("   " .. XPC .. ("%d XP/h"):format(xph)) or ""))
    else
        l[6]:SetText(GREY .. "Fighting time: not measured yet|r")
    end
    l[5]:SetText((mob.xpTotal or 0) > 0 and (GREY .. "Total XP from this enemy: |r" .. XPText(mob.xpTotal) ..
        GREY .. " over " .. ns.Plural(mob.xpKills or 0, "kill") .. "|r") or "")

    local drops = p and p.drops or {}
    local tbl = panel.table
    state.dropOffset = Clamp(state.dropOffset, 0, math.max(0, #drops - tbl.rowCount))
    FillRows(tbl, drops, state.dropOffset, function(d)
        return { ItemText(d), Percent(d.rate), ("%.1f"):format(d.qty), Money(d.price), Money(d.expected) }
    end)
    Footer(tbl, drops, state.dropOffset, "different drops", "Per kill = each x qty x chance")
end

------------------------------------------------------------------------
-- Loot tab
------------------------------------------------------------------------

local LOOT_COLUMNS = {
    { key = "name",  label = "Item",     x = 4,   w = 220, justify = "LEFT" },
    { key = "times", label = "Looted",   x = 228, w = 54,  justify = "RIGHT" },
    { key = "qty",   label = "Qty",      x = 286, w = 50,  justify = "RIGHT" },
    { key = "each",  label = "Each",     x = 340, w = 80,  justify = "RIGHT" },
    { key = "value", label = "Value",    x = 424, w = 150, justify = "RIGHT" },
}

local function LootList()
    local bucket = state.lootAll and ns.db.total.loot or ns.db.run.loot
    local list = {}
    for id, e in pairs(bucket or {}) do
        local each = ns.ItemPrice(id, e.qty > 0 and e.value / e.qty or 0)
        list[#list + 1] = { id = id, name = e.name or tostring(id), quality = e.quality, times = e.times,
                            qty = e.qty, value = each * e.qty, each = each }
    end
    Sort(list, state.lootSort, state.lootDesc, "name")
    return list
end

local function BuildLoot(panel)
    local tbl = CreateFrame("Frame", nil, panel)
    tbl:SetPoint("TOPLEFT", 0, -30)
    tbl:SetPoint("BOTTOMRIGHT")
    BuildTable(tbl, LOOT_COLUMNS, {
        rows = ROWS - 2,
        emptyText = "No items looted yet.",
        onHeaderClick = HeaderToggle("lootSort", "lootDesc", "lootOffset", { name = true }),
        onScroll = function(delta)
            state.lootOffset = state.lootOffset - delta * 3
            Refresh()
        end,
    })
    panel.table = tbl

    panel.toggle = Button(panel, "", 130, function()
        state.lootAll, state.lootOffset = not state.lootAll, 0
        Refresh()
    end)
    panel.toggle:SetPoint("TOPLEFT", 2, 0)
    panel.summary = Text(panel, "GameFontHighlight")
    panel.summary:SetPoint("LEFT", panel.toggle, "RIGHT", 12, 0)
end

local function RefreshLoot(panel)
    local s = state.lootAll and ns.db.total or ns.db.run
    panel.toggle:SetText(state.lootAll and "Showing: all time" or "Showing: since reset")
    panel.summary:SetText(("%s from %s  %s+ %s coin|r"):format(ns.Money(ns.StatsItems(s)), ns.Plural(s.itemCount or 0, "item"),
        GREY, ns.Money(s.coin)))
    local tbl = panel.table
    SortArrows(tbl, state.lootSort, state.lootDesc)
    local list = LootList()
    state.lootOffset = Clamp(state.lootOffset, 0, math.max(0, #list - tbl.rowCount))
    FillRows(tbl, list, state.lootOffset, function(e)
        return { ItemText(e), tostring(e.times), tostring(e.qty), ns.Money(e.each), ns.Money(e.value) }
    end)
    Footer(tbl, list, state.lootOffset, "different items", "click a heading to sort")
end

------------------------------------------------------------------------
-- Zones tab
------------------------------------------------------------------------

local ZONE_COLUMNS = {
    { key = "name",    label = "Zone",       x = 4,   w = 150, justify = "LEFT" },
    { key = "kills",   label = "Kills",      x = 158, w = 44,  justify = "RIGHT" },
    { key = "avg",     label = "Avg / kill", x = 206, w = 88,  justify = "RIGHT" },
    { key = "xp",      label = "XP / kill",  x = 298, w = 60,  justify = "RIGHT" },
    { key = "perHour", label = "Per hour",   x = 362, w = 100, justify = "RIGHT" },
    { key = "xpHour",  label = "XP / hour",  x = 466, w = 70,  justify = "RIGHT" },
    { key = "time",    label = "Time",       x = 540, w = 34,  justify = "RIGHT" },
}
local ZONE_MIN_SECONDS = 300 -- don't show per-hour figures for a zone you've barely been in

local function ShortTime(seconds)
    if seconds >= 3600 then return ("%dh"):format(seconds / 3600) end
    return ("%dm"):format(seconds / 60)
end

local function ZoneList()
    local list = {}
    for name, z in pairs(ns.db.zones or {}) do
        if z.kills > 0 or (z.xpKills or 0) > 0 then
            local t = ns.ZoneSeconds(name)
            local value = ns.StatsValue(z)
            local timed = t >= ZONE_MIN_SECONDS
            list[#list + 1] = { name = name, kills = math.max(z.kills, z.xpKills or 0), avg = ns.Average(z),
                                xp = ns.AverageXP(z), time = t,
                                perHour = timed and value * 3600 / t or 0,
                                xpHour = timed and (z.xp or 0) * 3600 / t or 0 }
        end
    end
    Sort(list, state.zoneSort, state.zoneDesc, "name")
    return list
end

local function RefreshZones(panel)
    SortArrows(panel, state.zoneSort, state.zoneDesc)
    local list = ZoneList()
    state.zoneOffset = Clamp(state.zoneOffset, 0, math.max(0, #list - panel.rowCount))
    FillRows(panel, list, state.zoneOffset, function(z)
        return { z.name, tostring(z.kills), ns.Money(z.avg), XPText(z.xp),
                 z.perHour > 0 and ns.Money(z.perHour) or GREY .. "-|r",
                 z.xpHour > 0 and XPText(z.xpHour) or GREY .. "-|r", GREY .. ShortTime(z.time) .. "|r" }
    end)
    Footer(panel, list, state.zoneOffset, #list == 1 and "zone" or "zones", "per hour = all time spent in the zone")
end

local function BuildZones(panel)
    BuildTable(panel, ZONE_COLUMNS, {
        onHeaderClick = HeaderToggle("zoneSort", "zoneDesc", "zoneOffset", { name = true }),
        onScroll = function(delta)
            state.zoneOffset = state.zoneOffset - delta * 3
            Refresh()
        end,
    })
end

------------------------------------------------------------------------
-- Recent kills tab
------------------------------------------------------------------------

local RECENT_COLUMNS = {
    { label = "When",  x = 4,   w = 70,  justify = "LEFT" },
    { label = "Enemy", x = 78,  w = 250, justify = "LEFT" },
    { label = "XP",    x = 332, w = 56,  justify = "RIGHT" },
    { label = "Value", x = 392, w = 182, justify = "RIGHT" },
}

local function RefreshRecent(panel)
    local list = ns.db.recent
    state.recentOffset = Clamp(state.recentOffset, 0, math.max(0, #list - panel.rowCount))
    FillRows(panel, list, state.recentOffset, function(k)
        local value
        if k.value == 0 and (k.items or 0) == 0 and (k.coin or 0) == 0 then
            value = GREY .. "no loot|r"
        else
            value = ns.Money(ns.UseAuction() and k.shown or k.value)
        end
        local tags = (k.inst and (GREY .. " [dungeon]|r") or "") .. (k.group and (GREY .. " [group]|r") or "")
        return { GREY .. Ago(k.time) .. "|r", k.name .. tags, XPText(k.xp), value }
    end)
    Footer(panel, list, state.recentOffset, "recent kills")
end

local function BuildRecent(panel)
    BuildTable(panel, RECENT_COLUMNS, {
        onScroll = function(delta)
            state.recentOffset = state.recentOffset - delta * 3
            Refresh()
        end,
    })
end

------------------------------------------------------------------------
-- Options tab
------------------------------------------------------------------------

local OPTIONS = {
    { key = "quiet", label = "Show a chat message for each kill", invert = true },
    { key = "verbose", label = "...including this enemy's total and average" },
    { key = "tooltip", label = "Show kill value and XP on enemy tooltips" },
    { key = "countEmpty", label = "Count kills that drop nothing (as 0)" },
    { key = "includeInstances", label = "Count dungeon and raid enemies" },
    { key = "includeGroup", label = "Count kills while in a party or raid (party loot)" },
    { key = "groupShare", label = "In a group, count only my share of the coin" },
    { key = "alerts", label = "Announce green-or-better and rare (under 5%) drops" },
    { key = "alertSound", label = "...with a sound" },
}

local function BuildOptions(panel)
    panel.boxes = {}
    local y = 0
    for _, o in ipairs(OPTIONS) do
        panel.boxes[#panel.boxes + 1] = CheckBox(panel, y, o.label,
            function() if o.invert then return not ns.db[o.key] end return ns.db[o.key] end,
            function(on) if o.invert then ns.db[o.key] = not on else ns.db[o.key] = on end end)
        y = y - 28
    end

    y = y - 6
    local label = Text(panel, "GameFontHighlight")
    label:SetPoint("TOPLEFT", 14, y - 4)
    panel.dropsLabel = label
    local minus = Button(panel, "-", 26, function()
        ns.db.tooltipDrops = math.max(0, (ns.db.tooltipDrops or 3) - 1)
        Refresh()
    end)
    minus:SetPoint("TOPLEFT", 280, y)
    local plus = Button(panel, "+", 26, function()
        ns.db.tooltipDrops = math.min(10, (ns.db.tooltipDrops or 3) + 1)
        Refresh()
    end)
    plus:SetPoint("LEFT", minus, "RIGHT", 4, 0)

    y = y - 28
    panel.priceLabel = Text(panel, "GameFontHighlight")
    panel.priceLabel:SetPoint("TOPLEFT", 14, y - 4)
    local price = Button(panel, "Switch", 80, function()
        ns.db.priceSource = ns.db.priceSource == "auction" and "vendor" or "auction"
        if ns.Notify then ns.Notify() end
        Refresh()
    end)
    price:SetPoint("TOPLEFT", 280, y)

    y = y - 28
    Text(panel, "GameFontHighlight", "Gold goal:"):SetPoint("TOPLEFT", 14, y - 4)
    local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    box:SetSize(90, 20)
    box:SetPoint("TOPLEFT", 286, y)
    box:SetAutoFocus(false)
    box:SetScript("OnEnterPressed", function(self)
        local text = self:GetText() or ""
        local copper = ns.ParseMoney(text)
        ns.db.goal = (copper and copper > 0) and copper or nil
        self:ClearFocus()
        if ns.Notify then ns.Notify() end
        Refresh()
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    panel.goalBox = box
    local hint = Text(panel, "GameFontDisableSmall", "e.g. 100g - Enter to set, empty to clear")
    hint:SetPoint("LEFT", box, "RIGHT", 10, 0)
    y = y - 4

    local help = Text(panel, "GameFontDisableSmall",
        "Kill value = average coin + each item's vendor price x how often it drops, learned from your own kills.\n" ..
        "Enemies you haven't killed are estimated from other enemies of the same level; XP from the 1.x formula.\n" ..
        "Kills you don't loot still count for XP. In a group, corpses you can't loot are left out of the averages.\n" ..
        "Auction prices take off the 5% cut and never go below the vendor price. 'Per fight hour' counts only time in combat.")
    help:SetPoint("TOPLEFT", 8, y - 36)
    help:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    help:SetJustifyH("LEFT")
end

local function RefreshOptions(panel)
    for _, b in ipairs(panel.boxes) do b:Refresh() end
    panel.dropsLabel:SetText("Drops listed on enemy tooltips: " .. (ns.db.tooltipDrops or 3))
    local source = "Vendor"
    if ns.db.priceSource == "auction" then
        source = ns.HasAuctionSource() and "Auction (Auctionator / TSM)" or "Auction - no Auctionator/TSM found, using vendor"
    end
    panel.priceLabel:SetText("Item prices: " .. source)
    if not panel.goalBox:HasFocus() then
        local g = ns.db.goal
        local text = ""
        if g then
            local gold, silver, copper = math.floor(g / 10000), math.floor(g / 100) % 100, g % 100
            text = (gold > 0 and (gold .. "g ") or "") .. (silver > 0 and (silver .. "s ") or "") .. (copper > 0 and (copper .. "c") or "")
        end
        panel.goalBox:SetText((text:gsub("%s+$", "")))
    end
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------

local TABS = {
    { key = "overview", label = "Overview",     build = BuildOverview, refresh = RefreshOverview },
    { key = "mobs",     label = "Enemies",      build = BuildMobs,     refresh = RefreshMobs },
    { key = "detail",   hidden = true,          build = BuildDetail,   refresh = RefreshDetail, parent = "mobs" },
    { key = "zones",    label = "Zones",        build = BuildZones,    refresh = RefreshZones },
    { key = "loot",     label = "Loot",         build = BuildLoot,     refresh = RefreshLoot },
    { key = "recent",   label = "Recent kills", build = BuildRecent,   refresh = RefreshRecent },
    { key = "options",  label = "Options",      build = BuildOptions,  refresh = RefreshOptions },
}

function Refresh()
    if not (window and window:IsShown()) then return end
    for _, tab in ipairs(TABS) do
        if tab.key == activeTab then tab.refresh(panels[tab.key]) end
    end
end

function SelectTab(key)
    activeTab = key
    for _, tab in ipairs(TABS) do
        local selected = tab.key == key
        panels[tab.key]:SetShown(selected)
        local b = tabButtons[tab.key]
        if b then
            local lit = selected
            for _, t in ipairs(TABS) do
                if t.key == key and t.parent == tab.key then lit = true end
            end
            if lit then b:LockHighlight() else b:UnlockHighlight() end
        end
    end
    Refresh()
end

local function CreateWindow()
    local f = CreateFrame("Frame", "KillValueFrame", UIParent, "BackdropTemplate")
    f:SetSize(WIDTH, HEIGHT)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ns.db.window = { point = point, relPoint = relPoint, x = x, y = y }
    end)

    local pos = ns.db.window
    if pos and pos.point then
        f:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    else
        f:SetPoint("CENTER")
    end

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end

    Text(f, "GameFontNormalLarge", "KillValue"):SetPoint("TOP", 0, -18)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    local prev
    for _, tab in ipairs(TABS) do
        if not tab.hidden then
            local b = Button(f, tab.label, 90, function() SelectTab(tab.key) end)
            if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 22, -44) end
            tabButtons[tab.key], prev = b, b
        end

        local panel = CreateFrame("Frame", nil, f)
        panel:SetPoint("TOPLEFT", 18, -80)
        panel:SetPoint("BOTTOMRIGHT", -18, 18)
        tab.build(panel)
        panels[tab.key] = panel
    end

    -- Keep "per hour" and "5m ago" current while the window is open.
    f:SetScript("OnUpdate", function(self, elapsed)
        self.sinceTick = (self.sinceTick or 0) + elapsed
        if self.sinceTick >= 1 then
            self.sinceTick = 0
            Refresh()
        end
    end)
    f:SetScript("OnShow", Refresh)

    if UISpecialFrames then table.insert(UISpecialFrames, "KillValueFrame") end -- Escape closes it
    return f
end

function ns.ToggleWindow()
    if not ns.db then return end
    if not window then
        window = CreateWindow()
        SelectTab(activeTab)
        return
    end
    window:SetShown(not window:IsShown())
end

ns.OnStatsChanged = Refresh
ns._selectTab = function(key, detail) if detail then state.detail = detail end SelectTab(key) end -- used by the test harness

-- Entry for the addons menu next to the minimap (## AddonCompartmentFunc in the .toc).
function KillValue_ToggleWindow()
    ns.ToggleWindow()
end
