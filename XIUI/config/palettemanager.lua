--[[
* XIUI Config - Palette Manager
* A separate modal window for managing palettes across job/subjob combinations
* Supports creating, renaming, deleting, reordering, and copying palettes
]]--

require('common');
require('handlers.helpers');
local imgui = require('imgui');
local jobs = require('libs.jobs');
local palette = require('modules.hotbar.palette');
local data = require('modules.hotbar.data');

local M = {};

-- Window state
local windowState = {
    isOpen = false,
    selectedJobId = nil,
    selectedSubjobId = nil,  -- 0 = shared
    selectedPaletteType = 'hotbar',  -- 'hotbar' or 'crossbar'
    selectedPaletteName = nil,
};

-- Modal state for create/rename/copy operations
local modalState = {
    isOpen = false,
    mode = nil,  -- 'create', 'rename', 'copy'
    inputBuffer = { '' },
    errorMessage = nil,
    -- For copy operation
    copyTargetJobId = nil,
    copyTargetSubjobId = nil,
};

-- Job names mapping (for display)
local JOB_NAMES = {
    [1] = 'WAR', [2] = 'MNK', [3] = 'WHM', [4] = 'BLM', [5] = 'RDM',
    [6] = 'THF', [7] = 'PLD', [8] = 'DRK', [9] = 'BST', [10] = 'BRD',
    [11] = 'RNG', [12] = 'SAM', [13] = 'NIN', [14] = 'DRG', [15] = 'SMN',
    [16] = 'BLU', [17] = 'COR', [18] = 'PUP', [19] = 'DNC', [20] = 'SCH',
    [21] = 'GEO', [22] = 'RUN',
};

-- Get job name from ID
local function GetJobName(jobId)
    if jobId == 0 then return 'Shared'; end
    return JOB_NAMES[jobId] or ('Job ' .. jobId);
end

-- Get list of all jobs that have palettes defined
local function GetJobsWithPalettes()
    local jobsList = palette.GetJobsWithPalettes();
    -- Always include current player job
    local currentJobId = data.jobId or 1;
    local hasCurrentJob = false;
    for _, jobId in ipairs(jobsList) do
        if jobId == currentJobId then
            hasCurrentJob = true;
            break;
        end
    end
    if not hasCurrentJob then
        table.insert(jobsList, 1, currentJobId);
    end
    table.sort(jobsList);
    return jobsList;
end

-- Get list of subjobs for a job that have palettes defined
local function GetSubjobsForJob(jobId)
    local subjobsList = palette.GetSubjobsWithPalettes(jobId);
    -- Always include 0 (shared) at the start
    local hasShared = false;
    for _, subjobId in ipairs(subjobsList) do
        if subjobId == 0 then
            hasShared = true;
            break;
        end
    end
    if not hasShared then
        table.insert(subjobsList, 1, 0);
    end
    table.sort(subjobsList);
    return subjobsList;
end

-- Open the palette manager window
function M.Open()
    windowState.isOpen = true;
    -- Initialize with current job if not set
    if not windowState.selectedJobId then
        windowState.selectedJobId = data.jobId or 1;
    end
    if not windowState.selectedSubjobId then
        windowState.selectedSubjobId = data.subjobId or 0;
    end
end

-- Close the palette manager window
function M.Close()
    windowState.isOpen = false;
end

-- Check if window is open
function M.IsOpen()
    return windowState.isOpen;
end

-- Helper: Draw palette type selector (hotbar vs crossbar)
local function DrawPaletteTypeSelector()
    imgui.Text('Type:');
    imgui.SameLine();
    if imgui.RadioButton('Hotbar##paletteType', windowState.selectedPaletteType == 'hotbar') then
        windowState.selectedPaletteType = 'hotbar';
        windowState.selectedPaletteName = nil;
    end
    imgui.SameLine();
    if imgui.RadioButton('Crossbar##paletteType', windowState.selectedPaletteType == 'crossbar') then
        windowState.selectedPaletteType = 'crossbar';
        windowState.selectedPaletteName = nil;
    end
end

-- Helper: Draw job selector dropdown
local function DrawJobSelector()
    local changed = false;
    local currentLabel = GetJobName(windowState.selectedJobId);

    imgui.Text('Job:');
    imgui.SameLine();
    imgui.PushItemWidth(80);
    if imgui.BeginCombo('##jobSelector', currentLabel) then
        for jobId = 1, 22 do
            local isSelected = (jobId == windowState.selectedJobId);
            if imgui.Selectable(GetJobName(jobId), isSelected) then
                if jobId ~= windowState.selectedJobId then
                    windowState.selectedJobId = jobId;
                    windowState.selectedSubjobId = 0;  -- Reset to shared
                    windowState.selectedPaletteName = nil;
                    changed = true;
                end
            end
            if isSelected then
                imgui.SetItemDefaultFocus();
            end
        end
        imgui.EndCombo();
    end
    imgui.PopItemWidth();

    return changed;
end

-- Helper: Draw subjob selector dropdown
local function DrawSubjobSelector()
    local changed = false;
    local currentLabel = windowState.selectedSubjobId == 0 and 'Shared' or GetJobName(windowState.selectedSubjobId);

    imgui.SameLine();
    imgui.Text('Subjob:');
    imgui.SameLine();
    imgui.PushItemWidth(80);
    if imgui.BeginCombo('##subjobSelector', currentLabel) then
        -- Shared option first
        local sharedSelected = (windowState.selectedSubjobId == 0);
        if imgui.Selectable('Shared', sharedSelected) then
            if windowState.selectedSubjobId ~= 0 then
                windowState.selectedSubjobId = 0;
                windowState.selectedPaletteName = nil;
                changed = true;
            end
        end
        if sharedSelected then
            imgui.SetItemDefaultFocus();
        end
        -- All jobs as subjob options
        for subjobId = 1, 22 do
            local isSelected = (subjobId == windowState.selectedSubjobId);
            if imgui.Selectable(GetJobName(subjobId), isSelected) then
                if subjobId ~= windowState.selectedSubjobId then
                    windowState.selectedSubjobId = subjobId;
                    windowState.selectedPaletteName = nil;
                    changed = true;
                end
            end
            if isSelected then
                imgui.SetItemDefaultFocus();
            end
        end
        imgui.EndCombo();
    end
    imgui.PopItemWidth();

    return changed;
end

-- Helper: Draw palette list
local function DrawPaletteList()
    local palettes;
    local usingFallback = false;

    if windowState.selectedPaletteType == 'hotbar' then
        palettes = palette.GetAvailablePalettes(1, windowState.selectedJobId, windowState.selectedSubjobId);
        usingFallback = windowState.selectedSubjobId ~= 0 and
                        palette.IsUsingFallbackPalettes(windowState.selectedJobId, windowState.selectedSubjobId);
    else
        palettes = palette.GetCrossbarAvailablePalettes(windowState.selectedJobId, windowState.selectedSubjobId);
        usingFallback = windowState.selectedSubjobId ~= 0 and #palettes > 0 and
                        not palette.GetCrossbarAvailablePalettes(windowState.selectedJobId, windowState.selectedSubjobId)[1];
    end

    -- Show fallback indicator
    if usingFallback then
        imgui.TextColored({0.7, 0.7, 0.3, 1.0}, '(Using shared palettes - no subjob-specific palettes exist)');
        imgui.Spacing();
    end

    -- Palette list header
    local headerText = string.format('Palettes for %s', windowState.selectedSubjobId == 0 and 'Shared' or
                                     string.format('%s/%s', GetJobName(windowState.selectedJobId), GetJobName(windowState.selectedSubjobId)));
    imgui.Text(headerText);
    imgui.Separator();

    -- List of palettes
    local listHeight = 150;
    imgui.BeginChild('##paletteList', { 0, listHeight }, true);

    if #palettes == 0 then
        imgui.TextColored({0.5, 0.5, 0.5, 1.0}, 'No palettes defined');
    else
        for i, paletteName in ipairs(palettes) do
            local isSelected = windowState.selectedPaletteName == paletteName;
            if imgui.Selectable(paletteName .. '##palette' .. i, isSelected) then
                windowState.selectedPaletteName = paletteName;
            end

            -- Context menu for right-click
            if imgui.BeginPopupContextItem('##paletteContext' .. i) then
                if imgui.MenuItem('Rename') then
                    modalState.mode = 'rename';
                    modalState.inputBuffer[1] = paletteName;
                    modalState.errorMessage = nil;
                    modalState.isOpen = true;
                    windowState.selectedPaletteName = paletteName;
                end
                if imgui.MenuItem('Copy To...') then
                    modalState.mode = 'copy';
                    modalState.inputBuffer[1] = paletteName;
                    modalState.errorMessage = nil;
                    modalState.copyTargetJobId = windowState.selectedJobId;
                    modalState.copyTargetSubjobId = windowState.selectedSubjobId;
                    modalState.isOpen = true;
                    windowState.selectedPaletteName = paletteName;
                end
                if #palettes > 1 then
                    imgui.Separator();
                    if imgui.MenuItem('Delete') then
                        local success, err;
                        if windowState.selectedPaletteType == 'hotbar' then
                            success, err = palette.DeletePalette(1, paletteName, windowState.selectedJobId, windowState.selectedSubjobId);
                        else
                            success, err = palette.DeleteCrossbarPalette(paletteName, windowState.selectedJobId, windowState.selectedSubjobId);
                        end
                        if success then
                            windowState.selectedPaletteName = nil;
                        end
                    end
                end
                imgui.EndPopup();
            end
        end
    end

    imgui.EndChild();

    return palettes;
end

-- Helper: Draw action buttons
local function DrawActionButtons(palettes)
    -- New palette button
    if imgui.Button('+ New') then
        modalState.mode = 'create';
        modalState.inputBuffer[1] = '';
        modalState.errorMessage = nil;
        modalState.isOpen = true;
    end

    imgui.SameLine();

    -- Rename button (enabled if palette selected)
    local hasSelection = windowState.selectedPaletteName ~= nil;
    if not hasSelection then imgui.BeginDisabled(); end
    if imgui.Button('Rename') then
        modalState.mode = 'rename';
        modalState.inputBuffer[1] = windowState.selectedPaletteName;
        modalState.errorMessage = nil;
        modalState.isOpen = true;
    end
    if not hasSelection then imgui.EndDisabled(); end

    imgui.SameLine();

    -- Delete button (enabled if palette selected and more than 1 palette)
    local canDelete = hasSelection and #palettes > 1;
    if not canDelete then imgui.BeginDisabled(); end
    if imgui.Button('Delete') then
        local success, err;
        if windowState.selectedPaletteType == 'hotbar' then
            success, err = palette.DeletePalette(1, windowState.selectedPaletteName, windowState.selectedJobId, windowState.selectedSubjobId);
        else
            success, err = palette.DeleteCrossbarPalette(windowState.selectedPaletteName, windowState.selectedJobId, windowState.selectedSubjobId);
        end
        if success then
            windowState.selectedPaletteName = nil;
        end
    end
    if not canDelete then imgui.EndDisabled(); end

    imgui.SameLine();

    -- Copy To button
    if not hasSelection then imgui.BeginDisabled(); end
    if imgui.Button('Copy To...') then
        modalState.mode = 'copy';
        modalState.inputBuffer[1] = windowState.selectedPaletteName;
        modalState.errorMessage = nil;
        modalState.copyTargetJobId = windowState.selectedJobId;
        modalState.copyTargetSubjobId = windowState.selectedSubjobId;
        modalState.isOpen = true;
    end
    if not hasSelection then imgui.EndDisabled(); end

    -- Reorder buttons on next line
    imgui.Spacing();

    if not hasSelection then imgui.BeginDisabled(); end
    if imgui.Button('Move Up') then
        local success, err;
        if windowState.selectedPaletteType == 'hotbar' then
            success, err = palette.MovePalette(1, windowState.selectedPaletteName, -1, windowState.selectedJobId, windowState.selectedSubjobId);
        else
            success, err = palette.MoveCrossbarPalette(windowState.selectedPaletteName, -1, windowState.selectedJobId, windowState.selectedSubjobId);
        end
    end
    imgui.SameLine();
    if imgui.Button('Move Down') then
        local success, err;
        if windowState.selectedPaletteType == 'hotbar' then
            success, err = palette.MovePalette(1, windowState.selectedPaletteName, 1, windowState.selectedJobId, windowState.selectedSubjobId);
        else
            success, err = palette.MoveCrossbarPalette(windowState.selectedPaletteName, 1, windowState.selectedJobId, windowState.selectedSubjobId);
        end
    end
    if not hasSelection then imgui.EndDisabled(); end
end

-- Helper: Draw create/rename modal
local function DrawCreateRenameModal()
    if not modalState.isOpen or (modalState.mode ~= 'create' and modalState.mode ~= 'rename') then
        return;
    end

    local title = modalState.mode == 'create' and 'Create New Palette' or 'Rename Palette';
    imgui.OpenPopup(title .. '##paletteModal');

    if imgui.BeginPopupModal(title .. '##paletteModal', nil, ImGuiWindowFlags_AlwaysAutoResize) then
        imgui.Text('Palette Name:');
        imgui.PushItemWidth(200);
        local enterPressed = imgui.InputText('##paletteName', modalState.inputBuffer, 32, ImGuiInputTextFlags_EnterReturnsTrue);
        imgui.PopItemWidth();

        -- Show error if any
        if modalState.errorMessage then
            imgui.TextColored({1.0, 0.3, 0.3, 1.0}, modalState.errorMessage);
        end

        imgui.Spacing();

        -- Buttons
        local newName = modalState.inputBuffer[1];
        local canSubmit = newName and newName ~= '';

        if imgui.Button('OK', { 80, 0 }) or enterPressed then
            if canSubmit then
                local success, err;
                if modalState.mode == 'create' then
                    if windowState.selectedPaletteType == 'hotbar' then
                        success, err = palette.CreatePalette(1, newName, windowState.selectedJobId, windowState.selectedSubjobId);
                    else
                        success, err = palette.CreateCrossbarPalette(newName, windowState.selectedJobId, windowState.selectedSubjobId);
                    end
                else  -- rename
                    if windowState.selectedPaletteType == 'hotbar' then
                        success, err = palette.RenamePalette(1, windowState.selectedPaletteName, newName, windowState.selectedJobId, windowState.selectedSubjobId);
                    else
                        success, err = palette.RenameCrossbarPalette(windowState.selectedPaletteName, newName, windowState.selectedJobId, windowState.selectedSubjobId);
                    end
                end

                if success then
                    windowState.selectedPaletteName = newName;
                    modalState.isOpen = false;
                    imgui.CloseCurrentPopup();
                else
                    modalState.errorMessage = err or 'Operation failed';
                end
            end
        end

        imgui.SameLine();

        if imgui.Button('Cancel', { 80, 0 }) then
            modalState.isOpen = false;
            imgui.CloseCurrentPopup();
        end

        imgui.EndPopup();
    end
end

-- Helper: Draw copy modal
local function DrawCopyModal()
    if not modalState.isOpen or modalState.mode ~= 'copy' then
        return;
    end

    imgui.OpenPopup('Copy Palette##copyModal');

    if imgui.BeginPopupModal('Copy Palette##copyModal', nil, ImGuiWindowFlags_AlwaysAutoResize) then
        imgui.Text('Copy "' .. windowState.selectedPaletteName .. '" to:');
        imgui.Spacing();

        -- Job selector
        imgui.Text('Job:');
        imgui.SameLine();
        imgui.PushItemWidth(100);
        if imgui.BeginCombo('##copyJobSelector', GetJobName(modalState.copyTargetJobId)) then
            for jobId = 1, 22 do
                local isSelected = (jobId == modalState.copyTargetJobId);
                if imgui.Selectable(GetJobName(jobId), isSelected) then
                    modalState.copyTargetJobId = jobId;
                end
                if isSelected then
                    imgui.SetItemDefaultFocus();
                end
            end
            imgui.EndCombo();
        end
        imgui.PopItemWidth();

        -- Subjob selector
        imgui.SameLine();
        imgui.Text('Subjob:');
        imgui.SameLine();
        imgui.PushItemWidth(100);
        local currentSubjobLabel = modalState.copyTargetSubjobId == 0 and 'Shared' or GetJobName(modalState.copyTargetSubjobId);
        if imgui.BeginCombo('##copySubjobSelector', currentSubjobLabel) then
            -- Shared option
            local sharedSelected = (modalState.copyTargetSubjobId == 0);
            if imgui.Selectable('Shared', sharedSelected) then
                modalState.copyTargetSubjobId = 0;
            end
            if sharedSelected then
                imgui.SetItemDefaultFocus();
            end
            -- Job options
            for subjobId = 1, 22 do
                local isSelected = (subjobId == modalState.copyTargetSubjobId);
                if imgui.Selectable(GetJobName(subjobId), isSelected) then
                    modalState.copyTargetSubjobId = subjobId;
                end
                if isSelected then
                    imgui.SetItemDefaultFocus();
                end
            end
            imgui.EndCombo();
        end
        imgui.PopItemWidth();

        imgui.Spacing();

        -- New name input
        imgui.Text('New Name (leave blank to keep same):');
        imgui.PushItemWidth(200);
        imgui.InputText('##copyNewName', modalState.inputBuffer, 32);
        imgui.PopItemWidth();

        -- Show error if any
        if modalState.errorMessage then
            imgui.TextColored({1.0, 0.3, 0.3, 1.0}, modalState.errorMessage);
        end

        imgui.Spacing();

        -- Buttons
        if imgui.Button('Copy', { 80, 0 }) then
            local newName = modalState.inputBuffer[1];
            if newName == '' then newName = nil; end

            local success, err;
            if windowState.selectedPaletteType == 'hotbar' then
                success, err = palette.CopyPalette(
                    windowState.selectedPaletteName,
                    windowState.selectedJobId,
                    windowState.selectedSubjobId,
                    modalState.copyTargetJobId,
                    modalState.copyTargetSubjobId,
                    newName
                );
            else
                success, err = palette.CopyCrossbarPalette(
                    windowState.selectedPaletteName,
                    windowState.selectedJobId,
                    windowState.selectedSubjobId,
                    modalState.copyTargetJobId,
                    modalState.copyTargetSubjobId,
                    newName
                );
            end

            if success then
                modalState.isOpen = false;
                imgui.CloseCurrentPopup();
            else
                modalState.errorMessage = err or 'Copy failed';
            end
        end

        imgui.SameLine();

        if imgui.Button('Cancel', { 80, 0 }) then
            modalState.isOpen = false;
            imgui.CloseCurrentPopup();
        end

        imgui.EndPopup();
    end
end

-- Draw the main palette manager window
function M.Draw()
    if not windowState.isOpen then
        return;
    end

    -- Window size
    imgui.SetNextWindowSize({ 350, 400 }, ImGuiCond_FirstUseEver);

    local windowFlags = ImGuiWindowFlags_None;
    local isOpen = { windowState.isOpen };

    if imgui.Begin('Palette Manager##paletteManager', isOpen, windowFlags) then
        -- Type selector
        DrawPaletteTypeSelector();
        imgui.Spacing();

        -- Job/Subjob selectors
        DrawJobSelector();
        DrawSubjobSelector();
        imgui.Spacing();

        -- Palette list
        local palettes = DrawPaletteList();
        imgui.Spacing();

        -- Action buttons
        DrawActionButtons(palettes);

        -- Draw modals
        DrawCreateRenameModal();
        DrawCopyModal();
    end
    imgui.End();

    windowState.isOpen = isOpen[1];
end

return M;
