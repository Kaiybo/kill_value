std = "lua51"
max_line_length = false
codes = true
exclude_files = { ".release", "tests", ".luarocks", "lua_modules" }
ignore = { "212/self", "212/_.*", "542" }
globals = { "KillValueDB", "SlashCmdList", "SLASH_KILLVALUE1", "SLASH_KILLVALUE2", "KillValue_ToggleWindow" }
read_globals = {
    "C_Item", "C_Spell", "C_Timer", "CanLootUnit", "CreateFrame", "DEFAULT_CHAT_FRAME", "Enum", "GameTooltip",
    "GetGameTime", "GetItemInfo", "GetLootSlotInfo", "GetLootSlotLink", "GetLootSlotType", "GetLootSourceInfo",
    "GetMaxPlayerLevel", "GetNumGroupMembers", "GetNumLootItems", "GetSpellInfo", "GetTime", "GetXPExhaustion",
    "IsFishingLoot", "IsInGroup", "IsInInstance", "MAX_PLAYER_LEVEL", "TooltipDataProcessor", "UIParent",
    "UISpecialFrames", "UnitCanAttack", "UnitClassification", "UnitCreatureType", "UnitExists", "UnitGUID",
    "UnitIsDead", "UnitIsPlayer", "UnitIsTapDenied", "UnitLevel", "UnitName", "UnitXP", "UnitXPMax",
    "issecretvalue", "date", "time", "Auctionator", "TSM_API", "PlaySound", "SOUNDKIT", "GetMoney",
    "GetRealZoneText", "GetZoneText", "LibStub",
    "GOLD_AMOUNT", "SILVER_AMOUNT", "COPPER_AMOUNT", "LOOT_MONEY_SPLIT",
    "COMBATLOG_XPGAIN_FIRSTPERSON", "COMBATLOG_XPGAIN_EXHAUSTION1", "COMBATLOG_XPGAIN_EXHAUSTION2",
    "COMBATLOG_XPGAIN_EXHAUSTION4", "COMBATLOG_XPGAIN_EXHAUSTION5", "COMBATLOG_XPGAIN_FIRSTPERSON_GROUP",
    "COMBATLOG_XPGAIN_FIRSTPERSON_RAID",
}
