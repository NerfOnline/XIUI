--[[
* XIUI Hotbar - Player Data Module
* Shared module for retrieving player spells, abilities, weaponskills, and items
* Used by both macropalette.lua and config/hotbar.lua
]]--
require('common');
local actiondb = require('modules.hotbar.actiondb');
local M = {};

-- ============================================
-- Cache State
-- ============================================

local cachedSpells = nil;
local cachedAbilities = nil;
local cachedWeaponskills = nil;
local cachedItems = nil;
local cacheJobId = nil;
local cacheSubJobId = nil;

-- Dat ID ceilings (full-scan verified Horizon + retail, 2026-06): spell 1019, ability 2227.
local DAT_SPELL_ID_MAX = 1051;
local DAT_ABILITY_ID_MAX = 2259;

-- Server-accurate availability lookup for hotbar dimming (built incrementally from live memory).
local AVAILABILITY_SPELL_MAX = DAT_SPELL_ID_MAX;
local AVAILABILITY_ABILITY_MAX = DAT_ABILITY_ID_MAX;
local AVAILABILITY_BUILD_BATCH = 64;
local knownSpells = {};
local knownAbilities = {};
local knownWeaponskills = {};
local knownPetCommands = {};
local availabilityBuild = nil;
local availabilityReady = false;
local availabilitySignature = nil;

-- Player memory readiness (HasSpell/HasAbility trustworthy); separate from lookup scan.
local memoryReady = false;
local memoryStableFrames = 0;
local MEMORY_STABLE_FRAMES_REQUIRED = 2;
local MEMORY_PROBE_ABILITY_MAX = DAT_ABILITY_ID_MAX;
local MEMORY_PROBE_SPELL_MAX = DAT_SPELL_ID_MAX;

-- Server list packets (0x0AA spells, 0x0AC abilities) hold authoritative ownership
-- bitmaps. Live HasSpell/HasAbility can lag until the server syncs; we prefer the
-- packet when present and seed from memory until the first list arrives.
local PACKET_SPELL_MAX = 1024;
local PACKET_ABILITY_MAX = 1792;
local ownedSpellsFromPacket = nil;
local ownedAbilitiesFromPacket = nil;
local spellListVersion = 0;
local abilityListVersion = 0;

-- ============================================
-- Container Definitions
-- ============================================

local CONTAINERS = {
    { id = 0, name = 'Inventory' },
    { id = 5, name = 'Satchel' },
    { id = 6, name = 'Sack' },
    { id = 7, name = 'Case' },
    { id = 1, name = 'Safe' },
    { id = 2, name = 'Storage' },
    { id = 4, name = 'Locker' },
    { id = 8, name = 'Wardrobe' },
    { id = 10, name = 'Wardrobe 2' },
    { id = 11, name = 'Wardrobe 3' },
    { id = 12, name = 'Wardrobe 4' },
    { id = 13, name = 'Wardrobe 5' },
    { id = 14, name = 'Wardrobe 6' },
    { id = 15, name = 'Wardrobe 7' },
    { id = 16, name = 'Wardrobe 8' },
};

-- Containers reachable from the field without mog house / special access
local ACCESSIBLE_CONTAINERS = { 0, 8, 10, 11, 12, 13, 14, 15, 16 };
local ALL_CONTAINER_IDS = {};
for _, container in ipairs(CONTAINERS) do
    ALL_CONTAINER_IDS[#ALL_CONTAINER_IDS + 1] = container.id;
end

-- ============================================
-- Helper Functions
-- ============================================

--- Check if a spell name looks like a garbage/test entry (e.g., AAEV, AAGK)
local function IsGarbageSpellName(name)
    if not name or #name < 2 then return true; end
    -- Check if it's all uppercase letters with no spaces (garbage codes)
    if #name <= 5 and name:match('^[A-Z]+$') then
        return true;
    end
    return false;
end

-- Retail spdata spell/ability requirement flags (LSB spell_requirement).
-- On Horizon/Windower exports, bit 0 is also set on many normal spells (e.g. Cure);
-- only treat as merit when the job level entry is 75.
local SPELLREQ_MERIT = 0x01;
local MERIT_SORT_LEVEL = 75;
local UNLEARNABLE_LEVEL = -1;

-- Per-job spell eligibility from Ashita dat (LevelRequired + Requirements bits).
local SCH_JOB_ID = 20;
local IMPOSSIBLE_LEVEL = 999;
local BUFF_ADDENDUM_ANY = 416;
local BUFF_LIGHT_ARTS = 358;
local BUFF_DARK_ARTS = 359;
local BUFF_METEOR = 79;
local BUFF_TABULA = 377;
local BUFF_UNBRIDLED = { [485] = true, [505] = true };
-- BLU unbridled spells; dat Requirements alone does not flag these.
local UNBRIDLED_SPELL_IDS = {
    [736] = true, [737] = true, [738] = true, [739] = true, [740] = true,
    [741] = true, [742] = true, [743] = true, [744] = true, [745] = true,
    [746] = true, [747] = true, [748] = true, [749] = true, [750] = true,
    [751] = true, [752] = true, [753] = true,
};
local spellProfileCache = {};
local function PlayerHasBuff(buffId)
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then return false; end
    local buffs = player:GetBuffs();
    if not buffs then return false; end
    for i = 1, 32 do
        if buffs[i] == buffId then return true; end
    end
    return false;
end
local function PlayerHasAnyBuff(buffSet)
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then return false; end
    local buffs = player:GetBuffs();
    if not buffs then return false; end
    for i = 1, 32 do
        if buffSet[buffs[i]] then return true; end
    end
    return false;
end
local function HasAddendumForSpell(addendumBuffId)
    if PlayerHasBuff(BUFF_ADDENDUM_ANY) then return true; end
    if addendumBuffId then return PlayerHasBuff(addendumBuffId); end
    return false;
end
local function PassesSpellBuffGate(buffCheck)
    if not buffCheck then return true; end
    if buffCheck == 'meteor' then return PlayerHasBuff(BUFF_METEOR); end
    if buffCheck == 'tabula' then return PlayerHasBuff(BUFF_TABULA); end
    if buffCheck == 'unbridled' then return PlayerHasAnyBuff(BUFF_UNBRIDLED); end
    return true;
end
local function ResolveSpellBuffCheck(spell)
    if not spell then return nil; end
    local req = spell.Requirements or 0;
    if bit.band(bit.rshift(req, 4), 1) == 1 then return 'meteor'; end
    if bit.band(bit.rshift(req, 3), 1) == 1 then return 'tabula'; end
    if UNBRIDLED_SPELL_IDS[spell.Index or spell.Id] then return 'unbridled'; end
    return nil;
end
local function NormalizeReqLevel(reqLevel)
    if not reqLevel or reqLevel <= 0 or reqLevel == 255 or reqLevel == 0xFF then
        return nil;
    end
    if reqLevel == UNLEARNABLE_LEVEL then
        return nil;
    end
    return reqLevel;
end

--- Read one index from Ashita LevelRequired/Level (plain table or indexable userdata).
local function ReadLevelIndex(levelArray, index)
    if not levelArray or not index then
        return nil;
    end
    local ok, value = pcall(function()
        return levelArray[index];
    end);
    if ok then
        return NormalizeReqLevel(value);
    end
    return nil;
end

--- Read a job level from a dat level array (tries jobId+1 and jobId indices).
local function LevelAtJobIndex(levelArray, jobId)
    if not levelArray or not jobId or jobId <= 0 then
        return nil;
    end
    if type(levelArray) == 'number' then
        return NormalizeReqLevel(levelArray);
    end
    return ReadLevelIndex(levelArray, jobId + 1) or ReadLevelIndex(levelArray, jobId);
end
local function BuildSpellJobProfile(spell, mainJobId, subJobId)
    local cacheKey = string.format('%d:%d:%d', spell.Index or spell.Id or 0, mainJobId, subJobId);
    local cached = spellProfileCache[cacheKey];
    if cached then return cached; end
    local profile = {
        mainReq = IMPOSSIBLE_LEVEL,
        subReq = IMPOSSIBLE_LEVEL,
        mainUsesJobPoints = false,
        mainAddendum = false,
        subAddendum = false,
        addendumBuffId = nil,
        buffCheck = ResolveSpellBuffCheck(spell),
    };
    if spell.LevelRequired then
        local jpMask = spell.JobPointMask or 0;
        local mainReq = LevelAtJobIndex(spell.LevelRequired, mainJobId) or IMPOSSIBLE_LEVEL;
        if bit.band(bit.rshift(jpMask, mainJobId), 1) == 1 then
            profile.mainUsesJobPoints = true;
            profile.mainReq = mainReq;
        else
            profile.mainReq = mainReq;
            if profile.mainReq == -1 then profile.mainReq = IMPOSSIBLE_LEVEL; end
            if mainJobId == SCH_JOB_ID and bit.band(bit.rshift(spell.Requirements or 0, 2), 1) == 1 then
                profile.mainAddendum = true;
                profile.addendumBuffId = (spell.Type == 1) and 401 or 402;
            end
        end
        if subJobId > 0 and bit.band(bit.rshift(jpMask, subJobId), 1) == 0 then
            profile.subReq = LevelAtJobIndex(spell.LevelRequired, subJobId) or IMPOSSIBLE_LEVEL;
            if profile.subReq == -1 then profile.subReq = IMPOSSIBLE_LEVEL; end
            if subJobId == SCH_JOB_ID and bit.band(bit.rshift(spell.Requirements or 0, 2), 1) == 1 then
                profile.subAddendum = true;
                if not profile.addendumBuffId then
                    profile.addendumBuffId = (spell.Type == 1) and 401 or 402;
                end
            end
        end
    end
    spellProfileCache[cacheKey] = profile;
    return profile;
end

-- Total JP spent on a job (tHotBar uses 0x63 totals; Ashita exposes GetJobPointsSpent).
local function GetJobPointTotal(player, jobId)
    if not player or not jobId or jobId == 0 then
        return 0;
    end
    if player.GetJobPointsSpent then
        local spent = player:GetJobPointsSpent(jobId);
        if spent and spent > 0 then
            return spent;
        end
    end
    return player:GetJobPoints(jobId) or 0;
end

local function MainJobMeetsSpellProfile(profile, mainJobId, mainLevel, player)
    if profile.mainUsesJobPoints then
        return GetJobPointTotal(player, mainJobId) >= profile.mainReq, true;
    end
    if profile.mainReq > 99 then
        return GetJobPointTotal(player, mainJobId) >= profile.mainReq, true;
    end
    if mainLevel < profile.mainReq then return false, false; end
    local addendumOk = true;
    if profile.mainAddendum then
        addendumOk = HasAddendumForSpell(profile.addendumBuffId);
    end
    return true, addendumOk;
end

local function SubJobMeetsSpellProfile(profile, subJobId, subLevel)
    if subJobId == 0 then return false, false; end
    if subLevel < profile.subReq then return false, false; end
    local addendumOk = true;
    if profile.subAddendum then
        addendumOk = HasAddendumForSpell(profile.addendumBuffId);
    end
    return true, addendumOk;
end
local function ResourceRequiresMerit(requirements, level)
    return level == MERIT_SORT_LEVEL
        and requirements ~= nil
        and bit.band(requirements, SPELLREQ_MERIT) ~= 0;
end

--- Whether a job slot's dat level is satisfied (normal levels, merit, or JP gifts).
local function JobMeetsLevelRequirement(reqLevel, playerLevel, requirements)
    local req = NormalizeReqLevel(reqLevel);
    if not req then
        return false;
    end
    if req > 99 then
        return true;
    end
    if ResourceRequiresMerit(requirements, req) then
        return true;
    end
    return playerLevel >= req;
end

--- Spell is usable on current main/sub (Ashita LevelRequired profile; HasSpell checked elsewhere).
local function IsSpellUsableForCurrentJobs(spell, player, mainJobId, subJobId)
    if not spell then return false; end
    if not spell.LevelRequired then return true; end
    local profile = BuildSpellJobProfile(spell, mainJobId, subJobId);
    local mainLevel = player:GetMainJobLevel() or 0;
    local subLevel = subJobId > 0 and (player:GetSubJobLevel() or 0) or 0;
    local mainOk, mainReady = MainJobMeetsSpellProfile(profile, mainJobId, mainLevel, player);
    local subOk, subReady = SubJobMeetsSpellProfile(profile, subJobId, subLevel);
    if not mainOk and not subOk then return false; end
    local ready = mainReady or subReady;
    if ready then ready = PassesSpellBuffGate(profile.buffCheck); end
    return ready;
end

--- Hotbar heavy-dim gate: job level or JP only (tHotBar State.Available), not buff/addendum ready state.
local function IsSpellJobUnlockedForHotbar(spell, player, mainJobId, subJobId)
    if not spell or not spell.LevelRequired then
        return true;
    end
    local profile = BuildSpellJobProfile(spell, mainJobId, subJobId);
    local mainLevel = player:GetMainJobLevel() or 0;
    local subLevel = subJobId > 0 and (player:GetSubJobLevel() or 0) or 0;
    local mainOk = select(1, MainJobMeetsSpellProfile(profile, mainJobId, mainLevel, player));
    local subOk = select(1, SubJobMeetsSpellProfile(profile, subJobId, subLevel));
    return mainOk or subOk;
end
local function JobArrayHasLevelEntry(levelArray, jobId)
    if not levelArray or not jobId then
        return false;
    end
    if type(levelArray) == 'number' then
        return NormalizeReqLevel(levelArray) ~= nil;
    end
    return ReadLevelIndex(levelArray, jobId + 1) ~= nil
        or ReadLevelIndex(levelArray, jobId) ~= nil;
end

--- Job ability is usable on current main/sub (HasAbility plus dat job level).
local function IsAbilityUsableForCurrentJobs(ability, player, mainJobId, subJobId, levelArray)
    if not ability then
        return false;
    end
    levelArray = levelArray or ability.Level;
    if not levelArray then
        return true;
    end
    local hasMainSlot = JobArrayHasLevelEntry(levelArray, mainJobId);
    local hasSubSlot = subJobId > 0 and JobArrayHasLevelEntry(levelArray, subJobId);
    if not hasMainSlot and not hasSubSlot then
        return true;
    end
    local mainLevel = player:GetMainJobLevel() or 0;
    local subLevel = subJobId > 0 and (player:GetSubJobLevel() or 0) or 0;
    local mainReq = LevelAtJobIndex(levelArray, mainJobId);
    local subReq = subJobId > 0 and LevelAtJobIndex(levelArray, subJobId) or nil;
    return JobMeetsLevelRequirement(mainReq, mainLevel, ability.Requirements)
        or JobMeetsLevelRequirement(subReq, subLevel, ability.Requirements);
end

--- Dat level for menu labels/sort only (not used for inclusion).
--- Merit-gated entries use [MP 75]; job-point gifts (level > 99) use [JP ###].
local function PackLevelDisplay(level, requirements)
    if not level or level <= 0 then
        return nil, nil;
    end
    if ResourceRequiresMerit(requirements, level) then
        return MERIT_SORT_LEVEL, 'MP 75';
    end
    if level > 99 then
        return level, string.format('JP %d', level);
    end
    return level, nil;
end

--- Pick display level and main/sub source from a per-job level array (LevelRequired / Level).
local function GetDisplayLevelForJobs(levelArray, mainJobId, subJobId, requirements)
    if not levelArray then
        return nil, nil, nil;
    end
    local mainReqLevel = LevelAtJobIndex(levelArray, mainJobId) or 0;
    local subReqLevel = subJobId > 0 and (LevelAtJobIndex(levelArray, subJobId) or 0) or 0;
    if mainReqLevel > 0 then
        local sortLevel, levelLabel = PackLevelDisplay(mainReqLevel, requirements);
        return sortLevel, levelLabel, 'main';
    end
    if subReqLevel > 0 then
        local sortLevel, levelLabel = PackLevelDisplay(subReqLevel, requirements);
        return sortLevel, levelLabel, 'sub';
    end
    return nil, nil, nil;
end

--- Label/sort level for abilities: prefer main/sub, else lowest job entry in dat.
local function GetDisplayLevelForAbilityLabel(levelArray, mainJobId, subJobId, requirements)
    local sortLevel, levelLabel, source = GetDisplayLevelForJobs(
        levelArray, mainJobId, subJobId, requirements);
    if sortLevel then
        return sortLevel, levelLabel, source;
    end
    if type(levelArray) == 'number' and levelArray > 0 then
        local sl, ll = PackLevelDisplay(levelArray, requirements);
        return sl, ll, nil;
    end
    if not levelArray then
        return nil, nil, nil;
    end
    local bestLevel = nil;
    local bestJob = nil;
    for jobId = 1, 22 do
        local req = LevelAtJobIndex(levelArray, jobId);
        if req and (not bestLevel or req < bestLevel) then
            bestLevel = req;
            bestJob = jobId;
        end
    end
    if not bestLevel then
        return nil, nil, nil;
    end
    local sl, ll = PackLevelDisplay(bestLevel, requirements);
    local src = nil;
    if bestJob == mainJobId then
        src = 'main';
    elseif subJobId > 0 and bestJob == subJobId then
        src = 'sub';
    end
    return sl, ll, src;
end

--- Combat-skill requirement for a weaponskill (e.g. 175 for Rampage), not player job level.
local function GetWeaponskillSkillLevel(ability, abilityId)
    local skillLevel = actiondb.GetWeaponskillSkillLevel(abilityId, ability);
    if skillLevel and skillLevel > 0 then
        return skillLevel;
    end
    return nil;
end

--- Attach sort/label fields for macro editor dropdown rows.
local function ApplyActionListLevelFields(entry, mainJobId, subJobId, listKind, resource, resourceId)
    if not entry or not resource then
        return;
    end
    if listKind == 'weaponskill' then
        local wsName = resource.Name and resource.Name[1] or entry.name;
        local levelLabel, sortLevel = actiondb.FormatWeaponskillLevelLabel(wsName);
        if levelLabel then
            entry.level = sortLevel;
            entry.levelLabel = levelLabel;
        else
            entry.level = GetWeaponskillSkillLevel(resource, resourceId or entry.id);
            if entry.level then
                entry.levelLabel = tostring(entry.level);
            elseif resource.MonsterLevel and resource.MonsterLevel > 0 then
                entry.level = resource.MonsterLevel;
                entry.levelLabel = tostring(resource.MonsterLevel);
            end
        end
        entry.source = nil;
        return;
    end
    local levelArray = listKind == 'spell' and resource.LevelRequired
        or actiondb.GetAbilityLevelArray(resourceId or entry.id, resource)
        or actiondb.GetAbilityLevelArrayFromResource(resource);
    local sortLevel, levelLabel, source;
    if listKind == 'spell' then
        local profile = BuildSpellJobProfile(resource, mainJobId, subJobId);
        if profile.mainUsesJobPoints and profile.mainReq < IMPOSSIBLE_LEVEL then
            sortLevel = profile.mainReq;
            levelLabel = string.format('JP %d', profile.mainReq);
            source = 'main';
        elseif subJobId > 0 then
            local subProfile = BuildSpellJobProfile(resource, subJobId, 0);
            if subProfile.mainUsesJobPoints and subProfile.mainReq < IMPOSSIBLE_LEVEL then
                sortLevel = subProfile.mainReq;
                levelLabel = string.format('JP %d', subProfile.mainReq);
                source = 'sub';
            end
        end
        if not sortLevel then
            sortLevel, levelLabel, source = GetDisplayLevelForJobs(
                levelArray, mainJobId, subJobId, resource.Requirements);
        end
        if not sortLevel and resource.JobPointMask then
            for jobId = 1, 22 do
                if bit.band(bit.rshift(resource.JobPointMask or 0, jobId), 1) == 1 then
                    local req = LevelAtJobIndex(levelArray, jobId);
                    if req then
                        sortLevel = req;
                        levelLabel = string.format('JP %d', req);
                        if jobId == mainJobId then
                            source = 'main';
                        elseif subJobId > 0 and jobId == subJobId then
                            source = 'sub';
                        end
                        break;
                    end
                end
            end
        end
    elseif listKind == 'ability' then
        sortLevel, levelLabel, source = GetDisplayLevelForAbilityLabel(
            levelArray, mainJobId, subJobId, resource.Requirements);
    else
        sortLevel, levelLabel, source = GetDisplayLevelForJobs(
            levelArray, mainJobId, subJobId, resource.Requirements);
    end
    entry.level = sortLevel;
    entry.levelLabel = levelLabel;
    entry.source = source;
    if not sortLevel and listKind == 'ability' then
        local abilityId = resourceId or entry.id;
        local mainReq = actiondb.GetAbilityLevelForJob(abilityId, mainJobId, resource);
        local subReq = subJobId > 0 and actiondb.GetAbilityLevelForJob(abilityId, subJobId, resource) or nil;
        local req = mainReq or subReq;
        if req then
            sortLevel, levelLabel = PackLevelDisplay(req, resource.Requirements);
            entry.level = sortLevel;
            entry.levelLabel = levelLabel;
            entry.source = mainReq and 'main' or 'sub';
        end
        if not entry.level then
            local bestLevel = actiondb.GetAbilityBestDisplayLevel(abilityId, resource);
            if bestLevel then
                sortLevel, levelLabel = PackLevelDisplay(bestLevel, resource.Requirements);
                entry.level = sortLevel;
                entry.levelLabel = levelLabel;
            end
        end
    elseif not sortLevel and listKind == 'spell' and levelArray then
        for jobId = 1, 22 do
            local req = LevelAtJobIndex(levelArray, jobId);
            if req then
                sortLevel, levelLabel = PackLevelDisplay(req, resource.Requirements);
                entry.level = sortLevel;
                entry.levelLabel = levelLabel;
                if jobId == mainJobId then
                    entry.source = 'main';
                elseif subJobId > 0 and jobId == subJobId then
                    entry.source = 'sub';
                end
                break;
            end
        end
    end
    if not entry.level and listKind == 'ability' then
        local abilityId = resourceId or entry.id;
        local sl, ll, src = actiondb.GetCatalogDisplayLevelForJobs(
            abilityId, mainJobId, subJobId);
        if sl then
            entry.level = sl;
            entry.levelLabel = ll;
            entry.source = src or entry.source;
        end
    end
end

--- Format a macro editor list entry label with optional level, merit, or JP prefix.
function M.FormatActionListLabel(item, itemName)
    itemName = itemName or (item and item.name) or '';
    if item and item.levelLabel then
        return string.format('[%s] %s', item.levelLabel, itemName);
    end
    if item and item.level then
        return string.format('[%d] %s', item.level, itemName);
    end
    return itemName;
end
local function SortByLevelThenId(a, b)
    local aLevel = a.level or 9999;
    local bLevel = b.level or 9999;
    if aLevel ~= bLevel then
        return aLevel < bLevel;
    end
    return (a.id or 0) < (b.id or 0);
end
local EDITOR_SPELL_TYPE_ORDER = {
    'WhiteMagic', 'BlackMagic', 'BardSong', 'Ninjutsu',
    'SummonerPact', 'BlueMagic', 'Geomancy', 'Trust', 'Unknown',
};
local EDITOR_SPELL_TYPE_RANK = {};
for i, spellType in ipairs(EDITOR_SPELL_TYPE_ORDER) do
    EDITOR_SPELL_TYPE_RANK[spellType] = i;
end
local function SortByTypeThenLevelThenId(a, b)
    local aRank = EDITOR_SPELL_TYPE_RANK[a.type] or 999;
    local bRank = EDITOR_SPELL_TYPE_RANK[b.type] or 999;
    if aRank ~= bRank then
        return aRank < bRank;
    end
    return SortByLevelThenId(a, b);
end
local STATUS_HAVE = 'have';
local STATUS_LEARNABLE = 'learnable';
local STATUS_UNAVAILABLE = 'unavailable';
local function StatusReasonLevelTooLow(entry)
    if entry.levelLabel or entry.level then
        return string.format(
            'Level too low (requires Lv. %s)',
            tostring(entry.levelLabel or entry.level));
    end
    return 'Level too low';
end
local function AttachSpellType(entry, spell, spellId)
    entry.type = actiondb.GetSpellPickerType(spell, spellId);
end

--- Set status + tooltip for macro editor Show All rows.
local function ClassifyEditorEntry(entry, hasIt, meetsRequirements, listedForJob)
    if hasIt and meetsRequirements and (listedForJob == nil or listedForJob) then
        entry.status = STATUS_HAVE;
        entry.statusReason = nil;
    elseif meetsRequirements and (listedForJob == nil or listedForJob) then
        entry.status = STATUS_LEARNABLE;
        entry.statusReason = 'Not yet learned';
    else
        entry.status = STATUS_UNAVAILABLE;
        if listedForJob == false then
            entry.statusReason = 'Not available to your current job';
        else
            entry.statusReason = StatusReasonLevelTooLow(entry);
        end
    end
end

--- Whether a spell has a valid dat level on the given job column (0/255/-1 = not learnable).
local function SpellHasJobColumn(spell, jobId)
    if not spell or not jobId or jobId <= 0 then
        return false;
    end
    if not spell.LevelRequired then
        return true;
    end
    return LevelAtJobIndex(spell.LevelRequired, jobId) ~= nil;
end

--- Whether catalog lists an ability on main or sub job column.
local function AbilityHasJobColumn(abilityId, mainJobId, subJobId)
    if not abilityId then
        return false;
    end
    if actiondb.AbilityCatalogHasJob(abilityId, mainJobId) then
        return true;
    end
    return subJobId > 0 and actiondb.AbilityCatalogHasJob(abilityId, subJobId);
end

--- Ability belongs in macro editor: learned + catalog job column (if catalog has entry).
local function IsAbilityListedForEditor(abilityId, mainJobId, subJobId)
    if not abilityId then
        return false;
    end
    if not actiondb.GetCatalogEntry(abilityId) then
        return true;
    end
    return AbilityHasJobColumn(abilityId, mainJobId, subJobId);
end
local function ClassifySpellEntry(entry, spell, player, mainJobId, subJobId)
    local hasJobCol = SpellHasJobColumn(spell, mainJobId)
        or (subJobId > 0 and SpellHasJobColumn(spell, subJobId));
    local hasSpell = player:HasSpell(entry.id);
    local meetsLevel = IsSpellUsableForCurrentJobs(spell, player, mainJobId, subJobId);
    if hasSpell and (not hasJobCol or meetsLevel) then
        entry.status = STATUS_HAVE;
        entry.statusReason = nil;
        return;
    end
    ClassifyEditorEntry(entry, false, hasJobCol and meetsLevel, hasJobCol);
end
local function ClassifyAbilityEntry(entry, ability, abilityId, player, mainJobId, subJobId)
    local levelArray = actiondb.GetAbilityLevelArray(abilityId, ability);
    local hasAbility = player:HasAbility(abilityId);
    local meetsLevel = actiondb.PlayerMeetsCatalogAbilityLevel(
        abilityId, player, mainJobId, subJobId)
        or IsAbilityUsableForCurrentJobs(ability, player, mainJobId, subJobId, levelArray);
    local listedForEditor = IsAbilityListedForEditor(abilityId, mainJobId, subJobId);
    ClassifyEditorEntry(entry, hasAbility, meetsLevel, listedForEditor);
end

--- Spell belongs in macro editor: learned (HasSpell checked upstream) + main/sub dat column.
local function IsSpellListedForEditor(spell, player, mainJobId, subJobId)
    if not spell then
        return false;
    end
    return SpellHasJobColumn(spell, mainJobId)
        or (subJobId > 0 and SpellHasJobColumn(spell, subJobId));
end

--- Trust companion spells (896–1024); excluded from macro editor spell list.
local function IsTrustSpellId(spellId)
    return spellId >= 896 and spellId <= 1024;
end

-- Inventory count cache (500ms TTL): one memory sweep replaces per-slot scans each frame.
local INVENTORY_CACHE_TTL = 0.5;
local inventoryCacheExpiry = 0;
local inventoryAccessibleById = {};
local inventoryAllById = {};
local function ClearInventoryCountTables()
    for k in pairs(inventoryAccessibleById) do
        inventoryAccessibleById[k] = nil;
    end
    for k in pairs(inventoryAllById) do
        inventoryAllById[k] = nil;
    end
end
local function ScanContainersIntoCounts(containerIds, countsById)
    local memMgr = AshitaCore:GetMemoryManager();
    if not memMgr then return; end
    local inventory = memMgr:GetInventory();
    if not inventory then return; end
    for _, containerId in ipairs(containerIds) do
        local maxSlots = inventory:GetContainerCountMax(containerId);
        if maxSlots and maxSlots > 0 then
            for slotIndex = 1, maxSlots do
                local item = inventory:GetContainerItem(containerId, slotIndex);
                if item and item.Id and item.Id > 0 and item.Id ~= 65535 then
                    countsById[item.Id] = (countsById[item.Id] or 0) + (item.Count or 1);
                end
            end
        end
    end
end
local function RefreshInventoryCache()
    local now = os.clock();
    if now < inventoryCacheExpiry then
        return;
    end
    inventoryCacheExpiry = now + INVENTORY_CACHE_TTL;
    ClearInventoryCountTables();
    ScanContainersIntoCounts(ACCESSIBLE_CONTAINERS, inventoryAccessibleById);
    ScanContainersIntoCounts(ALL_CONTAINER_IDS, inventoryAllById);
end
function M.InvalidateInventoryCache()
    inventoryCacheExpiry = 0;
    ClearInventoryCountTables();
end

-- ============================================
-- Player Data Retrieval Functions
-- ============================================

--- Get player's known spells for current main/sub (HasSpell + dat job column; sorted by level, id).
function M.GetPlayerSpells()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then return {}; end
    local mainJobId = player:GetMainJob();
    local subJobId = player:GetSubJob();
    local resMgr = AshitaCore:GetResourceManager();
    local spells = {};
    local addedSpells = {};  -- Track by spell ID to avoid duplicates
    for spellId = 0, DAT_SPELL_ID_MAX do
        if not IsTrustSpellId(spellId) and player:HasSpell(spellId) and not addedSpells[spellId] then
            local spell = resMgr:GetSpellById(spellId);
            if spell and spell.Name and spell.Name[1] and spell.Name[1] ~= ''
                and IsSpellListedForEditor(spell, player, mainJobId, subJobId) then
                local spellName = spell.Name[1];
                if not IsGarbageSpellName(spellName) then
                    local entry = {
                        id = spellId,
                        name = spellName,
                    };
                    ApplyActionListLevelFields(entry, mainJobId, subJobId, 'spell', spell, spellId);
                    AttachSpellType(entry, spell, spellId);
                    entry.status = STATUS_HAVE;
                    table.insert(spells, entry);
                    addedSpells[spellId] = true;
                end
            end
        end
    end
    table.sort(spells, SortByTypeThenLevelThenId);
    return spells;
end

--- Macro editor spell list (known-only or full dat scan with availability status).
function M.GetEditorSpells(showAll)
    if not showAll then
        return M.GetPlayerSpells();
    end
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then return {}; end
    local mainJobId = player:GetMainJob();
    local subJobId = player:GetSubJob();
    local resMgr = AshitaCore:GetResourceManager();
    if not resMgr then return {}; end
    local spells = {};
    for spellId = 0, DAT_SPELL_ID_MAX do
        if IsTrustSpellId(spellId) then
            goto continue;
        end
        local spell = resMgr:GetSpellById(spellId);
        if not spell or not spell.Name or not spell.Name[1] or spell.Name[1] == '' then
            goto continue;
        end
        local spellName = spell.Name[1];
        if IsGarbageSpellName(spellName) then
            goto continue;
        end
        if actiondb.IsSpellOmittedForEditor(spellName) then
            goto continue;
        end
        local canonicalId = actiondb.GetSpellId(spellName);
        if canonicalId and canonicalId ~= spellId then
            goto continue;
        end
        local entry = {
            id = spellId,
            name = spellName,
        };
        ApplyActionListLevelFields(entry, mainJobId, subJobId, 'spell', spell, spellId);
        AttachSpellType(entry, spell, spellId);
        ClassifySpellEntry(entry, spell, player, mainJobId, subJobId);
        table.insert(spells, entry);
        ::continue::
    end
    table.sort(spells, SortByTypeThenLevelThenId);
    return spells;
end

-- Ability Type constants — IAbility.Type is a plain uint8 enum (NOT a bitfield).
-- Authoritative source: ai/references/Ashita-v4beta/plugins/sdk/ffxi/enums.h `AbilityType`.
local ABILITY_TYPE = {
    General           = 0,
    JobAbility        = 1,
    PetCommand        = 2,
    WeaponSkill       = 3,
    Trait             = 4,
    BloodPactRage     = 6,
    CorsairRoll       = 8,
    CorsairShot       = 9,
    BloodPactWard     = 10,
    DancerSamba       = 11,
    DancerWaltz       = 12,
    DancerStep        = 13,
    DancerFlourish1   = 14,
    ScholarStratagem  = 15,
    DancerJig         = 16,
    DancerFlourish2   = 17,
    BeastmasterSic    = 18,
    DancerFlourish3   = 19,
    MonsterSkill      = 20,
    RuneEnhancement   = 21,
    RuneWard          = 22,
    RuneEffusion      = 23,
};

-- Pet commands to filter out from ability list (these belong in Pet Command section)
local PET_COMMAND_NAMES = {
    ['Assault'] = true,
    ['Retreat'] = true,
    ['Stay'] = true,
    ['Heel'] = true,
    ['Release'] = true,
    ['Leave'] = true,
    ['Fight'] = true,
    ['Sic'] = true,
    ['Ready'] = true,
    -- SMN commands
    ['Avatar\'s Favor'] = true,
    -- DRG commands
    ['Steady Wing'] = true,
    -- PUP commands
    ['Deploy'] = true,
    ['Retrieve'] = true,
    ['Activate'] = true,
    ['Deactivate'] = true,
};

-- FFXI macro-maker subcategory headers ("Sambas", "Waltzes", etc.) are present
-- as ability entries in the resource manager and HasAbility() returns true for
-- them, but they aren't executable. Filter them out of editor dropdowns.
local CATEGORY_PLACEHOLDER_NAMES = {
    -- DNC
    ['Sambas']         = true,
    ['Waltzes']        = true,
    ['Steps']          = true,
    ['Jigs']           = true,
    ['Flourishes I']   = true,
    ['Flourishes II']  = true,
    ['Flourishes III'] = true,
    -- BST
    ['Ready']          = true,
    -- SCH
    ['Stratagems']     = true,
    -- RUN
    ['Rune Enchantment'] = true,
    ['Ward']           = true,
    ['Effusion']       = true,
    -- COR
    ['Phantom Roll']   = true,
    ['Quick Draw']     = true,
    -- SMN
    ['Blood Pact: Rage'] = true,
    ['Blood Pact: Ward'] = true,
};
local function IsCategoryPlaceholderName(abilityName)
    return abilityName ~= nil and CATEGORY_PLACEHOLDER_NAMES[abilityName] == true;
end

--- Category label for macro editor rows (matches petregistry type names).
local function EditorCategoryFromAbilityType(abilityType)
    if abilityType == ABILITY_TYPE.BloodPactRage then
        return 'BP: Rage';
    end
    if abilityType == ABILITY_TYPE.BloodPactWard then
        return 'BP: Ward';
    end
    if abilityType == ABILITY_TYPE.MonsterSkill then
        return 'Ready';
    end
    if abilityType == ABILITY_TYPE.BeastmasterSic then
        return 'Command';
    end
    return 'Command';
end

--- Whether name is a job's base /pet order (Assault, Heel, etc.).
local function IsJobBasePetCommandName(petregistry, jobId, commandName)
    if not commandName or not jobId then
        return false;
    end
    for _, cmd in ipairs(petregistry.GetMacroEditorBasePetCommands(jobId)) do
        if cmd.name == commandName then
            return true;
        end
    end
    return false;
end
local function PlayerHasPetJobSlotted(jobId, mainJobId, subJobId)
    return mainJobId == jobId or (subJobId > 0 and subJobId == jobId);
end

--- Job-level gate for macro editor pet rows (ability dat levels; base /pet orders).
local function EditorPetCommandMeetsJobLevel(player, commandName, mainJobId, subJobId, actiondbMod, resMgr, petregistry)
    for _, abilityId in ipairs(actiondbMod.GetAbilityIds(commandName)) do
        local ability = resMgr:GetAbilityById(abilityId);
        if ability then
            local skip = petregistry.IsBloodPactName(commandName)
                and not actiondbMod.IsBloodPactAbilityType(ability.Type);
            if not skip
                and actiondbMod.PlayerMeetsCatalogAbilityLevel(
                    abilityId, player, mainJobId, subJobId) then
                return true;
            end
        end
    end
    return IsJobBasePetCommandName(petregistry, mainJobId, commandName)
        or IsJobBasePetCommandName(petregistry, subJobId, commandName);
end

--- Whether a scanned dat ability belongs in this job's macro editor pet list.
local function IsEditorPetAbilityForJob(jobId, abilityName, abilityType, petregistry)
    if IsCategoryPlaceholderName(abilityName) then
        return false;
    end
    if abilityType == ABILITY_TYPE.BloodPactRage
        or abilityType == ABILITY_TYPE.BloodPactWard then
        return jobId == petregistry.JOB_SMN;
    end
    if abilityType == ABILITY_TYPE.BeastmasterSic
        or abilityType == ABILITY_TYPE.MonsterSkill then
        return jobId == petregistry.JOB_BST;
    end
    if abilityType == ABILITY_TYPE.PetCommand then
        if IsJobBasePetCommandName(petregistry, jobId, abilityName) then
            return true;
        end
        if jobId == petregistry.JOB_DRG then
            for _, cmd in ipairs(petregistry.wyvernCommands) do
                if cmd.name == abilityName then
                    return true;
                end
            end
        elseif jobId == petregistry.JOB_PUP then
            for _, cmd in ipairs(petregistry.automatonCommands) do
                if cmd.name == abilityName then
                    return true;
                end
            end
            for _, cmd in ipairs(petregistry.maneuverCommands) do
                if cmd.name == abilityName then
                    return true;
                end
            end
        end
        return false;
    end
    return false;
end

--- Whether a blood pact belongs to any SummonerPact-unlocked avatar.
local function IsBloodPactForAnyUnlockedAvatar(pactName, unlockedAvatars, petregistry)
    if not unlockedAvatars then
        return false;
    end
    for avatarName, _ in pairs(unlockedAvatars) do
        if petregistry.IsBloodPactForAvatar(pactName, avatarName) then
            return true;
        end
    end
    return false;
end

--- Macro editor: blood pact owned via ability memory, or dat level for an unlocked avatar.
--- Ashita often omits BP rows from HasAbility until an avatar has been summoned once.
local function PlayerOwnsEditorBloodPact(
    player, abilityId, ability, unlockedAvatars, mainJobId, subJobId, actiondb, petregistry)
    if actiondb.PlayerHasAbilityId(player, abilityId) then
        return true;
    end
    local pactName = ability.Name and ability.Name[1];
    if pactName and M.HasKnownPetCommand(pactName) then
        return true;
    end
    if not pactName or not IsBloodPactForAnyUnlockedAvatar(pactName, unlockedAvatars, petregistry) then
        return false;
    end
    return actiondb.PlayerMeetsCatalogAbilityLevel(
        abilityId, player, mainJobId, subJobId);
end

--- Resolve pet-command ability row from dat (handles duplicate names like Impact).
local function ResolveEditorPetAbilityByName(commandName, actiondb, resMgr)
    if not commandName or commandName == '' then
        return nil, nil;
    end
    for _, abilityId in ipairs(actiondb.GetAbilityIds(commandName)) do
        local ability = resMgr:GetAbilityById(abilityId);
        if ability and actiondb.IsMacroEditorPetAbilityType(ability.Type) then
            return abilityId, ability;
        end
    end
    local abilityId = actiondb.GetAbilityId(commandName);
    if abilityId then
        return abilityId, resMgr:GetAbilityById(abilityId);
    end
    return nil, nil;
end

--- Build macro editor pet commands from dat ability types + live HasAbility.
local function BuildEditorPetCommandsFromMemory(
    player, jobId, avatarName, activePetName, jugOwnedInternalNames, unlockedAvatars,
    petregistry, actiondb, resMgr, mainJobId, subJobId, showAll)
    local commands = {};
    local seen = {};
    local function ClassifyPetCommandEntry(entry, ability, abilityId)
        local hasCommand = false;
        if abilityId and abilityId > 0 then
            hasCommand = actiondb.PlayerHasAbilityId(player, abilityId);
        end
        if not hasCommand and entry.name then
            hasCommand = actiondb.PlayerHasPetCommand(player, entry.name);
        end
        local meetsLevel = EditorPetCommandMeetsJobLevel(
            player, entry.name, mainJobId, subJobId, actiondb, resMgr, petregistry);
        ClassifyEditorEntry(entry, hasCommand, meetsLevel, nil);
    end
    local function AppendEntry(name, category, abilityId, ability)
        if not name or seen[name] then
            return;
        end
        if jobId == petregistry.JOB_SMN and avatarName
            and actiondb.IsBloodPactAbilityType(ability and ability.Type or 0)
            and not petregistry.IsBloodPactForAvatar(name, avatarName) then
            return;
        end
        local entry = {
            id = abilityId,
            name = name,
            category = category,
        };
        if ability then
            ApplyActionListLevelFields(
                entry, mainJobId, subJobId, 'ability', ability, abilityId);
        end
        if showAll then
            ClassifyPetCommandEntry(entry, ability, abilityId);
        else
            entry.status = STATUS_HAVE;
        end
        table.insert(commands, entry);
        seen[name] = true;
    end
    for abilityId = 0, AVAILABILITY_ABILITY_MAX do
        local includeAbility = showAll or actiondb.PlayerHasAbilityId(player, abilityId);
        if includeAbility then
            local ability = resMgr:GetAbilityById(abilityId);
            if ability and ability.Name and ability.Name[1] and ability.Name[1] ~= '' then
                local abilityName = ability.Name[1];
                local abilityType = ability.Type or 0;
                if IsEditorPetAbilityForJob(jobId, abilityName, abilityType, petregistry) then
                    AppendEntry(
                        abilityName,
                        EditorCategoryFromAbilityType(abilityType),
                        abilityId,
                        ability);
                end
            end
        end
    end
    if jobId == petregistry.JOB_SMN then
        for abilityId = 0, AVAILABILITY_ABILITY_MAX do
            local ability = resMgr:GetAbilityById(abilityId);
            if ability and ability.Name and ability.Name[1] and ability.Name[1] ~= '' then
                local abilityType = ability.Type or 0;
                if actiondb.IsBloodPactAbilityType(abilityType) then
                    local includePact = showAll
                        or PlayerOwnsEditorBloodPact(
                            player, abilityId, ability, unlockedAvatars,
                            mainJobId, subJobId, actiondb, petregistry);
                    if includePact then
                        AppendEntry(
                            ability.Name[1],
                            EditorCategoryFromAbilityType(abilityType),
                            abilityId,
                            ability);
                    end
                end
            end
        end
    end
    if jobId == petregistry.JOB_BST then
        local function AppendReadyMoves(moves)
            if not moves then
                return;
            end
            for _, move in ipairs(moves) do
                if move.name and not seen[move.name] then
                    local includeMove = showAll
                        or actiondb.PlayerHasPetCommand(player, move.name);
                    if includeMove then
                        local abilityId = actiondb.GetPlayerAbilityId(player, move.name);
                        local ability = abilityId and resMgr:GetAbilityById(abilityId) or nil;
                        AppendEntry(move.name, move.category or 'Ready', abilityId, ability);
                    end
                end
            end
        end
        if activePetName then
            AppendReadyMoves(petregistry.GetReadyMovesForPet(activePetName));
        elseif jugOwnedInternalNames and #jugOwnedInternalNames > 0 then
            for _, petName in ipairs(jugOwnedInternalNames) do
                AppendReadyMoves(petregistry.GetReadyMovesForPet(petName));
            end
        elseif showAll then
            AppendReadyMoves(petregistry.GetAllReadyMoves());
        end
    end
    for _, cmd in ipairs(petregistry.GetMacroEditorBasePetCommands(jobId)) do
        if not seen[cmd.name] and PlayerHasPetJobSlotted(jobId, mainJobId, subJobId) then
            local includeBase = showAll
                or EditorPetCommandMeetsJobLevel(
                    player, cmd.name, mainJobId, subJobId, actiondb, resMgr, petregistry);
            if includeBase then
                local abilityId, ability = ResolveEditorPetAbilityByName(cmd.name, actiondb, resMgr);
                AppendEntry(cmd.name, cmd.category, abilityId, ability);
            end
        end
    end
    table.sort(commands, SortByLevelThenId);
    return commands;
end

--- Get player's available job abilities (HasAbility + current job levels; labels from dat).
--- Excludes weaponskills, pet-command types, MonsterSkill, and menu placeholders.
function M.GetPlayerAbilities()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then return {}; end
    local mainJobId = player:GetMainJob();
    local subJobId = player:GetSubJob();
    local resMgr = AshitaCore:GetResourceManager();
    local abilities = {};
    local addedAbilities = {};  -- Track by ability ID to avoid duplicates
    for abilityId = 1, AVAILABILITY_ABILITY_MAX do
        if player:HasAbility(abilityId) and not addedAbilities[abilityId] then
            local ability = resMgr:GetAbilityById(abilityId);
            if ability and ability.Name and ability.Name[1] and ability.Name[1] ~= '' then
                local levelArray = actiondb.GetAbilityLevelArray(abilityId, ability);
                if IsAbilityUsableForCurrentJobs(ability, player, mainJobId, subJobId, levelArray) then
                    local abilityType = ability.Type or 0;
                    local abilityName = ability.Name[1];
                    if actiondb.IsMacroEditorJobAbilityType(abilityType)
                        and not IsCategoryPlaceholderName(abilityName)
                        and IsAbilityListedForEditor(
                            abilityId, mainJobId, subJobId, actiondb)
                    then
                        local entry = {
                            id = abilityId,
                            name = abilityName,
                        };
                        ApplyActionListLevelFields(entry, mainJobId, subJobId, 'ability', ability, abilityId);
                        entry.status = STATUS_HAVE;
                        table.insert(abilities, entry);
                        addedAbilities[abilityId] = true;
                    end
                end
            end
        end
    end
    table.sort(abilities, SortByLevelThenId);
    return abilities;
end

--- Macro editor ability list (known-only or full dat scan with availability status).
function M.GetEditorAbilities(showAll)
    if not showAll then
        return M.GetPlayerAbilities();
    end
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then return {}; end
    local mainJobId = player:GetMainJob();
    local subJobId = player:GetSubJob();
    local resMgr = AshitaCore:GetResourceManager();
    if not resMgr then return {}; end
    local abilities = {};
    local addedNames = {};
    for abilityId = 1, DAT_ABILITY_ID_MAX do
        local ability = resMgr:GetAbilityById(abilityId);
        if not ability or not ability.Name or not ability.Name[1] or ability.Name[1] == '' then
            goto continue;
        end
        local abilityName = ability.Name[1];
        if addedNames[abilityName] then
            goto continue;
        end
        local abilityType = ability.Type or 0;
        if not actiondb.IsMacroEditorJobAbilityType(abilityType)
            or IsCategoryPlaceholderName(abilityName) then
            goto continue;
        end
        local canonicalId = actiondb.GetAbilityId(abilityName);
        if canonicalId and canonicalId ~= abilityId then
            goto continue;
        end
        local entry = {
            id = abilityId,
            name = abilityName,
        };
        ApplyActionListLevelFields(entry, mainJobId, subJobId, 'ability', ability, abilityId);
        ClassifyAbilityEntry(entry, ability, abilityId, player, mainJobId, subJobId);
        table.insert(abilities, entry);
        addedNames[abilityName] = true;
        ::continue::
    end
    table.sort(abilities, SortByLevelThenId);
    return abilities;
end

--- Get player's available weaponskills
--- Uses HasAbility and filters by Type 3 (weapon skills)
function M.GetPlayerWeaponskills()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then return {}; end
    local resMgr = AshitaCore:GetResourceManager();
    local weaponskills = {};
    local addedWeaponskills = {};  -- Track by name to avoid duplicates

    -- Scan HasAbility and filter by Type == WeaponSkill (3)
    for abilityId = 1, AVAILABILITY_ABILITY_MAX do
        if player:HasAbility(abilityId) then
            local ability = resMgr:GetAbilityById(abilityId);
            if ability and ability.Name and ability.Name[1] and ability.Name[1] ~= '' then
                local abilityType = ability.Type or 0;
                if abilityType == ABILITY_TYPE.WeaponSkill then
                    local wsName = ability.Name[1];
                    if not addedWeaponskills[wsName] then
                        local mainJobId = player:GetMainJob();
                        local subJobId = player:GetSubJob();
                        local entry = {
                            id = abilityId,
                            name = wsName,
                        };
                        ApplyActionListLevelFields(entry, mainJobId, subJobId, 'weaponskill', ability, abilityId);
                        entry.status = STATUS_HAVE;
                        table.insert(weaponskills, entry);
                        addedWeaponskills[wsName] = true;
                    end
                end
            end
        end
    end
    table.sort(weaponskills, SortByLevelThenId);
    return weaponskills;
end
local function EditorWsNotLearnedReason(entry)
    if entry.levelLabel then
        return string.format('Not yet learned — requires %s', entry.levelLabel);
    end
    if entry.level then
        return string.format(
            'Not yet learned — use the weapon in battle (skill Lv. %d)',
            entry.level);
    end
    return 'Not yet learned';
end

--- Macro editor weaponskill list (known-only or full dat scan with availability status).
function M.GetEditorWeaponskills(showAll)
    if not showAll then
        return M.GetPlayerWeaponskills();
    end
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then return {}; end
    local mainJobId = player:GetMainJob();
    local subJobId = player:GetSubJob();
    local resMgr = AshitaCore:GetResourceManager();
    if not resMgr then return {}; end
    local weaponskills = {};
    local addedNames = {};
    for abilityId = 1, DAT_ABILITY_ID_MAX do
        local ability = resMgr:GetAbilityById(abilityId);
        if not ability or not ability.Name or not ability.Name[1] or ability.Name[1] == '' then
            goto continue;
        end
        local abilityType = ability.Type or 0;
        if abilityType ~= ABILITY_TYPE.WeaponSkill then
            goto continue;
        end
        local wsName = ability.Name[1];
        if addedNames[wsName] then
            goto continue;
        end
        local hasWs = player:HasAbility(abilityId);
        local entry = {
            id = abilityId,
            name = wsName,
        };
        ApplyActionListLevelFields(entry, mainJobId, subJobId, 'weaponskill', ability, abilityId);
        entry.status = hasWs and STATUS_HAVE or STATUS_UNAVAILABLE;
        if not hasWs then
            entry.statusReason = EditorWsNotLearnedReason(entry);
        end
        table.insert(weaponskills, entry);
        addedNames[wsName] = true;
        ::continue::
    end
    table.sort(weaponskills, SortByLevelThenId);
    return weaponskills;
end

--- Whether the player has learned a summoning spell (avatar or spirit) by name.
--- Avatars use SummonerPact dat rows (skill 38); spirits use normal summon magic.
local function PlayerHasSummonSpell(player, summonName, actiondbMod, petregistry)
    if petregistry and petregistry.avatars and petregistry.avatars[summonName] then
        return actiondbMod.PlayerHasSummonerPactSpell(player, summonName);
    end
    return actiondbMod.PlayerHasSpell(player, summonName);
end

--- Pet commands / blood pacts use HasPetCommand when available; fall back to HasAbility.
local function PlayerHasPetCommandByName(player, commandName, actiondbMod)
    return actiondbMod.PlayerHasPetCommand(player, commandName);
end

--- Macro editor: learned pet commands via HasAbility (blood pacts + pet-menu abilities).
--- SummonerPact spells are avatar unlock only — never treated as owned pet commands.
local function PlayerOwnsPetCommandForEditor(player, commandName, actiondbMod, petregistry)
    if not player or not commandName or commandName == '' then
        return false;
    end
    if petregistry.IsBloodPactName(commandName) then
        return actiondbMod.PlayerHasBloodPactAbility(player, commandName);
    end
    if actiondbMod.PlayerHasPetMenuAbility(player, commandName) then
        return true;
    end
    local resMgr = AshitaCore:GetResourceManager();
    if not resMgr then
        return false;
    end
    for _, abilityId in ipairs(actiondbMod.GetAbilityIds(commandName)) do
        if player:HasAbility(abilityId) then
            local ability = resMgr:GetAbilityById(abilityId);
            if ability and actiondbMod.IsMacroEditorPetAbilityType(ability.Type) then
                return true;
            end
        end
    end
    return false;
end
local function IsScannedPetCommandAbility(ability, abilityName)
    if not ability or not abilityName or abilityName == '' then
        return false;
    end
    local abilityType = ability.Type or 0;
    return abilityType == ABILITY_TYPE.PetCommand
        or abilityType == ABILITY_TYPE.BloodPactRage
        or abilityType == ABILITY_TYPE.BloodPactWard
        or abilityType == ABILITY_TYPE.BeastmasterSic
        or abilityType == ABILITY_TYPE.MonsterSkill
        or PET_COMMAND_NAMES[abilityName];
end

--- Refresh known pet commands from live HasAbility before editor lists.
local function EnsureEditorPetCommandScan(player, jobId, petregistry, actiondbMod)
    local resMgr = AshitaCore:GetResourceManager();
    if not resMgr or not player then
        return;
    end
    for _, pact in ipairs(petregistry.GetAllBloodPacts()) do
        knownPetCommands[pact.name] = nil;
    end
    for _, cmd in ipairs(petregistry.GetMacroEditorBasePetCommands(jobId)) do
        knownPetCommands[cmd.name] = nil;
    end
    for abilityId = 1, AVAILABILITY_ABILITY_MAX do
        if player:HasAbility(abilityId) then
            local ability = resMgr:GetAbilityById(abilityId);
            if ability and ability.Name and ability.Name[1] and ability.Name[1] ~= '' then
                local abilityName = ability.Name[1];
                local abilityType = ability.Type or 0;
                if actiondbMod.IsBloodPactAbilityType(abilityType) then
                    knownPetCommands[abilityName] = true;
                    knownAbilities[abilityName] = true;
                elseif IsScannedPetCommandAbility(ability, abilityName) then
                    knownPetCommands[abilityName] = true;
                    knownAbilities[abilityName] = true;
                end
            end
        end
    end
end

--- Clear and rescan editor pet-command ownership (call when opening the pet dropdown).
function M.RefreshEditorPetCommandCache(player, jobId)
    if not player or not jobId then
        return;
    end
    local petregistry = require('modules.hotbar.petregistry');
    if not petregistry.IsPetJob(jobId) then
        return;
    end
    local actiondbMod = actiondb;
    EnsureEditorPetCommandScan(player, jobId, petregistry, actiondbMod);
end

--- Macro editor: learned commands only (HasAbility / scan), never live pet-runtime checks.
local function PlayerKnowsCommandForEditor(player, commandName, actiondbMod, petregistry)
    return PlayerOwnsPetCommandForEditor(player, commandName, actiondbMod, petregistry);
end

--- Avatar/spirit unlocked via summon spell or any known blood pact for that avatar.
local function IsSummonUnlocked(player, summonName, petregistry, actiondb, isAvatar)
    if PlayerHasSummonSpell(player, summonName, actiondb, petregistry) then
        return true;
    end
    if not isAvatar then
        return false;
    end
    for _, pact in ipairs(petregistry.GetBloodPactsForAvatar(summonName)) do
        if actiondb.PlayerHasBloodPactAbility(player, pact.name) then
            return true;
        end
    end
    return false;
end

--- Summon names the player has unlocked (summon spell or blood pacts for that avatar).
local function GetUnlockedSummonNames(player, petregistry, actiondb)
    local unlocked = {};
    for avatarName in pairs(petregistry.avatars) do
        if IsSummonUnlocked(player, avatarName, petregistry, actiondb, true) then
            table.insert(unlocked, avatarName);
        end
    end
    for spiritName in pairs(petregistry.spirits) do
        if IsSummonUnlocked(player, spiritName, petregistry, actiondb, false)
            or PlayerHasSummonSpell(player, spiritName, actiondb, petregistry) then
            table.insert(unlocked, spiritName);
        end
    end
    table.sort(unlocked);
    return unlocked;
end

--- Avatar names unlocked via summon spell, known blood pacts, or availability scan.
local function BuildUnlockedAvatars(player, petregistry, actiondb)
    local unlockedAvatars = {};
    for _, summonName in ipairs(GetUnlockedSummonNames(player, petregistry, actiondb)) do
        if petregistry.avatars[summonName] then
            unlockedAvatars[summonName] = true;
        end
    end
    for avatar, _ in pairs(petregistry.avatars) do
        if not unlockedAvatars[avatar] then
            for _, pact in ipairs(petregistry.GetBloodPactsForAvatar(avatar)) do
                if actiondb.PlayerHasBloodPactAbility(player, pact.name) then
                    unlockedAvatars[avatar] = true;
                    break;
                end
            end
        end
    end
    return unlockedAvatars;
end

--- Ordered avatar names the player has unlocked (for macro editor filters).
function M.GetUnlockedAvatarNames()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then
        return {};
    end
    local petregistry = require('modules.hotbar.petregistry');
    local unlockedAvatars = BuildUnlockedAvatars(player, petregistry, actiondb);
    local list = {};
    for avatarName in pairs(unlockedAvatars) do
        list[#list + 1] = avatarName;
    end
    table.sort(list);
    return list;
end

--- Summon avatars for macro editor avatar filter (owned/unlocked, no pact-only avatars).
function M.GetMacroEditorAvatarNames()
    local owned = M.GetUnlockedAvatarNames();
    local petregistry = require('modules.hotbar.petregistry');
    local filtered = {};
    for _, avatarName in ipairs(owned) do
        if petregistry.IsMacroEditorAvatar(avatarName) then
            filtered[#filtered + 1] = avatarName;
        end
    end
    return filtered;
end

--- Build pet command candidates for a job before HasAbility filtering.
local function BuildPetCommandCandidates(
    petregistry, jobId, avatarName, activePetName, unlockedAvatars, jugOwnedInternalNames)
    local candidates = {};
    for _, cmd in ipairs(petregistry.GetMacroEditorBasePetCommands(jobId)) do
        table.insert(candidates, cmd);
    end
    if jobId == petregistry.JOB_SMN then
        if avatarName and petregistry.avatars[avatarName] then
            if unlockedAvatars[avatarName] then
                for _, pact in ipairs(petregistry.GetBloodPactsForAvatar(avatarName)) do
                    table.insert(candidates, pact);
                end
            end
        else
            for avatar, _ in pairs(unlockedAvatars) do
                if petregistry.avatars[avatar] then
                    for _, pact in ipairs(petregistry.GetBloodPactsForAvatar(avatar)) do
                        table.insert(candidates, pact);
                    end
                end
            end
        end
    elseif jobId == petregistry.JOB_DRG then
        for _, cmd in ipairs(petregistry.wyvernCommands) do
            table.insert(candidates, cmd);
        end
    elseif jobId == petregistry.JOB_PUP then
        for _, cmd in ipairs(petregistry.automatonCommands) do
            table.insert(candidates, cmd);
        end
        for _, cmd in ipairs(petregistry.maneuverCommands) do
            table.insert(candidates, cmd);
        end
    elseif jobId == petregistry.JOB_BST then
        for _, cmd in ipairs(petregistry.bstReadyCommands) do
            table.insert(candidates, cmd);
        end
        local function AppendReadyMoves(moves)
            if not moves then
                return;
            end
            for _, move in ipairs(moves) do
                table.insert(candidates, move);
            end
        end
        if activePetName then
            AppendReadyMoves(petregistry.GetReadyMovesForPet(activePetName));
        elseif jugOwnedInternalNames and #jugOwnedInternalNames > 0 then
            for _, petName in ipairs(jugOwnedInternalNames) do
                AppendReadyMoves(petregistry.GetReadyMovesForPet(petName));
            end
        elseif activePetName == nil and not jugOwnedInternalNames then
            local readyMoves = petregistry.GetAllReadyMoves();
            AppendReadyMoves(readyMoves);
        end
    end
    return candidates;
end

--- Macro editor candidates: do not require unlockedAvatars or a live pet for SMN pacts.
local function BuildEditorRegistryCommandNames(
    petregistry, jobId, avatarName, activePetName, jugOwnedInternalNames,
    unlockedAvatars, player, actiondb)
    local candidates = {};
    local seen = {};
    local function Append(cmd)
        if cmd and cmd.name and not seen[cmd.name] then
            table.insert(candidates, cmd);
            seen[cmd.name] = true;
        end
    end
    for _, cmd in ipairs(petregistry.GetMacroEditorBasePetCommands(jobId)) do
        Append(cmd);
    end
    if jobId == petregistry.JOB_SMN then
        if avatarName and petregistry.avatars[avatarName] then
            for _, pact in ipairs(petregistry.GetBloodPactsForAvatar(avatarName)) do
                Append(pact);
            end
        else
            local avatars = {};
            if unlockedAvatars then
                for avatar, _ in pairs(unlockedAvatars) do
                    avatars[avatar] = true;
                end
            end
            for avatar, _ in pairs(avatars) do
                if petregistry.avatars[avatar] then
                    for _, pact in ipairs(petregistry.GetBloodPactsForAvatar(avatar)) do
                        Append(pact);
                    end
                end
            end
        end
    elseif jobId == petregistry.JOB_DRG then
        for _, cmd in ipairs(petregistry.wyvernCommands) do
            Append(cmd);
        end
    elseif jobId == petregistry.JOB_PUP then
        for _, cmd in ipairs(petregistry.automatonCommands) do
            Append(cmd);
        end
        for _, cmd in ipairs(petregistry.maneuverCommands) do
            Append(cmd);
        end
    elseif jobId == petregistry.JOB_BST then
        for _, cmd in ipairs(petregistry.bstReadyCommands) do
            Append(cmd);
        end
        local function AppendReadyMoves(moves)
            if not moves then
                return;
            end
            for _, move in ipairs(moves) do
                Append(move);
            end
        end
        if activePetName then
            AppendReadyMoves(petregistry.GetReadyMovesForPet(activePetName));
        elseif jugOwnedInternalNames and #jugOwnedInternalNames > 0 then
            for _, petName in ipairs(jugOwnedInternalNames) do
                AppendReadyMoves(petregistry.GetReadyMovesForPet(petName));
            end
        else
            AppendReadyMoves(petregistry.GetAllReadyMoves());
        end
    end
    return candidates;
end

--- Pet commands the player can use (HasPetCommand; SMN pacts only for unlocked summons).
--- Editor mode lists learned commands; SMN blood pacts also require main/sub job level like abilities.
function M.GetPlayerPetCommands(jobId, avatarName, activePetName, forEditor, jugOwnedInternalNames, showAll)
    jobId = tonumber(jobId) or jobId;
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player or not jobId then
        return {};
    end
    local petregistry = require('modules.hotbar.petregistry');
    if not petregistry.IsPetJob(jobId) then
        return {};
    end
    local resMgr = AshitaCore:GetResourceManager();
    if not resMgr then
        return {};
    end
    local mainJobId = player:GetMainJob();
    local subJobId = player:GetSubJob();
    local unlockedAvatars = {};
    if jobId == petregistry.JOB_SMN then
        unlockedAvatars = BuildUnlockedAvatars(player, petregistry, actiondb);
    end
    if forEditor then
        return BuildEditorPetCommandsFromMemory(
            player, jobId, avatarName, activePetName, jugOwnedInternalNames, unlockedAvatars,
            petregistry, actiondb, resMgr, mainJobId, subJobId, showAll == true);
    end
    if jobId == petregistry.JOB_SMN then
        if avatarName and not unlockedAvatars[avatarName] then
            return {};
        end
    end
    local candidates = BuildPetCommandCandidates(
        petregistry, jobId, avatarName, activePetName, unlockedAvatars, jugOwnedInternalNames);
    local commands = {};
    local seen = {};
    for _, cmd in ipairs(candidates) do
        local isKnown = PlayerHasPetCommandByName(player, cmd.name, actiondb);
        if isKnown and cmd.name and not seen[cmd.name] then
            local abilityId = actiondb.GetAbilityId(cmd.name);
            local ability = abilityId and resMgr:GetAbilityById(abilityId) or nil;
            local entry = {
                id = abilityId,
                name = cmd.name,
                category = cmd.category,
            };
            if ability then
                ApplyActionListLevelFields(
                    entry, mainJobId, subJobId, 'ability', ability, abilityId);
            end
            table.insert(commands, entry);
            seen[cmd.name] = true;
        end
    end
    table.sort(commands, SortByLevelThenId);
    return commands;
end

--- Macro editor pet command list (known-only or expanded with availability status).
function M.GetEditorPetCommands(showAll, jobId, avatarName, activePetName, jugOwnedInternalNames)
    return M.GetPlayerPetCommands(
        jobId, avatarName, activePetName, true, jugOwnedInternalNames, showAll == true);
end

--- Pet-command macro editor list (learned only; ignores live pet/automaton state).
function M.GetPlayerPetMacroAbilities(jobId, avatarName)
    return M.GetPlayerPetCommands(jobId, avatarName, nil, true, nil);
end

--- Get items from all player storage containers
function M.GetPlayerItems()
    local memMgr = AshitaCore:GetMemoryManager();
    if not memMgr then return {}; end
    local inventory = memMgr:GetInventory();
    if not inventory then return {}; end
    local resMgr = AshitaCore:GetResourceManager();
    local items = {};
    local seenItems = {};  -- Track unique items by name to avoid duplicates
    for _, container in ipairs(CONTAINERS) do
        local maxSlots = inventory:GetContainerCountMax(container.id);
        if maxSlots and maxSlots > 0 then
            for slotIndex = 1, maxSlots do
                local item = inventory:GetContainerItem(container.id, slotIndex);
                if item and item.Id and item.Id > 0 and item.Id ~= 65535 then
                    local itemRes = resMgr:GetItemById(item.Id);
                    if itemRes and itemRes.Name and itemRes.Name[1] and itemRes.Name[1] ~= '' then
                        local itemName = itemRes.Name[1];
                        -- Only add if we haven't seen this item name yet
                        if not seenItems[itemName] then
                            seenItems[itemName] = true;
                            -- Check if item is usable (has activation time or recast delay)
                            local isUsable = false;
                            if itemRes.CastTime and itemRes.CastTime > 0 then
                                isUsable = true;
                            elseif itemRes.RecastDelay and itemRes.RecastDelay > 0 then
                                isUsable = true;
                            end
                            table.insert(items, {
                                id = item.Id,
                                name = itemName,
                                container = container.name,
                                count = item.Count or 1,
                                slots = itemRes.Slots or 0,  -- Equipment slot bitmask
                                usable = isUsable,
                            });
                        end
                    end
                end
            end
        end
    end
    table.sort(items, function(a, b)
        return a.name < b.name;
    end);
    return items;
end

-- ============================================
-- Cache Management
-- ============================================

--- Refresh cached lists if job changed or cache is empty
--- Call this before accessing cached data
function M.RefreshCachedLists(dataModule)
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then return; end
    local currentJobId = player:GetMainJob();
    local currentSubJobId = player:GetSubJob();

    -- Ignore invalid job IDs (can happen during menu transitions)
    -- This prevents the cache from being corrupted with job 0
    if not currentJobId or currentJobId == 0 then return; end

    -- Check if dataModule indicates a pending job change we haven't processed yet
    -- This catches cases where the packet handler updated data.jobId but player API was slower
    local dataJobId = dataModule and dataModule.jobId or currentJobId;
    local dataSubjobId = dataModule and dataModule.subjobId or currentSubJobId;

    -- Refresh if main job, sub job changed, or cache is empty
    -- Also refresh if data.jobId differs from cache (pending job change)
    local jobChanged = cacheJobId ~= currentJobId or cacheSubJobId ~= currentSubJobId;
    local pendingChange = cacheJobId ~= nil and (cacheJobId ~= dataJobId or cacheSubJobId ~= dataSubjobId);
    if jobChanged or pendingChange or not cachedSpells then
        cachedSpells = M.GetPlayerSpells();
        cachedAbilities = M.GetPlayerAbilities();
        cachedWeaponskills = M.GetPlayerWeaponskills();
        cachedItems = nil;  -- Clear items cache to refresh on next access
        cacheJobId = currentJobId;
        cacheSubJobId = currentSubJobId;
    end

    -- Only refresh items if cache is empty (expensive operation)
    if not cachedItems then
        cachedItems = M.GetPlayerItems();
    end
end

--- Get cached spells (call RefreshCachedLists first)
function M.GetCachedSpells()
    return cachedSpells;
end

--- Get cached abilities (call RefreshCachedLists first)
function M.GetCachedAbilities()
    return cachedAbilities;
end

--- Get cached weaponskills (call RefreshCachedLists first)
function M.GetCachedWeaponskills()
    return cachedWeaponskills;
end

--- Get cached items (call RefreshCachedLists first)
function M.GetCachedItems()
    return cachedItems;
end

--- Clear macro-editor dropdown caches only (does not touch availability lookup).
function M.ClearDropdownCaches()
    cachedSpells = nil;
    cachedAbilities = nil;
    cachedWeaponskills = nil;
    cachedItems = nil;
    cacheJobId = nil;
    cacheSubJobId = nil;
end

--- Force clear all caches including availability lookup (legacy; prefer targeted invalidation).
function M.ClearCache()
    M.ClearDropdownCaches();
    M.InvalidateAvailabilityLookup();
    M.ClearSpellProfileCache();
    M.InvalidateInventoryCache();
end
local function ResetKnownActionTables()
    knownSpells = {};
    knownAbilities = {};
    knownWeaponskills = {};
    knownPetCommands = {};
end

--- Signature of main/sub job only; availability lookup rebuilds on this change.
function M.GetJobSignature()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player or player.isZoning then
        return nil;
    end
    local jobId = player:GetMainJob();
    if not jobId or jobId == 0 then
        return nil;
    end
    return string.format('%d:%d', jobId, player:GetSubJob());
end

--- Signature of main/sub levels; slot cache clears on this change (lazy re-validation).
function M.GetLevelSignature()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player or player.isZoning then
        return nil;
    end
    local mainLevel = player:GetMainJobLevel();
    if mainLevel == 0 then
        return nil;
    end
    return string.format('%d:%d', mainLevel, player:GetSubJobLevel());
end

--- Full player signature (job, subjob, levels).
function M.GetPlayerStateSignature()
    local jobSig = M.GetJobSignature();
    local levelSig = M.GetLevelSignature();
    if not jobSig or not levelSig then
        return nil;
    end
    return jobSig .. ':' .. levelSig;
end
local function ProbePlayerMemory(player)
    if not player or player.isZoning then
        return false;
    end
    local jobId = player:GetMainJob();
    if not jobId or jobId == 0 or player:GetMainJobLevel() == 0 then
        return false;
    end
    local subJobId = player:GetSubJob() or 0;
    for abilityId = 1, MEMORY_PROBE_ABILITY_MAX do
        if player:HasAbility(abilityId) then
            return true;
        end
    end
    if M.JobCanCastSpells(jobId) or (subJobId > 0 and M.JobCanCastSpells(subJobId)) then
        for spellId = 1, MEMORY_PROBE_SPELL_MAX do
            if player:HasSpell(spellId) then
                return true;
            end
        end
    end
    return false;
end

--- Reset memory readiness (call on zone transition or job change).
function M.ResetMemoryReady()
    memoryReady = false;
    memoryStableFrames = 0;
end

--- Whether live HasSpell/HasAbility checks are trustworthy.
function M.IsPlayerMemoryReady()
    return memoryReady;
end

--- Advance memory readiness probe; call once per frame while not ready.
function M.TickMemoryReadyProbe()
    if memoryReady then
        return true;
    end
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if ProbePlayerMemory(player) then
        memoryStableFrames = memoryStableFrames + 1;
        if memoryStableFrames >= MEMORY_STABLE_FRAMES_REQUIRED then
            memoryReady = true;
            return true;
        end
    else
        memoryStableFrames = 0;
    end
    return false;
end

-- Clear packet-synced spell/ability ownership (zone out / logout).
function M.ResetPacketOwnership()
    ownedSpellsFromPacket = nil;
    ownedAbilitiesFromPacket = nil;
end

-- Seed ownership from live memory until the first list packet arrives.
function M.SeedPacketOwnershipFromMemory()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player or player.isZoning then
        return;
    end

    -- Never overwrite an existing 0x0AA / 0x0AC snapshot (zone-in seed used to clobber it).
    if not ownedSpellsFromPacket then
        ownedSpellsFromPacket = {};
        for spellId = 1, PACKET_SPELL_MAX do
            ownedSpellsFromPacket[spellId] = player:HasSpell(spellId);
        end
    end
    if not ownedAbilitiesFromPacket then
        ownedAbilitiesFromPacket = {};
        for abilityId = 1, PACKET_ABILITY_MAX do
            ownedAbilitiesFromPacket[abilityId] = player:HasAbility(abilityId);
        end
    end
end

-- Spell ownership from server spell-list packet (0x0AA).
function M.HandleSpellListPacket(e)
    if not e or not e.data_raw then
        return;
    end
    if not ownedSpellsFromPacket then
        ownedSpellsFromPacket = {};
    end
    for spellId = 1, PACKET_SPELL_MAX do
        ownedSpellsFromPacket[spellId] = (ashita.bits.unpack_be(e.data_raw, 4, spellId, 1) == 1);
    end
    spellListVersion = spellListVersion + 1;
end

-- Ability ownership from server ability-list packet (0x0AC).
function M.HandleAbilityListPacket(e)
    if not e or not e.data_raw then
        return;
    end
    if not ownedAbilitiesFromPacket then
        ownedAbilitiesFromPacket = {};
    end
    for abilityId = 1, PACKET_ABILITY_MAX do
        ownedAbilitiesFromPacket[abilityId] = (ashita.bits.unpack_be(e.data_raw, 4, abilityId, 1) == 1);
    end
    abilityListVersion = abilityListVersion + 1;
end

-- Whether the player owns a spell (packet bitmap when synced, else live HasSpell).
function M.PlayerOwnsSpell(spellId)
    if not spellId or spellId <= 0 then
        return false;
    end
    if ownedSpellsFromPacket then
        return ownedSpellsFromPacket[spellId] == true;
    end
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    return player and player:HasSpell(spellId) or false;
end

-- True when 0x0AA marks this spell owned (authoritative for hotbar dimming).
function M.IsSpellOwnedFromPacket(spellId)
    return ownedSpellsFromPacket ~= nil and ownedSpellsFromPacket[spellId] == true;
end

-- Whether the player owns an ability (0x0AC bitmap when synced, else live HasAbility).
function M.PlayerOwnsAbility(abilityId)
    if not abilityId or abilityId <= 0 then
        return false;
    end
    if ownedAbilitiesFromPacket then
        return ownedAbilitiesFromPacket[abilityId] == true;
    end
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    return player and player:HasAbility(abilityId) or false;
end

-- Bumped on each 0x0AA spell-list packet.
function M.GetSpellListVersion()
    return spellListVersion;
end

-- Bumped on each 0x0AC ability-list packet.
function M.GetAbilityListVersion()
    return abilityListVersion;
end

--- Mark availability lookup stale and begin an incremental rebuild.
function M.InvalidateAvailabilityLookup()
    availabilityReady = false;
    availabilitySignature = nil;
    ResetKnownActionTables();
    availabilityBuild = { phase = 'spells', index = 1 };
end

--- Whether the incremental availability lookup has finished for the current player state.
function M.IsAvailabilityLookupReady()
    return availabilityReady;
end

--- Whether inventory-based availability checks can run (items/equip use live scans).
function M.CanCheckInventoryAvailability()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player or player.isZoning then
        return false;
    end
    local jobId = player:GetMainJob();
    return jobId ~= nil and jobId ~= 0 and player:GetMainJobLevel() ~= 0;
end

--- Whether availability checks for an action type can run yet.
function M.IsActionDataReadyForType(actionType)
    if actionType == 'item' or actionType == 'equip' then
        return M.CanCheckInventoryAvailability();
    end
    return M.IsPlayerMemoryReady();
end

--- Advance the incremental availability lookup by processing up to batchSize IDs.
function M.TickAvailabilityLookup(batchSize)
    batchSize = batchSize or AVAILABILITY_BUILD_BATCH;
    if availabilityReady then
        local jobSig = M.GetJobSignature();
        if jobSig and availabilitySignature and jobSig ~= availabilitySignature then
            M.InvalidateAvailabilityLookup();
            return false;
        end
        return true;
    end
    if not availabilityBuild then
        M.InvalidateAvailabilityLookup();
    end
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player or player.isZoning or not M.IsPlayerMemoryReady() then
        return false;
    end
    local jobSig = M.GetJobSignature();
    if not jobSig then
        return false;
    end
    if availabilitySignature and jobSig ~= availabilitySignature then
        M.InvalidateAvailabilityLookup();
        return false;
    end
    local resMgr = AshitaCore:GetResourceManager();
    if not resMgr then
        return false;
    end
    local budget = batchSize;
    while budget > 0 and availabilityBuild do
        local phase = availabilityBuild.phase;
        local index = availabilityBuild.index;
        if phase == 'spells' then
            local endIndex = math.min(index + budget - 1, AVAILABILITY_SPELL_MAX);
            for spellId = index, endIndex do
                if M.PlayerOwnsSpell(spellId) then
                    local spell = resMgr:GetSpellById(spellId);
                    if spell and spell.Name and spell.Name[1] and spell.Name[1] ~= '' then
                        local spellName = spell.Name[1];
                        if not IsGarbageSpellName(spellName) then
                            knownSpells[spellName] = true;
                        end
                    end
                end
            end
            budget = budget - (endIndex - index + 1);
            availabilityBuild.index = endIndex + 1;
            if availabilityBuild.index > AVAILABILITY_SPELL_MAX then
                availabilityBuild.phase = 'abilities';
                availabilityBuild.index = 1;
            end
        elseif phase == 'abilities' then
            local endIndex = math.min(index + budget - 1, AVAILABILITY_ABILITY_MAX);
            for abilityId = index, endIndex do
                if M.PlayerOwnsAbility(abilityId) then
                    local ability = resMgr:GetAbilityById(abilityId);
                    if ability and ability.Name and ability.Name[1] and ability.Name[1] ~= '' then
                        local abilityName = ability.Name[1];
                        local abilityType = ability.Type or 0;
                        if abilityType == ABILITY_TYPE.WeaponSkill then
                            knownWeaponskills[abilityName] = true;
                        elseif IsScannedPetCommandAbility(ability, abilityName) then
                            knownPetCommands[abilityName] = true;
                            knownAbilities[abilityName] = true;
                        elseif abilityType ~= ABILITY_TYPE.Trait
                            and not IsCategoryPlaceholderName(abilityName) then
                            knownAbilities[abilityName] = true;
                        end
                    end
                end
            end
            budget = budget - (endIndex - index + 1);
            availabilityBuild.index = endIndex + 1;
            if availabilityBuild.index > AVAILABILITY_ABILITY_MAX then
                availabilityBuild = nil;
                availabilityReady = true;
                availabilitySignature = M.GetJobSignature();
            end
        else
            availabilityBuild = nil;
            availabilityReady = true;
            availabilitySignature = M.GetJobSignature();
            break;
        end
    end
    return availabilityReady;
end
function M.HasKnownSpell(spellName)
    if not spellName or spellName == '' then
        return false;
    end
    return knownSpells[spellName] == true;
end
function M.HasKnownAbility(abilityName)
    if not abilityName or abilityName == '' then
        return false;
    end
    return knownAbilities[abilityName] == true;
end
function M.HasKnownWeaponskill(wsName)
    if not wsName or wsName == '' then
        return false;
    end
    return knownWeaponskills[wsName] == true;
end
function M.HasKnownPetCommand(commandName)
    if not commandName or commandName == '' then
        return false;
    end
    return knownPetCommands[commandName] == true or knownAbilities[commandName] == true;
end

--- Force rebuild spell cache (call when macro editor dropdown opens)
function M.ForceRefreshSpells(showAll)
    cachedSpells = M.GetEditorSpells(showAll == true);
end

--- Force rebuild ability cache (call when macro editor dropdown opens)
function M.ForceRefreshAbilities(showAll)
    actiondb.InvalidateAbilityMeta();
    cachedAbilities = M.GetEditorAbilities(showAll == true);
end

--- Force rebuild weaponskill cache (call when macro editor dropdown opens)
function M.ForceRefreshWeaponskills(showAll)
    actiondb.InvalidateAbilityMeta();
    cachedWeaponskills = M.GetEditorWeaponskills(showAll == true);
end

--- Force rebuild item cache (call when macro editor dropdown opens)
function M.ForceRefreshItems()
    cachedItems = M.GetPlayerItems();
end

--- Get current cache job ID
function M.GetCacheJobId()
    return cacheJobId;
end

--- Get current cache subjob ID
function M.GetCacheSubJobId()
    return cacheSubJobId;
end

--- Jobs that can cast magic (main or sub); used for spell-load readiness only.
function M.JobCanCastSpells(jobId)
    return jobId == 3   -- WHM
        or jobId == 4   -- BLM
        or jobId == 5   -- RDM
        or jobId == 13  -- NIN
        or jobId == 15  -- SMN
        or jobId == 16  -- BLU
        or jobId == 20  -- SCH
        or jobId == 21; -- GEO
end

--- Check if an ability name is in the cached abilities list
--- This ensures availability check uses same data as dropdown
function M.IsAbilityInCache(abilityName)
    if not cachedAbilities then return true; end  -- No cache = assume available
    for _, ability in ipairs(cachedAbilities) do
        if ability.name == abilityName then
            return true;
        end
    end
    return false;
end

--- Check if a spell name is in the cached spells list (fallback when ID lookup fails)
function M.IsSpellInCache(spellName)
    if not cachedSpells then return true; end
    for _, spell in ipairs(cachedSpells) do
        if spell.name == spellName then
            return true;
        end
    end
    return false;
end

--- Check if a weaponskill name is in the cached weaponskills list
function M.IsWeaponskillInCache(wsName)
    if not cachedWeaponskills then return true; end
    for _, ws in ipairs(cachedWeaponskills) do
        if ws.name == wsName then
            return true;
        end
    end
    return false;
end

-- Equipment slot bitmasks for equip availability checks
local EQUIP_SLOT_MASKS = {
    main = 0x0001,
    sub = 0x0002,
    range = 0x0004,
    ammo = 0x0008,
    head = 0x0010,
    body = 0x0020,
    hands = 0x0040,
    legs = 0x0080,
    feet = 0x0100,
    neck = 0x0200,
    waist = 0x0400,
    ear1 = 0x0800,
    ear2 = 0x1000,
    ring1 = 0x2000,
    ring2 = 0x4000,
    back = 0x8000,
};
local function GetEquippedSlotItemId(slotIndex)
    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    if not inventory then
        return 0;
    end
    local equipped = inventory:GetEquippedItem(slotIndex);
    if not equipped or not equipped.Index then
        return 0;
    end
    local index = bit.band(equipped.Index, 0x00FF);
    if index <= 0 then
        return 0;
    end
    local container = bit.rshift(bit.band(equipped.Index, 0xFF00), 8);
    local item = inventory:GetContainerItem(container, index);
    if item and item.Id and item.Id > 0 and item.Id ~= 65535 then
        return item.Id;
    end
    return 0;
end

--- Whether a ranged weapon (bow/gun/crossbow/etc.) is equipped in the range slot.
function M.HasEquippedRangeWeapon()
    local itemId = GetEquippedSlotItemId(2);
    if itemId <= 0 then
        return false;
    end
    local resMgr = AshitaCore:GetResourceManager();
    local item = resMgr and resMgr:GetItemById(itemId);
    if not item or not item.Slots then
        return true;
    end
    return bit.band(item.Slots, EQUIP_SLOT_MASKS.range) ~= 0;
end

--- Whether ammo/throwables are equipped in the ammo slot.
function M.HasEquippedAmmo()
    local itemId = GetEquippedSlotItemId(3);
    if itemId <= 0 then
        return false;
    end
    local resMgr = AshitaCore:GetResourceManager();
    local item = resMgr and resMgr:GetItemById(itemId);
    if not item or not item.Slots then
        return true;
    end
    return bit.band(item.Slots, EQUIP_SLOT_MASKS.ammo) ~= 0;
end

--- Build a signature of currently equipped combat slots (main/sub/range/ammo)
--- Used to invalidate availability cache when weapons change
function M.GetEquipmentSignature()
    local parts = {};
    for slot = 0, 3 do
        parts[#parts + 1] = tostring(GetEquippedSlotItemId(slot));
    end
    return table.concat(parts, ':');
end
local ANIMATOR_ITEM_NAME_PATTERN = 'Animator|Manipulator|Alternator|Magneto|Divinator';

--- Whether the player currently has a pet entity (avatar, wyvern, automaton, jug, etc.).
function M.IsPlayerPetActive()
    local playerEntity = GetPlayerEntity();
    if not playerEntity or playerEntity.PetTargetIndex == 0 then
        return false;
    end
    local pet = GetEntity(playerEntity.PetTargetIndex);
    return pet ~= nil and pet.Name ~= nil and pet.Name ~= '';
end

--- Whether an animator-class item is equipped in the ranged slot (required for maneuvers).
function M.HasAnimatorEquipped()
    local itemId = GetEquippedSlotItemId(2);
    if itemId <= 0 then
        return false;
    end
    local resMgr = AshitaCore:GetResourceManager();
    local item = resMgr and resMgr:GetItemById(itemId);
    if not item then
        return false;
    end
    local name = (item.Name and item.Name[1]) or (item.LogName and item.LogName[1]) or '';
    if name == '' then
        return false;
    end
    return name:find(ANIMATOR_ITEM_NAME_PATTERN) ~= nil;
end

--- Signature of live pet/automaton state for availability cache keys.
function M.GetPetAvailabilitySignature(mainJobId)
    local petregistry = require('modules.hotbar.petregistry');
    local context = petregistry.GetActivePetContext(mainJobId);
    local parts = { context.active and '1' or '0' };
    if context.active and context.petName then
        parts[#parts + 1] = context.petName;
        if context.petType then
            parts[#parts + 1] = context.petType;
        end
    end
    if mainJobId == 18 then
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        parts[#parts + 1] = petregistry.IsPupAutomatonActive(player) and '1' or '0';
        parts[#parts + 1] = M.HasAnimatorEquipped() and '1' or '0';
    end
    return table.concat(parts, ':');
end

--- Check if the player owns an item anywhere in tracked storage containers
function M.IsItemOwned(itemId, itemName)
    RefreshInventoryCache();
    if itemId and inventoryAllById[itemId] and inventoryAllById[itemId] > 0 then
        return true;
    end
    if itemName and itemName ~= '' then
        local resolvedId = actiondb.GetItemId(itemName);
        if resolvedId then
            return M.IsItemOwned(resolvedId, nil);
        end
    end
    return false;
end

--- Count an item in accessible inventory (inventory + wardrobes)
function M.CountAccessibleItem(itemId, itemName)
    RefreshInventoryCache();
    if itemId and inventoryAccessibleById[itemId] then
        return inventoryAccessibleById[itemId];
    end
    if itemName and itemName ~= '' then
        local resolvedId = actiondb.GetItemId(itemName);
        if resolvedId then
            return M.CountAccessibleItem(resolvedId, nil);
        end
    end
    return 0;
end

--- Check if an item is in accessible inventory (inventory + wardrobes, not mog safe/storage/satchel)
function M.IsItemInAccessibleInventory(itemId, itemName)
    return M.CountAccessibleItem(itemId, itemName) > 0;
end

--- Check if an equip macro/action can currently be used
function M.IsEquipActionAvailable(equipSlot, itemName, itemId)
    if not itemName or itemName == '' then
        return false;
    end
    if not itemId then
        itemId = actiondb.GetItemId(itemName);
    end
    if not M.IsItemOwned(itemId, itemName) then
        return false;
    end
    if equipSlot and itemId then
        local resMgr = AshitaCore:GetResourceManager();
        local item = resMgr and resMgr:GetItemById(itemId);
        local slotMask = EQUIP_SLOT_MASKS[equipSlot];
        if item and slotMask and item.Slots and bit.band(item.Slots, slotMask) == 0 then
            return false;
        end
    end
    return true;
end

--- Check if a pet command is available for the current job/pet context
function M.IsPetCommandAvailable(commandName)
    if not commandName or commandName == '' then
        return false;
    end
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then return true; end
    local jobId = player:GetMainJob();
    local petregistry = require('modules.hotbar.petregistry');
    if not petregistry.IsPetJob(jobId) then
        return false;
    end
    return M.HasKnownPetCommand(commandName);
end

--- Spell is usable on current main/sub jobs (HasSpell/HasAbility is checked elsewhere).
function M.IsSpellUsableForCurrentJobs(spell, player, mainJobId, subJobId)
    return IsSpellUsableForCurrentJobs(spell, player, mainJobId, subJobId);
end

--- Whether a spell passes tHotBar-style job level/JP gates for hotbar availability dimming.
function M.IsSpellJobUnlockedForHotbar(spell, player, mainJobId, subJobId)
    return IsSpellJobUnlockedForHotbar(spell, player, mainJobId, subJobId);
end

--- Buff signature for spell/ability availability cache invalidation.
--- SCH Light/Dark Arts toggles change which job abilities HasAbility reports (Parsimony,
--- Penury, Addendum, etc.), so arts buffs must be part of the cache key for ja slots.
function M.GetSpellAvailBuffSignature()
    local parts = {};
    if PlayerHasBuff(BUFF_LIGHT_ARTS) then parts[#parts + 1] = '358'; end
    if PlayerHasBuff(BUFF_DARK_ARTS) then parts[#parts + 1] = '359'; end
    if PlayerHasBuff(BUFF_ADDENDUM_ANY) then parts[#parts + 1] = '416'; end
    if PlayerHasBuff(401) then parts[#parts + 1] = '401'; end
    if PlayerHasBuff(402) then parts[#parts + 1] = '402'; end
    if PlayerHasBuff(BUFF_METEOR) then parts[#parts + 1] = '79'; end
    if PlayerHasBuff(BUFF_TABULA) then parts[#parts + 1] = '377'; end
    if PlayerHasAnyBuff(BUFF_UNBRIDLED) then parts[#parts + 1] = 'ub'; end
    return table.concat(parts, ',');
end

--- Buff signature for action cost cache invalidation.
function M.GetCostBuffSignature()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then return ''; end
    local buffs = player:GetBuffs();
    if not buffs then return ''; end
    local parts = {};
    for i = 1, 32 do
        local b = buffs[i];
        if b and b ~= 0 and b ~= 255 then parts[#parts + 1] = tostring(b); end
    end
    table.sort(parts);
    return table.concat(parts, ',');
end
function M.ClearSpellProfileCache()
    spellProfileCache = {};
end

--- Ability is usable on current main/sub jobs (HasAbility is checked elsewhere).
function M.IsAbilityUsableForCurrentJobs(ability, player, mainJobId, subJobId, levelArray)
    return IsAbilityUsableForCurrentJobs(ability, player, mainJobId, subJobId, levelArray);
end

-- Export helper for external use
M.IsGarbageSpellName = IsGarbageSpellName;
M.CONTAINERS = CONTAINERS;
M.ACCESSIBLE_CONTAINERS = ACCESSIBLE_CONTAINERS;
return M;
