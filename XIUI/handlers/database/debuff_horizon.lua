-- Horizon debuff overlay on handlers/database/debuff_retail.lua.
-- Only duration fields that differ from retail. Names and kinds stay on the base table.

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
    [46] = {duration = 6}, -- Shield Bash
    [77] = {duration = 6}, -- Weapon Bash
};

return overlay;
