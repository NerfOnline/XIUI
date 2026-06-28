--[[
* XIUI Hotbar - Macro Palette Module
* Provides a visual grid of user-created macros that can be dragged to hotbar slots
]]--
require('common');
require('handlers.helpers');
local imgui = require('imgui');
local ffi = require('ffi');
local data = require('modules.hotbar.data');
local actions = require('modules.hotbar.actions');
local textures = require('modules.hotbar.textures');
local TextureManager = require('libs.texturemanager');
local jobs = require('libs.jobs');
local components = require('config.components');
local dragdrop = require('libs.dragdrop');
local petpalette = require('modules.hotbar.petpalette');
local petregistry = require('modules.hotbar.petregistry');
local playerdata = require('modules.hotbar.playerdata');
local actiondb = require('modules.hotbar.actiondb');
local iconpicker = require('modules.hotbar.iconpicker');
-- display and crossbar are loaded lazily to avoid circular dependencies
local display = nil;
local crossbar = nil;
local M = {};

-- ============================================
-- Constants
-- ============================================

local INPUT_BUFFER_SIZE = 64;
local MACRO_BUFFER_SIZE = 512;  -- 8 lines * ~60 chars each
local PALETTE_COLUMNS = 6;
local PALETTE_ROWS = 6;
local PALETTE_MACROS_PER_PAGE = PALETTE_COLUMNS * PALETTE_ROWS;  -- 36 macros per page
local PALETTE_TILE_SIZE = 48;
local PALETTE_TILE_GAP = 4;
local PALETTE_PADDING = 8;

-- XIUI Color Scheme (from components.TAB_STYLE)
local COLORS = {
    gold = components.TAB_STYLE.gold,
    goldDim = {0.957 * 0.7, 0.855 * 0.7, 0.592 * 0.7, 1.0},
    goldDark = {0.765, 0.684, 0.474, 1.0},       -- #C3AE79 - Darker gold for hover
    goldDarker = {0.573, 0.512, 0.355, 1.0},     -- #92835B - Even darker gold
    bgMedium = components.TAB_STYLE.bgMedium,
    bgLight = components.TAB_STYLE.bgLight,
    bgLighter = components.TAB_STYLE.bgLighter,
    bgDark = {0.067, 0.063, 0.055, 0.95},
    text = {0.9, 0.9, 0.9, 1.0},
    textDim = {0.6, 0.6, 0.6, 1.0},
    textMuted = {0.4, 0.4, 0.4, 1.0},
    border = {0.3, 0.28, 0.24, 0.8},
    success = {0.4, 0.7, 0.4, 1.0},
    danger = {0.8, 0.3, 0.3, 1.0},
    dangerDim = {0.6, 0.25, 0.25, 1.0},
    usable = {0.5, 0.7, 1.0, 1.0},  -- Blue tint for usable items
};

-- Deferred save state for hotbar slot changes
-- Instead of saving immediately (which causes ~500ms freeze), we track dirty state
-- and save only at natural pause points: zone change, palette close, config close, unload
local hotbarDataDirty = false;
local function MarkHotbarDirty()
    hotbarDataDirty = true;
end

-- Deferred icon cache clear: dropping texture references mid-render-frame lets
-- GC release D3D COM objects whose pointers are still queued in ImGui's draw
-- list, causing EXCEPTION_ACCESS_VIOLATION. We schedule the clear and execute
-- it at the TOP of the next d3d_present (after TextureManager.FlushPendingReleases).
local pendingIconCacheClear = false;

-- Helper to generate abbreviated text from action name (max 4 chars)
-- If preferAction is true, prioritize action name over displayName (for previews)
local function GetActionAbbreviation(macro, preferAction)
    local name;
    if preferAction then
        name = macro.action or macro.displayName or '';
    else
        name = macro.displayName or macro.action or '';
    end
    if name == '' then return '?'; end

    -- Remove common prefixes/suffixes
    name = name:gsub('^%s+', ''):gsub('%s+$', '');  -- Trim whitespace

    -- If short enough, just use it
    if #name <= 4 then
        return name:upper();
    end

    -- Check for multi-word names (take first letter of each word)
    local words = {};
    for word in name:gmatch('%S+') do
        table.insert(words, word);
    end
    if #words >= 2 then
        -- Multi-word: take first letter of each word (up to 4)
        local abbr = '';
        for i = 1, math.min(#words, 4) do
            abbr = abbr .. words[i]:sub(1, 1):upper();
        end
        return abbr;
    end

    -- Single word: take first 4 chars
    return name:sub(1, 4):upper();
end

-- Helper to clear all hotbar/crossbar icon caches (full clear - expensive)
-- IMPORTANT: This must only run at the TOP of d3d_present, never mid-frame.
-- Clearing texturePtrCache mid-frame drops the last Lua reference to D3D
-- texture tables, making them GC-eligible. If GC fires (e.g. from the heavy
-- string allocations in SerializeLegacy), it releases COM objects whose
-- pointers are still queued in the current frame's ImGui draw list → crash.
local slotrenderer = nil;  -- Lazy-loaded
local function ClearAllIconCaches()
    -- Lazy-load display to avoid circular dependency
    if display == nil then
        local success, mod = pcall(require, 'modules.hotbar.display');
        if success then display = mod; end
    end
    if display and display.ClearIconCache then
        display.ClearIconCache();
    end
    -- Lazy-load crossbar to avoid circular dependency
    if crossbar == nil then
        local success, mod = pcall(require, 'modules.hotbar.crossbar');
        if success then crossbar = mod; end
    end
    if crossbar and crossbar.ClearIconCache then
        crossbar.ClearIconCache();
    end
    -- Lazy-load slotrenderer to clear slot rendering cache
    if slotrenderer == nil then
        local success, mod = pcall(require, 'modules.hotbar.slotrenderer');
        if success then slotrenderer = mod; end
    end
    if slotrenderer and slotrenderer.ClearSlotRenderingCache then
        slotrenderer.ClearSlotRenderingCache();
    end
    -- Edits that change a macro's action leave the old actionType:action entry
    -- orphaned in mpCostCache / availabilityCache. Functionally fine (the new key
    -- naturally misses), but bounds memory across many edits.
    if slotrenderer and slotrenderer.ClearMPCostCache then
        slotrenderer.ClearMPCostCache();
    end
    if slotrenderer and slotrenderer.ClearAvailabilityCache then
        slotrenderer.ClearAvailabilityCache();
    end
    -- Clear the icon-resolution negative cache so newly-added custom icons
    -- on edited macros are picked up next frame.
    if actions and actions.ClearNoIconCache then
        actions.ClearNoIconCache();
    end
end

-- When true, FlushPendingFrameWork also calls slotrenderer.ClearAllCache
-- (needed for pet palette switches that change which abilities are visible).
local pendingFullSlotCacheClear = false;

-- Schedule icon cache clear for the start of the next frame instead of
-- executing it immediately. Call this from mid-frame code paths (button
-- handlers, save callbacks) that must not drop texture references.
local function ScheduleIconCacheClear(includeFullSlotCache)
    pendingIconCacheClear = true;
    if includeFullSlotCache then
        pendingFullSlotCacheClear = true;
    end
end

-- Helper to clear icon cache for a single hotbar slot (targeted - fast)
local function ClearSlotIconCache(barIndex, slotIndex)
    -- Lazy-load modules
    if display == nil then
        local success, mod = pcall(require, 'modules.hotbar.display');
        if success then display = mod; end
    end
    if slotrenderer == nil then
        local success, mod = pcall(require, 'modules.hotbar.slotrenderer');
        if success then slotrenderer = mod; end
    end
    -- Clear display icon cache for this slot
    if display and display.ClearIconCacheForSlot then
        display.ClearIconCacheForSlot(barIndex, slotIndex);
    end
end

-- Helper to clear icon cache for a single crossbar slot (targeted - fast)
local function ClearCrossbarSlotIconCache(comboMode, slotIndex)
    -- Lazy-load modules
    if crossbar == nil then
        local success, mod = pcall(require, 'modules.hotbar.crossbar');
        if success then crossbar = mod; end
    end
    if slotrenderer == nil then
        local success, mod = pcall(require, 'modules.hotbar.slotrenderer');
        if success then slotrenderer = mod; end
    end
    -- Clear crossbar icon cache for this slot
    if crossbar and crossbar.ClearIconCacheForSlot then
        crossbar.ClearIconCacheForSlot(comboMode, slotIndex);
    end
end

-- Action type constants (needed by DrawMacroTile and DrawMacroEditor)
local ACTION_TYPES = { 'ma', 'ja', 'ws', 'item', 'equip', 'macro', 'pet' };
local ACTION_TYPE_LABELS = {
    ma = 'Spell (ma)',
    ja = 'Ability (ja)',
    ws = 'Weaponskill (ws)',
    item = 'Item',
    equip = 'Equip',
    macro = 'Macro',
    pet = 'Pet Command',
};

-- Recast source types for macros (allows displaying cooldown from a different action)
local RECAST_SOURCE_TYPES = { 'none', 'ma', 'ja', 'ws', 'item', 'pet' };
local RECAST_SOURCE_LABELS = {
    none = 'None',
    ma = 'Spell',
    ja = 'Ability',
    ws = 'Weaponskill',
    item = 'Item',
    pet = 'Pet Command',
};

-- Helper to format target for display (strips existing brackets, adds fresh ones)
-- Handles: "me", "<me>", "<<me>>", "t", "<t>", etc.
local function FormatTargetForDisplay(target)
    if not target then return nil; end
    -- Strip any existing < > brackets
    local cleaned = target:gsub('[<>]', '');
    if cleaned == '' then return nil; end
    return '<' .. cleaned .. '>';
end

-- FFXI equipment slot bitmasks (for filtering items by equip slot)
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

-- ============================================
-- Helper Functions for Job ID Key Normalization
-- ============================================

-- Special key for global (non-job-specific) slot storage
local GLOBAL_SLOT_KEY = 'global';

-- Special key for global macros (shared across all jobs)
local GLOBAL_MACRO_KEY = 'global';

-- Helper to deep copy a table (for migrating slot data)
local function deepCopyTable(tbl)
    if type(tbl) ~= 'table' then return tbl; end
    local copy = {};
    for k, v in pairs(tbl) do
        copy[k] = deepCopyTable(v);
    end
    return copy;
end

-- Helper to ensure slotActions structure exists for a storage key
-- Handles: 'global' and composite keys ('15:10', '15:10:avatar:ifrit')
-- IMPORTANT: When creating a new key, copies data from fallback keys to preserve slot data
local function ensureSlotActionsStructure(barSettings, storageKey)
    if not barSettings.slotActions then
        barSettings.slotActions = {};
    end
    -- Handle 'global' key specially
    if storageKey == GLOBAL_SLOT_KEY then
        if not barSettings.slotActions[GLOBAL_SLOT_KEY] then
            barSettings.slotActions[GLOBAL_SLOT_KEY] = {};
        end
        return barSettings.slotActions[GLOBAL_SLOT_KEY];
    end
    -- All job-specific keys are composite strings (job:subjob format)
    if not barSettings.slotActions[storageKey] then
        -- Before creating empty table, check for fallback data to migrate
        -- This preserves slot data when subjob changes (e.g., '1:0' -> '1:5')
        local jobId, subjobId, suffix = storageKey:match('^(%d+):(%d+)(.*)$');
        if jobId and subjobId ~= '0' then
            -- Build fallback key with subjob=0, preserving any suffix (palette, avatar, etc.)
            local fallbackKey = jobId .. ':0' .. (suffix or '');
            local fallbackData = barSettings.slotActions[fallbackKey];
            if fallbackData then
                -- Deep copy fallback data to the new key to preserve all slots
                barSettings.slotActions[storageKey] = deepCopyTable(fallbackData);
            else
                barSettings.slotActions[storageKey] = {};
            end
        else
            barSettings.slotActions[storageKey] = {};
        end
    end
    return barSettings.slotActions[storageKey];
end

-- ============================================
-- State
-- ============================================

local paletteOpen = false;
local selectedMacroIndex = nil;
local editingMacro = nil;
local isCreatingNew = false;
local currentPalettePage = 1;  -- Current page in macro palette (1-indexed)

-- Selected job for viewing/editing macros (nil = use current player job)
local selectedPaletteType = nil;  -- Can be GLOBAL_MACRO_KEY or a job ID
local selectedAvatarPalette = nil;  -- For SMN: nil = base, or avatar name like 'Ifrit'

-- Cached pet commands (managed locally, not in shared module)
local cachedPetCommands = nil;
local cachedPetCommandsShowAll = nil;
local function InvalidatePetCommandCache()
    cachedPetCommands = nil;
    cachedPetCommandsShowAll = nil;
end
local petAvatarFilter = 1;  -- 1 = All, 2+ = specific avatar index
local petJugFilter = 1;  -- 1 = All Jug Pets, 2+ = owned jug pet index
local cachedOwnedJugPets = nil;  -- { internalName, displayName } from inventory
local cachedOwnedJugPetsSignature = nil;

-- Search filter for dropdowns
local searchFilter = { '' };

-- Macro editor "Show All" toggles (per action category; imgui checkbox state arrays)
local editorShowAll = {
    spells = { false },
    abilities = { false },
    weaponskills = { false },
    pet = { false },
};

-- Forward declaration; defined after ForceRefreshPetCommands.
local RefreshEditorShowAll;

-- Macro editor dropdown refresh state (shows "Loading..." when reopening lists)
local editorFrameCounter = 0;
local dropdownLoadState = {};  -- [label] = frame when refresh started

-- Copy macro dialog state
local copyMacroDialogOpen = false;
local copyMacroSource = nil;
local copyTargetIndex = { 1 };

-- ============================================
-- Spell/Ability/Weaponskill Retrieval (via shared playerdata module)
-- ============================================

local function RefreshCachedLists()
    playerdata.RefreshCachedLists(data);
    if playerdata.GetCacheJobId() ~= data.jobId then
        InvalidatePetCommandCache();
    end
    -- playerdata.RefreshCachedLists always rebuilds known-only lists; re-apply Show All when active.
    if editorShowAll.spells[1] then RefreshEditorShowAll('spells'); end
    if editorShowAll.abilities[1] then RefreshEditorShowAll('abilities'); end
    if editorShowAll.weaponskills[1] then RefreshEditorShowAll('weaponskills'); end
end
local function GetCachedEditorList(kind)
    local cached;
    if kind == 'spells' then
        cached = playerdata.GetCachedSpells();
    elseif kind == 'abilities' then
        cached = playerdata.GetCachedAbilities();
    else
        cached = playerdata.GetCachedWeaponskills();
    end
    if cached then
        return cached;
    end
    RefreshEditorShowAll(kind);
    if kind == 'spells' then
        return playerdata.GetCachedSpells() or {};
    elseif kind == 'abilities' then
        return playerdata.GetCachedAbilities() or {};
    end
    return playerdata.GetCachedWeaponskills() or {};
end
local function GetCachedSpells()
    return GetCachedEditorList('spells');
end
local function GetCachedAbilities()
    return GetCachedEditorList('abilities');
end
local function GetCachedWeaponskills()
    return GetCachedEditorList('weaponskills');
end
local function GetCachedItems()
    return playerdata.GetCachedItems();
end
local function GetPetCommandsForJob(jobId, avatarName, activePetName, forEditor, jugOwnedInternalNames)
    return playerdata.GetPlayerPetCommands(
        jobId, avatarName, activePetName, forEditor, jugOwnedInternalNames);
end
local function ResolveEditorPetJobId()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if not player then
        return 0;
    end
    local viewedJobId = selectedPaletteType;
    if type(viewedJobId) == 'string' then
        viewedJobId = tonumber(viewedJobId:match('^(%d+)')) or 0;
    end
    if type(viewedJobId) == 'number' and petregistry.IsPetJob(viewedJobId) then
        return viewedJobId;
    end
    local mainJobId = player:GetMainJob() or 0;
    local subJobId = player:GetSubJob() or 0;
    if petregistry.IsPetJob(mainJobId) then
        return mainJobId;
    end
    if subJobId > 0 and petregistry.IsPetJob(subJobId) then
        return subJobId;
    end
    return type(viewedJobId) == 'number' and viewedJobId or mainJobId;
end
local function GetOwnedAvatarList()
    return playerdata.GetMacroEditorAvatarNames();
end
local function NormalizePetAvatarFilter()
    if petAvatarFilter <= 1 then
        return;
    end
    local owned = GetOwnedAvatarList();
    if not owned[petAvatarFilter - 1] then
        petAvatarFilter = 1;
        InvalidatePetCommandCache();
            end
        end
local function BuildOwnedJugPetFilterList()
    local internalNames = petregistry.GetOwnedJugPetInternalNames();
    local signature = table.concat(internalNames, '|');
    if signature == cachedOwnedJugPetsSignature and cachedOwnedJugPets then
        return cachedOwnedJugPets;
    end
    cachedOwnedJugPetsSignature = signature;
    cachedOwnedJugPets = {};
    for _, internalName in ipairs(internalNames) do
        table.insert(cachedOwnedJugPets, {
            internalName = internalName,
            displayName = petregistry.FormatJugPetDisplayName(internalName) or internalName,
                });
            end
    return cachedOwnedJugPets;
end
local function NormalizePetJugFilter()
    if petJugFilter <= 1 then
        return;
    end
    local owned = BuildOwnedJugPetFilterList();
    if not owned[petJugFilter - 1] then
        petJugFilter = 1;
        InvalidatePetCommandCache();
    end
end
local function GetSelectedJugFilterInternalName()
    NormalizePetJugFilter();
    if petJugFilter <= 1 then
        return nil;
    end
    local owned = BuildOwnedJugPetFilterList();
    local entry = owned[petJugFilter - 1];
    return entry and entry.internalName or nil;
end
local function GetSelectedJugFilterDisplayName()
    NormalizePetJugFilter();
    if petJugFilter <= 1 then
        return 'All Jug Pets';
    end
    local owned = BuildOwnedJugPetFilterList();
    local entry = owned[petJugFilter - 1];
    return entry and entry.displayName or 'All Jug Pets';
end

-- Browsing icon cache for DrawSearchableCombo dropdowns.
local browsingIconCache = {
    icons = {},
    itemIds = nil,
    loadIndex = 0,
    loaded = false,
    loading = false,
    batchSize = 25,
    generation = 0,
};

-- Start pre-loading browsing icons for a list of items.
-- Returns immediately; call LoadBrowsingIconBatch() each frame to make progress.
local function StartBrowsingIconLoad(items)
    if not items or #items == 0 then
        browsingIconCache.loaded = true;
        browsingIconCache.loading = false;
        return;
    end

    -- Build the list of item IDs that need loading
    local ids = {};
    for _, item in ipairs(items) do
        if item.id and item.id > 0 and item.id ~= 65535 then
            -- Skip if already cached from a previous load
            if browsingIconCache.icons[item.id] == nil then
                ids[#ids + 1] = item.id;
            end
        end
    end
    if #ids == 0 then
        browsingIconCache.loaded = true;
        browsingIconCache.loading = false;
        return;
    end
    browsingIconCache.itemIds = ids;
    browsingIconCache.loadIndex = 0;
    browsingIconCache.loaded = false;
    browsingIconCache.loading = true;
end

-- Load a batch of browsing icons (call once per frame while loading).
local function LoadBrowsingIconBatch()
    if browsingIconCache.loaded or not browsingIconCache.loading then
        return;
    end
    local ids = browsingIconCache.itemIds;
    if not ids then return; end
    local endIdx = math.min(browsingIconCache.loadIndex + browsingIconCache.batchSize, #ids);
    for i = browsingIconCache.loadIndex + 1, endIdx do
        local itemId = ids[i];
        if browsingIconCache.icons[itemId] == nil then
            local icon = textures:LoadItemIconFromMemory(itemId);
            -- Store the texture (or false as a negative cache entry)
            browsingIconCache.icons[itemId] = icon or false;
        end
    end
    browsingIconCache.loadIndex = endIdx;
    if browsingIconCache.loadIndex >= #ids then
        browsingIconCache.loaded = true;
        browsingIconCache.loading = false;
        browsingIconCache.itemIds = nil;
    end
end

-- Get a browsing icon from the pre-built cache (O(1), no D3D calls).
local function GetBrowsingIcon(itemId)
    local cached = browsingIconCache.icons[itemId];
    if cached and cached ~= false then
        return cached;
    end
    return nil;
end

-- Get browsing icon load progress (0-100).
local function GetBrowsingIconProgress()
    if browsingIconCache.loaded then return 100; end
    if not browsingIconCache.itemIds or #browsingIconCache.itemIds == 0 then return 0; end
    return math.floor((browsingIconCache.loadIndex / #browsingIconCache.itemIds) * 100);
end

-- Invalidate browsing icon cache (call when player inventory changes).
local function InvalidateBrowsingIconCache()
    browsingIconCache.icons = {};
    browsingIconCache.itemIds = nil;
    browsingIconCache.loadIndex = 0;
    browsingIconCache.loaded = false;
    browsingIconCache.loading = false;
    browsingIconCache.generation = browsingIconCache.generation + 1;
end
local function ResolveEditorPetCommandContext()
    NormalizePetAvatarFilter();
    local viewedJobId = ResolveEditorPetJobId();
        local avatarName = nil;
    local avatarList = GetOwnedAvatarList();
        if viewedJobId == petregistry.JOB_SMN then
            if selectedAvatarPalette then
            for _, owned in ipairs(avatarList) do
                if owned == selectedAvatarPalette then
                avatarName = selectedAvatarPalette;
                    break;
                end
            end
        end
        if not avatarName and petAvatarFilter > 1 then
                avatarName = avatarList[petAvatarFilter - 1];
            end
        if avatarName then
            local avatarValid = false;
            for _, owned in ipairs(avatarList) do
                if owned == avatarName then
                    avatarValid = true;
                    break;
                end
            end
            if not avatarValid then
                avatarName = nil;
            end
        end
    end
    local jugOwnedInternalNames = nil;
    local jugFilterInternal = nil;
    if viewedJobId == petregistry.JOB_BST then
        NormalizePetJugFilter();
        jugOwnedInternalNames = petregistry.GetOwnedJugPetInternalNames();
        jugFilterInternal = GetSelectedJugFilterInternalName();
    end
    return viewedJobId, avatarName, jugFilterInternal, jugOwnedInternalNames;
end

-- Build/return pet commands for the macro editor dropdown.
local function GetEditorPetCommands()
    local showAll = editorShowAll.pet[1];
    local cache = showAll and cachedPetCommandsShowAll or cachedPetCommands;
    if not cache then
        local viewedJobId, avatarName, jugFilterInternal, jugOwnedInternalNames =
            ResolveEditorPetCommandContext();
        if not petregistry.IsPetJob(viewedJobId) then
            cache = {};
        elseif showAll then
            cache = playerdata.GetEditorPetCommands(
                true, viewedJobId, avatarName, jugFilterInternal, jugOwnedInternalNames);
        else
            cache = GetPetCommandsForJob(
                viewedJobId, avatarName, jugFilterInternal, true, jugOwnedInternalNames);
        end
        if showAll then
            cachedPetCommandsShowAll = cache;
        else
            cachedPetCommands = cache;
        end
    end
    return cache or {};
end

-- Eagerly rebuild pet command cache (matches playerdata ForceRefresh* pattern)
local function ForceRefreshPetCommands()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if player then
        require('modules.hotbar.actiondb').InvalidateAbilityMeta();
        playerdata.RefreshEditorPetCommandCache(player, ResolveEditorPetJobId());
    end
    InvalidatePetCommandCache();
    return GetEditorPetCommands();
end
local function DrawShowAllCheckbox(idSuffix, state, onToggle)
    if imgui.Checkbox('Show All##' .. idSuffix, state) and onToggle then
        onToggle();
    end
end
RefreshEditorShowAll = function(kind)
    if kind == 'spells' then
        playerdata.ForceRefreshSpells(editorShowAll.spells[1]);
    elseif kind == 'abilities' then
        playerdata.ForceRefreshAbilities(editorShowAll.abilities[1]);
    elseif kind == 'weaponskills' then
        playerdata.ForceRefreshWeaponskills(editorShowAll.weaponskills[1]);
    else
        InvalidatePetCommandCache();
    end
end

-- Refresh macro editor dropdown data when a list is opened.
local DROPDOWN_REFRESH = {
    spells = function()
        RefreshEditorShowAll('spells');
    end,
    abilities = function()
        RefreshEditorShowAll('abilities');
    end,
    weaponskills = function()
        RefreshEditorShowAll('weaponskills');
    end,
    items = function()
        playerdata.ForceRefreshItems();
        InvalidateBrowsingIconCache();
    end,
    pet = function()
        cachedOwnedJugPets = nil;
        cachedOwnedJugPetsSignature = nil;
        if not petregistry.IsJugBrothCacheBuildActive() then
            petregistry.StartJugBrothCacheBuild();
        end
        ForceRefreshPetCommands();
    end,
    recastSource = function()
        RefreshEditorShowAll('spells');
        RefreshEditorShowAll('abilities');
        RefreshEditorShowAll('weaponskills');
        playerdata.ForceRefreshItems();
        ForceRefreshPetCommands();
        InvalidateBrowsingIconCache();
    end,
};
local function RefreshDropdownList(refreshType)
    local refresh = DROPDOWN_REFRESH[refreshType];
    if refresh then
        refresh();
    end
end
local ITEM_COMBO_WIDTH = 220;

-- Item section title with optional inventory quantity on the same line, right-aligned to combo width.
local function DrawItemLabelWithQuantity(label, itemId, itemName)
    imgui.TextColored(COLORS.goldDim, label);
    if not itemName or itemName == '' then return; end
    if slotrenderer == nil then
        local success, mod = pcall(require, 'modules.hotbar.slotrenderer');
        if success then slotrenderer = mod; end
    end
    if not slotrenderer or not slotrenderer.GetItemQuantity then return; end
    local resolvedItemId = itemId;
    if not resolvedItemId or resolvedItemId <= 0 then
        resolvedItemId = actiondb.GetItemId(itemName);
    end
    local qty = slotrenderer.GetItemQuantity(resolvedItemId, itemName) or 0;
    local color = qty == 0 and COLORS.danger or COLORS.textMuted;
    local text = 'x' .. qty .. ' in inventory';
    local textWidth = imgui.CalcTextSize(text);
    imgui.SameLine(ITEM_COMBO_WIDTH - textWidth);
    imgui.TextColored(color, text);
end
local function ResolveMacroStatusItemId(macro)
    if not macro then return nil; end
    if macro.actionType == 'item' then
        if macro.itemId and macro.itemId > 0 then
            return macro.itemId;
        end
        if macro.action and macro.action ~= '' then
            return actiondb.GetItemId(macro.action);
        end
    elseif macro.recastSourceType == 'item' then
        if macro.recastSourceItemId and macro.recastSourceItemId > 0 then
            return macro.recastSourceItemId;
        end
        if macro.recastSourceAction and macro.recastSourceAction ~= '' then
            return actiondb.GetItemId(macro.recastSourceAction);
        end
    end
    return nil;
end
local function EnsureSlotrenderer()
    if slotrenderer == nil then
        local success, mod = pcall(require, 'modules.hotbar.slotrenderer');
        if success then slotrenderer = mod; end
    end
    return slotrenderer;
end
local function DrawMacroBloodPactStatusOverlay(drawList, macro, x, y, size)
    if not drawList or not macro then return; end
    local renderer = EnsureSlotrenderer();
    if not renderer or not renderer.GetBloodPactNameFromBind then return; end
    local pactName = renderer.GetBloodPactNameFromBind(macro);
    if not pactName then return; end
    if renderer.DrawBloodPactStatusEffectOverlay then
        renderer.DrawBloodPactStatusEffectOverlay(drawList, x, y, size, pactName, 1.0);
                        end
                    end
local function DrawMacroStatusOverlay(drawList, macro, x, y, size)
    if not drawList or not macro then return; end
    local statusItemId = ResolveMacroStatusItemId(macro);
    if statusItemId then
        local renderer = EnsureSlotrenderer();
        if renderer and renderer.DrawItemStatusEffectOverlay then
            renderer.DrawItemStatusEffectOverlay(drawList, x, y, size, statusItemId, 1.0);
                end
            end
    DrawMacroBloodPactStatusOverlay(drawList, macro, x, y, size);
end

-- Push XIUI styling for combo popups
local function PushComboStyle()
    imgui.PushStyleColor(ImGuiCol_PopupBg, COLORS.bgDark);
    imgui.PushStyleColor(ImGuiCol_ChildBg, COLORS.bgDark);
    imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
    imgui.PushStyleColor(ImGuiCol_FrameBg, COLORS.bgMedium);
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered, COLORS.bgLight);
    imgui.PushStyleColor(ImGuiCol_Header, COLORS.bgLight);
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, COLORS.bgLighter);
    imgui.PushStyleColor(ImGuiCol_ScrollbarBg, COLORS.bgDark);
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrab, COLORS.bgLight);
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrabHovered, COLORS.bgLighter);
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrabActive, COLORS.gold);
end
local function PopComboStyle()
    imgui.PopStyleColor(11);
end

-- Status tier colors for macro editor "Show All" mode
local STATUS_COLORS = {
    ['have'] = { 0.35, 0.85, 0.35, 1.0 },
    ['learnable'] = { 0.95, 0.78, 0.25, 1.0 },
    ['unavailable'] = { 0.75, 0.30, 0.30, 1.0 },
};
local SPELL_TYPE_COLORS = {
    WhiteMagic = { 0.96, 0.92, 0.78, 1.0 },
    BlackMagic = { 0.75, 0.50, 0.90, 1.0 },
    BardSong = { 0.50, 0.80, 1.00, 1.0 },
    Ninjutsu = { 0.78, 0.60, 0.38, 1.0 },
    SummonerPact = { 0.50, 0.75, 0.38, 1.0 },
    BlueMagic = { 0.30, 0.70, 0.95, 1.0 },
    Geomancy = { 0.60, 0.85, 0.45, 1.0 },
    Trust = { 0.80, 0.80, 0.80, 1.0 },
};
local SPELL_TYPE_HEADERS = {
    WhiteMagic = 'White Magic',
    BlackMagic = 'Black Magic',
    BardSong = 'Songs',
    Ninjutsu = 'Ninjutsu',
    SummonerPact = 'Summoning',
    BlueMagic = 'Blue Magic',
    Geomancy = 'Geomancy',
    Trust = 'Trust',
};
local function FormatComboLevelPrefix(item)
    if item.levelLabel then
        return '[' .. item.levelLabel .. '] ';
    end
    if item.level then
        return '[' .. tostring(item.level) .. '] ';
    end
    return '';
end
local function DrawComboItemTooltip(item)
    local tip = item.statusReason or item.reason;
    if tip and imgui.IsItemHovered() then
        imgui.BeginTooltip();
        imgui.TextUnformatted(tip);
        imgui.EndTooltip();
    end
end

-- Draw a searchable dropdown combo box with XIUI styling
-- getItems: function returning the item list (refreshed each time the dropdown opens)
-- showIcons: if true, will attempt to load and display item icons
-- equipSlotFilter: if provided, only show items that can be equipped in this slot (e.g., 'main', 'head')
-- refreshType: when set, invalidates cached data when the dropdown is opened
-- emptyMessage: text shown when the list is empty after loading
-- useStatusColors: when true, color rows by item.status (have/learnable/unavailable)
local function DrawSearchableCombo(label, getItems, currentValue, onSelect, showIcons, equipSlotFilter, refreshType, emptyMessage, useStatusColors)
    local displayText = currentValue ~= '' and currentValue or 'Select...';

    -- Get the slot mask for filtering if provided
    local slotMask = equipSlotFilter and EQUIP_SLOT_MASKS[equipSlotFilter] or nil;
    local iconsReady = not showIcons;  -- true when icons aren't requested

    -- Apply XIUI styling to combo popup
    PushComboStyle();
    imgui.SetNextItemWidth(ITEM_COMBO_WIDTH);
    -- Use HeightLargest so popup fits our child window without its own scrollbar
    if imgui.BeginCombo(label, displayText, ImGuiComboFlags_HeightLargest) then
        if imgui.IsWindowAppearing() and refreshType then
            RefreshDropdownList(refreshType);
            dropdownLoadState[label] = editorFrameCounter;
        end
        local isLoading = dropdownLoadState[label] ~= nil
            and editorFrameCounter <= dropdownLoadState[label];
        local items = nil;
        if not isLoading then
            dropdownLoadState[label] = nil;
            items = getItems();
        end

        -- Kick off batched icon loading when the popup is open so we never
        -- call D3DXCreateTextureFromFileInMemoryEx inside the item loop.
        if showIcons and items and #items > 0 then
            if not browsingIconCache.loaded and not browsingIconCache.loading then
                StartBrowsingIconLoad(items);
            end
            if browsingIconCache.loading then
                LoadBrowsingIconBatch();
            end
            iconsReady = browsingIconCache.loaded;
        end

        -- Search input at top (fixed, not scrollable)
        imgui.SetNextItemWidth(200);
        imgui.PushStyleColor(ImGuiCol_Text, COLORS.text);
        imgui.InputText('##search' .. label, searchFilter, INPUT_BUFFER_SIZE);
        imgui.PopStyleColor();
        if searchFilter[1] == '' then
            -- Show placeholder hint
            local inputPos = {imgui.GetItemRectMin()};
            imgui.SetCursorScreenPos({inputPos[1] + 6, inputPos[2] + 3});
            imgui.TextColored(COLORS.textMuted, 'Type to search...');
        end
        imgui.Separator();
        if isLoading then
            imgui.TextColored(COLORS.textMuted, 'Loading...');
        elseif showIcons and items and #items > 0 and not iconsReady then
            local progress = GetBrowsingIconProgress();
            imgui.TextColored(COLORS.textMuted, string.format('Loading... %d%%', progress));
        elseif not items or #items == 0 then
            imgui.TextColored(COLORS.textMuted, emptyMessage or 'No matches');
        else
            -- Scrollable child region for items only
            local childHeight = 200;
            imgui.BeginChild('##comboScroll' .. label, {0, childHeight}, false);
            local filter = searchFilter[1]:lower();
            local matchCount = 0;
            local iconSize = 16;
            local lastType = nil;
            local isSearching = filter ~= '';
            for _, item in ipairs(items) do
                local itemName = item.name or '';

                -- Check if item passes equipment slot filter
                local passesSlotFilter = true;
                if slotMask and item.slots then
                    passesSlotFilter = bit.band(item.slots, slotMask) ~= 0;
                end
                if passesSlotFilter and (filter == '' or itemName:lower():find(filter, 1, true)) then
                    matchCount = matchCount + 1;
                    if not isSearching and item.type and item.type ~= lastType then
                        if lastType ~= nil then
                            imgui.Separator();
                        end
                        local headerLabel = SPELL_TYPE_HEADERS[item.type] or item.type;
                        local headerColor = SPELL_TYPE_COLORS[item.type] or COLORS.textDim;
                        imgui.TextColored(headerColor, headerLabel);
                        lastType = item.type;
                    end
                    local isSelected = currentValue == itemName;
                    local uid = item.id or matchCount;
                    local isSpellWithType = item.type and SPELL_TYPE_COLORS[item.type] ~= nil;
                    if isSpellWithType and not isSelected then
                        local levelColor = SPELL_TYPE_COLORS[item.type];
                        local nameColor = (useStatusColors and item.status and STATUS_COLORS[item.status]) or COLORS.text;
                        local rowW = math.max(60, ITEM_COMBO_WIDTH - 24);
                        local padY = 2;
                        local lineH = imgui.GetTextLineHeight();
                        local rowH = lineH + padY * 2;
                        imgui.InvisibleButton('##item' .. uid, {rowW, rowH});
                        local clicked = imgui.IsItemClicked();
                        local hovered = imgui.IsItemHovered();
                        local dl = imgui.GetWindowDrawList();
                        local rmin = {imgui.GetItemRectMin()};
                        local tx = rmin[1] + 6;
                        local ty = rmin[2] + padY;
                        local curX = tx;
                        local lvlStr = FormatComboLevelPrefix(item);
                        if lvlStr ~= '' then
                            dl:AddText({curX, ty}, imgui.GetColorU32(levelColor), lvlStr);
                            local lw = imgui.CalcTextSize(lvlStr);
                            curX = curX + ((type(lw) == 'table' and (lw[1] or lw.x)) or lw);
                        end
                        dl:AddText({curX, ty}, imgui.GetColorU32(nameColor), itemName);
                        if hovered then
                            DrawComboItemTooltip(item);
                        end
                        if clicked then
                            onSelect(item);
                            searchFilter[1] = '';
                            imgui.CloseCurrentPopup();
                        end
                    else
                    local textColor = nil;
                    if isSelected then
                        textColor = COLORS.gold;
                        elseif useStatusColors and item.status and STATUS_COLORS[item.status] then
                            textColor = STATUS_COLORS[item.status];
                    elseif item.usable then
                        textColor = COLORS.usable;
                    end
                    if textColor then
                        imgui.PushStyleColor(ImGuiCol_Text, textColor);
                    end
                    if showIcons and iconsReady and item.id then
                        local icon = GetBrowsingIcon(item.id);
                        if icon and icon.image then
                            local iconPtr = tonumber(ffi.cast("uint32_t", icon.image));
                            if iconPtr then
                                imgui.Image(iconPtr, {iconSize, iconSize});
                                imgui.SameLine();
                            end
                        end
                    end
                        local itemLabel = playerdata.FormatActionListLabel(item, itemName);
                    if item.count and item.count > 1 then
                        itemLabel = itemLabel .. ' x' .. item.count;
                    end
                        if imgui.Selectable(itemLabel .. '##item' .. uid, isSelected) then
                        onSelect(item);
                        searchFilter[1] = '';
                        imgui.CloseCurrentPopup();
                    end
                        DrawComboItemTooltip(item);
                    if textColor then
                        imgui.PopStyleColor();
                    end
                end
            end
            end
            if matchCount == 0 then
                imgui.TextColored(COLORS.textMuted, 'No matches');
            end
            imgui.EndChild();
        end
        imgui.EndCombo();
    else
        dropdownLoadState[label] = nil;
    end
    PopComboStyle();
end

-- ============================================
-- Macro Database Functions
-- ============================================

-- Get current effective type for the palette (selected type or player's current job)
-- Returns GLOBAL_MACRO_KEY for global macros, a job ID, or a composite key like "15:avatar:ifrit"
local function GetEffectivePaletteType()
    if selectedPaletteType then
        -- If Global is selected, return the global key
        if selectedPaletteType == GLOBAL_MACRO_KEY then
            return GLOBAL_MACRO_KEY;
        end
        -- If a valid job ID is selected
        if type(selectedPaletteType) == 'number' and selectedPaletteType > 0 then
            -- Check for SMN avatar-specific palette
            if selectedPaletteType == petregistry.JOB_SMN and selectedAvatarPalette then
                local avatarKey = petregistry.avatars[selectedAvatarPalette];
                if avatarKey then
                    return string.format('%d:avatar:%s', selectedPaletteType, avatarKey);
                end
            end
            return selectedPaletteType;
        end
    end
    -- Default to current player job
    return data.jobId or 1;
end

-- Get display name for a palette type key
local function GetPaletteDisplayName(typeKey)
    if typeKey == GLOBAL_MACRO_KEY then
        return 'Global';
    end
    if type(typeKey) == 'number' then
        return jobs[typeKey] or 'Unknown';
    end
    -- Composite key like "15:avatar:ifrit"
    if type(typeKey) == 'string' then
        local jobId, petType, petId = typeKey:match('^(%d+):([^:]+):(.+)$');
        if jobId and petType == 'avatar' and petId then
            -- Find avatar display name
            for name, key in pairs(petregistry.avatars) do
                if key == petId then
                    return string.format('%s (%s)', jobs[tonumber(jobId)] or 'SMN', name);
                end
            end
        end
    end
    return tostring(typeKey);
end

-- Sync palette to current player job (call on job change)
function M.SyncToCurrentJob()
    -- Only sync if not viewing Global - preserve Global selection across job changes
    if selectedPaletteType ~= GLOBAL_MACRO_KEY then
        selectedPaletteType = data.jobId or 1;
    end
    -- Clear spell/ability/item caches so they rebuild for new job
    playerdata.ClearDropdownCaches();
    InvalidateBrowsingIconCache();
    InvalidatePetCommandCache();
    petAvatarFilter = 1;
    petJugFilter = 1;
    cachedOwnedJugPets = nil;
    cachedOwnedJugPetsSignature = nil;
    selectedAvatarPalette = nil;
    -- Close editor window if open (spells/abilities are job-specific)
    if editingMacro then
        editingMacro = nil;
        isCreatingNew = false;
        searchFilter[1] = '';
        iconpicker.close();
    end
    -- Clear macro selection (macros are per-type)
    selectedMacroIndex = nil;
    -- If palette is open, immediately refresh the caches
    if paletteOpen then
        RefreshCachedLists();
    end
end

-- Clear pet commands cache (call on pet change for BST)
function M.ClearPetCommandsCache()
    InvalidatePetCommandCache();
end

-- Get the macro database for selected type (Global or job-specific)
function M.GetMacroDatabase()
    local typeKey = GetEffectivePaletteType();
    if not gConfig.macroDB then
        gConfig.macroDB = {};
    end
    if not gConfig.macroDB[typeKey] then
        gConfig.macroDB[typeKey] = {};
    end
    return gConfig.macroDB[typeKey], typeKey;
end

-- Add a new macro to the database
function M.AddMacro(macroData)
    local db, _ = M.GetMacroDatabase();

    -- Generate unique ID
    local maxId = 0;
    for _, macro in ipairs(db) do
        if macro.id and macro.id > maxId then
            maxId = macro.id;
        end
    end
    macroData.id = maxId + 1;
    table.insert(db, macroData);
    MarkHotbarDirty();
    data.MarkMacroLookupDirty();
    return macroData.id;
end

-- Escape special characters for use in Lua pattern matching
local function EscapePattern(str)
    return (str:gsub('([%%%^%$%(%)%.%[%]%*%+%-%?])', '%%%1'));
end

-- Build the next incremental copy name: "Stun" -> "Stun (1)", "Stun (1)" -> "Stun (1) (1)"
local function GetNextCopyDisplayName(sourceName, db)
    local prefix = sourceName or 'Macro';
    local pattern = '^' .. EscapePattern(prefix) .. ' %((%d+)%)%$';
    local maxN = 0;
    for _, macro in ipairs(db) do
        local name = macro.displayName or macro.action or '';
        local n = name:match(pattern);
        if n then
            maxN = math.max(maxN, tonumber(n));
        end
    end
    return prefix .. ' (' .. (maxN + 1) .. ')';
end

-- Add a macro copy to a specific palette type key (Global, job ID, etc.)
local function AddMacroToTypeKey(typeKey, macroData)
    if not gConfig.macroDB then
        gConfig.macroDB = {};
    end
    if not gConfig.macroDB[typeKey] then
        gConfig.macroDB[typeKey] = {};
    end
    local db = gConfig.macroDB[typeKey];
    local maxId = 0;
    for _, macro in ipairs(db) do
        if macro.id and macro.id > maxId then
            maxId = macro.id;
        end
    end
    local copy = deep_copy_table(macroData);
    copy.id = maxId + 1;
    table.insert(db, copy);
    SaveSettingsToDisk();
    data.MarkMacroLookupDirty();
    return copy.id;
end

-- Update an existing macro
function M.UpdateMacro(macroId, macroData)
    local db = M.GetMacroDatabase();
    for i, macro in ipairs(db) do
        if macro.id == macroId then
            macroData.id = macroId;  -- Preserve ID
            db[i] = macroData;
            MarkHotbarDirty();
            -- Defer icon cache clear to next frame start to avoid dropping
            -- D3D texture references while ImGui draw list still holds pointers
            ScheduleIconCacheClear();
            data.MarkMacroLookupDirty();
            return true;
        end
    end
    return false;
end

-- Clear all hotbar/crossbar slots that reference a specific macro ID
-- For Global macros, clears from ALL jobs' slot actions
local function ClearSlotsReferencingMacro(macroId, typeKey)
    local isGlobalMacro = (typeKey == GLOBAL_MACRO_KEY);

    -- Clear from all hotbars (1-6)
    for barIndex = 1, 6 do
        local configKey = 'hotbarBar' .. barIndex;
        if gConfig[configKey] and gConfig[configKey].slotActions then
            local barSettings = gConfig[configKey];

            -- Clear from ALL storage keys (macro could be on any job:subjob combination)
            for storageKey, jobSlotActions in pairs(barSettings.slotActions) do
                if jobSlotActions then
                    for slotIndex, slotAction in pairs(jobSlotActions) do
                        if slotAction and slotAction.macroRef == macroId then
                            jobSlotActions[slotIndex] = { cleared = true };
                        end
                    end
                end
            end
        end
    end

    -- Clear from crossbar (all combo modes, all storage keys)
    if gConfig.hotbarCrossbar and gConfig.hotbarCrossbar.slotActions then
        local crossbarSettings = gConfig.hotbarCrossbar;
        local comboModes = { 'L2', 'R2', 'L2R2', 'R2L2', 'L2x2', 'R2x2' };
        for storageKey, jobSlotActions in pairs(crossbarSettings.slotActions) do
            if jobSlotActions then
                for _, comboMode in ipairs(comboModes) do
                    local comboSlots = jobSlotActions[comboMode];
                    if comboSlots then
                        for slotIndex, slotAction in pairs(comboSlots) do
                            if slotAction and slotAction.macroRef == macroId then
                                comboSlots[slotIndex] = nil;
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Delete a macro from the database
function M.DeleteMacro(macroId)
    local db, typeKey = M.GetMacroDatabase();
    for i, macro in ipairs(db) do
        if macro.id == macroId then
            table.remove(db, i);
            -- Clear any hotbar/crossbar slots referencing this macro
            ClearSlotsReferencingMacro(macroId, typeKey);
            MarkHotbarDirty();
            -- Defer icon cache clear to next frame start
            ScheduleIconCacheClear();
            data.MarkMacroLookupDirty();
            return true;
        end
    end
    return false;
end

-- Get a macro by ID
function M.GetMacroById(macroId)
    local db = M.GetMacroDatabase();
    for _, macro in ipairs(db) do
        if macro.id == macroId then
            return macro;
        end
    end
    return nil;
end

-- ============================================
-- Drag & Drop Functions (using dragdrop library)
-- ============================================

-- Start dragging a macro from the palette
function M.StartDragMacro(macroIndex, macroData)
    -- Get icon for this macro
    local icon = actions.GetBindIcon(macroData);

    -- Include palette key in data so crossbar drops know which palette the macro came from
    local dragData = {};
    for k, v in pairs(macroData) do dragData[k] = v; end
    dragData.macroPaletteKey = GetEffectivePaletteType();
    dragdrop.StartDrag('macro', {
        data = dragData,
        macroIndex = macroIndex,
        label = macroData.displayName or macroData.action or 'Macro',
        icon = icon,
    });
end

-- Start dragging from a hotbar slot
function M.StartDragSlot(barIndex, slotIndex, slotData)
    -- Empty/orphaned slot - nothing to drag
    if not slotData then return; end

    -- Snapshot bind data: GetKeybindForSlot returns a pooled table reused each frame.
    local icon = actions.GetBindIcon(slotData);
    dragdrop.StartDrag('slot', {
        data = data.SnapshotSlotBind(slotData),
        barIndex = barIndex,
        slotIndex = slotIndex,
        label = slotData.displayName or slotData.action or 'Slot',
        icon = icon,
    });
end

-- Clear drag state
function M.ClearDrag()
    dragdrop.CancelDrag();
end

-- Get current drag state (compatibility wrapper)
function M.GetDragState()
    local payload = dragdrop.GetPayload();
    if payload then
        return {
            isDragging = dragdrop.IsDragging(),
            sourceType = payload.type,
            macroIndex = payload.macroIndex,
            barIndex = payload.barIndex,
            slotIndex = payload.slotIndex,
            macroData = payload.data,
        };
    end
    return {
        isDragging = false,
        sourceType = nil,
        macroIndex = nil,
        barIndex = nil,
        slotIndex = nil,
        macroData = nil,
    };
end

-- Check if currently dragging
function M.IsDragging()
    return dragdrop.IsDragging();
end

-- Handle drop on a hotbar slot (called by dragdrop.DropZone onDrop callback)
function M.HandleDropOnSlot(payload, targetBarIndex, targetSlotIndex)
    if not payload then
        return false;
    end
    local configKey = 'hotbarBar' .. targetBarIndex;

    -- Ensure config structure exists
    if not gConfig[configKey] then
        gConfig[configKey] = {};
    end
    -- Use pet-aware storage key (handles global, job-specific, and pet palettes)
    local storageKey = data.GetStorageKeyForBar(targetBarIndex);
    local jobSlotActions = ensureSlotActionsStructure(gConfig[configKey], storageKey);
    if payload.type == 'macro' then
        -- Dragging from palette to slot - store only the macro reference.
        -- macroDB is the single source of truth for action/macroText/displayName/etc.
        local macroData = payload.data;
        if macroData then
            jobSlotActions[targetSlotIndex] = data.BuildSlotDataForWrite({
                macroRef = macroData.id,
                macroPaletteKey = macroData.macroPaletteKey or GetEffectivePaletteType(),
            });
            MarkHotbarDirty();
        end
    elseif payload.type == 'slot' then
        -- Dragging from slot to slot (swap or move)
        local sourceBarIndex = payload.barIndex;
        local sourceSlotIndex = payload.slotIndex;
        local sourceConfigKey = 'hotbarBar' .. sourceBarIndex;
        local sourceData = data.BuildSlotDataForWrite(payload.data);

        -- Get target slot data
        local targetBind = data.GetKeybindForSlot(targetBarIndex, targetSlotIndex);
        local targetData;
        if targetBind then
            targetData = data.BuildSlotDataForWrite(targetBind);
        else
            -- Target slot is empty - mark as cleared
            targetData = { cleared = true };
        end

        -- Ensure source config structure exists
        if not gConfig[sourceConfigKey] then
            gConfig[sourceConfigKey] = {};
        end
        -- Use pet-aware storage key for source bar
        local sourceStorageKey = data.GetStorageKeyForBar(sourceBarIndex);
        local sourceJobSlotActions = ensureSlotActionsStructure(gConfig[sourceConfigKey], sourceStorageKey);

        -- Swap the slots
        jobSlotActions[targetSlotIndex] = sourceData;
        sourceJobSlotActions[sourceSlotIndex] = targetData;
        MarkHotbarDirty();
    elseif payload.type == 'crossbar_slot' then
        -- Dragging from crossbar to hotbar (one-way copy, doesn't clear source)
        if payload.data then
            jobSlotActions[targetSlotIndex] = data.BuildSlotDataForWrite(payload.data);
            MarkHotbarDirty();
        end
    end

    -- Clear icon cache for affected slots (targeted - fast)
    ClearSlotIconCache(targetBarIndex, targetSlotIndex);
    -- For slot swaps, also clear the source slot
    if payload.type == 'slot' then
        ClearSlotIconCache(payload.barIndex, payload.slotIndex);
    end
    return true;
end

-- Clear a hotbar slot
function M.ClearSlot(barIndex, slotIndex)
    -- Use the pet-aware clear function from data.lua
    data.ClearSlotData(barIndex, slotIndex);
    -- Clear icon cache for this slot (targeted - fast)
    ClearSlotIconCache(barIndex, slotIndex);
end

-- ============================================
-- Palette Window
-- ============================================

function M.OpenPalette()
    paletteOpen = true;
    selectedMacroIndex = nil;
    editingMacro = nil;
    isCreatingNew = false;

    -- Sync to current player job when opening (unless Global was selected)
    if selectedPaletteType ~= GLOBAL_MACRO_KEY then
        selectedPaletteType = data.jobId or 1;
    end

    -- Refresh spell/ability/weaponskill caches
    RefreshCachedLists();
end
function M.ClosePalette()
    -- Save any pending hotbar changes when user closes the palette
    if hotbarDataDirty then
        SaveSettingsToDisk();
        hotbarDataDirty = false;
    end
    paletteOpen = false;
    selectedMacroIndex = nil;
    editingMacro = nil;
    isCreatingNew = false;
    currentPalettePage = 1;  -- Reset to page 1
    copyMacroDialogOpen = false;
    copyMacroSource = nil;
    InvalidateBrowsingIconCache();
end
function M.IsPaletteOpen()
    return paletteOpen;
end
function M.TogglePalette()
    if paletteOpen then
        M.ClosePalette();
    else
        M.OpenPalette();
    end
end

-- Draw a single macro tile (used in palette)
local function DrawMacroTile(macro, index, x, y, size)
    local isSelected = selectedMacroIndex == index;
    local isHovered = false;

    -- Set cursor position
    imgui.SetCursorScreenPos({x, y});

    -- Draw button with XIUI styling
    if isSelected then
        -- Selected state: gold tinted
        imgui.PushStyleColor(ImGuiCol_Button, {0.15, 0.13, 0.08, 0.95});
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, {0.2, 0.17, 0.1, 0.95});
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.bgLighter);
    else
        -- Normal state: dark with subtle highlight
        imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgDark);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.bgMedium);
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.bgLight);
    end
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 4);
    imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 1);
    imgui.PushStyleColor(ImGuiCol_Border, isSelected and COLORS.gold or COLORS.border);
    local buttonId = string.format('##macrotile%d', index);
    if imgui.Button(buttonId, {size, size}) then
        selectedMacroIndex = index;
    end
    imgui.PopStyleColor(4);
    imgui.PopStyleVar(2);
    isHovered = imgui.IsItemHovered();

    -- Draw icon if available, otherwise show abbreviated text
    local icon = actions.GetBindIcon(macro);
    local iconRendered = false;
    if icon and icon.image then
        local drawList = imgui.GetWindowDrawList();
        if drawList then
            local iconSize = size - 8;  -- Slightly smaller than tile
            local iconX = x + 4;
            local iconY = y + 4;
            local iconPtr = tonumber(ffi.cast("uint32_t", icon.image));
            if iconPtr and iconPtr ~= 0 then
                drawList:AddImage(
                    iconPtr,
                    {iconX, iconY},
                    {iconX + iconSize, iconY + iconSize}
                );
                iconRendered = true;
            end
        end
    end
    do
        local tileDrawList = imgui.GetWindowDrawList();
        if tileDrawList then
            DrawMacroStatusOverlay(tileDrawList, macro, x, y, size);
        end
    end

    -- No icon rendered - show abbreviated action name
    if not iconRendered then
        local drawList = GetUIDrawList();
        if drawList then
            local abbr = GetActionAbbreviation(macro);
            local textSize = imgui.CalcTextSize(abbr);
            local textX = x + (size - textSize) / 2;
            local textY = y + (size - 14) / 2;
            local textColor = imgui.GetColorU32(COLORS.gold);
            drawList:AddText({textX, textY}, textColor, abbr);
        end
    end

    -- Handle drag source - use custom dragdrop library
    if imgui.IsItemActive() and imgui.IsMouseDragging(0, 3) then
        if not dragdrop.IsDragging() and not dragdrop.IsDragPending() then
            M.StartDragMacro(index, macro);
        end
    end

    -- Tooltip with full info
    if isHovered then
        imgui.PushStyleColor(ImGuiCol_PopupBg, COLORS.bgDark);
        imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {8, 6});
        imgui.BeginTooltip();
        imgui.TextColored(COLORS.gold, macro.displayName or macro.action or 'Unknown');
        imgui.Spacing();
        imgui.TextColored(COLORS.textDim, 'Type: ' .. (ACTION_TYPE_LABELS[macro.actionType] or macro.actionType or '?'));
        if macro.actionType ~= 'macro' and macro.target then
            local formattedTarget = FormatTargetForDisplay(macro.target);
            if formattedTarget then
                imgui.TextColored(COLORS.textDim, 'Target: ' .. formattedTarget);
            end
        end
        imgui.Spacing();
        imgui.TextColored(COLORS.textMuted, 'Drag to hotbar slot');
        imgui.EndTooltip();
        imgui.PopStyleVar();
        imgui.PopStyleColor(2);
    end
    return isHovered;
end

-- Apply XIUI window styling
local function PushWindowStyle()
    imgui.PushStyleColor(ImGuiCol_WindowBg, COLORS.bgDark);
    imgui.PushStyleColor(ImGuiCol_TitleBg, COLORS.bgMedium);
    imgui.PushStyleColor(ImGuiCol_TitleBgActive, COLORS.bgLight);
    imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
    imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgMedium);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.bgLight);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.bgLighter);
    imgui.PushStyleColor(ImGuiCol_FrameBg, COLORS.bgDark);
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered, COLORS.bgMedium);
    imgui.PushStyleColor(ImGuiCol_FrameBgActive, COLORS.bgLight);
    imgui.PushStyleColor(ImGuiCol_Header, COLORS.bgMedium);
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, COLORS.bgLight);
    imgui.PushStyleColor(ImGuiCol_HeaderActive, COLORS.bgLighter);
    imgui.PushStyleColor(ImGuiCol_Separator, COLORS.border);
    imgui.PushStyleColor(ImGuiCol_Text, COLORS.text);
    -- Scrollbar colors
    imgui.PushStyleColor(ImGuiCol_ScrollbarBg, COLORS.bgDark);
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrab, COLORS.bgLight);
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrabHovered, COLORS.bgLighter);
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrabActive, COLORS.gold);
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 4);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 3);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {10, 10});
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {6, 4});
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {8, 6});
end
local function PopWindowStyle()
    imgui.PopStyleVar(5);
    imgui.PopStyleColor(19);  -- 15 base + 4 scrollbar colors
end

-- Build job list for dropdown
local JOB_LIST = {};
local JOB_ID_MAP = {};
for jobId, jobName in pairs(jobs) do
    table.insert(JOB_LIST, { id = jobId, name = jobName });
end
table.sort(JOB_LIST, function(a, b) return a.id < b.id; end);
for i, job in ipairs(JOB_LIST) do
    JOB_ID_MAP[job.id] = i;
end

-- Build destination options for the copy macro dialog
local copyTargetOptions = nil;
local function GetCopyTargetOptions()
    if copyTargetOptions then
        return copyTargetOptions;
    end
    copyTargetOptions = {
        { key = GLOBAL_MACRO_KEY, label = 'Global' },
    };
    for _, job in ipairs(JOB_LIST) do
        copyTargetOptions[#copyTargetOptions + 1] = {
            key = job.id,
            label = job.name,
        };
    end
    return copyTargetOptions;
end
local function DrawCopyMacroDialog()
    if not copyMacroDialogOpen or not copyMacroSource then
        return;
    end
    local isOpen = { true };
    imgui.SetNextWindowSize({320, 170}, ImGuiCond_Appearing);
    PushWindowStyle();
    if imgui.Begin('Copy Macro###CopyMacroDialog', isOpen, ImGuiWindowFlags_NoCollapse) then
        local macroName = copyMacroSource.displayName or copyMacroSource.action or 'Macro';
        imgui.TextColored(COLORS.textDim, 'Copy "' .. macroName .. '" to:');
        imgui.Spacing();
        local targets = GetCopyTargetOptions();
        local selectedTarget = targets[copyTargetIndex[1]] or targets[1];
        PushComboStyle();
        imgui.SetNextItemWidth(260);
        if imgui.BeginCombo('##copyTarget', selectedTarget.label) then
            for i, target in ipairs(targets) do
                local isSelected = copyTargetIndex[1] == i;
                if isSelected then imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold); end
                if imgui.Selectable(target.label, isSelected) then
                    copyTargetIndex[1] = i;
                end
                if isSelected then imgui.PopStyleColor(); end
            end
            imgui.EndCombo();
        end
        PopComboStyle();
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();
        imgui.PushStyleColor(ImGuiCol_Button, COLORS.success);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, {0.5, 0.8, 0.5, 1.0});
        imgui.PushStyleColor(ImGuiCol_ButtonActive, {0.6, 0.9, 0.6, 1.0});
        imgui.PushStyleColor(ImGuiCol_Text, {0.1, 0.1, 0.1, 1.0});
        if imgui.Button('Copy', {90, 28}) then
            local target = targets[copyTargetIndex[1]] or targets[1];
            local copy = deep_copy_table(copyMacroSource);
            copy.id = nil;
            local currentTypeKey = GetEffectivePaletteType();
            if target.key == currentTypeKey then
                local baseName = copy.displayName or copy.action or 'Macro';
                local targetDb = gConfig.macroDB and gConfig.macroDB[target.key] or {};
                copy.displayName = GetNextCopyDisplayName(baseName, targetDb);
            end
            AddMacroToTypeKey(target.key, copy);
            copyMacroDialogOpen = false;
            copyMacroSource = nil;
        end
        imgui.PopStyleColor(4);
        imgui.SameLine();
        if imgui.Button('Cancel', {90, 28}) then
            copyMacroDialogOpen = false;
            copyMacroSource = nil;
        end
    end
    imgui.End();
    PopWindowStyle();
    if not isOpen[1] then
        copyMacroDialogOpen = false;
        copyMacroSource = nil;
    end
end

-- Draw the palette window
function M.DrawPalette()
    if not paletteOpen then
        return;
    end

    -- Continuously check for job changes while palette is open
    -- This catches cases where job changed but cache wasn't refreshed properly
    RefreshCachedLists();

    -- Initialize selectedPaletteType to current job if not set
    if not selectedPaletteType then
        selectedPaletteType = data.jobId or 1;
    end
    local db, typeKey = M.GetMacroDatabase();
    local isGlobal = (typeKey == GLOBAL_MACRO_KEY);
    local typeName = GetPaletteDisplayName(typeKey);
    local currentPlayerJob = data.jobId or 1;
    -- For SMN with avatar selected, check base job ID
    local baseJobId = type(typeKey) == 'number' and typeKey or tonumber(tostring(typeKey):match('^(%d+)'));
    local isViewingCurrentJob = (not isGlobal and baseJobId == currentPlayerJob);

    -- Calculate pagination
    local totalMacros = #db;
    local totalPages = math.max(1, math.ceil(totalMacros / PALETTE_MACROS_PER_PAGE));

    -- Clamp current page to valid range
    if currentPalettePage > totalPages then
        currentPalettePage = totalPages;
    end
    if currentPalettePage < 1 then
        currentPalettePage = 1;
    end

    -- Calculate how many macros/rows on this page
    local startIdx = (currentPalettePage - 1) * PALETTE_MACROS_PER_PAGE + 1;
    local endIdx = math.min(startIdx + PALETTE_MACROS_PER_PAGE - 1, totalMacros);
    local macrosOnPage = math.max(0, endIdx - startIdx + 1);
    local rowsOnPage = math.max(1, math.ceil(macrosOnPage / PALETTE_COLUMNS));

    -- Calculate grid dimensions
    local gridWidth = PALETTE_COLUMNS * PALETTE_TILE_SIZE + (PALETTE_COLUMNS - 1) * PALETTE_TILE_GAP;
    local gridHeight = rowsOnPage * PALETTE_TILE_SIZE + (rowsOnPage - 1) * PALETTE_TILE_GAP;
    local windowFlags = bit.bor(
        ImGuiWindowFlags_NoCollapse,
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoScrollbar
    );
    local isOpen = { true };

    -- Apply XIUI styling
    PushWindowStyle();
    if imgui.Begin('Macro Palette###MacroPalette', isOpen, windowFlags) then
        -- Header with gold accent
        imgui.TextColored(COLORS.gold, 'Drag macros to your hotbar slots');
        imgui.Spacing();

        -- Type selector row
        imgui.TextColored(COLORS.textDim, 'Type:');
        imgui.SameLine();

        -- Style the combo popup
        PushComboStyle();
        imgui.PushItemWidth(100);

        -- Helper to get macro count for a type (Global or job ID)
        local function getMacroCount(key)
            if gConfig.macroDB and gConfig.macroDB[key] then
                return #gConfig.macroDB[key];
            end
            return 0;
        end

        -- Build display label with macro count
        local macroCount = getMacroCount(typeKey);
        local displayLabel = macroCount > 0 and string.format('%s (%d)', typeName, macroCount) or typeName;
        if imgui.BeginCombo('##TypeSelect', displayLabel, ImGuiComboFlags_None) then
            -- Global option first
            local globalSelected = isGlobal;
            local globalMacroCount = getMacroCount(GLOBAL_MACRO_KEY);
            local globalLabel = 'Global';
            if globalMacroCount > 0 then
                globalLabel = string.format('Global (%d)', globalMacroCount);
            end

            -- Highlight Global if it has macros
            if globalMacroCount > 0 and not globalSelected then
                imgui.PushStyleColor(ImGuiCol_Text, COLORS.text);
            elseif globalSelected then
                imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold);
            else
                imgui.PushStyleColor(ImGuiCol_Text, COLORS.textDim);
            end
            if imgui.Selectable(globalLabel, globalSelected) then
                selectedPaletteType = GLOBAL_MACRO_KEY;
                selectedAvatarPalette = nil;
                selectedMacroIndex = nil;
                currentPalettePage = 1;
                -- Clear caches to force refresh
                playerdata.ClearDropdownCaches();
                InvalidateBrowsingIconCache();
                InvalidatePetCommandCache();
                petAvatarFilter = 1;
                petJugFilter = 1;
                cachedOwnedJugPets = nil;
                cachedOwnedJugPetsSignature = nil;
            end
            imgui.PopStyleColor();
            if globalSelected then
                imgui.SetItemDefaultFocus();
            end

            -- Separator between Global and jobs
            imgui.Separator();

            -- Job options
            for i, job in ipairs(JOB_LIST) do
                local isSelected = (not isGlobal and job.id == typeKey);
                local jobMacroCount = getMacroCount(job.id);

                -- Build label with indicators
                local label = job.name;

                -- Add macro count if > 0
                if jobMacroCount > 0 then
                    label = string.format('%s (%d)', label, jobMacroCount);
                end

                -- Add main job indicator
                if job.id == currentPlayerJob then
                    label = label .. '  *';
                end

                -- Add subjob indicator
                if job.id == data.subjobId then
                    label = label .. '  /sub';
                end

                -- Highlight jobs with macros
                if jobMacroCount > 0 and not isSelected then
                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.text);
                elseif isSelected then
                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold);
                else
                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.textDim);
                end
                if imgui.Selectable(label, isSelected) then
                    selectedPaletteType = job.id;
                    selectedAvatarPalette = nil;  -- Clear avatar selection when switching jobs
                    selectedMacroIndex = nil;  -- Clear selection when switching types
                    currentPalettePage = 1;    -- Reset to page 1 when switching types
                    -- Clear caches to force refresh
                    playerdata.ClearDropdownCaches();
                    InvalidateBrowsingIconCache();
                    InvalidatePetCommandCache();
                    petAvatarFilter = 1;
                    petJugFilter = 1;
                    cachedOwnedJugPets = nil;
                    cachedOwnedJugPetsSignature = nil;
                end
                imgui.PopStyleColor();
                if isSelected then
                    imgui.SetItemDefaultFocus();
                end
            end
            imgui.EndCombo();
        end
        imgui.PopItemWidth();
        PopComboStyle();

        -- Avatar sub-palette dropdown (only for SMN)
        -- Use selectedPaletteType (the job ID) not typeKey (which may be composite like "15:avatar:ifrit")
        if not isGlobal and selectedPaletteType == petregistry.JOB_SMN then
            imgui.SameLine();
            local avatarList = GetOwnedAvatarList();
            local avatarLabel = selectedAvatarPalette or 'Base SMN';

            -- Count macros for current avatar selection
            local avatarMacroCount = 0;
            local currentAvatarKey = GetEffectivePaletteType();
            if gConfig.macroDB and gConfig.macroDB[currentAvatarKey] then
                avatarMacroCount = #gConfig.macroDB[currentAvatarKey];
            end
            if avatarMacroCount > 0 then
                avatarLabel = string.format('%s (%d)', avatarLabel, avatarMacroCount);
            end
            PushComboStyle();
            imgui.SetNextItemWidth(140);
            if imgui.BeginCombo('##AvatarPalette', avatarLabel, ImGuiComboFlags_None) then
                -- Base SMN option
                local isBaseSelected = selectedAvatarPalette == nil;
                local baseMacroCount = 0;
                if gConfig.macroDB and gConfig.macroDB[petregistry.JOB_SMN] then
                    baseMacroCount = #gConfig.macroDB[petregistry.JOB_SMN];
                end
                local baseLabel = baseMacroCount > 0 and string.format('Base SMN (%d)', baseMacroCount) or 'Base SMN';
                if isBaseSelected then
                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold);
                elseif baseMacroCount > 0 then
                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.text);
                else
                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.textDim);
                end
                if imgui.Selectable(baseLabel, isBaseSelected) then
                    selectedAvatarPalette = nil;
                    selectedMacroIndex = nil;
                    currentPalettePage = 1;
                    InvalidatePetCommandCache();  -- Refresh pet commands for new avatar
                end
                imgui.PopStyleColor();
                if isBaseSelected then
                    imgui.SetItemDefaultFocus();
                end
                imgui.Separator();

                -- Avatar options
                for _, avatar in ipairs(avatarList) do
                    local isSelected = selectedAvatarPalette == avatar;
                    local avatarKey = petregistry.avatars[avatar];
                    local fullKey = string.format('%d:avatar:%s', petregistry.JOB_SMN, avatarKey);
                    local macroCount = 0;
                    if gConfig.macroDB and gConfig.macroDB[fullKey] then
                        macroCount = #gConfig.macroDB[fullKey];
                    end
                    local label = macroCount > 0 and string.format('%s (%d)', avatar, macroCount) or avatar;
                    if isSelected then
                        imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold);
                    elseif macroCount > 0 then
                        imgui.PushStyleColor(ImGuiCol_Text, COLORS.text);
                    else
                        imgui.PushStyleColor(ImGuiCol_Text, COLORS.textDim);
                    end
                    if imgui.Selectable(label, isSelected) then
                        selectedAvatarPalette = avatar;
                        selectedMacroIndex = nil;
                        currentPalettePage = 1;
                        InvalidatePetCommandCache();  -- Refresh pet commands for new avatar
                    end
                    imgui.PopStyleColor();
                    if isSelected then
                        imgui.SetItemDefaultFocus();
                    end
                end
                imgui.EndCombo();
            end
            PopComboStyle();
        end

        -- Pet Palette section (only show if selected palette type is a pet job AND any bar has petAware enabled)
        local isPetJob = false;
        if selectedPaletteType and type(selectedPaletteType) == 'number' then
            isPetJob = petregistry.IsPetJob(selectedPaletteType);
        end
        local hasPetAwareBar = false;
        if isPetJob then
            for barIndex = 1, data.NUM_BARS do
                local barSettings = data.GetBarSettings(barIndex);
                if barSettings and barSettings.petAware then
                    hasPetAwareBar = true;
                    break;
                end
            end
        end
        if hasPetAwareBar then
            imgui.Spacing();
            imgui.Separator();
            imgui.Spacing();

            -- Show current pet detection
            local currentPetKey = petpalette.GetCurrentPetKey();
            local petDisplayName = currentPetKey and petregistry.GetDisplayNameForKey(currentPetKey) or 'No Pet';
            imgui.TextColored(COLORS.textDim, 'Active Pet:');
            imgui.SameLine();
            if currentPetKey then
                imgui.TextColored({0.5, 1.0, 0.8, 1.0}, petDisplayName);
            else
                imgui.TextColored(COLORS.textMuted, petDisplayName);
            end

            -- Show per-bar palette status with dropdown
            imgui.Spacing();
            local allSummons = petregistry.GetAllSummonsList();
            for barIndex = 1, data.NUM_BARS do
                local barSettings = data.GetBarSettings(barIndex);
                if barSettings and barSettings.petAware and barSettings.enabled then
                    local paletteName = petpalette.GetPaletteDisplayName(barIndex, data.jobId);
                    local hasOverride = petpalette.HasManualOverride(barIndex);
                    imgui.TextColored(COLORS.textDim, string.format('Bar %d:', barIndex));
                    imgui.SameLine();

                    -- Dropdown for palette selection
                    local currentLabel = hasOverride and paletteName or 'Automatic';
                    PushComboStyle();
                    imgui.SetNextItemWidth(130);
                    if imgui.BeginCombo('##petPalette' .. barIndex, currentLabel, ImGuiComboFlags_None) then
                        -- Automatic option (first)
                        local isAutoSelected = not hasOverride;
                        if isAutoSelected then
                            imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold);
                        else
                            imgui.PushStyleColor(ImGuiCol_Text, COLORS.text);
                        end
                        if imgui.Selectable('Automatic', isAutoSelected) then
                            petpalette.SetPalette(barIndex, nil);
                            ScheduleIconCacheClear(true);
                        end
                        imgui.PopStyleColor();
                        if isAutoSelected then
                            imgui.SetItemDefaultFocus();
                        end
                        imgui.Separator();

                        -- Avatars section (owned only)
                        imgui.TextColored(COLORS.textDim, 'Avatars');
                        for _, avatarName in ipairs(GetOwnedAvatarList()) do
                            local petKey = petregistry.GetPetKeyForSummon(avatarName);
                            local isSelected = hasOverride and petpalette.GetPaletteDisplayName(barIndex, data.jobId) == avatarName;
                                if isSelected then
                                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold);
                                else
                                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.text);
                                end
                            if imgui.Selectable('  ' .. avatarName, isSelected) then
                                    petpalette.SetPalette(barIndex, petKey);
                                    ScheduleIconCacheClear(true);
                                end
                                imgui.PopStyleColor();
                                if isSelected then
                                    imgui.SetItemDefaultFocus();
                                end
                            end
                        imgui.Separator();

                        -- Spirits section
                        imgui.TextColored(COLORS.textDim, 'Spirits');
                        for _, summon in ipairs(allSummons) do
                            if summon.category == 'spirit' then
                                local petKey = petregistry.GetPetKeyForSummon(summon.name);
                                local isSelected = hasOverride and petpalette.GetPaletteDisplayName(barIndex, data.jobId) == summon.name;
                                if isSelected then
                                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold);
                                else
                                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.text);
                                end
                                if imgui.Selectable('  ' .. summon.name, isSelected) then
                                    petpalette.SetPalette(barIndex, petKey);
                                    ScheduleIconCacheClear(true);
                                end
                                imgui.PopStyleColor();
                                if isSelected then
                                    imgui.SetItemDefaultFocus();
                                end
                            end
                        end
                        imgui.EndCombo();
                    end
                    PopComboStyle();
                end
            end
        end
        imgui.Spacing();

        -- Button row with XIUI button styling
        imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgLight);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.bgLighter);
        imgui.PushStyleColor(ImGuiCol_ButtonActive, {0.2, 0.18, 0.15, 1.0});
        imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 1);
        imgui.PushStyleColor(ImGuiCol_Border, COLORS.gold);
        imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold);
        if imgui.Button('+ New Macro', {115, 26}) then
            isCreatingNew = true;
            editingMacro = {
                actionType = 'ma',
                action = '',
                target = 't',
                displayName = '',
            };
            selectedMacroIndex = nil;
        end
        imgui.PopStyleColor(5);
        imgui.PopStyleVar();
        imgui.SameLine();

        -- Edit/Delete buttons (always visible, disabled when no selection)
        local hasSelection = selectedMacroIndex and db[selectedMacroIndex];
        if not hasSelection then
            imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.4);
        end
        if imgui.Button('Edit', {60, 26}) and hasSelection then
            editingMacro = deep_copy_table(db[selectedMacroIndex]);
            isCreatingNew = false;
        end
        imgui.SameLine();
        if imgui.Button('Copy', {60, 26}) and hasSelection then
            copyMacroSource = deep_copy_table(db[selectedMacroIndex]);
            copyTargetIndex[1] = 1;
            local currentTypeKey = GetEffectivePaletteType();
            for i, target in ipairs(GetCopyTargetOptions()) do
                if target.key == currentTypeKey then
                    copyTargetIndex[1] = i;
                    break;
                end
            end
            copyMacroDialogOpen = true;
        end
        imgui.SameLine();

        -- Delete button with danger styling (or dimmed when disabled)
        if hasSelection then
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.dangerDim);
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.danger);
            imgui.PushStyleColor(ImGuiCol_ButtonActive, {0.9, 0.35, 0.35, 1.0});
        end
        if imgui.Button('Delete', {60, 26}) and hasSelection then
            M.DeleteMacro(db[selectedMacroIndex].id);
            selectedMacroIndex = nil;
        end
        if hasSelection then
            imgui.PopStyleColor(3);
        end
        if not hasSelection then
            imgui.PopStyleVar();
        end
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        -- Macro grid
        if #db == 0 then
            imgui.TextColored(COLORS.textDim, 'No macros yet.');
            imgui.TextColored(COLORS.textMuted, 'Click "+ New Macro" to create one.');
        else
            -- Draw grid row by row using standard ImGui layout
            for row = 0, rowsOnPage - 1 do
                for col = 0, PALETTE_COLUMNS - 1 do
                    local idx = startIdx + row * PALETTE_COLUMNS + col;
                    if idx <= endIdx then
                        local macro = db[idx];
                        if macro then
                            if col > 0 then
                                imgui.SameLine(0, PALETTE_TILE_GAP);
                            end

                            -- Draw the tile inline
                            local isSelected = selectedMacroIndex == idx;
                            if isSelected then
                                imgui.PushStyleColor(ImGuiCol_Button, {0.15, 0.13, 0.08, 0.95});
                                imgui.PushStyleColor(ImGuiCol_ButtonHovered, {0.2, 0.17, 0.1, 0.95});
                                imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.bgLighter);
                            else
                                imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgDark);
                                imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.bgMedium);
                                imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.bgLight);
                            end
                            imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 4);
                            imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 1);
                            imgui.PushStyleColor(ImGuiCol_Border, isSelected and COLORS.gold or COLORS.border);
                            local buttonId = string.format('##macrotile%d', idx);
                            local buttonPos = {imgui.GetCursorScreenPos()};
                            if imgui.Button(buttonId, {PALETTE_TILE_SIZE, PALETTE_TILE_SIZE}) then
                                selectedMacroIndex = idx;
                            end
                            imgui.PopStyleColor(4);
                            imgui.PopStyleVar(2);

                            -- Draw icon on top of button, or abbreviation if no icon
                            local icon = actions.GetBindIcon(macro);
                            local iconRendered = false;
                            if icon and icon.image then
                                local drawList = imgui.GetWindowDrawList();
                                if drawList then
                                    local iconSize = PALETTE_TILE_SIZE - 8;
                                    local iconX = buttonPos[1] + 4;
                                    local iconY = buttonPos[2] + 4;
                                    local iconPtr = tonumber(ffi.cast("uint32_t", icon.image));
                                    if iconPtr and iconPtr ~= 0 then
                                        drawList:AddImage(iconPtr, {iconX, iconY}, {iconX + iconSize, iconY + iconSize});
                                        iconRendered = true;
                                    end
                                end
                            end

                            -- No icon - show abbreviated action name
                            if not iconRendered then
                                local drawList = imgui.GetWindowDrawList();
                                if drawList then
                                    local abbr = GetActionAbbreviation(macro);
                                    local textSize = imgui.CalcTextSize(abbr);
                                    local textX = buttonPos[1] + (PALETTE_TILE_SIZE - textSize) / 2;
                                    local textY = buttonPos[2] + (PALETTE_TILE_SIZE - 14) / 2;
                                    local textColor = imgui.GetColorU32(COLORS.gold);
                                    drawList:AddText({textX, textY}, textColor, abbr);
                                end
                            end
                            do
                                local drawList = imgui.GetWindowDrawList();
                                if drawList then
                                    DrawMacroStatusOverlay(
                                        drawList, macro, buttonPos[1], buttonPos[2], PALETTE_TILE_SIZE
                                    );
                                end
                            end

                            -- Handle drag
                            if imgui.IsItemActive() and imgui.IsMouseDragging(0, 3) then
                                if not dragdrop.IsDragging() and not dragdrop.IsDragPending() then
                                    M.StartDragMacro(idx, macro);
                                end
                            end

                            -- Tooltip
                            if imgui.IsItemHovered() then
                                imgui.PushStyleColor(ImGuiCol_PopupBg, COLORS.bgDark);
                                imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
                                imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {8, 6});
                                imgui.BeginTooltip();
                                imgui.TextColored(COLORS.gold, macro.displayName or macro.action or 'Unknown');
                                imgui.Spacing();
                                imgui.TextColored(COLORS.textDim, 'Type: ' .. (ACTION_TYPE_LABELS[macro.actionType] or macro.actionType or '?'));
                                if macro.actionType ~= 'macro' and macro.target then
                                    local formattedTarget = FormatTargetForDisplay(macro.target);
                                    if formattedTarget then
                                        imgui.TextColored(COLORS.textDim, 'Target: ' .. formattedTarget);
                                    end
                                end
                                imgui.Spacing();
                                imgui.TextColored(COLORS.textMuted, 'Drag to hotbar slot');
                                imgui.EndTooltip();
                                imgui.PopStyleVar();
                                imgui.PopStyleColor(2);
                            end
                        end
                    end
                end
            end

            -- Reserve remaining space to always have full 6x6 grid height
            if rowsOnPage < PALETTE_ROWS then
                local remainingRows = PALETTE_ROWS - rowsOnPage;
                local remainingHeight = remainingRows * (PALETTE_TILE_SIZE + PALETTE_TILE_GAP);
                imgui.Dummy({gridWidth, remainingHeight});
            end
        end

        -- Pagination controls (always visible, arrows disabled at boundaries)
        imgui.Spacing();

        -- Center the pagination controls
        local paginationWidth = 200;
        local winWidth = imgui.GetWindowWidth();
        local paginationStartX = (winWidth - paginationWidth) / 2;
        imgui.SetCursorPosX(paginationStartX);

        -- Previous button (disabled when on first page)
        local canGoPrev = currentPalettePage > 1;
        if not canGoPrev then
            imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.3);
        end
        if imgui.Button('<##PrevPage', {30, 22}) and canGoPrev then
            currentPalettePage = currentPalettePage - 1;
            selectedMacroIndex = nil;
        end
        if not canGoPrev then
            imgui.PopStyleVar();
        end
        imgui.SameLine();

        -- Page indicator
        local pageText = string.format('Page %d / %d', currentPalettePage, totalPages);
        local textWidth = imgui.CalcTextSize(pageText);
        imgui.SetCursorPosX(paginationStartX + (paginationWidth - textWidth) / 2);
        imgui.TextColored(COLORS.textDim, pageText);
        imgui.SameLine();
        imgui.SetCursorPosX(paginationStartX + paginationWidth - 30);

        -- Next button (disabled when on last page)
        local canGoNext = currentPalettePage < totalPages;
        if not canGoNext then
            imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.3);
        end
        if imgui.Button('>##NextPage', {30, 22}) and canGoNext then
            currentPalettePage = currentPalettePage + 1;
            selectedMacroIndex = nil;
        end
        if not canGoNext then
            imgui.PopStyleVar();
        end
    end
    imgui.End();
    PopWindowStyle();

    -- Handle window close
    if not isOpen[1] then
        M.ClosePalette();
    end

    -- Draw macro editor popup if needed
    if editingMacro then
        M.DrawMacroEditor();
    end

    -- Draw copy macro dialog if needed
    DrawCopyMacroDialog();
end

-- ============================================
-- Macro Editor Popup
-- ============================================

-- Editor state
local editorFields = {
    actionType = { 1 },
    action = { '' },
    target = { 1 },
    displayName = { '' },
    equipSlot = { 1 },
    macroText = { '' },
    recastSourceType = { 1 },    -- Index into RECAST_SOURCE_TYPES (1 = 'none')
    recastSourceAction = { '' }, -- Action name for recast lookup
};
local function ClearMacroCustomIcon(macro)
    if not macro then
        return;
    end
    macro.customIconType = nil;
    macro.customIconId = nil;
    macro.customIconPath = nil;
end
local function ApplyMacroIconFromSpell(macro, spell)
    if not macro or not spell then
        return;
    end
    macro.customIconType = 'spell';
    macro.customIconId = spell.id;
    macro.customIconPath = nil;
end
local function ApplyMacroIconFromAbility(macro, ability)
    if not macro or not ability then
        return;
    end
    macro.customIconType = 'ability';
    macro.customIconId = ability.id;
    macro.customIconPath = nil;
end
local TARGET_OPTIONS = { 'me', 't', 'stpc', 'stnpc', 'st', 'bt', 'lastst', 'stal', 'stpt', 'p0', 'p1', 'p2', 'p3', 'p4', 'p5' };
local TARGET_LABELS = {
    me = '<me> (Self)',
    t = '<t> (Current Target)',
    stpc = '<stpc> (Select Player)',
    stnpc = '<stnpc> (Select NPC/Enemy)',
    st = '<st> (Sub Target)',
    bt = '<bt> (Battle Target)',
    lastst = '<lastst> (Last Sub Target)',
    stal = '<stal> (Select Alliance)',
    stpt = '<stpt> (Select Party)',
    p0 = '<p0> (Party Member 1)',
    p1 = '<p1> (Party Member 2)',
    p2 = '<p2> (Party Member 3)',
    p3 = '<p3> (Party Member 4)',
    p4 = '<p4> (Party Member 5)',
    p5 = '<p5> (Party Member 6)',
};
local EQUIP_SLOTS = { 'main', 'sub', 'range', 'ammo', 'head', 'body', 'hands', 'legs', 'feet', 'neck', 'waist', 'ear1', 'ear2', 'ring1', 'ring2', 'back' };
local EQUIP_SLOT_LABELS = {
    main = 'Main Hand',
    sub = 'Sub/Shield',
    range = 'Range',
    ammo = 'Ammo',
    head = 'Head',
    body = 'Body',
    hands = 'Hands',
    legs = 'Legs',
    feet = 'Feet',
    neck = 'Neck',
    waist = 'Waist',
    ear1 = 'Ear 1',
    ear2 = 'Ear 2',
    ring1 = 'Ring 1',
    ring2 = 'Ring 2',
    back = 'Back',
};
local function FindIndex(array, value)
    for i, v in ipairs(array) do
        if v == value then return i; end
    end
    return 1;
end

-- Draw icon preview box with current icon
local function DrawIconPreview(macro, x, y, size)
    local drawList = imgui.GetWindowDrawList();
    if not drawList then return; end

    -- Draw background box
    local bgColor = imgui.GetColorU32({0.1, 0.09, 0.08, 0.95});
    local borderColor = imgui.GetColorU32(COLORS.border);
    drawList:AddRectFilled({x, y}, {x + size, y + size}, bgColor, 4);
    drawList:AddRect({x, y}, {x + size, y + size}, borderColor, 4, 0, 1);

    -- Draw icon if available
    local icon = actions.GetBindIcon(macro);
    if icon and icon.image then
        local iconPtr = tonumber(ffi.cast("uint32_t", icon.image));
        if iconPtr then
            local padding = 4;
            drawList:AddImage(
                iconPtr,
                {x + padding, y + padding},
                {x + size - padding, y + size - padding}
            );
        end
    else
        -- No icon - show abbreviated action name (prefer action for preview)
        local abbr = GetActionAbbreviation(macro, true);
        local textSize = imgui.CalcTextSize(abbr);
        local textX = x + (size - textSize) / 2;
        local textY = y + (size - 14) / 2;
        local textColor = imgui.GetColorU32(COLORS.gold);
        drawList:AddText({textX, textY}, textColor, abbr);
    end
    DrawMacroStatusOverlay(drawList, macro, x, y, size);
end
function M.DrawMacroEditor()
    if not editingMacro then
        return;
    end
    editorFrameCounter = editorFrameCounter + 1;

    -- Initialize editor fields from editing macro
    editorFields.actionType[1] = FindIndex(ACTION_TYPES, editingMacro.actionType or 'ma');
    editorFields.action[1] = editingMacro.action or '';
    editorFields.target[1] = FindIndex(TARGET_OPTIONS, editingMacro.target or 't');
    editorFields.displayName[1] = editingMacro.displayName or '';
    editorFields.equipSlot[1] = FindIndex(EQUIP_SLOTS, editingMacro.equipSlot or 'main');
    editorFields.macroText[1] = editingMacro.macroText or '';
    editorFields.recastSourceType[1] = FindIndex(RECAST_SOURCE_TYPES, editingMacro.recastSourceType or 'none');
    editorFields.recastSourceAction[1] = editingMacro.recastSourceAction or '';
    local title = isCreatingNew and 'Create Macro###MacroEditor' or 'Edit Macro###MacroEditor';
    local isOpen = { true };
    imgui.SetNextWindowSize({420, 480}, ImGuiCond_FirstUseEver);

    -- Apply XIUI styling
    PushWindowStyle();
    if imgui.Begin(title, isOpen, ImGuiWindowFlags_NoCollapse) then
        -- Icon preview section at the top right (uses window-relative positioning for scrolling)
        local iconPreviewSize = 64;
        local contentWidth = imgui.GetContentRegionAvail();
        local iconPreviewX = contentWidth - iconPreviewSize - 10;

        -- Draw icon preview and Change button together
        local startCursorY = imgui.GetCursorPosY();
        imgui.SetCursorPosX(iconPreviewX);

        -- Get screen position for icon preview (DrawIconPreview needs screen coords)
        local screenPos = {imgui.GetCursorScreenPos()};
        DrawIconPreview(editingMacro, screenPos[1], screenPos[2], iconPreviewSize);
        imgui.Dummy({iconPreviewSize, iconPreviewSize});

        -- Change Icon button below preview (use window-relative SetCursorPos for scroll support)
        imgui.SetCursorPos({iconPreviewX - 10, startCursorY + iconPreviewSize + 8});
        imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 1);
        imgui.PushStyleColor(ImGuiCol_Border, COLORS.gold);
        if imgui.Button('Change', {iconPreviewSize + 20, 22}) then
            iconpicker.open();
        end
        imgui.PopStyleColor();
        imgui.PopStyleVar();

        -- Reset cursor for main content (left side, use window-relative positioning)
        imgui.SetCursorPos({8, startCursorY});

        -- Action Type dropdown with label
        imgui.TextColored(COLORS.goldDim, 'Action Type');
        PushComboStyle();
        imgui.SetNextItemWidth(240);
        local currentType = ACTION_TYPES[editorFields.actionType[1]];
        if imgui.BeginCombo('##actionType', ACTION_TYPE_LABELS[currentType] or 'Select...') then
            for i, actionType in ipairs(ACTION_TYPES) do
                local isSelected = editorFields.actionType[1] == i;
                if isSelected then
                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold);
                end
                if imgui.Selectable(ACTION_TYPE_LABELS[actionType], isSelected) then
                    editorFields.actionType[1] = i;
                    editingMacro.actionType = actionType;
                    -- Clear action and icon when type changes
                    editingMacro.action = '';
                    editorFields.action[1] = '';
                    editingMacro.itemId = nil;
                    ClearMacroCustomIcon(editingMacro);
                    InvalidatePetCommandCache();
                    searchFilter[1] = '';
                    -- Clear recast source fields when changing away from macro type
                    if actionType ~= 'macro' then
                        editingMacro.recastSourceType = nil;
                        editingMacro.recastSourceAction = nil;
                        editingMacro.recastSourceItemId = nil;
                        editorFields.recastSourceType[1] = 1;  -- Reset to 'none'
                        editorFields.recastSourceAction[1] = '';
                    end
                end
                if isSelected then
                    imgui.PopStyleColor();
                end
            end
            imgui.EndCombo();
        end
        PopComboStyle();
        imgui.Spacing();
        imgui.Spacing();

        -- Dynamic fields based on action type
        currentType = ACTION_TYPES[editorFields.actionType[1]];
        if currentType == 'ma' then
            DrawShowAllCheckbox('spellShowAll', editorShowAll.spells, function()
                RefreshEditorShowAll('spells');
            end);
            imgui.TextColored(COLORS.goldDim, 'Spell');
            DrawSearchableCombo('##spellCombo', GetCachedSpells, editingMacro.action or '', function(spell)
                editingMacro.action = spell.name;
                editorFields.action[1] = spell.name;
                ApplyMacroIconFromSpell(editingMacro, spell);
                if (editingMacro.displayName or '') == '' then
                    editingMacro.displayName = spell.name;
                    editorFields.displayName[1] = spell.name;
                end
            end, false, nil, 'spells', 'No spells available for this job', editorShowAll.spells[1]);

            -- Target dropdown
            imgui.Spacing();
            imgui.TextColored(COLORS.goldDim, 'Target');
            PushComboStyle();
            imgui.SetNextItemWidth(240);
            if imgui.BeginCombo('##targetType', TARGET_LABELS[TARGET_OPTIONS[editorFields.target[1]]] or 'Select...') then
                for i, target in ipairs(TARGET_OPTIONS) do
                    local isSelected = editorFields.target[1] == i;
                    if isSelected then imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold); end
                    if imgui.Selectable(TARGET_LABELS[target], isSelected) then
                        editorFields.target[1] = i;
                        editingMacro.target = target;
                    end
                    if isSelected then imgui.PopStyleColor(); end
                end
                imgui.EndCombo();
            end
            PopComboStyle();
        elseif currentType == 'ja' then
            DrawShowAllCheckbox('abilityShowAll', editorShowAll.abilities, function()
                RefreshEditorShowAll('abilities');
            end);
            imgui.TextColored(COLORS.goldDim, 'Ability');
            DrawSearchableCombo('##abilityCombo', GetCachedAbilities, editingMacro.action or '', function(ability)
                editingMacro.action = ability.name;
                editorFields.action[1] = ability.name;
                ApplyMacroIconFromAbility(editingMacro, ability);
                if (editingMacro.displayName or '') == '' then
                    editingMacro.displayName = ability.name;
                    editorFields.displayName[1] = ability.name;
                end
            end, false, nil, 'abilities', 'No abilities available', editorShowAll.abilities[1]);

            -- Target dropdown
            imgui.Spacing();
            imgui.TextColored(COLORS.goldDim, 'Target');
            PushComboStyle();
            imgui.SetNextItemWidth(240);
            if imgui.BeginCombo('##targetType', TARGET_LABELS[TARGET_OPTIONS[editorFields.target[1]]] or 'Select...') then
                for i, target in ipairs(TARGET_OPTIONS) do
                    local isSelected = editorFields.target[1] == i;
                    if isSelected then imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold); end
                    if imgui.Selectable(TARGET_LABELS[target], isSelected) then
                        editorFields.target[1] = i;
                        editingMacro.target = target;
                    end
                    if isSelected then imgui.PopStyleColor(); end
                end
                imgui.EndCombo();
            end
            PopComboStyle();
        elseif currentType == 'ws' then
            DrawShowAllCheckbox('wsShowAll', editorShowAll.weaponskills, function()
                RefreshEditorShowAll('weaponskills');
            end);
            imgui.TextColored(COLORS.goldDim, 'Weaponskill');
            DrawSearchableCombo('##wsCombo', GetCachedWeaponskills, editingMacro.action or '', function(ws)
                editingMacro.action = ws.name;
                editorFields.action[1] = ws.name;
                ApplyMacroIconFromAbility(editingMacro, ws);
                if (editingMacro.displayName or '') == '' then
                    editingMacro.displayName = ws.name;
                    editorFields.displayName[1] = ws.name;
                end
            end, false, nil, 'weaponskills', 'No weaponskills available', editorShowAll.weaponskills[1]);

            -- Target dropdown (default to <t>)
            imgui.Spacing();
            imgui.TextColored(COLORS.goldDim, 'Target');
            PushComboStyle();
            imgui.SetNextItemWidth(240);
            if imgui.BeginCombo('##targetType', TARGET_LABELS[TARGET_OPTIONS[editorFields.target[1]]] or 'Select...') then
                for i, target in ipairs(TARGET_OPTIONS) do
                    local isSelected = editorFields.target[1] == i;
                    if isSelected then imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold); end
                    if imgui.Selectable(TARGET_LABELS[target], isSelected) then
                        editorFields.target[1] = i;
                        editingMacro.target = target;
                    end
                    if isSelected then imgui.PopStyleColor(); end
                end
                imgui.EndCombo();
            end
            PopComboStyle();
        elseif currentType == 'item' then
            -- Item: Searchable dropdown or manual input
            DrawItemLabelWithQuantity('Item', editingMacro.itemId, editingMacro.action);
            DrawSearchableCombo('##itemCombo', GetCachedItems, editingMacro.action or '', function(item)
                editingMacro.action = item.name;
                editingMacro.itemId = item.id;  -- Store item ID for fast icon lookup
                editorFields.action[1] = item.name;
                editingMacro.displayName = item.name;
                editorFields.displayName[1] = item.name;
            end, true, nil, 'items', 'No items found in storage');

            -- Manual input fallback
            imgui.Spacing();
            imgui.TextColored(COLORS.goldDim, 'Or type item name:');
            imgui.SetNextItemWidth(220);
            if imgui.InputText('##itemName', editorFields.action, INPUT_BUFFER_SIZE) then
                editingMacro.action = editorFields.action[1];
            end

            -- Target dropdown
            imgui.Spacing();
            imgui.TextColored(COLORS.goldDim, 'Target');
            PushComboStyle();
            imgui.SetNextItemWidth(240);
            if imgui.BeginCombo('##targetType', TARGET_LABELS[TARGET_OPTIONS[editorFields.target[1]]] or 'Select...') then
                for i, target in ipairs(TARGET_OPTIONS) do
                    local isSelected = editorFields.target[1] == i;
                    if isSelected then imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold); end
                    if imgui.Selectable(TARGET_LABELS[target], isSelected) then
                        editorFields.target[1] = i;
                        editingMacro.target = target;
                    end
                    if isSelected then imgui.PopStyleColor(); end
                end
                imgui.EndCombo();
            end
            PopComboStyle();
        elseif currentType == 'equip' then
            -- Equipment slot dropdown
            imgui.TextColored(COLORS.goldDim, 'Equipment Slot');
            PushComboStyle();
            imgui.SetNextItemWidth(240);
            if imgui.BeginCombo('##equipSlot', EQUIP_SLOT_LABELS[EQUIP_SLOTS[editorFields.equipSlot[1]]] or 'Select...') then
                for i, slot in ipairs(EQUIP_SLOTS) do
                    local isSelected = editorFields.equipSlot[1] == i;
                    if isSelected then imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold); end
                    if imgui.Selectable(EQUIP_SLOT_LABELS[slot], isSelected) then
                        editorFields.equipSlot[1] = i;
                        editingMacro.equipSlot = slot;
                        -- Clear item selection when slot changes (old item may not fit new slot)
                        editingMacro.action = '';
                        editingMacro.itemId = nil;
                        editingMacro.displayName = '';
                        editorFields.action[1] = '';
                        editorFields.displayName[1] = '';
                    end
                    if isSelected then imgui.PopStyleColor(); end
                end
                imgui.EndCombo();
            end
            PopComboStyle();

            -- Item: Searchable dropdown or manual input (filtered by selected equipment slot)
            imgui.Spacing();
            local selectedSlot = EQUIP_SLOTS[editorFields.equipSlot[1]];
            DrawItemLabelWithQuantity('Item (' .. EQUIP_SLOT_LABELS[selectedSlot] .. ')', editingMacro.itemId, editingMacro.action);
            DrawSearchableCombo('##equipItemCombo', GetCachedItems, editingMacro.action or '', function(item)
                editingMacro.action = item.name;
                editingMacro.itemId = item.id;  -- Store item ID for fast icon lookup
                editorFields.action[1] = item.name;
                editingMacro.displayName = item.name;
                editorFields.displayName[1] = item.name;
            end, true, selectedSlot, 'items', 'No items found in storage');

            -- Manual input fallback
            imgui.Spacing();
            imgui.TextColored(COLORS.goldDim, 'Or type item name:');
            imgui.SetNextItemWidth(220);
            if imgui.InputText('##equipItemName', editorFields.action, INPUT_BUFFER_SIZE) then
                editingMacro.action = editorFields.action[1];
            end
        elseif currentType == 'macro' then
            -- Raw macro command (8 lines like native FFXI macro editor)
            imgui.TextColored(COLORS.goldDim, 'Macro Commands (8 lines)');

            -- Style the multiline input
            imgui.PushStyleColor(ImGuiCol_FrameBg, COLORS.bgMedium);
            imgui.PushStyleColor(ImGuiCol_FrameBgHovered, COLORS.bgLight);
            imgui.PushStyleColor(ImGuiCol_FrameBgActive, COLORS.bgLight);

            -- 8 rows * ~16px line height + padding
            local lineHeight = imgui.GetTextLineHeight();
            local inputHeight = (lineHeight * 8) + 8;
            if imgui.InputTextMultiline('##macroText', editorFields.macroText, MACRO_BUFFER_SIZE, {280, inputHeight}) then
                editingMacro.macroText = editorFields.macroText[1];
                editingMacro.action = editorFields.macroText[1];
            end
            imgui.PopStyleColor(3);
            imgui.ShowHelp('Enter commands, one per line (e.g., /ma "Cure" <stpc>)');

            -- Recast Source section (optional)
            imgui.Spacing();
            imgui.Spacing();
            if imgui.TreeNode('Recast Source (Optional)##recastSource') then
                imgui.TextColored(COLORS.textMuted, 'Show cooldown from a different action');
                imgui.Spacing();

                -- Recast source type dropdown
                imgui.TextColored(COLORS.goldDim, 'Source Type');
                PushComboStyle();
                imgui.SetNextItemWidth(240);
                local currentRecastType = RECAST_SOURCE_TYPES[editorFields.recastSourceType[1]] or 'none';
                if imgui.BeginCombo('##recastSourceType', RECAST_SOURCE_LABELS[currentRecastType] or 'None') then
                    if imgui.IsWindowAppearing() then
                        RefreshDropdownList('recastSource');
                        dropdownLoadState['##recastSourceType'] = editorFrameCounter;
                    end
                    local isRecastTypeLoading = dropdownLoadState['##recastSourceType'] ~= nil
                        and editorFrameCounter <= dropdownLoadState['##recastSourceType'];
                    if isRecastTypeLoading then
                        imgui.TextColored(COLORS.textMuted, 'Loading...');
                    else
                        dropdownLoadState['##recastSourceType'] = nil;
                        for i, sourceType in ipairs(RECAST_SOURCE_TYPES) do
                            local isSelected = editorFields.recastSourceType[1] == i;
                            if isSelected then imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold); end
                            if imgui.Selectable(RECAST_SOURCE_LABELS[sourceType], isSelected) then
                                editorFields.recastSourceType[1] = i;
                                if sourceType == 'none' then
                                    editingMacro.recastSourceType = nil;
                                    editingMacro.recastSourceAction = nil;
                                    editingMacro.recastSourceItemId = nil;
                                else
                                    editingMacro.recastSourceType = sourceType;
                                end
                                -- Clear action when type changes
                                editingMacro.recastSourceAction = nil;
                                editingMacro.recastSourceItemId = nil;
                                editorFields.recastSourceAction[1] = '';
                            end
                            if isSelected then imgui.PopStyleColor(); end
                        end
                    end
                    imgui.EndCombo();
                else
                    dropdownLoadState['##recastSourceType'] = nil;
                end
                PopComboStyle();

                -- Show action selector based on recast source type
                currentRecastType = RECAST_SOURCE_TYPES[editorFields.recastSourceType[1]] or 'none';
                if currentRecastType == 'ma' then
                    imgui.Spacing();
                    DrawShowAllCheckbox('recastSpellShowAll', editorShowAll.spells, function()
                        RefreshEditorShowAll('spells');
                    end);
                    imgui.TextColored(COLORS.goldDim, 'Spell');
                    DrawSearchableCombo('##recastSpellCombo', GetCachedSpells, editingMacro.recastSourceAction or '', function(spell)
                        editingMacro.recastSourceAction = spell.name;
                        editorFields.recastSourceAction[1] = spell.name;
                    end, false, nil, 'spells', 'No spells available', editorShowAll.spells[1]);
                elseif currentRecastType == 'ja' then
                    imgui.Spacing();
                    DrawShowAllCheckbox('recastAbilityShowAll', editorShowAll.abilities, function()
                        RefreshEditorShowAll('abilities');
                    end);
                    imgui.TextColored(COLORS.goldDim, 'Ability');
                    DrawSearchableCombo('##recastAbilityCombo', GetCachedAbilities, editingMacro.recastSourceAction or '', function(ability)
                        editingMacro.recastSourceAction = ability.name;
                        editorFields.recastSourceAction[1] = ability.name;
                    end, false, nil, 'abilities', 'No abilities available', editorShowAll.abilities[1]);
                elseif currentRecastType == 'ws' then
                    imgui.Spacing();
                    DrawShowAllCheckbox('recastWsShowAll', editorShowAll.weaponskills, function()
                        RefreshEditorShowAll('weaponskills');
                    end);
                    imgui.TextColored(COLORS.goldDim, 'Weaponskill');
                    DrawSearchableCombo('##recastWsCombo', GetCachedWeaponskills, editingMacro.recastSourceAction or '', function(ws)
                        editingMacro.recastSourceAction = ws.name;
                        editorFields.recastSourceAction[1] = ws.name;
                    end, false, nil, 'weaponskills', 'No weaponskills available', editorShowAll.weaponskills[1]);
                elseif currentRecastType == 'item' then
                    imgui.Spacing();
                    DrawItemLabelWithQuantity('Item', editingMacro.recastSourceItemId, editingMacro.recastSourceAction);
                    DrawSearchableCombo('##recastItemCombo', GetCachedItems, editingMacro.recastSourceAction or '', function(item)
                        editingMacro.recastSourceAction = item.name;
                        editingMacro.recastSourceItemId = item.id;
                        editorFields.recastSourceAction[1] = item.name;
                    end, true, nil, 'items', 'No items available');
                elseif currentRecastType == 'pet' then
                    imgui.Spacing();
                    DrawShowAllCheckbox('recastPetShowAll', editorShowAll.pet, function()
                        RefreshEditorShowAll('pet');
                    end);
                    imgui.TextColored(COLORS.goldDim, 'Pet Command');
                    DrawSearchableCombo('##recastPetCombo', GetEditorPetCommands, editingMacro.recastSourceAction or '', function(cmd)
                        editingMacro.recastSourceAction = cmd.name;
                        editorFields.recastSourceAction[1] = cmd.name;
                    end, false, nil, 'pet', 'No pet commands available', editorShowAll.pet[1]);
                end
                imgui.TreePop();
            end
        elseif currentType == 'pet' then
            -- For SMN, show avatar filter dropdown (owned summons only)
            local viewedJobId = ResolveEditorPetJobId();
            NormalizePetAvatarFilter();
            local avatarList = GetOwnedAvatarList();
            if viewedJobId == petregistry.JOB_SMN then
                imgui.TextColored(COLORS.goldDim, 'Avatar Filter');
                PushComboStyle();
                imgui.SetNextItemWidth(240);
                local filterLabel = petAvatarFilter == 1 and 'All Avatars'
                    or (avatarList[petAvatarFilter - 1] or 'All Avatars');
                if imgui.BeginCombo('##avatarFilter', filterLabel) then
                    -- "All" option
                    local isAllSelected = petAvatarFilter == 1;
                    if isAllSelected then imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold); end
                    if imgui.Selectable('All Avatars', isAllSelected) then
                        petAvatarFilter = 1;
                        InvalidatePetCommandCache();  -- Clear cache to rebuild
                    end
                    if isAllSelected then imgui.PopStyleColor(); end
                    if #avatarList > 0 then
                    imgui.Separator();
                    end

                    -- Individual avatars (owned only)
                    for i, avatar in ipairs(avatarList) do
                        local isSelected = petAvatarFilter == i + 1;
                        if isSelected then imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold); end
                        if imgui.Selectable(avatar, isSelected) then
                            petAvatarFilter = i + 1;
                            InvalidatePetCommandCache();  -- Clear cache to rebuild
                        end
                        if isSelected then imgui.PopStyleColor(); end
                    end
                    imgui.EndCombo();
                end
                PopComboStyle();
                imgui.Spacing();
            end
            if viewedJobId == petregistry.JOB_BST then
                NormalizePetJugFilter();
                local ownedJugs = BuildOwnedJugPetFilterList();
                imgui.TextColored(COLORS.goldDim, 'Jug Pet Filter');
                PushComboStyle();
                imgui.SetNextItemWidth(240);
                local jugFilterLabel = GetSelectedJugFilterDisplayName();
                if imgui.BeginCombo('##jugPetFilter', jugFilterLabel) then
                    local isAllSelected = petJugFilter == 1;
                    if isAllSelected then imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold); end
                    if imgui.Selectable('All Jug Pets', isAllSelected) then
                        petJugFilter = 1;
                        InvalidatePetCommandCache();
                    end
                    if isAllSelected then imgui.PopStyleColor(); end
                    if #ownedJugs > 0 then
                        imgui.Separator();
                    end
                    for i, entry in ipairs(ownedJugs) do
                        local isSelected = petJugFilter == i + 1;
                        local label = entry.displayName or entry.internalName;
                        if isSelected then imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold); end
                        if imgui.Selectable(label, isSelected) then
                            petJugFilter = i + 1;
                            InvalidatePetCommandCache();
                        end
                        if isSelected then imgui.PopStyleColor(); end
                    end
                    imgui.EndCombo();
                end
                PopComboStyle();
                imgui.Spacing();
            end
            DrawShowAllCheckbox('petShowAll', editorShowAll.pet, function()
                RefreshEditorShowAll('pet');
            end);
            imgui.TextColored(COLORS.goldDim, 'Pet Command');
            DrawSearchableCombo('##petCommandCombo', GetEditorPetCommands, editingMacro.action or '', function(cmd)
                editingMacro.action = cmd.name;
                editorFields.action[1] = cmd.name;
                ApplyMacroIconFromAbility(editingMacro, cmd);
                if (editingMacro.displayName or '') == '' then
                    editingMacro.displayName = cmd.name;
                    editorFields.displayName[1] = cmd.name;
                end
            end, false, nil, 'pet', 'No pet commands available for this job', editorShowAll.pet[1]);

            -- Manual input fallback
            imgui.Spacing();
            imgui.TextColored(COLORS.goldDim, 'Or type command:');
            imgui.SetNextItemWidth(220);
            if imgui.InputText('##petCommandManual', editorFields.action, INPUT_BUFFER_SIZE) then
                editingMacro.action = editorFields.action[1];
            end

            -- Target dropdown
            imgui.Spacing();
            imgui.TextColored(COLORS.goldDim, 'Target');
            PushComboStyle();
            imgui.SetNextItemWidth(240);
            if imgui.BeginCombo('##targetType', TARGET_LABELS[TARGET_OPTIONS[editorFields.target[1]]] or 'Select...') then
                for i, target in ipairs(TARGET_OPTIONS) do
                    local isSelected = editorFields.target[1] == i;
                    if isSelected then imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold); end
                    if imgui.Selectable(TARGET_LABELS[target], isSelected) then
                        editorFields.target[1] = i;
                        editingMacro.target = target;
                    end
                    if isSelected then imgui.PopStyleColor(); end
                end
                imgui.EndCombo();
            end
            PopComboStyle();
        end

        -- Slot Label input (for all types)
        imgui.Spacing();
        imgui.Spacing();
        imgui.TextColored(COLORS.goldDim, 'Slot Label');
        imgui.SetNextItemWidth(240);
        if imgui.InputText('##displayName', editorFields.displayName, 32) then
            editingMacro.displayName = editorFields.displayName[1];
        end
        if currentType ~= 'macro' then
            imgui.ShowHelp('Short label shown on the slot (e.g., "Cure3"). Leave empty to use action name.');
        else
            imgui.ShowHelp('Label shown on the slot for this macro.');
        end
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        -- Save button with success styling
        imgui.PushStyleColor(ImGuiCol_Button, COLORS.success);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, {0.5, 0.8, 0.5, 1.0});
        imgui.PushStyleColor(ImGuiCol_ButtonActive, {0.6, 0.9, 0.6, 1.0});
        imgui.PushStyleColor(ImGuiCol_Text, {0.1, 0.1, 0.1, 1.0});
        if imgui.Button('Save', {90, 28}) then
            -- Validate before saving
            local canSave = false;
            if currentType == 'macro' then
                canSave = (editingMacro.macroText or '') ~= '';
                if canSave and (editingMacro.displayName or '') == '' then
                    editingMacro.displayName = 'Macro';
                end
                -- Clear target for macro type (targets are embedded in macro text)
                editingMacro.target = nil;
            else
                canSave = (editingMacro.action or '') ~= '';
                if canSave and (editingMacro.displayName or '') == '' then
                    editingMacro.displayName = editingMacro.action;
                end
            end
            if canSave then
                -- Look up itemId for item/equip macros if not already set
                -- This handles cases where user typed item name manually instead of selecting from dropdown
                if (currentType == 'item' or currentType == 'equip') and not editingMacro.itemId and editingMacro.action then
                    editingMacro.itemId = actiondb.GetItemId(editingMacro.action);
                end
                if isCreatingNew then
                    M.AddMacro(editingMacro);
                    -- Navigate to last page to show the new macro
                    local db = M.GetMacroDatabase();
                    currentPalettePage = math.max(1, math.ceil(#db / PALETTE_MACROS_PER_PAGE));
                else
                    M.UpdateMacro(editingMacro.id, editingMacro);
                end
                editingMacro = nil;
                isCreatingNew = false;
                searchFilter[1] = '';
                iconpicker.close();
            end
        end
        imgui.PopStyleColor(4);
        imgui.SameLine();

        -- Cancel button
        if imgui.Button('Cancel', {90, 28}) then
            editingMacro = nil;
            isCreatingNew = false;
            searchFilter[1] = '';
            iconpicker.close();
        end
    end
    imgui.End();
    PopWindowStyle();
    if not isOpen[1] then
        editingMacro = nil;
        isCreatingNew = false;
        searchFilter[1] = '';
        iconpicker.close();
    end

    -- Draw icon picker if open
    iconpicker.draw(editingMacro);
end

-- ============================================
-- Dragdrop Library Accessors (for display.lua)
-- ============================================

-- Get the dragdrop library reference
function M.GetDragDropLib()
    return dragdrop;
end

-- Update drag state (call every frame)
function M.UpdateDrag()
    dragdrop.Update();
end

-- Render drag preview (call at end of frame)
function M.RenderDragPreview()
    dragdrop.Render();
end

-- Flush any pending slot save (call on unload to ensure changes are persisted)
function M.FlushPendingSave()
    if hotbarDataDirty then
        SaveSettingsToDisk();
        hotbarDataDirty = false;
    end
end

-- Process deferred work at the start of each frame.
-- Call AFTER TextureManager.FlushPendingReleases so that any textures queued
-- for release last frame have already been handled before we drop new refs.
function M.FlushPendingFrameWork()
    if pendingIconCacheClear then
        pendingIconCacheClear = false;
        if pendingFullSlotCacheClear then
            pendingFullSlotCacheClear = false;
            if slotrenderer == nil then
                local success, mod = pcall(require, 'modules.hotbar.slotrenderer');
                if success then slotrenderer = mod; end
            end
            if slotrenderer and slotrenderer.ClearAllCache then
                slotrenderer.ClearAllCache();
            end
        end
        ClearAllIconCaches();
    end
end

-- Check if hotbar has unsaved changes
function M.IsHotbarDirty()
    return hotbarDataDirty;
end

-- Clear the dirty flag (call after saving)
function M.ClearHotbarDirty()
    hotbarDataDirty = false;
end

-- Register as callback with data.lua for unified slot change handling
-- When slots change, just mark dirty - don't save immediately
data.SetSlotDataChangedCallback(MarkHotbarDirty);
return M;
