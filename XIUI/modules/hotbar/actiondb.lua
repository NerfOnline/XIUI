--[[
* XIUI hotbar - Action Database
* Maps action names to spell/ability IDs for recast lookups
* Caches per-ability display metadata (job levels, WS skill rating) from dat.
]]--

local iconRedirect = require('modules.hotbar.database.icon_redirect');
local catalog = nil;
local function GetCatalog()
    if not catalog then
        catalog = require('modules.hotbar.database.catalog');
    end
    return catalog;
end

--- Ability display name from Ashita resource (for name-keyed Horizon catalog).
local function GetAbilityNameById(abilityId)
    if not abilityId then
        return nil;
    end
    local resourceMgr = AshitaCore:GetResourceManager();
    if not resourceMgr then
        return nil;
    end
    local ability = resourceMgr:GetAbilityById(abilityId);
    if ability and ability.Name and ability.Name[1] and ability.Name[1] ~= '' then
        return ability.Name[1];
    end
    return nil;
end

local M = {};

--- Whether HorizonXI limited mode is active (global set in XIUI.lua).
function M.IsHorizonMode()
    return HzLimitedMode == true;
end

-- Lookup tables (built on first use)

M.spellNameToId = nil;
M.spellNameToIds = nil;
M.abilityNameToId = nil;
M.abilityNameToIds = nil;

-- Dat ID ceilings (full-scan verified Horizon + retail, 2026-06): spell 1019, ability 2227.
local SPELL_ID_MAX = 1051;
local ABILITY_ID_MAX = 2259;
M.itemNameToId = nil;
M.abilityMetaById = nil;

-- Raw-string memoization: avoid :lower() allocations on repeated lookups per frame.
local rawSpellCache = {};
local rawAbilityCache = {};
local rawItemCache = {};
local ABILITY_TYPE_WEAPON_SKILL = 3;
local ABILITY_TYPE_TRAIT = 4;
local ABILITY_TYPE_BEASTMASTER_SIC = 18;
local ABILITY_TYPE_MONSTER_SKILL = 20;
local PET_ABILITY_TYPES = {
    [2] = true,  -- PetCommand
    [6] = true,  -- BloodPactRage
    [10] = true, -- BloodPactWard
    [18] = true, -- BeastmasterSic
    [20] = true, -- MonsterSkill
};
local MACRO_PET_ABILITY_TYPES = {
    [2] = true,  -- PetCommand
    [6] = true,  -- BloodPactRage
    [10] = true, -- BloodPactWard
    [18] = true, -- BeastmasterSic
};

local function NormalizeLevelValue(value)
    if not value or value <= 0 or value == 255 or value == 0xFF or value == -1 then
        return nil;
    end
    return value;
end

--- Read one index from Ashita ability.Level / spell.LevelRequired (table or userdata).
local function ReadLevelIndex(levelArray, index)
    if not levelArray or not index then
        return nil;
    end
    local ok, value = pcall(function()
        return levelArray[index];
    end);
    if ok then
        return NormalizeLevelValue(value);
    end
    return nil;
end
local function LevelForJob(levelArray, jobId)
    if not levelArray or not jobId then
        return nil;
    end
    if type(levelArray) == 'number' then
        return NormalizeLevelValue(levelArray);
    end
    return ReadLevelIndex(levelArray, jobId + 1) or ReadLevelIndex(levelArray, jobId);
end
local ABILITY_LEVEL_PROPERTY_NAMES = { 'Level', 'LevelRequired', 'Levels' };
local function LevelArrayHasAnyEntry(levelArray)
    if not levelArray then
        return false;
    end
    if type(levelArray) == 'number' then
        return NormalizeLevelValue(levelArray) ~= nil;
    end
    for i = 1, 24 do
        if ReadLevelIndex(levelArray, i) then
            return true;
        end
    end
    for jobId = 1, 22 do
        if LevelForJob(levelArray, jobId) then
            return true;
        end
    end
    return false;
end

--- Resolve per-job level array from Ashita ability resource (field name varies by client).
local function GetAbilityLevelArrayFromResource(ability)
    if not ability then
        return nil;
    end
    for _, prop in ipairs(ABILITY_LEVEL_PROPERTY_NAMES) do
        local levelArray = ability[prop];
        if LevelArrayHasAnyEntry(levelArray) then
            return levelArray;
        end
    end
    return nil;
end
local function MaxPositiveInLevelArray(levelArray, minValue, maxValue)
    if not levelArray then
        return nil;
    end
    if type(levelArray) == 'number' then
        local v = NormalizeLevelValue(levelArray);
        if v and (not minValue or v >= minValue) and (not maxValue or v <= maxValue) then
            return v;
        end
        return nil;
    end
    local best = nil;
    for i = 1, 24 do
        local v = ReadLevelIndex(levelArray, i);
        if v and (not minValue or v >= minValue) and (not maxValue or v <= maxValue) then
            if not best or v > best then
                best = v;
            end
        end
    end
    if best then
        return best;
    end
    for jobId = 1, 22 do
        local v = LevelForJob(levelArray, jobId);
        if v and (not minValue or v >= minValue) and (not maxValue or v <= maxValue) then
            if not best or v > best then
                best = v;
            end
        end
    end
    return best;
end
local function BuildAbilityMetaEntry(ability, abilityId)
    local abilityType = ability.Type or 0;
    local levelArray = GetAbilityLevelArrayFromResource(ability);
    local meta = {
        id = abilityId,
        type = abilityType,
        levelByJob = nil,
        jaDisplayLevel = nil,
        wsSkillLevel = nil,
    };
    if levelArray then
        meta.levelByJob = {};
        for jobId = 1, 22 do
            local lvl = LevelForJob(levelArray, jobId);
            if lvl then
                meta.levelByJob[jobId] = lvl;
                meta.levelByJob[jobId + 1] = lvl;
            end
        end
        if not next(meta.levelByJob) then
            meta.levelByJob = nil;
        end
    end
    if abilityType == ABILITY_TYPE_WEAPON_SKILL then
        local skillLevel = ability.MonsterLevel;
        if skillLevel and skillLevel > 0 then
            meta.wsSkillLevel = skillLevel;
        else
            meta.wsSkillLevel = MaxPositiveInLevelArray(levelArray, 5, 570);
        end
    else
        meta.jaDisplayLevel = MaxPositiveInLevelArray(meta.levelByJob or levelArray, 1, 99);
        meta.bestDisplayLevel = MaxPositiveInLevelArray(meta.levelByJob or levelArray, 1, 99999);
        if not meta.jaDisplayLevel or meta.jaDisplayLevel <= 0 then
            local ref = GetCatalog();
            local catEntry;
            if M.IsHorizonMode() then
                local name = ability.Name and ability.Name[1];
                catEntry = name and ref.horizon.abilitiesByName[name];
            else
                catEntry = ref.retail.abilitiesById[abilityId];
            end
            if catEntry and catEntry.level and catEntry.level > 0 then
                meta.jaDisplayLevel = catEntry.level;
                meta.bestDisplayLevel = catEntry.level;
            end
        end
    end
    return meta;
end

-- Build spell name lookup table

local function BuildSpellLookup()
    if M.spellNameToId then return; end
    M.spellNameToId = {};
    M.spellNameToIds = {};
    local resourceMgr = AshitaCore:GetResourceManager();
    if not resourceMgr then return; end
    for id = 0, SPELL_ID_MAX do
        local spell = resourceMgr:GetSpellById(id);
        if spell and spell.Name and spell.Name[1] then
            local name = spell.Name[1]:lower();
            -- Keep the lowest ID when names collide (e.g. Sleepga 273 vs 363).
            -- Higher duplicate IDs are unlearnable placeholders in some dat files.
            if not M.spellNameToId[name] then
                M.spellNameToId[name] = id;
            end
            local ids = M.spellNameToIds[name];
            if not ids then
                ids = {};
                M.spellNameToIds[name] = ids;
            end
            ids[#ids + 1] = id;
        end
    end
end

-- Build ability name lookup table and display metadata cache

local function BuildAbilityLookup()
    if M.abilityNameToId then return; end
    M.abilityNameToId = {};
    M.abilityNameToIds = {};
    M.abilityMetaById = {};
    local resourceMgr = AshitaCore:GetResourceManager();
    if not resourceMgr then return; end
    for id = 0, ABILITY_ID_MAX do
        local ability = resourceMgr:GetAbilityById(id);
        if ability and ability.Name and ability.Name[1] then
            local name = ability.Name[1]:lower();
            if not M.abilityNameToId[name] then
                M.abilityNameToId[name] = id;
            end
            local ids = M.abilityNameToIds[name];
            if not ids then
                ids = {};
                M.abilityNameToIds[name] = ids;
            end
            ids[#ids + 1] = id;
            M.abilityMetaById[id] = BuildAbilityMetaEntry(ability, id);
        end
    end
end

--- Cached dat metadata for menu labels (job levels, WS skill rating).

function M.GetAbilityMeta(abilityId)
    if not abilityId then return nil; end
    BuildAbilityLookup();
    if M.abilityMetaById and M.abilityMetaById[abilityId] then
        return M.abilityMetaById[abilityId];
    end
    local resourceMgr = AshitaCore:GetResourceManager();
    if not resourceMgr then return nil; end
    local ability = resourceMgr:GetAbilityById(abilityId);
    if not ability then return nil; end
    if not M.abilityMetaById then
        M.abilityMetaById = {};
    end
    M.abilityMetaById[abilityId] = BuildAbilityMetaEntry(ability, abilityId);
    return M.abilityMetaById[abilityId];
end

--- Drop cached ability metadata so the next lookup rebuilds from live dat.
function M.InvalidateAbilityMeta()
    M.abilityMetaById = nil;
end

--- Per-job level array from an ability resource row (Level / LevelRequired / Levels).
function M.GetAbilityLevelArrayFromResource(ability)
    return GetAbilityLevelArrayFromResource(ability);
end

--- Job level array for an ability (copy from cache or live resource).

function M.GetAbilityLevelArray(abilityId, ability)
    local meta = M.GetAbilityMeta(abilityId);
    if meta and meta.levelByJob and next(meta.levelByJob) then
        return meta.levelByJob;
    end
    if ability then
        return GetAbilityLevelArrayFromResource(ability);
    end
    return nil;
end

--- Weaponskill combat skill requirement (e.g. 175 for Rampage).

function M.GetWeaponskillSkillLevel(abilityId, ability)
    if ability then
        if ability.MonsterLevel and ability.MonsterLevel > 0 then
            return ability.MonsterLevel;
        end
        local fromLevel = MaxPositiveInLevelArray(GetAbilityLevelArrayFromResource(ability), 5, 570);
        if fromLevel and fromLevel > 0 then
            return fromLevel;
        end
    end
    local meta = M.GetAbilityMeta(abilityId);
    if meta and meta.wsSkillLevel and meta.wsSkillLevel > 0 then
        return meta.wsSkillLevel;
    end
    return nil;
end

--- Catalog row for macro editor (retail by id, Horizon by ability name).
function M.GetCatalogEntry(abilityId)
    if not abilityId then
        return nil;
    end
    local ref = GetCatalog();
    if M.IsHorizonMode() then
        local name = GetAbilityNameById(abilityId);
        return name and ref.horizon.abilitiesByName[name] or nil;
    end
    return ref.retail.abilitiesById[abilityId];
end
local function GetWeaponskillTierInfo(wsName)
    if not wsName or wsName == '' then
        return nil, nil;
    end
    local ref = GetCatalog();
    local tierEntry = ref.weaponskillTiers and ref.weaponskillTiers[wsName];
    if not tierEntry then
        return nil, nil;
    end
    if type(tierEntry) == 'table' then
        return tierEntry.tier, tierEntry.skill;
    end
    return tierEntry, nil;
end

--- Weaponskill metadata for macro editor labels (skill requirement, weapon type).
function M.GetEditorWeaponskillMeta(wsName)
    if not wsName or wsName == '' then
        return nil;
    end
    local ref = GetCatalog();
    local tbl = M.IsHorizonMode() and ref.horizon.weaponskillsByName
        or ref.retail.weaponskillsByName;
    local meta = tbl and tbl[wsName];
    local tier, tierSkill = GetWeaponskillTierInfo(wsName);
    if not meta and not tier then
        return nil;
    end
    meta = meta or {};
    if tier then
        meta.tier = tier;
        meta.tierSkill = tierSkill;
    end
    return meta;
end

--- Macro editor weaponskill level prefix (e.g. "Quest 250", "Aeonic 357", "Relic").
function M.FormatWeaponskillLevelLabel(wsName)
    if not wsName or wsName == '' then
        return nil, nil;
    end
    local meta = M.GetEditorWeaponskillMeta(wsName) or {};
    local tier = meta.tier;
    local tierSkill = meta.tierSkill;
    if meta.relic or tier == 'relic' then
        return 'Relic', 9000;
    end
    if tier == 'prime' then
        return 'Prime', 9005;
    end
    if tier == 'mythic' then
        return 'Mythic', 9004;
    end
    if tier == 'empyrean' then
        return 'Empyrean', 9003;
    end
    if tier == 'aeonic' then
        local sk = tierSkill or meta.skill;
        if sk and sk > 0 then
            return 'Aeonic ' .. tostring(sk), 8000 + sk;
        end
        return 'Aeonic 357', 8357;
    end
    if tier == 'quest' then
        local sk = meta.skill;
        if sk and sk > 0 then
            return 'Quest ' .. tostring(sk), sk;
        end
    end
    if meta.skill and meta.skill > 0 then
        return tostring(meta.skill), meta.skill;
    end
    return nil, nil;
end

--- Whether a spell is omitted from Horizon "Show All" lists.
function M.IsSpellOmittedForEditor(spellName)
    if not spellName or spellName == '' or not M.IsHorizonMode() then
        return false;
    end
    local ref = GetCatalog();
    return ref.horizon.spellOmissions[spellName] == true;
end

--- Whether a job ability exists on retail but not Horizon progression.
function M.IsRetailOnlyAbility(name)
    if not name or name == '' or not M.IsHorizonMode() then
        return false;
    end
    local ref = GetCatalog();
    return ref.horizon.retailOnlyAbilities[name] == true;
end

--- Learn level for ability on a specific job column from catalog.
function M.GetCatalogAbilityLevelForJob(abilityId, jobId)
    local entry = M.GetCatalogEntry(abilityId);
    if not entry or not jobId or jobId <= 0 or entry.job ~= jobId then
        return nil;
    end
    if not entry.level or entry.level <= 0 then
        return nil;
    end
    return entry.level;
end

--- Whether catalog lists this ability on the given job.
function M.AbilityCatalogHasJob(abilityId, jobId)
    local entry = M.GetCatalogEntry(abilityId);
    return entry ~= nil and entry.job == jobId;
end

--- Display/sort level for macro editor from catalog (main/sub preference).
function M.GetCatalogDisplayLevelForJobs(abilityId, mainJobId, subJobId)
    local entry = M.GetCatalogEntry(abilityId);
    if not entry or not entry.level or entry.level <= 0 then
        return nil, nil, nil;
    end
    if entry.job == mainJobId then
        if entry.merit then
            return 75, 'MP 75', 'main';
        end
        return entry.level, nil, 'main';
    end
    if subJobId > 0 and entry.job == subJobId then
        if entry.merit then
            return 75, 'MP 75', 'sub';
        end
        return entry.level, nil, 'sub';
    end
    if entry.merit then
        return 75, 'MP 75', nil;
    end
    return entry.level, nil, nil;
end

--- Whether player main/sub meets catalog learn level (editor simulation; merit always passes).
function M.PlayerMeetsCatalogAbilityLevel(abilityId, player, mainJobId, subJobId)
    if not abilityId or not player then
        return false;
    end
    local entry = M.GetCatalogEntry(abilityId);
    if not entry or not entry.level or entry.level <= 0 then
        return true;
    end
    if entry.merit then
        return true;
    end
    local mainLevel = player:GetMainJobLevel() or 0;
    local subLevel = subJobId > 0 and (player:GetSubJobLevel() or 0) or 0;
    if entry.job == mainJobId and mainLevel >= entry.level then
        return true;
    end
    if subJobId > 0 and entry.job == subJobId and subLevel >= entry.level then
        return true;
    end
    return false;
end

--- Level for a specific job column (1-based job id).

function M.GetAbilityLevelForJob(abilityId, jobId, ability)
    local levelArray = M.GetAbilityLevelArray(abilityId, ability);
    local fromDat = LevelForJob(levelArray, jobId);
    if fromDat and fromDat > 0 then
        return fromDat;
    end
    return M.GetCatalogAbilityLevelForJob(abilityId, jobId);
end

--- Best positive level across all job columns (includes JP values above 99).

function M.GetAbilityBestDisplayLevel(abilityId, ability)
    local meta = M.GetAbilityMeta(abilityId);
    if meta and meta.bestDisplayLevel and meta.bestDisplayLevel > 0 then
        return meta.bestDisplayLevel;
    end
    if meta and meta.jaDisplayLevel and meta.jaDisplayLevel > 0 then
        return meta.jaDisplayLevel;
    end
    local levelArray = M.GetAbilityLevelArray(abilityId, ability);
    local best = MaxPositiveInLevelArray(levelArray, 1, 99999);
    if best and best > 0 then
        return best;
    end
    local entry = M.GetCatalogEntry(abilityId);
    if entry and entry.level and entry.level > 0 then
        return entry.level;
    end
    return nil;
end

-- Get spell ID by name (canonical / lowest when duplicates exist)

function M.GetSpellId(spellName)
    if not spellName then return nil; end
    local cached = rawSpellCache[spellName];
    if cached ~= nil then
        return cached or nil;
    end
    BuildSpellLookup();
    local id = M.spellNameToId[spellName:lower()];
    rawSpellCache[spellName] = id or false;
    return id;
end

--- All spell IDs sharing a display name (duplicate dat rows, e.g. Sleepga 273 and 363).

function M.GetSpellIds(spellName)
    if not spellName then return {}; end
    local cached = rawSpellCache[spellName .. ':ids'];
    if cached then return cached; end
    BuildSpellLookup();
    local ids = M.spellNameToIds[spellName:lower()] or {};
    rawSpellCache[spellName .. ':ids'] = ids;
    return ids;
end

-- Get ability ID by name (canonical / lowest when duplicates exist)

function M.GetAbilityId(abilityName)
    if not abilityName then return nil; end
    local cached = rawAbilityCache[abilityName];
    if cached ~= nil then
        return cached or nil;
    end
    BuildAbilityLookup();
    local id = M.abilityNameToId[abilityName:lower()];
    rawAbilityCache[abilityName] = id or false;
    return id;
end

--- All ability IDs sharing a display name.

function M.GetAbilityIds(abilityName)
    if not abilityName then return {}; end
    local cached = rawAbilityCache[abilityName .. ':ids'];
    if cached then return cached; end
    BuildAbilityLookup();
    local ids = M.abilityNameToIds[abilityName:lower()] or {};
    rawAbilityCache[abilityName .. ':ids'] = ids;
    return ids;
end

--- True when the player owns any dat ID for this spell name.

function M.PlayerHasSpell(player, spellName)
    if not player or not spellName or spellName == '' then
        return false;
    end
    local ids = M.GetSpellIds(spellName);
    local playerdata = require('modules.hotbar.playerdata');
    for _, spellId in ipairs(ids) do
        if playerdata.PlayerOwnsSpell(spellId) then
            return true;
        end
    end
    return false;
end

--- True when the player has a SummonerPact spell (skill 38) by name.
--- Used for avatar unlock only; blood pact ownership uses HasAbility.

function M.PlayerHasSummonerPactSpell(player, spellName)
    if not player or not spellName or spellName == '' then
        return false;
    end
    local resourceMgr = AshitaCore:GetResourceManager();
    if not resourceMgr then
        return false;
    end
    for _, spellId in ipairs(M.GetSpellIds(spellName)) do
        if player:HasSpell(spellId) then
            local spell = resourceMgr:GetSpellById(spellId);
            if M.IsSummonerPactSpell(spell, spellId) then
                return true;
            end
        end
    end
    return false;
end

--- Spell ID the player actually has, or canonical ID for recast when none match yet.

function M.GetPlayerSpellId(player, spellName)
    if not spellName or spellName == '' then
        return nil;
    end
    if player then
        local ids = M.GetSpellIds(spellName);
        for _, spellId in ipairs(ids) do
            if player:HasSpell(spellId) then
                return spellId;
            end
        end
    end
    return M.GetSpellId(spellName);
end

--- True when the player has any dat ID for this ability / weaponskill name.

function M.PlayerHasAbility(player, abilityName)
    if not player or not abilityName or abilityName == '' then
        return false;
    end
    local ids = M.GetAbilityIds(abilityName);
    for _, abilityId in ipairs(ids) do
        if player:HasAbility(abilityId) then
            return true;
        end
    end
    return false;
end

-- Returns true when the player has learned this weaponskill (not a job ability with the same id).
function M.PlayerHasWeaponSkill(player, wsName)
    if not player or not wsName or wsName == '' then
        return false;
    end
    if not M.GetEditorWeaponskillMeta(wsName) then
        return false;
    end
    local resourceMgr = AshitaCore:GetResourceManager();
    if not resourceMgr then
        return false;
    end
    for _, abilityId in ipairs(M.GetAbilityIds(wsName)) do
        local ability = resourceMgr:GetAbilityById(abilityId);
        if ability and M.IsWeaponskillAbilityType(ability.Type)
            and player.HasWeaponSkill and player:HasWeaponSkill(abilityId) then
            return true;
        end
    end
    return false;
end

--- True when ability type is Blood Pact Rage or Ward.

function M.IsBloodPactAbilityType(abilityType)
    local t = abilityType or 0;
    return t == 6 or t == 10;
end

--- Whether the player owns a specific ability ID (HasAbility, or HasPetCommand when present).
function M.PlayerHasAbilityId(player, abilityId)
    if not player or not abilityId then
        return false;
    end
    if player:HasAbility(abilityId) then
        return true;
    end
    if player.HasPetCommand and player:HasPetCommand(abilityId) then
        return true;
    end
    return false;
end

--- True when the player owns a blood pact ability (HasAbility + BP rage/ward type).

function M.PlayerHasBloodPactAbility(player, abilityName)
    if not player or not abilityName or abilityName == '' then
        return false;
    end
    local resourceMgr = AshitaCore:GetResourceManager();
    if not resourceMgr then
        return false;
    end
    for _, abilityId in ipairs(M.GetAbilityIds(abilityName)) do
        if M.PlayerHasAbilityId(player, abilityId) then
            local ability = resourceMgr:GetAbilityById(abilityId);
            if ability and M.IsBloodPactAbilityType(ability.Type) then
                return true;
            end
        end
    end
    return false;
end

--- True when the player owns a pet-menu ability (HasAbility + PetCommand type).

function M.PlayerHasPetMenuAbility(player, abilityName)
    if not player or not abilityName or abilityName == '' then
        return false;
    end
    local resourceMgr = AshitaCore:GetResourceManager();
    if not resourceMgr then
        return false;
    end
    for _, abilityId in ipairs(M.GetAbilityIds(abilityName)) do
        if player:HasAbility(abilityId) then
            local ability = resourceMgr:GetAbilityById(abilityId);
            if ability and (ability.Type or 0) == 2 then
                return true;
            end
        end
    end
    return false;
end

--- Ability ID the player actually has, or canonical ID for recast when none match yet.

function M.GetPlayerAbilityId(player, abilityName)
    if not abilityName or abilityName == '' then
        return nil;
    end
    if player then
        local ids = M.GetAbilityIds(abilityName);
        for _, abilityId in ipairs(ids) do
            if player:HasAbility(abilityId) then
                return abilityId;
            end
        end
    end
    return M.GetAbilityId(abilityName);
end

--- Pet command ownership across duplicate ability IDs.

function M.PlayerHasPetCommand(player, commandName)
    if not player or not commandName or commandName == '' then
        return false;
    end
    local ids = M.GetAbilityIds(commandName);
    for _, abilityId in ipairs(ids) do
        if (player.HasPetCommand and player:HasPetCommand(abilityId))
            or player:HasAbility(abilityId) then
            return true;
        end
    end
    return false;
end

--- Pet command ID the player actually has, or canonical ID for recast.

function M.GetPlayerPetCommandId(player, commandName)
    if not commandName or commandName == '' then
        return nil;
    end
    if player then
        local ids = M.GetAbilityIds(commandName);
        for _, abilityId in ipairs(ids) do
            if (player.HasPetCommand and player:HasPetCommand(abilityId))
                or player:HasAbility(abilityId) then
                return abilityId;
            end
        end
    end
    return M.GetAbilityId(commandName);
end

-- Build item name lookup table

local function BuildItemLookup()
    if M.itemNameToId then return; end
    M.itemNameToId = {};
    local resourceMgr = AshitaCore:GetResourceManager();
    if not resourceMgr then return; end
    for id = 1, 65535 do
        local item = resourceMgr:GetItemById(id);
        if item and item.Name and item.Name[1] then
            local name = item.Name[1]:lower();
            M.itemNameToId[name] = id;
        end
    end
end

-- Get item ID by name

function M.GetItemId(itemName)
    if not itemName then return nil; end
    local cached = rawItemCache[itemName];
    if cached ~= nil then
        return cached or nil;
    end
    BuildItemLookup();
    local id = M.itemNameToId[itemName:lower()];
    rawItemCache[itemName] = id or false;
    return id;
end
local allSpellsCatalog = nil;

--- Menu icon index from Ashita spell dat (ListIconHQ / ListIconNQ; legacy ListIcon1/2 fallback).
function M.GetSpellListIconId(spell)
    if not spell then return nil; end
    local iconId = spell.ListIconHQ or spell.ListIconNQ
        or spell.ListIcon1 or spell.ListIcon2;
    if iconId and iconId > 0 then
        return iconId;
    end
    return nil;
end

--- Canonical bundled spell icon id (assets/hotbar/spells/{id}.png), following duplicate redirects.
function M.ResolveSpellIconId(spellId)
    if not spellId or spellId <= 0 then
        return nil;
    end
    local resolved = spellId;
    local seen = {};
    while iconRedirect.spells[resolved] and not seen[resolved] do
        seen[resolved] = true;
        resolved = iconRedirect.spells[resolved];
    end
    return resolved;
end

--- Raw menu list icon from Ashita ability dat.
local function GetRawAbilityListIconId(ability)
    if not ability then return nil; end
    local iconId = ability.ListIconId or 0;
    if iconId > 0 then
        return iconId;
    end
    return nil;
end

--- Follow listIconId redirect chain (duplicate menu icons -> canonical PNG id).
local function ResolveListIconRedirect(listIconId, remapTable)
    if not listIconId or listIconId <= 0 or not remapTable then
        return listIconId;
    end
    local resolved = listIconId;
    local seen = {};
    while remapTable[resolved] and not seen[resolved] do
        seen[resolved] = true;
        resolved = remapTable[resolved];
    end
    return resolved;
end

--- Ability id -> bundled PNG list icon overrides (see database/icon_redirect.lua).
local function ResolveAbilityListIconId(abilityId, ability, remapTable)
    if not ability and abilityId then
        local resourceMgr = AshitaCore:GetResourceManager();
        if resourceMgr then
            ability = resourceMgr:GetAbilityById(abilityId);
        end
    end
    local listIconId = GetRawAbilityListIconId(ability);
    if not listIconId then
        return nil;
    end
    if abilityId and remapTable and remapTable[abilityId] then
        return remapTable[abilityId];
    end
    return listIconId;
end

--- Menu list icon for job abilities (assets/hotbar/abilities/{listIconId}.png).
function M.GetAbilityListIconId(abilityId, ability)
    if not ability and abilityId then
        local resourceMgr = AshitaCore:GetResourceManager();
        if resourceMgr then
            ability = resourceMgr:GetAbilityById(abilityId);
        end
    end
    local listIconId = GetRawAbilityListIconId(ability);
    if not listIconId then
        return nil;
    end
    return ResolveListIconRedirect(listIconId, iconRedirect.abilities);
end

--- Menu list icon for weaponskills (assets/hotbar/weaponskills/{listIconId}.png).
function M.GetWeaponskillListIconId(abilityId, ability)
    if not ability and abilityId then
        local resourceMgr = AshitaCore:GetResourceManager();
        if resourceMgr then
            ability = resourceMgr:GetAbilityById(abilityId);
        end
    end
    local listIconId = GetRawAbilityListIconId(ability);
    if not listIconId then
        return nil;
    end
    return ResolveListIconRedirect(listIconId, iconRedirect.weaponskills);
end

--- Menu list icon for pet commands (assets/hotbar/petcommands/{listIconId}.png).
function M.GetPetCommandListIconId(abilityId, ability)
    if not ability and abilityId then
        local resourceMgr = AshitaCore:GetResourceManager();
        if resourceMgr then
            ability = resourceMgr:GetAbilityById(abilityId);
        end
    end
    local listIconId = GetRawAbilityListIconId(ability);
    if not listIconId then
        return nil;
    end
    return ResolveListIconRedirect(listIconId, iconRedirect.petcommands);
end

function M.IsPetAbilityType(abilityType)
    return PET_ABILITY_TYPES[abilityType or 0] == true;
end
function M.IsWeaponskillAbilityType(abilityType)
    return (abilityType or 0) == ABILITY_TYPE_WEAPON_SKILL;
end
function M.IsMacroEditorPetAbilityType(abilityType)
    return MACRO_PET_ABILITY_TYPES[abilityType or 0] == true;
end
function M.IsMacroEditorJobAbilityType(abilityType)
    local abilityTypeId = abilityType or 0;
    if abilityTypeId == ABILITY_TYPE_WEAPON_SKILL
        or abilityTypeId == ABILITY_TYPE_TRAIT
        or abilityTypeId == ABILITY_TYPE_MONSTER_SKILL
        or M.IsMacroEditorPetAbilityType(abilityTypeId) then
        return false;
    end
    return true;
end

--- Ashita spell Skill id for blood pacts / summoning magic menu entries.
M.SKILL_SUMMONER_PACT = 38;

--- True when spell dat row is SummonerPact (skill 38).
function M.IsSummonerPactSpell(spell, spellId)
    if spell and (spell.Skill or 0) == M.SKILL_SUMMONER_PACT then
        return true;
    end
    if spellId then
        local resourceMgr = AshitaCore:GetResourceManager();
        local spellDat = spell or (resourceMgr and resourceMgr:GetSpellById(spellId));
        return spellDat ~= nil and (spellDat.Skill or 0) == M.SKILL_SUMMONER_PACT;
    end
    return false;
end

--- Menu list icon for SummonerPact spells (assets/hotbar/petcommands/{listIconId}.png).
--- Uses the spell dat list icon as-is; folder routing is handled by GetSummonerPactAsset.
function M.GetSummonerPactListIconId(spell)
    return M.GetSpellListIconId(spell);
end

--- Macro palette / icon picker category from Ashita spell Skill (+ trust id range).
function M.GetSpellPickerType(spell, spellId)
    spellId = spellId or (spell and (spell.Index or spell.Id));
    if spellId and spellId >= 896 then
        return 'Trust';
    end
    if not spell then
        return 'Unknown';
    end
    local skill = spell.Skill or 0;
    if skill == 38 then return 'SummonerPact'; end
    if skill == 39 then return 'Ninjutsu'; end
    if skill == 40 then return 'BardSong'; end
    if skill == 43 then return 'BlueMagic'; end
    if skill == 36 or skill == 37 then return 'BlackMagic'; end
    if skill == 32 or skill == 33 or skill == 34 then return 'WhiteMagic'; end
    if skill == 35 then
        return (spell.Type == 2) and 'BlackMagic' or 'WhiteMagic';
    end
    return 'Unknown';
end
local function IsGarbageSpellName(name)
    if not name or #name < 2 then return true; end
    if #name <= 5 and name:match('^[A-Z]+$') then
        return true;
    end
    return false;
end

--- Full spell catalog for icon picker (Ashita dat scan).
function M.GetAllSpellsForIconPicker()
    if allSpellsCatalog then
        return allSpellsCatalog;
    end
    BuildSpellLookup();
    local resourceMgr = AshitaCore:GetResourceManager();
    if not resourceMgr then
        allSpellsCatalog = {};
        return allSpellsCatalog;
    end
    allSpellsCatalog = {};
    for id = 0, SPELL_ID_MAX do
        local spell = resourceMgr:GetSpellById(id);
        if spell and spell.Name and spell.Name[1] and spell.Name[1] ~= '' then
            local name = spell.Name[1];
            if not IsGarbageSpellName(name) then
                allSpellsCatalog[#allSpellsCatalog + 1] = {
                    id = id,
                    name = name,
                    icon_id = M.GetSpellListIconId(spell) or 0,
                    type = M.GetSpellPickerType(spell, id),
                };
            end
        end
    end
    return allSpellsCatalog;
end
local allAbilitiesCatalog = nil;

--- Full ability catalog for icon picker (Ashita dat scan).
function M.GetAllAbilitiesForIconPicker()
    if allAbilitiesCatalog then
        return allAbilitiesCatalog;
    end
    local resourceMgr = AshitaCore:GetResourceManager();
    if not resourceMgr then
        allAbilitiesCatalog = {};
        return allAbilitiesCatalog;
    end
    allAbilitiesCatalog = {};
    for id = 0, ABILITY_ID_MAX do
        local ability = resourceMgr:GetAbilityById(id);
        if ability and ability.Name and ability.Name[1] and ability.Name[1] ~= '' then
            local name = ability.Name[1];
            if not IsGarbageSpellName(name) then
                allAbilitiesCatalog[#allAbilitiesCatalog + 1] = {
                    id = id,
                    name = name,
                    type = ability.Type or 0,
                };
            end
        end
    end
    table.sort(allAbilitiesCatalog, function(a, b)
        return a.name < b.name;
    end);
    return allAbilitiesCatalog;
end

-- Clear caches (call on zone if needed)

--- Status effect ID for a blood pact ward/buff corner icon, or nil.
function M.GetBloodPactStatusEffectId(pactName)
    if not pactName or pactName == '' then
        return nil;
    end
    local effects = GetCatalog().bloodPactStatusEffects;
    return effects and effects[pactName] or nil;
end
function M.Clear()
    M.spellNameToId = nil;
    M.spellNameToIds = nil;
    M.abilityNameToId = nil;
    M.abilityNameToIds = nil;
    M.itemNameToId = nil;
    M.abilityMetaById = nil;
    allSpellsCatalog = nil;
    allAbilitiesCatalog = nil;
    rawSpellCache = {};
    rawAbilityCache = {};
    rawItemCache = {};
end
return M;
