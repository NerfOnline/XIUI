--[[
    Test Mode Module
    Provides dynamic simulated data for all XIUI modules to facilitate
    performance testing. Unlike preview mode (static, config-tied), test mode
    generates time-varying data that simulates a full alliance in combat.

    Usage:
        /xiui test          - Toggle all modules
        /xiui test "module" - Toggle a specific module

    Module keys: playerbar, targetbar, partylist, enemylist, castbar,
                 expbar, giltracker, petbar, notifications, treasurepool
]]

local testMode = {};

-- ============================================
-- State
-- ============================================
local active = false;
local activeModules = {};  -- Per-module overrides: nil = follow global, true/false = explicit

-- Frame clock cache: set once per frame via BeginFrame(), used by all functions
local frameClock = 0;

-- Pre-allocated reusable tables (avoid per-frame garbage collection)
local _playerBarResult = { hp = 0, hpPercent = 0, maxhp = 0, mp = 0, mpPercent = 0, maxmp = 0, tp = 0 };
local _castBarResult = { percent = 0, spellName = nil };
local _expBarResult = {
    mainJob = 0, jobLevel = 0, subJob = 0, subJobLevel = 0,
    expPoints = { 0, 0 }, limitPoints = { 0, 0 }, meritPoints = { 0, 0 },
    capPoints = { 0, 0 }, jobPoints = { 0, 0 }, masteryEnabled = false,
    meritMode = false, mastery = { 0, 0 }, progressBarProgress = 0,
};
local _expData = {
    expCurrent = 0, expNeeded = 0, mainJob = 0, mainJobLevel = 0,
    subJob = 0, subJobLevel = 0, limitPoints = 0, meritPoints = 0,
    meritPointsMax = 0, isLimitMode = false, isExpLocked = false,
};
local _memberResults = {};
for i = 0, 17 do
    _memberResults[i] = {
        hpp = 0, maxhp = 0, hp = 0, mpp = 0, maxmp = 0, mp = 0, tp = 0,
        job = 0, level = 0, subjob = 0, subjoblevel = 0, serverid = 0,
        buffs = {}, sync = false, zone = 0, inzone = false, name = '',
        leader = false, allianceLeader = false, targeted = false,
        isSubtargetStyle = false, previewDistance = 0, castData = nil,
    };
end
local _targetData = {
    Name = '', HPPercent = 0, Distance = 0, SpawnFlags = 0,
    ServerId = 0, TargetIndex = 0, debuffs = {},
};
local _petData = {
    name = '', hpPercent = 0, distance = 0, mpPercent = 0, tp = 0,
    job = 0, showMp = false, isCharmed = false, isJug = false,
    level = 0, jugTimeRemaining = nil, charmElapsed = nil, petType = '',
};
local _petTargetData = { Name = '', HPPercent = 0, Distance = 0 };
local _enemyData = {};
local _enemyDebuffs = {};
local _enemyTargets = {};
local _enemyEntries = {};
for i = 1, 8 do
    _enemyEntries[i] = { Name = '', HPPercent = 0, Distance = 0 };
end
local _pickAvailable = {};

-- Canonical module name mapping (lowercase input -> internal key)
local MODULE_ALIASES = {
    ['playerbar']    = 'playerbar',
    ['player bar']   = 'playerbar',
    ['player']       = 'playerbar',
    ['targetbar']    = 'targetbar',
    ['target bar']   = 'targetbar',
    ['target']       = 'targetbar',
    ['partylist']    = 'partylist',
    ['party list']   = 'partylist',
    ['party']        = 'partylist',
    ['enemylist']    = 'enemylist',
    ['enemy list']   = 'enemylist',
    ['enemy']        = 'enemylist',
    ['castbar']      = 'castbar',
    ['cast bar']     = 'castbar',
    ['cast']         = 'castbar',
    ['expbar']       = 'expbar',
    ['exp bar']      = 'expbar',
    ['exp']          = 'expbar',
    ['giltracker']   = 'giltracker',
    ['gil tracker']  = 'giltracker',
    ['gil']          = 'giltracker',
    ['petbar']       = 'petbar',
    ['pet bar']      = 'petbar',
    ['pet']          = 'petbar',
    ['notifications'] = 'notifications',
    ['notification']  = 'notifications',
    ['notif']         = 'notifications',
    ['treasurepool'] = 'treasurepool',
    ['treasure pool'] = 'treasurepool',
    ['treasure']      = 'treasurepool',
    ['pool']          = 'treasurepool',
    ['inventory']     = 'inventory',
    ['inv']           = 'inventory',
    ['hotbar']        = 'hotbar',
    ['crossbar']      = 'hotbar',
};

-- All valid module keys
local ALL_MODULES = {
    'playerbar', 'targetbar', 'partylist', 'enemylist', 'castbar',
    'expbar', 'giltracker', 'petbar', 'notifications', 'treasurepool',
    'inventory', 'hotbar',
};

-- ============================================
-- Public API
-- ============================================

-- Cache os.clock() once per frame. Call from d3d_present before rendering modules.
function testMode.BeginFrame()
    if active or next(activeModules) then
        frameClock = os.clock();
    end
end

-- Check if test mode is active for a specific module (or globally)
function testMode.IsActive(moduleName)
    if moduleName then
        local override = activeModules[moduleName];
        if override ~= nil then
            return override;
        end
    end
    return active;
end

-- Toggle global test mode on/off
function testMode.Toggle()
    active = not active;
    -- Clear per-module overrides when toggling global
    activeModules = {};
    return active;
end

-- Toggle a specific module's test mode
-- Returns: isActive, moduleName (resolved)
function testMode.ToggleModule(inputName)
    local key = MODULE_ALIASES[inputName:lower()];
    if not key then
        return nil, nil;
    end
    local current = testMode.IsActive(key);
    activeModules[key] = not current;
    return not current, key;
end

-- Get the resolved module name from user input
function testMode.ResolveModuleName(inputName)
    return MODULE_ALIASES[inputName:lower()];
end

-- Get status string for chat output
function testMode.GetStatusString()
    local parts = {};
    if active then
        table.insert(parts, 'Global: ON');
    else
        table.insert(parts, 'Global: OFF');
    end
    for _, key in ipairs(ALL_MODULES) do
        if activeModules[key] ~= nil then
            table.insert(parts, key .. ': ' .. (activeModules[key] and 'ON' or 'OFF'));
        end
    end
    return table.concat(parts, ', ');
end

-- ============================================
-- Simulated Alliance Data (18 members)
-- ============================================

local ALLIANCE_NAMES = {
    -- Party 1
    'Aetherius', 'Brutalix', 'Celestine', 'Darkblade', 'Elyndra', 'Frostwind',
    -- Party 2
    'Galeheart', 'Havenmist', 'Ironclad', 'Jadestorm', 'Kaelyth', 'Lunaris',
    -- Party 3
    'Moonshadow', 'Nightfall', 'Obsidian', 'Pyralis', 'Quicksilver', 'Runeblade',
};

-- Job assignments for alliance members (varied to test MP/no-MP rendering)
-- Job IDs: 1=WAR, 2=MNK, 3=WHM, 4=BLM, 5=RDM, 6=THF, 7=PLD, 8=DRK, 9=BST,
--           10=BRD, 11=RNG, 12=SAM, 13=NIN, 14=DRG, 15=SMN, 16=BLU, 17=COR, 18=PUP, 19=DNC, 20=SCH, 21=GEO, 22=RUN
local ALLIANCE_JOBS = {
    3, 13, 4, 1, 5, 10,    -- WHM, NIN, BLM, WAR, RDM, BRD
    7, 8, 6, 11, 12, 14,   -- PLD, DRK, THF, RNG, SAM, DRG
    15, 16, 17, 9, 20, 22, -- SMN, BLU, COR, BST, SCH, RUN
};
local ALLIANCE_SUBJOBS = {
    5, 1, 5, 13, 3, 3,     -- /RDM, /WAR, /RDM, /NIN, /WHM, /WHM
    1, 13, 13, 1, 13, 1,   -- /WAR, /NIN, /NIN, /WAR, /NIN, /WAR
    3, 13, 1, 13, 5, 7,    -- /WHM, /NIN, /WAR, /NIN, /RDM, /PLD
};

-- Common buff IDs for simulation
local BUFF_POOL = {
    33,  -- Haste
    40,  -- Blink
    43,  -- Stoneskin
    94,  -- Reraise
    116, -- Phalanx
    180, -- Multi Strikes
    187, -- Enmity Boost
    604, -- Ionis
    42,  -- Shell
    41,  -- Protect
    34,  -- Enfire
    35,  -- Enblizzard
    36,  -- Enthunder
    37,  -- Enwater
    38,  -- Enstone
    39,  -- Enaero
    222, -- March
    223, -- Ballad
    214, -- Minuet
};

-- Debuff IDs for simulation
local DEBUFF_POOL = {
    2,   -- Sleep
    3,   -- Poison
    4,   -- Paralysis
    5,   -- Blindness
    6,   -- Silence
    10,  -- Stun
    11,  -- Bind
    12,  -- Weight
    13,  -- Slow
};

-- Spell names for simulated casts
local SPELL_NAMES = {
    {name = 'Cure IV', id = 3, type = 33, duration = 2.0},
    {name = 'Curaga III', id = 10, type = 33, duration = 3.5},
    {name = 'Haste', id = 57, type = 33, duration = 2.0},
    {name = 'Protect V', id = 47, type = 33, duration = 3.0},
    {name = 'Shell V', id = 52, type = 33, duration = 3.0},
    {name = 'Utsusemi: Ni', id = 339, type = 36, duration = 4.0},
    {name = 'Fire IV', id = 148, type = 33, duration = 5.0},
    {name = 'Thunder IV', id = 167, type = 33, duration = 6.0},
    {name = 'Stoneskin', id = 54, type = 33, duration = 4.0},
    {name = 'Refresh', id = 109, type = 33, duration = 3.0},
};

-- Enemy names
local ENEMY_NAMES = {
    'Goblin Smithy', 'Yagudo Templar', 'Orcish Warlord', 'Quadav Veteran',
    'Shadow Dragon', 'Gigas Tiger', 'Iron Giant', 'Fomor Ranger',
};

-- ============================================
-- Dynamic Data Generation
-- ============================================

-- Per-member state for chunk-based value changes
local memberState = {};
local enemyState = {};
local expState = {};
local gilState = {};
local inventoryState = {};

-- Initialize member state with varied phases so they don't all sync
local function ensureMemberState(idx)
    if memberState[idx] then return memberState[idx]; end
    -- Use golden ratio-based phase offsetting for natural variation
    local phase = (idx * 0.618033988749895) % 1.0;
    memberState[idx] = {
        -- Track individual buff timers
        buffChangeTime = 0,
        currentBuffs = {},
        -- HP chunk simulation (instant jumps, not smooth)
        lastHpEvent = 0,
        hpEventInterval = 1.0 + phase * 2.0,  -- 1-3 seconds between events
        hp = 0.7 + phase * 0.3,               -- Start at 70-100%
        -- MP chunk simulation
        lastMpEvent = 0,
        mpEventInterval = 1.5 + phase * 2.5,  -- 1.5-4 seconds between events
        mp = 0.6 + phase * 0.4,               -- Start at 60-100%
        -- TP chunk simulation (builds, then resets on WS)
        lastTpEvent = 0,
        tpEventInterval = 1.0 + phase * 1.5,  -- 1-2.5 seconds between TP gains
        tp = math.floor(phase * 1500),         -- Start at varied TP
        -- Cast simulation
        castStartTime = 0,
        castSpell = nil,
        castInterval = 5.0 + phase * 10.0,    -- 5-15 seconds between casts
    };
    return memberState[idx];
end

local function ensureEnemyState(idx)
    if enemyState[idx] then return enemyState[idx]; end
    local phase = (idx * 0.7071067811865476) % 1.0;  -- sqrt(2)/2
    enemyState[idx] = {
        hp = 100 - math.floor(phase * 30),
        lastChange = 0,
        changeInterval = 2.0 + phase * 4.0,
        debuffChangeTime = 0,
        currentDebuffs = {},
    };
    return enemyState[idx];
end

-- Seeded pseudo-random that's deterministic per member+time bucket
local function seededRandom(seed, min, max)
    -- Simple hash-based pseudo-random
    local hash = math.abs(math.sin(seed * 12.9898 + 78.233) * 43758.5453);
    hash = hash - math.floor(hash);
    if min and max then
        return math.floor(hash * (max - min + 1)) + min;
    end
    return hash;
end

-- Pick N random items from a pool based on a seed
local function pickFromPool(pool, count, seed)
    local result = {};  -- Must be new (stored in member state across frames)
    -- Reuse scratch array for available items
    for i = 1, #pool do _pickAvailable[i] = pool[i]; end
    for i = #pool + 1, #_pickAvailable do _pickAvailable[i] = nil; end
    for i = 1, math.min(count, #_pickAvailable) do
        local idx = seededRandom(seed + i * 7.13, 1, #_pickAvailable);
        table.insert(result, _pickAvailable[idx]);
        table.remove(_pickAvailable, idx);
    end
    return result;
end

-- ============================================
-- Party/Alliance Member Data
-- ============================================

-- Get simulated member data for party list and player bar
-- @param memIdx: 0-17 (alliance member index)
-- @param clock: os.clock() value for current frame
function testMode.GetMemberData(memIdx, clock)
    local state = ensureMemberState(memIdx);

    -- HP: chunk-based damage/heals at varied intervals (instant jumps)
    if clock - state.lastHpEvent > state.hpEventInterval then
        state.lastHpEvent = clock;
        state.hpEventInterval = 1.0 + seededRandom(clock * 100 + memIdx, 5, 25) / 10.0;
        local eventSeed = math.floor(clock) * 100 + memIdx;
        if seededRandom(eventSeed, 1, 100) > 40 then
            -- Damage chunk (5-25% HP lost instantly)
            local dmgPercent = seededRandom(eventSeed + 1, 5, 25) / 100.0;
            state.hp = math.max(0.05, state.hp - dmgPercent);
        else
            -- Heal chunk (15-40% HP restored instantly)
            local healPercent = seededRandom(eventSeed + 2, 15, 40) / 100.0;
            state.hp = math.min(1.0, state.hp + healPercent);
        end
    end

    -- MP: chunk-based usage/refresh at varied intervals (instant jumps)
    if clock - state.lastMpEvent > state.mpEventInterval then
        state.lastMpEvent = clock;
        state.mpEventInterval = 1.5 + seededRandom(clock * 73 + memIdx, 5, 30) / 10.0;
        local mpSeed = math.floor(clock) * 77 + memIdx;
        if seededRandom(mpSeed, 1, 100) > 50 then
            -- MP cost from casting (10-30% MP spent)
            local costPercent = seededRandom(mpSeed + 1, 10, 30) / 100.0;
            state.mp = math.max(0.01, state.mp - costPercent);
        else
            -- MP refresh/convert (20-50% MP recovered)
            local refreshPercent = seededRandom(mpSeed + 2, 20, 50) / 100.0;
            state.mp = math.min(1.0, state.mp + refreshPercent);
        end
    end

    -- TP: chunk-based gains from melee hits, resets on weapon skill
    if clock - state.lastTpEvent > state.tpEventInterval then
        state.lastTpEvent = clock;
        state.tpEventInterval = 1.0 + seededRandom(clock * 59 + memIdx, 5, 20) / 10.0;
        if state.tp >= 1000 and seededRandom(math.floor(clock) * 31 + memIdx, 1, 100) > 60 then
            -- Weapon skill: reset TP to 0-200 range
            state.tp = seededRandom(math.floor(clock) * 41 + memIdx, 0, 200);
        else
            -- Melee hit: gain 50-150 TP as a chunk
            local tpGain = seededRandom(math.floor(clock) * 37 + memIdx, 50, 150);
            state.tp = math.min(3000, state.tp + tpGain);
        end
    end

    -- Buff rotation: change buffs every 3-6 seconds (faster than before)
    if clock - state.buffChangeTime > (3.0 + (memIdx % 4) * 0.8) then
        state.buffChangeTime = clock;
        local numBuffs = seededRandom(math.floor(clock) + memIdx * 37, 2, 7);
        state.currentBuffs = pickFromPool(BUFF_POOL, numBuffs, math.floor(clock) * 10 + memIdx);
        -- Occasionally add a debuff
        if seededRandom(math.floor(clock) + memIdx * 53, 1, 100) > 70 then
            local debuff = DEBUFF_POOL[seededRandom(math.floor(clock) + memIdx * 71, 1, #DEBUFF_POOL)];
            table.insert(state.currentBuffs, debuff);
        end
    end

    -- Cast simulation
    local castData = nil;
    if state.castSpell and clock < state.castStartTime + state.castSpell.duration then
        castData = {
            spellName = state.castSpell.name,
            spellId = state.castSpell.id,
            spellType = state.castSpell.type,
            castTime = state.castSpell.duration,
            startTime = state.castStartTime,
            timestamp = os.time(),
            job = ALLIANCE_JOBS[memIdx + 1] or 1,
            subjob = ALLIANCE_SUBJOBS[memIdx + 1] or 1,
            jobLevel = 99,
            subjobLevel = 49,
        };
    elseif clock - (state.castStartTime + (state.castSpell and state.castSpell.duration or 0)) > state.castInterval then
        -- Start a new cast
        local spellIdx = seededRandom(math.floor(clock) * 13 + memIdx, 1, #SPELL_NAMES);
        state.castSpell = SPELL_NAMES[spellIdx];
        state.castStartTime = clock;
        state.castInterval = 5.0 + seededRandom(math.floor(clock) + memIdx * 19, 0, 100) / 10.0;
    end

    local job = ALLIANCE_JOBS[memIdx + 1] or 1;
    local subjob = ALLIANCE_SUBJOBS[memIdx + 1] or 1;
    local maxhp = 1200 + memIdx * 50;
    local maxmp = 800 + memIdx * 30;

    local memInfo = _memberResults[memIdx];
    memInfo.hpp = state.hp;
    memInfo.maxhp = maxhp;
    memInfo.hp = math.floor(maxhp * state.hp);
    memInfo.mpp = state.mp;
    memInfo.maxmp = maxmp;
    memInfo.mp = math.floor(maxmp * state.mp);
    memInfo.tp = state.tp;
    memInfo.job = job;
    memInfo.level = 99;
    memInfo.subjob = subjob;
    memInfo.subjoblevel = 49;
    memInfo.serverid = -(memIdx + 100);  -- Negative IDs to avoid collision with game data
    memInfo.buffs = state.currentBuffs;
    memInfo.sync = false;
    memInfo.zone = 100;
    memInfo.inzone = true;
    memInfo.name = ALLIANCE_NAMES[memIdx + 1] or ('TestMember' .. (memIdx + 1));
    memInfo.leader = (memIdx % 6 == 0);
    memInfo.allianceLeader = (memIdx == 0);
    memInfo.targeted = (memIdx == 4);
    memInfo.isSubtargetStyle = false;
    memInfo.previewDistance = 5.0 + memIdx * 2.5;
    memInfo.castData = castData;

    return memInfo;
end

-- ============================================
-- Enemy Data
-- ============================================

function testMode.GetEnemyData(clock)
    local numEnemies = 6;

    for i = 1, numEnemies do
        local id = 9000 + i;
        local state = ensureEnemyState(i);

        -- Chunk-based HP changes (instant jumps)
        if clock - state.lastChange > state.changeInterval then
            state.lastChange = clock;
            state.changeInterval = 2.0 + seededRandom(math.floor(clock) * 7 + i, 10, 40) / 10.0;
            local dmg = seededRandom(math.floor(clock) * 11 + i, 5, 20);
            state.hp = math.max(1, state.hp - dmg);
            -- Respawn when HP gets low
            if state.hp < 10 then
                state.hp = 100;
            end
        end

        -- Debuff rotation (every 4-8 seconds)
        if clock - state.debuffChangeTime > (4.0 + i * 1.0) then
            state.debuffChangeTime = clock;
            local numDebuffs = seededRandom(math.floor(clock) + i * 41, 0, 4);
            state.currentDebuffs = pickFromPool(DEBUFF_POOL, numDebuffs, math.floor(clock) * 10 + i);
        end

        local entry = _enemyEntries[i];
        entry.Name = ENEMY_NAMES[i] or ('Enemy ' .. i);
        entry.HPPercent = state.hp;
        entry.Distance = 36 + i * 30 + 20 * math.sin(clock * 0.3 + i);
        _enemyData[id] = entry;
        _enemyDebuffs[id] = state.currentDebuffs;
        -- Some enemies target party members
        if i <= 4 then
            _enemyTargets[id] = ALLIANCE_NAMES[seededRandom(math.floor(clock / 5) + i, 1, 6)];
        end
    end

    return _enemyData, _enemyDebuffs, _enemyTargets;
end

-- ============================================
-- Target Data (simulated target entity)
-- ============================================

function testMode.GetTargetData(clock)
    local state = ensureEnemyState(99);

    -- Chunk-based HP changes (instant jumps)
    if clock - state.lastChange > state.changeInterval then
        state.lastChange = clock;
        state.changeInterval = 1.5 + seededRandom(math.floor(clock) * 17, 10, 30) / 10.0;
        local eventSeed = math.floor(clock) * 23;
        if seededRandom(eventSeed, 1, 100) > 30 then
            -- Damage chunk (5-15% lost)
            local dmg = seededRandom(eventSeed + 1, 5, 15);
            state.hp = math.max(1, state.hp - dmg);
        else
            -- Heal/regen chunk (10-25% restored)
            local heal = seededRandom(eventSeed + 2, 10, 25);
            state.hp = math.min(100, state.hp + heal);
        end
        -- Respawn when HP gets very low
        if state.hp < 5 then
            state.hp = 100;
        end
    end

    -- Debuff rotation (every 5 seconds)
    if clock - state.debuffChangeTime > 5.0 then
        state.debuffChangeTime = clock;
        local numDebuffs = seededRandom(math.floor(clock) * 31, 1, 5);
        state.currentDebuffs = pickFromPool(DEBUFF_POOL, numDebuffs, math.floor(clock) * 7);
    end

    _targetData.Name = 'Shadow Dragon';
    _targetData.HPPercent = state.hp;
    _targetData.Distance = 25.0 + 10 * math.sin(clock * 0.5);
    _targetData.SpawnFlags = 0x0010;
    _targetData.ServerId = 99999;
    _targetData.TargetIndex = 9099;
    _targetData.debuffs = state.currentDebuffs;
    return _targetData;
end

-- ============================================
-- Player Bar Data
-- ============================================

function testMode.GetPlayerData(clock)
    return testMode.GetMemberData(0, clock);
end

-- ============================================
-- Cast Bar Data
-- ============================================

function testMode.GetCastPercent(clock)
    -- Simulate continuous casting with varied durations
    local castDuration = 4.0;
    local pauseDuration = 2.0;
    local totalCycle = castDuration + pauseDuration;
    local cyclePos = clock % totalCycle;

    if cyclePos < castDuration then
        return cyclePos / castDuration, 'Fire IV';
    end
    return 1.0, nil;  -- Not casting
end

-- ============================================
-- Exp Bar Data
-- ============================================

function testMode.GetExpData(clock)
    -- Initialize EXP state if needed
    if not expState.expCurrent then
        expState.expCurrent = 12000;
        expState.lastGain = clock;
        expState.limitPoints = 2500;
        expState.lastLimitGain = clock;
    end

    local expNeeded = 55000;

    -- Chunk EXP gain every ~5 seconds (varied 4-7s)
    if clock - expState.lastGain > (4.0 + seededRandom(math.floor(clock) * 3, 0, 30) / 10.0) then
        expState.lastGain = clock;
        -- Gain 800-4000 EXP in a chunk (like killing a mob)
        local gain = seededRandom(math.floor(clock) * 47, 800, 4000);
        expState.expCurrent = expState.expCurrent + gain;
        -- Level up: reset to partial
        if expState.expCurrent >= expNeeded then
            expState.expCurrent = expState.expCurrent - expNeeded;
        end
    end

    -- Limit points gain every ~8 seconds
    if clock - expState.lastLimitGain > (6.0 + seededRandom(math.floor(clock) * 5, 0, 40) / 10.0) then
        expState.lastLimitGain = clock;
        local lpGain = seededRandom(math.floor(clock) * 53, 200, 1500);
        expState.limitPoints = expState.limitPoints + lpGain;
        if expState.limitPoints >= 10000 then
            expState.limitPoints = expState.limitPoints - 10000;
        end
    end

    _expData.expCurrent = expState.expCurrent;
    _expData.expNeeded = expNeeded;
    _expData.mainJob = 3;
    _expData.mainJobLevel = 99;
    _expData.subJob = 5;
    _expData.subJobLevel = 49;
    _expData.limitPoints = expState.limitPoints;
    _expData.meritPoints = math.floor(expState.limitPoints / 1000);
    _expData.meritPointsMax = 30;
    _expData.isLimitMode = false;
    _expData.isExpLocked = false;
    return _expData;
end

-- ============================================
-- Gil Data
-- ============================================

function testMode.GetGilData(clock)
    -- Initialize gil state if needed
    if not gilState.gil then
        gilState.gil = 1500000;
        gilState.lastChange = clock;
    end

    -- Chunk-based gil changes every 8-15 seconds
    if clock - gilState.lastChange > (8.0 + seededRandom(math.floor(clock) * 61, 0, 70) / 10.0) then
        gilState.lastChange = clock;
        local seed = math.floor(clock) * 67;
        if seededRandom(seed, 1, 100) > 40 then
            -- Gain gil (selling items, quest rewards): 5,000 - 50,000
            local gain = seededRandom(seed + 1, 5, 50) * 1000;
            gilState.gil = gilState.gil + gain;
        else
            -- Lose gil (buying items, repairs): 2,000 - 30,000
            local cost = seededRandom(seed + 2, 2, 30) * 1000;
            gilState.gil = math.max(10000, gilState.gil - cost);
        end
    end

    return gilState.gil;
end

-- ============================================
-- Inventory Data (simulated slot counts)
-- ============================================

function testMode.GetInventoryData(containerId, clock)
    -- Use containerId as state key
    local key = containerId or 0;
    if not inventoryState[key] then
        local phase = (key * 0.618033988749895) % 1.0;
        inventoryState[key] = {
            usedSlots = 30 + math.floor(phase * 40),  -- Start 30-70 slots used
            maxSlots = 80,
            lastChange = clock,
            changeInterval = 4.0 + phase * 6.0,  -- 4-10s between changes
        };
    end

    local state = inventoryState[key];

    -- Chunk-based slot changes at notification-like intervals (~5s)
    if clock - state.lastChange > state.changeInterval then
        state.lastChange = clock;
        state.changeInterval = 4.0 + seededRandom(math.floor(clock) * 83 + key, 10, 60) / 10.0;
        local seed = math.floor(clock) * 89 + key;
        if seededRandom(seed, 1, 100) > 45 then
            -- Gain items (1-5 slots)
            local gain = seededRandom(seed + 1, 1, 5);
            state.usedSlots = math.min(state.maxSlots, state.usedSlots + gain);
        else
            -- Lose items (1-5 slots)
            local loss = seededRandom(seed + 2, 1, 5);
            state.usedSlots = math.max(1, state.usedSlots - loss);
        end
    end

    return state.usedSlots, state.maxSlots;
end

-- ============================================
-- Pet Bar Data (dynamic pet vitals)
-- ============================================

local petState = {};

function testMode.GetPetData(clock)
    if not petState.hp then
        petState.hp = 100;
        petState.mp = 0;
        petState.tp = 800;
        petState.lastHpEvent = clock;
        petState.lastTpEvent = clock;
        petState.hpInterval = 4.0;
        petState.tpInterval = 3.0;
    end

    -- HP: chunk-based jumps (pet takes damage, gets healed)
    if clock - petState.lastHpEvent > petState.hpInterval then
        petState.lastHpEvent = clock;
        petState.hpInterval = 3.0 + seededRandom(math.floor(clock) * 91, 10, 50) / 10.0;
        local seed = math.floor(clock) * 97;
        if seededRandom(seed, 1, 100) > 45 then
            -- Damage (5-20% HP lost)
            local dmg = seededRandom(seed + 1, 5, 20);
            petState.hp = math.max(5, petState.hp - dmg);
        else
            -- Heal (15-35% HP restored)
            local heal = seededRandom(seed + 2, 15, 35);
            petState.hp = math.min(100, petState.hp + heal);
        end
    end

    -- TP: chunk gains, reset on blood pact
    if clock - petState.lastTpEvent > petState.tpInterval then
        petState.lastTpEvent = clock;
        petState.tpInterval = 2.0 + seededRandom(math.floor(clock) * 79, 10, 30) / 10.0;
        if petState.tp >= 1000 and seededRandom(math.floor(clock) * 83, 1, 100) > 70 then
            petState.tp = seededRandom(math.floor(clock) * 87, 0, 150);
        else
            petState.tp = math.min(3000, petState.tp + seededRandom(math.floor(clock) * 89, 50, 200));
        end
    end

    _petData.name = 'Ifrit';
    _petData.hpPercent = petState.hp;
    _petData.distance = 5.0 + 3 * math.sin(clock * 0.3);
    _petData.mpPercent = 0;
    _petData.tp = petState.tp;
    _petData.job = 15;       -- SMN
    _petData.showMp = false;
    _petData.isCharmed = false;
    _petData.isJug = false;
    _petData.level = 75;
    _petData.jugTimeRemaining = nil;
    _petData.charmElapsed = nil;
    _petData.petType = 'avatar';
    return _petData;
end

-- Pet target data for test mode
function testMode.GetPetTargetData(clock)
    local state = ensureEnemyState(98);

    -- Chunk-based HP changes
    if clock - state.lastChange > state.changeInterval then
        state.lastChange = clock;
        state.changeInterval = 2.0 + seededRandom(math.floor(clock) * 43, 10, 30) / 10.0;
        local seed = math.floor(clock) * 47;
        if seededRandom(seed, 1, 100) > 35 then
            local dmg = seededRandom(seed + 1, 3, 12);
            state.hp = math.max(1, state.hp - dmg);
        else
            local heal = seededRandom(seed + 2, 5, 15);
            state.hp = math.min(100, state.hp + heal);
        end
        if state.hp < 5 then
            state.hp = 100;
        end
    end

    _petTargetData.Name = 'Goblin Mugger';
    _petTargetData.HPPercent = state.hp;
    _petTargetData.Distance = 6.3 + 2 * math.sin(clock * 0.4);
    return _petTargetData;
end

-- ============================================
-- Hotbar Test State (simulates dimming, cooldowns, presses)
-- ============================================

local hotbarState = {};

function testMode.GetHotbarState(clock)
    if not hotbarState.initialized then
        hotbarState.initialized = true;
        hotbarState.noMpSlots = {};       -- slots that appear as "not enough MP"
        hotbarState.cooldownSlots = {};   -- slots on cooldown {remaining, total}
        hotbarState.pressedSlot = nil;
        hotbarState.pressedHotbar = nil;
        hotbarState.lastMpChange = clock;
        hotbarState.lastCdChange = clock;
        hotbarState.lastPressChange = clock;
        hotbarState.crossbarModifier = nil;  -- L2, R2, L2+R2, etc.
        hotbarState.lastModifierChange = clock;
    end

    -- Rotate which slots appear as "not enough MP" every 4-8s
    if clock - hotbarState.lastMpChange > (4.0 + seededRandom(math.floor(clock) * 101, 0, 40) / 10.0) then
        hotbarState.lastMpChange = clock;
        hotbarState.noMpSlots = {};
        local numDimmed = seededRandom(math.floor(clock) * 103, 0, 3);
        for i = 1, numDimmed do
            local slot = seededRandom(math.floor(clock) * 107 + i, 1, 10);
            hotbarState.noMpSlots[slot] = true;
        end
    end

    -- Rotate cooldown slots every 6-12s
    if clock - hotbarState.lastCdChange > (6.0 + seededRandom(math.floor(clock) * 109, 0, 60) / 10.0) then
        hotbarState.lastCdChange = clock;
        hotbarState.cooldownSlots = {};
        local numCooldowns = seededRandom(math.floor(clock) * 113, 0, 2);
        for i = 1, numCooldowns do
            local slot = seededRandom(math.floor(clock) * 119 + i, 1, 10);
            local total = seededRandom(math.floor(clock) * 127 + i, 15, 120);
            local remaining = seededRandom(math.floor(clock) * 131 + i, 1, total);
            hotbarState.cooldownSlots[slot] = {remaining = remaining, total = total};
        end
    end

    -- Simulate slot presses every 1.5-3s
    if clock - hotbarState.lastPressChange > (1.5 + seededRandom(math.floor(clock) * 137, 0, 15) / 10.0) then
        hotbarState.lastPressChange = clock;
        if seededRandom(math.floor(clock) * 139, 1, 100) > 30 then
            hotbarState.pressedHotbar = seededRandom(math.floor(clock) * 149, 1, 4);
            hotbarState.pressedSlot = seededRandom(math.floor(clock) * 151, 1, 10);
        else
            hotbarState.pressedHotbar = nil;
            hotbarState.pressedSlot = nil;
        end
    end

    -- Crossbar modifier changes every 3-6s
    if clock - hotbarState.lastModifierChange > (3.0 + seededRandom(math.floor(clock) * 157, 0, 30) / 10.0) then
        hotbarState.lastModifierChange = clock;
        local modChoice = seededRandom(math.floor(clock) * 163, 1, 5);
        if modChoice == 1 then
            hotbarState.crossbarModifier = 'L2';
        elseif modChoice == 2 then
            hotbarState.crossbarModifier = 'R2';
        elseif modChoice == 3 then
            hotbarState.crossbarModifier = 'L2R2';
        elseif modChoice == 4 then
            hotbarState.crossbarModifier = 'R2L2';
        else
            hotbarState.crossbarModifier = nil;
        end
    end

    return hotbarState;
end

-- ============================================
-- Module-Specific Convenience Functions
-- Each returns nil when test mode is not active for that module,
-- or returns data in the exact format the module expects.
-- This minimizes code insertion in module files.
-- ============================================

-- PlayerBar: returns table with hp/mp/tp values pre-formatted, or nil
function testMode.PlayerBar()
    if not testMode.IsActive('playerbar') then return nil end
    local d = testMode.GetMemberData(0, frameClock);
    _playerBarResult.hp = d.hp;
    _playerBarResult.hpPercent = d.hpp * 100;
    _playerBarResult.maxhp = d.maxhp;
    _playerBarResult.mp = d.mp;
    _playerBarResult.mpPercent = d.mpp * 100;
    _playerBarResult.maxmp = d.maxmp;
    _playerBarResult.tp = d.tp;
    return _playerBarResult;
end

-- TargetBar: returns target entity-like table, or nil
function testMode.TargetBar()
    if not testMode.IsActive('targetbar') then return nil end
    return testMode.GetTargetData(frameClock);
end

-- CastBar: returns {percent, spellName}, or nil
function testMode.CastBar()
    if not testMode.IsActive('castbar') then return nil end
    local percent, spellName = testMode.GetCastPercent(frameClock);
    _castBarResult.percent = percent;
    _castBarResult.spellName = spellName;
    return _castBarResult;
end

-- ExpBar: returns table with all exp fields pre-formatted, or nil
function testMode.ExpBar()
    if not testMode.IsActive('expbar') then return nil end
    local d = testMode.GetExpData(frameClock);
    _expBarResult.mainJob = d.mainJob;
    _expBarResult.jobLevel = d.mainJobLevel;
    _expBarResult.subJob = d.subJob;
    _expBarResult.subJobLevel = d.subJobLevel;
    _expBarResult.expPoints[1] = d.expCurrent;
    _expBarResult.expPoints[2] = d.expNeeded;
    _expBarResult.limitPoints[1] = d.limitPoints;
    _expBarResult.limitPoints[2] = 10000;
    _expBarResult.meritPoints[1] = d.meritPoints;
    _expBarResult.meritPoints[2] = d.meritPointsMax;
    _expBarResult.capPoints[1] = 0;
    _expBarResult.capPoints[2] = 30000;
    _expBarResult.jobPoints[1] = 0;
    _expBarResult.jobPoints[2] = 500;
    _expBarResult.masteryEnabled = false;
    _expBarResult.meritMode = false;
    _expBarResult.mastery[1] = 0;
    _expBarResult.mastery[2] = 0;
    _expBarResult.progressBarProgress = d.expCurrent / d.expNeeded;
    return _expBarResult;
end

-- GilTracker: returns simulated gil amount, or nil
function testMode.GilTracker()
    if not testMode.IsActive('giltracker') then return nil end
    return testMode.GetGilData(frameClock);
end

-- EnemyList: returns enemies, debuffs, targets tables, or nil
function testMode.EnemyList()
    if not testMode.IsActive('enemylist') then return nil end
    return testMode.GetEnemyData(frameClock);
end

-- PartyMember: returns member info for a specific index, or nil
function testMode.PartyMember(memIdx)
    if not testMode.IsActive('partylist') then return nil end
    return testMode.GetMemberData(memIdx, frameClock);
end

-- PetBar: returns pet data table, or nil
function testMode.PetBar()
    if not testMode.IsActive('petbar') then return nil end
    return testMode.GetPetData(frameClock);
end

-- PetJob: returns JOB_SMN constant (15), or nil
function testMode.PetJob()
    if not testMode.IsActive('petbar') then return nil end
    return 15; -- JOB_SMN
end

-- PetTypeKey: returns 'avatar', or nil
function testMode.PetTypeKey()
    if not testMode.IsActive('petbar') then return nil end
    return 'avatar';
end

-- PetTarget: returns pet target entity-like table, or nil
function testMode.PetTarget()
    if not testMode.IsActive('petbar') then return nil end
    return testMode.GetPetTargetData(frameClock);
end

-- Inventory: returns used, max slot counts, or nil
function testMode.Inventory(containerId)
    if not testMode.IsActive('inventory') then return nil end
    return testMode.GetInventoryData(containerId, frameClock);
end

-- ============================================
-- Module Side-Effect Helpers
-- These manage lifecycle/generation that would otherwise
-- require significant code in module files.
-- ============================================

-- Notification generation state (moved from notifications/init.lua)
local notifState = { lastTime = 0, index = 0, types = nil };

-- Generate periodic test notifications. Call from notifications DrawWindow.
function testMode.NotificationTick(currentTime, dataModule)
    if not testMode.IsActive('notifications') then return end
    if not notifState.types then
        notifState.types = {
            { type = dataModule.NOTIFICATION_TYPE.ITEM_OBTAINED, data = { itemId = 4096, itemName = 'Hi-Potion', quantity = 2 } },
            { type = dataModule.NOTIFICATION_TYPE.GIL_OBTAINED, data = { amount = 1200 } },
            { type = dataModule.NOTIFICATION_TYPE.ITEM_OBTAINED, data = { itemId = 4112, itemName = 'Ether', quantity = 1 } },
            { type = dataModule.NOTIFICATION_TYPE.ITEM_OBTAINED, data = { itemId = 4128, itemName = 'X-Potion', quantity = 3 } },
        };
    end
    if currentTime - notifState.lastTime > 5 then
        notifState.index = (notifState.index % #notifState.types) + 1;
        local notif = notifState.types[notifState.index];
        dataModule.Add(notif.type, notif.data);
        notifState.lastTime = currentTime;
    end
end

-- Treasure pool lifecycle state (moved from treasurepool/init.lua)
local tpState = { wasActive = false };

-- Manage treasure pool test mode lifecycle. Call from treasurepool DrawWindow.
function testMode.TreasurePoolTick(dataModule)
    local isActive = testMode.IsActive('treasurepool');
    if isActive then
        if not tpState.wasActive then
            dataModule.SetPreview(true);
            tpState.wasActive = true;
        elseif not dataModule.IsPreviewActive() then
            dataModule.SetPreview(true);
        else
            dataModule.RefreshExpiredPreviewItems();
        end
    elseif tpState.wasActive then
        dataModule.ClearPreview();
        tpState.wasActive = false;
    end
end

-- Hotbar slot state overrides. Returns notEnoughMp, isOnCooldown, recastText, isPressed
-- or nil if test mode is not active.
function testMode.HotbarSlotState(bind, buttonId)
    if not testMode.IsActive('hotbar') or not bind then return end
    local state = testMode.GetHotbarState(frameClock);
    local slotNum = buttonId and tonumber(buttonId:match('_(%d+)$'));
    if not slotNum or not state then return end
    local cd = state.cooldownSlots[slotNum];
    return
        state.noMpSlots[slotNum] or false,
        cd ~= nil,
        cd and tostring(cd.remaining) or nil,
        (state.pressedHotbar and state.pressedSlot == slotNum) or false;
end

-- Crossbar modifier override. Returns modifier string, or nil.
function testMode.CrossbarModifier()
    if not testMode.IsActive('hotbar') then return nil end
    local state = testMode.GetHotbarState(frameClock);
    return state and state.crossbarModifier or nil;
end

-- ============================================
-- Cleanup
-- ============================================

function testMode.Reset()
    memberState = {};
    enemyState = {};
    expState = {};
    gilState = {};
    inventoryState = {};
    petState = {};
    hotbarState = {};
    notifState = { lastTime = 0, index = 0, types = nil };
    -- Note: tpState.wasActive is NOT reset here; TreasurePoolTick handles cleanup naturally
end

return testMode;
