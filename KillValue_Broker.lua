-- Feeds info-bar addons (Titan Panel, ChocolateBar, Bazooka, ElvUI datatexts)
-- through LibDataBroker, and adds a minimap button through LibDBIcon, when
-- another addon has loaded those libraries. KillValue doesn't ship them.

local ADDON_NAME, ns = ...

local GREY = "|cff999999"
local feed

local function Text()
    local db = ns.db
    local rate = ns.PerHour()
    if rate then return ns.Money(rate) .. GREY .. "/h|r" end
    return ns.Money(ns.Average(db.run)) .. GREY .. "/kill|r"
end

local function Update()
    if feed then feed.text = Text() end
end

local function ShowTooltip(tt)
    local db, Money = ns.db, ns.Money
    local run = db.run
    tt:AddLine("KillValue")
    tt:AddDoubleLine("Kills since reset", tostring(run.kills), 1, 1, 1, 1, 1, 1)
    tt:AddDoubleLine("Total value", Money(ns.StatsValue(run)), 1, 1, 1, 1, 1, 1)
    tt:AddDoubleLine("Average per kill", Money(ns.Average(run)), 1, 1, 1, 1, 1, 1)
    local rate = ns.PerHour()
    if rate then tt:AddDoubleLine("Per hour played", Money(rate), 1, 1, 1, 1, 1, 1) end
    if (run.xpKills or 0) > 0 then
        tt:AddDoubleLine("XP", ("%d  (avg %d)"):format(run.xp, ns.AverageXP(run) + 0.5), 1, 1, 1, 0.5, 0.5, 1)
    end
    local goal = ns.GoalText()
    if goal then tt:AddLine("Goal: " .. goal, 1, 1, 1, true) end
    tt:AddLine(GREY .. "Click to open the window.|r")
end

table.insert(ns.inits, function()
    local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
    if not ldb then return end
    feed = ldb:NewDataObject(ADDON_NAME, {
        type = "data source",
        label = "KillValue",
        icon = "Interface\\Icons\\INV_Misc_Coin_02",
        text = "",
        OnClick = function() if ns.ToggleWindow then ns.ToggleWindow() end end,
        OnTooltipShow = ShowTooltip,
    })
    Update()

    local icon = LibStub("LibDBIcon-1.0", true)
    if icon then
        ns.db.minimap = ns.db.minimap or {}
        icon:Register(ADDON_NAME, feed, ns.db.minimap)
    end

    local previous = ns.OnStatsChanged
    ns.OnStatsChanged = function(...)
        Update()
        if previous then return previous(...) end
    end
    if C_Timer.NewTicker then C_Timer.NewTicker(10, Update) end
end)
