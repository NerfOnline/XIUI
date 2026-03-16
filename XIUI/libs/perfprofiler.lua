--[[
* XIUI Performance Profiler
* Measures per-module DrawWindow timing and provides reports via /xiui performance.
* Supports sub-section timing for modules that opt in to detailed profiling.
*
* Usage:
*   /xiui performance       - Toggle profiler on/off (prints report when turning off)
*   /xiui perf              - Alias for above
*
* Sub-section API (for module authors):
*   local profiler = require('libs.perfprofiler');
*   local t = profiler.BeginSection('partyList', 'setup');
*   -- ... code ...
*   profiler.EndSection('partyList', 'setup', t);
]]--

local chat = require('chat');

local M = {};

-- ============================================
-- State
-- ============================================
local active = false;
local frameCount = 0;
local reportInterval = 300; -- frames (~5 seconds at 60fps)

-- Per-module timing: [moduleName] = { totalTime, maxTime, minTime, callCount, visibleCount }
local moduleTimings = {};

-- Sub-section timing (opt-in): [moduleName][sectionName] = { totalTime, maxTime, callCount }
local sectionTimings = {};

-- Frame-level totals
local frameTotalTime = 0;
local frameTotalTimeSum = 0;
local frameMaxTime = 0;

-- ============================================
-- Core API
-- ============================================

function M.IsActive()
    return active;
end

function M.Toggle()
    active = not active;
    if active then
        M.Reset();
        print(chat.header('XIUI'):append(chat.success('Performance profiler ON'))
            :append(chat.message(' - reporting every ' .. reportInterval .. ' frames')));
    else
        M.Report();
        print(chat.header('XIUI'):append(chat.message('Performance profiler OFF')));
    end
    return active;
end

function M.Reset()
    frameCount = 0;
    moduleTimings = {};
    sectionTimings = {};
    frameTotalTimeSum = 0;
    frameMaxTime = 0;
end

-- ============================================
-- Frame Lifecycle (called from XIUI.lua render loop)
-- ============================================

function M.BeginFrame()
    if not active then return; end
    frameTotalTime = 0;
end

function M.EndFrame()
    if not active then return; end
    frameCount = frameCount + 1;
    frameTotalTimeSum = frameTotalTimeSum + frameTotalTime;
    if frameTotalTime > frameMaxTime then frameMaxTime = frameTotalTime; end

    if frameCount >= reportInterval then
        M.Report();
        M.Reset();
    end
end

-- ============================================
-- Module Timing (called from moduleregistry.lua)
-- ============================================

function M.BeginModule(name)
    if not active then return nil; end
    return os.clock();
end

function M.EndModule(name, startTime, wasRendered)
    if not active or not startTime then return; end
    local elapsed = os.clock() - startTime;

    if not moduleTimings[name] then
        moduleTimings[name] = { totalTime = 0, maxTime = 0, minTime = math.huge, callCount = 0, visibleCount = 0 };
    end

    local mt = moduleTimings[name];
    mt.totalTime = mt.totalTime + elapsed;
    mt.callCount = mt.callCount + 1;
    if elapsed > mt.maxTime then mt.maxTime = elapsed; end
    if elapsed < mt.minTime then mt.minTime = elapsed; end
    if wasRendered then mt.visibleCount = mt.visibleCount + 1; end

    frameTotalTime = frameTotalTime + elapsed;
end

-- ============================================
-- Sub-Section Timing (opt-in for modules)
-- ============================================

function M.BeginSection(moduleName, sectionName)
    if not active then return nil; end
    return os.clock();
end

function M.EndSection(moduleName, sectionName, startTime)
    if not active or not startTime then return; end
    local elapsed = os.clock() - startTime;

    if not sectionTimings[moduleName] then sectionTimings[moduleName] = {}; end
    if not sectionTimings[moduleName][sectionName] then
        sectionTimings[moduleName][sectionName] = { totalTime = 0, maxTime = 0, callCount = 0 };
    end

    local st = sectionTimings[moduleName][sectionName];
    st.totalTime = st.totalTime + elapsed;
    st.callCount = st.callCount + 1;
    if elapsed > st.maxTime then st.maxTime = elapsed; end
end

-- ============================================
-- Reporting
-- ============================================

function M.Report()
    if frameCount == 0 then
        print(chat.header('XIUI'):append(chat.message('No performance data collected yet.')));
        return;
    end

    local avgFrameTime = frameTotalTimeSum / frameCount;

    print(chat.header('XIUI'):append(chat.success('=== Performance Report (' .. frameCount .. ' frames) ===')));
    print(chat.header('XIUI'):append(chat.message(
        string.format('Total XIUI render: avg=%.2fms | max=%.2fms',
            avgFrameTime * 1000, frameMaxTime * 1000)
    )));

    -- Sort modules by total time (descending)
    local sorted = {};
    for name, mt in pairs(moduleTimings) do
        table.insert(sorted, { name = name, data = mt });
    end
    table.sort(sorted, function(a, b) return a.data.totalTime > b.data.totalTime; end);

    print(chat.header('XIUI'):append(chat.message('--- Per-Module Breakdown ---')));
    for _, entry in ipairs(sorted) do
        local mt = entry.data;
        local avg = mt.totalTime / mt.callCount;
        local pct = (frameTotalTimeSum > 0) and ((mt.totalTime / frameTotalTimeSum) * 100) or 0;
        local visibleStr = mt.visibleCount .. '/' .. mt.callCount;
        print(chat.header('XIUI'):append(chat.message(
            string.format('  %-20s avg=%.2fms  max=%.2fms  %5.1f%%  vis=%s',
                entry.name, avg * 1000, mt.maxTime * 1000, pct, visibleStr)
        )));

        -- Print sub-sections if any
        if sectionTimings[entry.name] then
            local sections = {};
            for secName, secData in pairs(sectionTimings[entry.name]) do
                table.insert(sections, { name = secName, data = secData });
            end
            table.sort(sections, function(a, b) return a.data.totalTime > b.data.totalTime; end);
            for _, sec in ipairs(sections) do
                local secAvg = sec.data.totalTime / sec.data.callCount;
                print(chat.header('XIUI'):append(chat.message(
                    string.format('    |- %-16s avg=%.2fms  max=%.2fms',
                        sec.name, secAvg * 1000, sec.data.maxTime * 1000)
                )));
            end
        end
    end
end

return M;
