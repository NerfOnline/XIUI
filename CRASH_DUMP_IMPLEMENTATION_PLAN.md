# XIUI Crash Dump System - Implementation Plan

## Problem Statement

The XIUI addon is causing intermittent game client freezes. Since Lua is single-threaded, when a freeze occurs no code can execute to capture state. We need a crash dump system that continuously logs state so we have diagnostic data from before any freeze.

## Requirements

1. **Periodic State Snapshots**: Write full addon state to file every 2-10 seconds (configurable)
2. **Manual Dump Command**: `/xiui dump` to write state on demand
3. **Config UI**: Toggle in settings menu + interval slider
4. **Ring Buffer**: Track last 100 events (packets, inputs) for timeline analysis
5. **Anomaly Detection**: Detect and log clock jumps (potential freeze indicators)

---

## Architecture Overview

```
                    +------------------+
                    |    XIUI.lua      |
                    | (d3d_present)    |
                    +--------+---------+
                             |
              +--------------+--------------+
              |                             |
    +---------v---------+         +---------v---------+
    |  crashdump.lua    |         |  Event Logging    |
    |  - PeriodicUpdate |         |  - packet_in      |
    |  - WriteDump      |         |  - key events     |
    |  - Ring Buffer    |         +-------------------+
    +---------+---------+
              |
    +---------v---------+
    |  State Collectors |
    |  - Timing         |
    |  - Player/Target  |
    |  - Resources      |
    |  - Caches         |
    |  - Modules        |
    +---------+---------+
              |
    +---------v---------+
    | crashdump.txt     |
    | (output file)     |
    +-------------------+
```

---

## Files to Create

### 1. `XIUI/libs/crashdump.lua` (NEW FILE)

Complete implementation:

```lua
--[[
* XIUI Crash Dump Module
* Provides periodic state snapshots and manual dump functionality
* for diagnosing game freezes
]]--

local M = {};

-- ============================================
-- Configuration
-- ============================================
M.enabled = false;
M.interval = 3.0;  -- seconds between dumps
M.lastDumpTime = 0;
M.frameCounter = 0;
M.lastClock = 0;
M.lastTime = 0;

-- ============================================
-- Ring Buffer for Recent Events
-- ============================================
M.eventBuffer = {};
M.eventBufferSize = 100;
M.eventBufferIndex = 1;

-- ============================================
-- Public API
-- ============================================

function M.Enable()
    M.enabled = true;
    M.lastDumpTime = os.clock();
    M.lastClock = os.clock();
    M.lastTime = os.time();
    print('[XIUI] Crash dump enabled');
end

function M.Disable()
    M.enabled = false;
    print('[XIUI] Crash dump disabled');
end

function M.SetInterval(seconds)
    M.interval = math.max(2, math.min(10, seconds));
end

function M.IncrementFrame()
    M.frameCounter = M.frameCounter + 1;
end

-- Log an event to the ring buffer
function M.LogEvent(eventType, data)
    M.eventBuffer[M.eventBufferIndex] = {
        timestamp = os.time(),
        clock = os.clock(),
        frame = M.frameCounter,
        eventType = eventType,
        data = data or {},
    };
    M.eventBufferIndex = (M.eventBufferIndex % M.eventBufferSize) + 1;
end

-- Called from d3d_present - handles throttling
function M.PeriodicUpdate(interval)
    if not M.enabled then return; end

    local currentClock = os.clock();

    -- Detect clock jumps (potential freeze indicator)
    local delta = currentClock - M.lastClock;
    if delta > 1.0 then
        M.WriteDump('anomaly_clock_jump');
    end

    -- Periodic dump
    if (currentClock - M.lastDumpTime) >= interval then
        M.WriteDump('periodic');
        M.lastDumpTime = currentClock;
    end

    M.lastClock = currentClock;
end

-- ============================================
-- State Collectors
-- ============================================

local function CollectTimingState()
    local currentClock = os.clock();
    return {
        osTime = os.time(),
        osClock = currentClock,
        lastClock = M.lastClock,
        clockDelta = currentClock - M.lastClock,
        clockJump = (currentClock - M.lastClock) > 1.0,
        frame = M.frameCounter,
    };
end

local function CollectPlayerState()
    local player = GetPlayerSafe and GetPlayerSafe();
    local party = GetPartySafe and GetPartySafe();

    if not player or not party then
        return { available = false };
    end

    local success, result = pcall(function()
        return {
            available = true,
            isZoning = player.isZoning or false,
            mainJob = player:GetMainJob(),
            subJob = player:GetSubJob(),
            mainJobLevel = player:GetMainJobLevel(),
            subJobLevel = player:GetSubJobLevel(),
            hp = player:GetHP(),
            hpMax = player:GetHPMax(),
            mp = player:GetMP(),
            mpMax = player:GetMPMax(),
            tp = player:GetTP(),
            zone = party:GetMemberZone(0),
        };
    end);

    return success and result or { available = false, error = tostring(result) };
end

local function CollectTargetState()
    local targets = GetTargets and GetTargets();

    if not targets or not targets.target then
        return { hasTarget = false };
    end

    local success, result = pcall(function()
        return {
            hasTarget = true,
            targetIndex = targets.target.Index or 0,
            targetServerId = targets.target.ServerId or 0,
            targetName = targets.target.Name or '',
            targetHPP = targets.target.HPPercent or 0,
            lockedOn = GetIsTargetLockedOn and GetIsTargetLockedOn() or false,
            subtargetActive = GetSubTargetActive and GetSubTargetActive() or false,
        };
    end);

    return success and result or { hasTarget = false, error = tostring(result) };
end

local function CollectResourceCounts()
    local diagnostics = require('libs.diagnostics');
    local stats = diagnostics.GetStats();
    return {
        primitiveCount = stats.primitiveCount or 0,
        peakPrimitiveCount = stats.peakPrimitiveCount or 0,
        primitiveCreated = stats.primitiveCreated or 0,
        primitiveDestroyed = stats.primitiveDestroyed or 0,
        textureCount = stats.textureCount or 0,
        fontCount = stats.fontCount or 0,
    };
end

local function CollectCacheSizes()
    local sizes = {};

    -- Status handler caches
    local statusHandler = require('handlers.statushandler');
    if statusHandler.getCacheSizes then
        local cacheSizes = statusHandler.getCacheSizes();
        sizes.iconCache = cacheSizes.iconCache or 0;
        sizes.jobIcons = cacheSizes.jobIcons or 0;
        sizes.partyBuffs = cacheSizes.partyBuffs or 0;
    end

    -- Debuff handler
    local debuffHandler = require('handlers.debuffhandler');
    if debuffHandler.getEnemyCount then
        sizes.debuffEnemies = debuffHandler.getEnemyCount();
    end

    -- Action tracker
    local actionTracker = require('handlers.actiontracker');
    if actionTracker.getTargetCount then
        sizes.actionTrackerTargets = actionTracker.getTargetCount();
    end

    -- Entity cache
    local packets = require('libs.packets');
    if packets.GetEntityCacheSize then
        sizes.entityCache = packets.GetEntityCacheSize();
    end

    return sizes;
end

local function CollectModuleStates()
    local states = {};
    local uiModules = require('core.moduleregistry');

    local success, result = pcall(function()
        local registry = uiModules.GetAll and uiModules.GetAll() or {};
        for name, entry in pairs(registry) do
            states[name] = {
                hasModule = entry.module ~= nil,
                hasInitialize = entry.module and entry.module.Initialize ~= nil,
                hasCleanup = entry.module and entry.module.Cleanup ~= nil,
            };
        end
        return states;
    end);

    return success and result or {};
end

local function CollectSettingsSnapshot()
    if not gConfig then return {}; end

    return {
        lockPositions = gConfig.lockPositions,
        showPlayerBar = gConfig.showPlayerBar,
        showTargetBar = gConfig.showTargetBar,
        showPartyList = gConfig.showPartyList,
        showEnemyList = gConfig.showEnemyList,
        showCastBar = gConfig.showCastBar,
        showPetBar = gConfig.showPetBar,
        showHotbar = gConfig.hotbarEnabled,
        fontFamily = gConfig.fontFamily,
        fontWeight = gConfig.fontWeight,
        hideDuringEvents = gConfig.hideDuringEvents,
        enableCrashDump = gConfig.enableCrashDump,
        crashDumpInterval = gConfig.crashDumpInterval,
    };
end

local function GetRecentEvents()
    local events = {};
    local startIdx = M.eventBufferIndex;

    for i = 0, M.eventBufferSize - 1 do
        local idx = ((startIdx - 1 + i) % M.eventBufferSize) + 1;
        if M.eventBuffer[idx] then
            table.insert(events, M.eventBuffer[idx]);
        end
    end

    return events;
end

-- ============================================
-- File Writing
-- ============================================

local function GetDumpFilePath()
    local installPath = AshitaCore:GetInstallPath();
    -- Remove trailing backslash if present
    installPath = installPath:gsub('\\$', ''):gsub('/$', '');
    return installPath .. '/config/addons/xiui/crashdump.txt';
end

local function FormatNumber(n)
    if n == nil then return 'nil'; end
    return tostring(n);
end

local function FormatBool(b)
    if b == nil then return 'nil'; end
    return b and 'true' or 'false';
end

function M.WriteDump(reason)
    local success, err = pcall(function()
        local path = GetDumpFilePath();
        local file = io.open(path, 'w');

        if not file then
            print('[XIUI] Failed to open crash dump file: ' .. path);
            return;
        end

        -- Header
        file:write('=== XIUI CRASH DUMP ===\n');
        file:write(string.format('Timestamp: %s\n', os.date('%Y-%m-%d %H:%M:%S')));
        file:write(string.format('Reason: %s\n', reason or 'unknown'));
        file:write(string.format('Addon: XIUI\n'));
        file:write('\n');

        -- Timing
        local timing = CollectTimingState();
        file:write('=== TIMING ===\n');
        file:write(string.format('os.time: %s\n', FormatNumber(timing.osTime)));
        file:write(string.format('os.clock: %.6f\n', timing.osClock or 0));
        file:write(string.format('Last clock: %.6f\n', timing.lastClock or 0));
        file:write(string.format('Clock delta: %.6f\n', timing.clockDelta or 0));
        file:write(string.format('Clock jump detected: %s\n', FormatBool(timing.clockJump)));
        file:write(string.format('Frame: %s\n', FormatNumber(timing.frame)));
        file:write('\n');

        -- Player State
        local player = CollectPlayerState();
        file:write('=== PLAYER STATE ===\n');
        if player.available then
            file:write(string.format('Logged in: true\n'));
            file:write(string.format('Zoning: %s\n', FormatBool(player.isZoning)));
            file:write(string.format('Main Job: %s\n', FormatNumber(player.mainJob)));
            file:write(string.format('Sub Job: %s\n', FormatNumber(player.subJob)));
            file:write(string.format('Main Job Level: %s\n', FormatNumber(player.mainJobLevel)));
            file:write(string.format('Sub Job Level: %s\n', FormatNumber(player.subJobLevel)));
            file:write(string.format('HP: %s/%s\n', FormatNumber(player.hp), FormatNumber(player.hpMax)));
            file:write(string.format('MP: %s/%s\n', FormatNumber(player.mp), FormatNumber(player.mpMax)));
            file:write(string.format('TP: %s\n', FormatNumber(player.tp)));
            file:write(string.format('Zone: %s\n', FormatNumber(player.zone)));
        else
            file:write('Available: false\n');
            if player.error then
                file:write(string.format('Error: %s\n', player.error));
            end
        end
        file:write('\n');

        -- Target State
        local target = CollectTargetState();
        file:write('=== TARGET STATE ===\n');
        if target.hasTarget then
            file:write(string.format('Has Target: true\n'));
            file:write(string.format('Target Index: %s\n', FormatNumber(target.targetIndex)));
            file:write(string.format('Target Server ID: 0x%08X\n', target.targetServerId or 0));
            file:write(string.format('Target Name: %s\n', target.targetName or ''));
            file:write(string.format('Target HPP: %s%%\n', FormatNumber(target.targetHPP)));
            file:write(string.format('Locked On: %s\n', FormatBool(target.lockedOn)));
            file:write(string.format('Subtarget Active: %s\n', FormatBool(target.subtargetActive)));
        else
            file:write('Has Target: false\n');
        end
        file:write('\n');

        -- Resource Counts
        local resources = CollectResourceCounts();
        file:write('=== RESOURCE COUNTS ===\n');
        file:write(string.format('Primitives: %s (peak: %s)\n',
            FormatNumber(resources.primitiveCount),
            FormatNumber(resources.peakPrimitiveCount)));
        file:write(string.format('Primitives Created: %s\n', FormatNumber(resources.primitiveCreated)));
        file:write(string.format('Primitives Destroyed: %s\n', FormatNumber(resources.primitiveDestroyed)));
        file:write(string.format('Textures: %s\n', FormatNumber(resources.textureCount)));
        file:write(string.format('Fonts: %s\n', FormatNumber(resources.fontCount)));
        file:write('\n');

        -- Cache Sizes
        local caches = CollectCacheSizes();
        file:write('=== CACHE SIZES ===\n');
        file:write(string.format('Icon Cache: %s\n', FormatNumber(caches.iconCache)));
        file:write(string.format('Job Icons: %s\n', FormatNumber(caches.jobIcons)));
        file:write(string.format('Party Buffs: %s\n', FormatNumber(caches.partyBuffs)));
        file:write(string.format('Debuff Enemies: %s\n', FormatNumber(caches.debuffEnemies)));
        file:write(string.format('Action Tracker Targets: %s\n', FormatNumber(caches.actionTrackerTargets)));
        file:write(string.format('Entity Cache: %s\n', FormatNumber(caches.entityCache)));
        file:write('\n');

        -- Module States
        local modules = CollectModuleStates();
        file:write('=== MODULE STATES ===\n');
        for name, state in pairs(modules) do
            local status = state.hasModule and 'loaded' or 'not loaded';
            if state.hasModule and state.hasInitialize then
                status = 'initialized';
            end
            file:write(string.format('%s: %s\n', name, status));
        end
        file:write('\n');

        -- Settings Snapshot
        local settings = CollectSettingsSnapshot();
        file:write('=== SETTINGS SNAPSHOT ===\n');
        for key, value in pairs(settings) do
            if type(value) == 'boolean' then
                file:write(string.format('%s: %s\n', key, FormatBool(value)));
            elseif type(value) == 'number' then
                file:write(string.format('%s: %s\n', key, FormatNumber(value)));
            else
                file:write(string.format('%s: %s\n', key, tostring(value)));
            end
        end
        file:write('\n');

        -- Recent Events
        local events = GetRecentEvents();
        file:write(string.format('=== RECENT EVENTS (last %d) ===\n', #events));
        for _, event in ipairs(events) do
            local dataStr = '';
            if event.data then
                for k, v in pairs(event.data) do
                    if k == 'id' then
                        dataStr = dataStr .. string.format(' %s=0x%04X', k, v);
                    else
                        dataStr = dataStr .. string.format(' %s=%s', k, tostring(v));
                    end
                end
            end
            file:write(string.format('[%.3f] frame=%d %s%s\n',
                event.clock or 0,
                event.frame or 0,
                event.eventType or 'unknown',
                dataStr));
        end
        file:write('\n');

        file:write('=== END DUMP ===\n');
        file:close();
    end);

    if not success then
        print('[XIUI] Error writing crash dump: ' .. tostring(err));
    end
end

return M;
```

---

## Files to Modify

### 2. `XIUI/core/settings/user.lua`

**Location:** Inside `createUserSettingsDefaults()` function, add near the top with other boolean settings:

```lua
-- Crash Dump settings (add after line ~30, near other boolean toggles)
enableCrashDump = false,         -- Enable periodic state dumps
crashDumpInterval = 3.0,         -- Seconds between dumps (2-10 range)
```

### 3. `XIUI/XIUI.lua`

**Add require at top** (after other libs, around line 30):
```lua
local crashdump = require('libs.crashdump');
```

**Add command handler** in `command_cb` function (find existing command handling, add new case):
```lua
-- Crash dump command: /xiui dump
if (command_args[2] == 'dump') then
    crashdump.WriteDump('manual');
    print('[XIUI] Manual crash dump written to config/addons/xiui/crashdump.txt');
    return;
end
```

**Add to d3d_present callback** (after logged-in check, before module rendering):
```lua
-- Update crash dump (always track frames, periodic dump if enabled)
crashdump.IncrementFrame();
if gConfig.enableCrashDump then
    crashdump.PeriodicUpdate(gConfig.crashDumpInterval);
end
```

**Add event logging in packet_in callback** (at start of handler):
```lua
-- Log packet for crash dump
crashdump.LogEvent('packet_in', { id = e.id, size = e.size });
```

### 4. `XIUI/config/global.lua`

**Add collapsing section** (find a good location, perhaps after "Bar Settings"):

```lua
-- Crash Dump Settings
if components.CollapsingSection('Crash Dump##global') then
    components.DrawCheckbox('Enable Crash Dump', 'enableCrashDump');
    imgui.ShowHelp('Periodically write addon state to crashdump.txt for debugging freezes.');

    if gConfig.enableCrashDump then
        components.DrawSlider('Dump Interval (sec)', 'crashDumpInterval', 2, 10, '%.1f');
        imgui.ShowHelp('How often to write state dumps (lower = more disk I/O).');
    end

    if imgui.Button('Write Manual Dump##crashdump') then
        local cd = require('libs.crashdump');
        cd.WriteDump('manual');
        print('[XIUI] Crash dump written to config/addons/xiui/crashdump.txt');
    end
    imgui.ShowHelp('Write a crash dump immediately, regardless of enable setting.');
end
```

### 5. Cache Size Getters (Add to existing handlers)

**`XIUI/handlers/statushandler.lua`** - Add at end of file before `return`:
```lua
-- Get cache sizes for crash dump
statusHandler.getCacheSizes = function()
    local iconCount = 0;
    for _ in pairs(icon_cache) do iconCount = iconCount + 1; end

    local jobIconCount = 0;
    for _ in pairs(jobIcons) do jobIconCount = jobIconCount + 1; end

    local partyBuffCount = 0;
    for _ in pairs(partyBuffs) do partyBuffCount = partyBuffCount + 1; end

    return {
        iconCache = iconCount,
        jobIcons = jobIconCount,
        partyBuffs = partyBuffCount,
    };
end
```

**`XIUI/handlers/debuffhandler.lua`** - Add at end of file before `return`:
```lua
-- Get enemy count for crash dump
debuffHandler.getEnemyCount = function()
    local count = 0;
    for _ in pairs(debuffHandler.enemies) do count = count + 1; end
    return count;
end
```

**`XIUI/handlers/actiontracker.lua`** - Add at end of file before `return`:
```lua
-- Get target count for crash dump
actionTracker.getTargetCount = function()
    local count = 0;
    for _ in pairs(actionTracker.lastTargets) do count = count + 1; end
    return count;
end
```

**`XIUI/libs/packets.lua`** - Add at end of file before `return`:
```lua
-- Get entity cache size for crash dump
function M.GetEntityCacheSize()
    local count = 0;
    for _ in pairs(entityIndexCache) do count = count + 1; end
    return count;
end
```

---

## Testing Checklist

- [ ] `/xiui dump` writes crashdump.txt to correct location
- [ ] Enable crash dump in config menu
- [ ] Verify periodic dumps occur at configured interval
- [ ] Check dump file contains all sections
- [ ] Verify clock jump detection works (simulate with sleep?)
- [ ] Test with various modules enabled/disabled
- [ ] Test during gameplay with combat, targeting, zoning
- [ ] Verify no significant frame rate impact

---

## Potential Freeze Causes (From Analysis)

During exploration, the following potential freeze causes were identified:

1. **FFI Deadlock in Hotbar** (`modules/hotbar/actions.lua`)
   - `macrosLib.stop()` called on every keypress when `disableMacroBars` enabled
   - FFI call to game memory without error handling
   - Could deadlock if game macro system is in locked state

2. **Unsafe FFI Casts** (`modules/hotbar/controller.lua`)
   - XInput state casting without validation
   - Line 453, 501: `ffi.cast('XINPUT_STATE*', e.state)`

3. **Excessive Frame Operations**
   - `SyncTreasurePoolFromMemory()` iterates 10 slots every frame
   - No change detection or caching

These should be investigated separately but the crash dump will help identify which of these (if any) is the actual cause.

---

## Output File Location

`<Ashita Install Path>/config/addons/xiui/crashdump.txt`

The file is overwritten on each dump, so only the most recent state is preserved. If investigating a freeze:
1. Enable crash dump in config
2. Play until freeze occurs
3. After recovering/restarting, check crashdump.txt for pre-freeze state
