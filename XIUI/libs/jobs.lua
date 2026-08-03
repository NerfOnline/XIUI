--[[
* XIUI job id helpers
* Standard adventurer jobs are 1..22. Anything else (Monstrosity monipulators,
* future unknowns) collapses into the shared "Other" category for macro/palette UI.
*
* The returned table keeps numeric keys only so existing `pairs(jobs)` / `jobs[id]`
* call sites keep working. Helpers live on the metatable.
]]--

local STANDARD_JOBS = {
    [1]  = 'WAR', [2]  = 'MNK', [3]  = 'WHM', [4]  = 'BLM',
    [5]  = 'RDM', [6]  = 'THF', [7]  = 'PLD', [8]  = 'DRK',
    [9]  = 'BST', [10] = 'BRD', [11] = 'RNG', [12] = 'SAM',
    [13] = 'NIN', [14] = 'DRG', [15] = 'SMN', [16] = 'BLU',
    [17] = 'COR', [18] = 'PUP', [19] = 'DNC', [20] = 'SCH',
    [21] = 'GEO', [22] = 'RUN',
};

-- Sentinel for palette / hotbar job:subjob storage when not on a standard job.
-- MacroDB uses the string key OTHER_MACRO_KEY instead.
local OTHER_JOB_ID = 23;
local OTHER_MACRO_KEY = 'other';
local OTHER_LABEL = 'Other';

local api = {};

api.OTHER_JOB_ID = OTHER_JOB_ID;
api.OTHER_MACRO_KEY = OTHER_MACRO_KEY;
api.OTHER_LABEL = OTHER_LABEL;
api.STANDARD_MAX = 22;

--- Whether jobId is a normal playable job (WAR..RUN)
---@param jobId number|nil
---@return boolean
function api.IsStandardJob(jobId)
    jobId = tonumber(jobId);
    return jobId ~= nil and STANDARD_JOBS[jobId] ~= nil;
end

--- Numeric job id used for hotbar/palette storage (maps unknown -> Other sentinel)
---@param jobId number|nil
---@return number
function api.ResolveJobCategory(jobId)
    jobId = tonumber(jobId) or 0;
    if api.IsStandardJob(jobId) then
        return jobId;
    end
    return OTHER_JOB_ID;
end

--- macroDB palette key for a main job (number, 'global', or 'other')
---@param jobId number|string|nil
---@return number|string
function api.ResolveMacroPaletteKey(jobId)
    if jobId == 'global' or jobId == OTHER_MACRO_KEY then
        return jobId;
    end
    local numeric = tonumber(jobId);
    if numeric and api.IsStandardJob(numeric) then
        return numeric;
    end
    if type(jobId) == 'string' then
        local base = tonumber(jobId:match('^(%d+)'));
        if base and api.IsStandardJob(base) then
            return jobId;
        end
        if jobId:match('^other') then
            return jobId;
        end
    end
    return OTHER_MACRO_KEY;
end

--- Display name for a job id / Other / Shared
---@param jobId number|string|nil
---@return string
function api.GetDisplayName(jobId)
    if jobId == 0 or jobId == '0' then
        return 'Shared';
    end
    if jobId == OTHER_JOB_ID or jobId == OTHER_MACRO_KEY or jobId == OTHER_LABEL then
        return OTHER_LABEL;
    end
    local numeric = tonumber(jobId);
    if numeric and STANDARD_JOBS[numeric] then
        return STANDARD_JOBS[numeric];
    end
    if type(jobId) == 'string' and jobId ~= '' then
        return jobId;
    end
    return OTHER_LABEL;
end

local jobs = {};
for id, name in pairs(STANDARD_JOBS) do
    jobs[id] = name;
end

return setmetatable(jobs, { __index = api });
