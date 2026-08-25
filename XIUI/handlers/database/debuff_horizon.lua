-- Horizon debuff overlay on handlers/database/debuff_retail.lua.
-- Only duration fields that differ from retail. Names and kinds stay on the base table.
-- Field value `false` clears a retail field during merge (e.g. fixed duration -> TP formula).

local overlay = {};

overlay.spells = {
    [25] = {duration = 150}, -- Dia III
    [232] = {duration = 150}, -- Bio III
    [235] = {duration = 120}, -- Burn
    [236] = {duration = 120}, -- Frost
    [237] = {duration = 120}, -- Choke
    [238] = {duration = 120}, -- Rasp
    [239] = {duration = 120}, -- Shock
    [240] = {duration = 120}, -- Drown
};

overlay.jaPhysical = {
    [45] = {duration = 30, buffId = 448}, -- Mug - Bewildered Daze (type 3)
    [46] = {duration = 6}, -- Shield Bash
    [77] = {duration = 6}, -- Weapon Bash
};

-- Horizon WS debuffs (see horizonffxi.wiki). Energy Drain Slow durations at 1k/2k/3k TP.
overlay.weaponSkills = {
    -- Enemy gets Slow; player Haste is a self-buff (not tracked here).
    [22] = {buffId = 13, tpTier = {{1000, 90}, {2000, 150}, {3000, 210}}}, -- Energy Drain - Slow
    [66] = {buffId = 12, duration = false, tpTier = {{1000, 20}, {2000, 40}, {3000, 60}}}, -- Gale Axe - Weight (replaces Choke)
    [121] = {duration = 30, buffId = 149}, -- Geirskogul - Defense Down (matches Angon)
    [197] = {duration = 5, buffId = 10}, -- Blast Arrow - Stun (duration unknown; common stun)
    [213] = {duration = 5, buffId = 10}, -- Blast Shot - Stun (duration unknown; common stun)
};

return overlay;
