local jobs = {
    [1]  = 'WAR', [2]  = 'MNK', [3]  = 'WHM', [4]  = 'BLM',
    [5]  = 'RDM', [6]  = 'THF', [7]  = 'PLD', [8]  = 'DRK',
    [9]  = 'BST', [10] = 'BRD', [11] = 'RNG', [12] = 'SAM',
    [13] = 'NIN', [14] = 'DRG', [15] = 'SMN', [16] = 'BLU',
    [17] = 'COR', [18] = 'PUP', [19] = 'DNC', [20] = 'SCH',
    [21] = 'GEO', [22] = 'RUN',
    [23] = 'Other',
};

jobs.OTHER_JOB_ID = 23;

-- 1-22 stay themselves. Unknown numeric ids (Monstrosity, etc.) map to Other.
-- nil/0 are not jobs and are returned unchanged.
function jobs.ResolveJobCategory(jobId)
    if type(jobId) ~= 'number' or jobId < 1 then
        return jobId;
    end
    if jobId <= 22 then
        return jobId;
    end
    return jobs.OTHER_JOB_ID;
end

function jobs.GetDisplayName(jobId)
    if jobId == 0 then return 'Shared'; end
    return jobs[jobId] or (jobId and 'Other') or nil;
end

-- Jobs 1-22 with level > 0, plus current main/sub when those are 1-22.
function jobs.GetUnlockedJobIds(currentMain, currentSub)
    local memory = AshitaCore and AshitaCore:GetMemoryManager();
    local player = memory and memory:GetPlayer();
    local ids = {};
    for jobId = 1, 22 do
        local include = (jobId == currentMain or jobId == currentSub);
        if not include and player and player.GetJobLevel then
            include = (player:GetJobLevel(jobId) or 0) > 0;
        end
        if include then
            ids[#ids + 1] = jobId;
        end
    end
    return ids;
end

return jobs;
