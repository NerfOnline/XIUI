--[[
* XIUI Hotbar - Icon Picker Module
* Spell/ability/item/custom icon selection popup for macro editor
]]--

require('common');
local imgui = require('imgui');
local ffi = require('ffi');
local actions = require('modules.hotbar.actions');
local textures = require('modules.hotbar.textures');
local TextureManager = require('libs.texturemanager');
local actiondb = require('modules.hotbar.actiondb');
local components = require('config.components');

local M = {};

local INPUT_BUFFER_SIZE = 64;

local COLORS = {
    gold = components.TAB_STYLE.gold,
    goldDim = {0.957 * 0.7, 0.855 * 0.7, 0.592 * 0.7, 1.0},
    goldDark = {0.765, 0.684, 0.474, 1.0},
    goldDarker = {0.573, 0.512, 0.355, 1.0},
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
    usable = {0.5, 0.7, 1.0, 1.0},
};

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
    imgui.PopStyleColor(19);
end

-- Icon picker state
local iconPickerOpen = false;
local iconPickerFilter = { '' };
local ICON_TAB_SPELLS = 1;
local ICON_TAB_ABILITIES = 2;
local ICON_TAB_ITEMS = 3;
local ICON_TAB_CUSTOM = 4;
local iconPickerTab = ICON_TAB_SPELLS;
local iconPickerPage = { 1, 1, 1, 1 };  -- spells, abilities, items, custom
local iconPickerLastFilter = { '', '', '', '' };
local iconPickerSpellType = 'All';
local iconPickerItemType = 0;

-- Filtered list caches for icon picker tabs
local filteredSpellsCache = nil;
local filteredSpellsCacheKey = nil;
local filteredAbilitiesCache = nil;
local filteredAbilitiesCacheKey = nil;
local filteredItemsCache = nil;
local filteredItemsCacheKey = nil;
local filteredCustomIconsCacheKey = nil;

-- Spell type display names and order
local SPELL_TYPE_ORDER = {
    'All', 'WhiteMagic', 'BlackMagic', 'BlueMagic', 'BardSong',
    'Ninjutsu', 'SummonerPact', 'Trust'
};
local SPELL_TYPE_LABELS = {
    ['All'] = 'All Spells',
    ['WhiteMagic'] = 'White Magic',
    ['BlackMagic'] = 'Black Magic',
    ['BlueMagic'] = 'Blue Magic',
    ['BardSong'] = 'Bard Songs',
    ['Ninjutsu'] = 'Ninjutsu',
    ['SummonerPact'] = 'Summoning',
    ['Trust'] = 'Trusts',
};
-- Job icon file names for spell type filters (from assets/jobs/FFXIV)
local SPELL_TYPE_JOB_ICONS = {
    ['All'] = 'infinite',   -- Infinite symbol for "All"
    ['WhiteMagic'] = 'whm',
    ['BlackMagic'] = 'blm',
    ['BlueMagic'] = 'blu',
    ['BardSong'] = 'brd',
    ['Ninjutsu'] = 'nin',
    ['SummonerPact'] = 'smn',
    ['Trust'] = nil,        -- Use custom trust icon instead
};

-- Cache for filter icons
local filterIconCache = {};

-- Load a filter icon (job icon or trust icon)
local function GetFilterIcon(spellType)
    -- Check cache first
    if filterIconCache[spellType] then
        return filterIconCache[spellType];
    end

    local icon = nil;

    if spellType == 'Trust' then
        -- Load custom trust icon (Shantotto)
        local path = string.format('%saddons\\XIUI\\assets\\hotbar\\custom\\trusts\\trust-shantotto.png', AshitaCore:GetInstallPath());
        icon = textures:LoadTextureFromPath(path);
    else
        -- Load job icon from FFXIV theme
        local jobAbbr = SPELL_TYPE_JOB_ICONS[spellType];
        if jobAbbr then
            local path = string.format('%saddons\\XIUI\\assets\\jobs\\FFXIV-1\\%s.png', AshitaCore:GetInstallPath(), jobAbbr);
            icon = textures:LoadTextureFromPath(path);
        end
    end

    filterIconCache[spellType] = icon;
    return icon;
end

-- Item type constants from FFXI (item.Type field)
-- Note: Only include types that have significant item counts
local ITEM_TYPE_ORDER = {
    0,   -- All
    4,   -- Weapon
    5,   -- Armor
    7,   -- Usable (food, medicine, etc.)
    1,   -- General
    8,   -- Crystal
    10,  -- Furnishing
};
local ITEM_TYPE_LABELS = {
    [0] = 'All Items',
    [1] = 'General',
    [4] = 'Weapons',
    [5] = 'Armor',
    [7] = 'Usable',
    [8] = 'Crystals',
    [10] = 'Furniture',
};
-- Representative item IDs for each type
local ITEM_TYPE_ICONS = {
    [0] = 6378,   -- All - Beist's Coffer (chest icon)
    [4] = 16535,  -- Bronze Sword
    [5] = 12505,  -- Bronze Cap
    [7] = 4112,   -- Potion
    [1] = 880,    -- Flint Stone
    [8] = 4096,   -- Fire Crystal
    [10] = 6232,  -- Furnishing item
};

-- Custom icon categories (subdirectories in assets/hotbar/custom/)
local CUSTOM_ICON_CATEGORIES = {};  -- Populated by scanning directory
local CUSTOM_ICON_LABELS = {
    ['all'] = 'All',
};
local customIconCategory = 'all';  -- 'all' or a folder name

-- Custom icon cache
local customIconsCache = nil;  -- All custom icons
local customIconsByCategoryCache = {};  -- Pre-filtered by category
local customIconsCacheKey = nil;

-- Custom icons directory path
local customIconsDir = nil;

-- New folder creation state
local newFolderName = { '' };

-- Delete folder confirmation state
local deleteFolderTarget = nil;  -- Category name to delete

-- Icon picker grid constants
local ICON_GRID_COLUMNS_DEFAULT = 12;  -- Default columns, recalculated based on window width
local ICON_GRID_SIZE = 36;
local ICON_GRID_GAP = 4;
local ICONS_PER_PAGE = 120;  -- 10 rows of 12 icons - loads in ~1 second

-- Progressive icon loading state (to prevent game freeze)
local iconLoadState = {
    currentPage = -1,        -- Track which page we're loading
    currentTab = -1,         -- Track which tab
    currentCacheKey = '',    -- Track filter/type changes
    loadedCount = 0,         -- How many icons loaded on current page
    iconsPerFrame = 3,       -- Load only 3 icons per frame (very smooth)
    frameSkip = 0,           -- Skip frames between loads for extra smoothness
    frameCounter = 0,        -- Current frame counter
    pageIconCache = {},      -- Cache of loaded icons for current page: [index] = icon
};

-- Reset progressive icon loading (call when page/filter/type changes)
local function ResetIconLoading()
    iconLoadState.currentPage = -1;
    iconLoadState.currentTab = -1;
    iconLoadState.currentCacheKey = '';
    iconLoadState.loadedCount = 0;
    iconLoadState.frameCounter = 0;
    iconLoadState.pageIconCache = {};
end

-- Cached spell/ability lists for icon picker (all entries, not just player-known)
local allSpellsCache = nil;
local allAbilitiesCache = nil;

-- Item icon loading state (for lazy loading)
local itemIconLoadState = {
    loaded = false,
    loading = false,
    items = {},
    itemsByType = {},  -- Pre-filtered lists by type for instant filtering
    seenNames = {},  -- Hash table for O(1) duplicate checking
    currentId = 0,
    maxId = 65535,
    batchSize = 500,  -- Load 500 items per frame (fast since we're just reading names)
};

-- Spell type sort order lookup for grouping
local SPELL_TYPE_SORT_ORDER = {};
for i, spellType in ipairs(SPELL_TYPE_ORDER) do
    SPELL_TYPE_SORT_ORDER[spellType] = i;
end

-- Build cache of ALL spells from Ashita dat (for icon picker)
local function GetAllSpells()
    if allSpellsCache then
        return allSpellsCache;
    end

    allSpellsCache = actiondb.GetAllSpellsForIconPicker();

    -- Sort by type (grouped) then by name within each type
    table.sort(allSpellsCache, function(a, b)
        local aOrder = SPELL_TYPE_SORT_ORDER[a.type] or 999;
        local bOrder = SPELL_TYPE_SORT_ORDER[b.type] or 999;
        if aOrder ~= bOrder then
            return aOrder < bOrder;
        end
        return a.name < b.name;
    end);

    return allSpellsCache;
end

local function GetAllAbilities()
    if not allAbilitiesCache then
        allAbilitiesCache = actiondb.GetAllAbilitiesForIconPicker();
    end
    return allAbilitiesCache;
end

--- Resolve spell icon for picker grid (spell id PNGs, then ListIcon fallback).
local function GetSpellPickerIcon(spell)
    if not spell then
        return nil;
    end

    -- Prefer bundled PNG assets (spell id, then dat ListIcon id).
    if spell.type == 'SummonerPact' then
        local icon = textures:GetSummonerPactAsset(spell.id, spell.icon_id);
        if icon and icon.image then
            return icon;
        end
    end

    local icon = textures:GetSpellAsset(spell.id);
    if icon and icon.image then
        return icon;
    end

    return nil;
end

local function SpellHasPickerIcon(spell)
    local icon = GetSpellPickerIcon(spell);
    return icon ~= nil and icon.image ~= nil;
end

local function AbilityHasPickerIcon(ability)
    local icon = textures:GetDefaultAbilityIcon(ability.id);
    return icon ~= nil and icon.image ~= nil;
end

-- Load a batch of item icons (for lazy loading)
local function LoadItemIconBatch()
    if itemIconLoadState.loaded or not itemIconLoadState.loading then
        return;
    end

    local resMgr = AshitaCore:GetResourceManager();
    if not resMgr then return; end

    local endId = math.min(itemIconLoadState.currentId + itemIconLoadState.batchSize, itemIconLoadState.maxId);

    for itemId = itemIconLoadState.currentId + 1, endId do
        local item = resMgr:GetItemById(itemId);
        if item and item.Name and item.Name[1] and item.Name[1] ~= '' then
            local itemName = item.Name[1];
            -- Skip duplicate names using hash table (O(1) lookup)
            if not itemIconLoadState.seenNames[itemName] then
                itemIconLoadState.seenNames[itemName] = true;
                -- Capture item type for filtering (Type field from FFXI item data)
                local itemType = item.Type or 1;
                table.insert(itemIconLoadState.items, {
                    id = itemId,
                    name = itemName,
                    itemType = itemType,
                });
            end
        end
    end

    itemIconLoadState.currentId = endId;

    if itemIconLoadState.currentId >= itemIconLoadState.maxId then
        itemIconLoadState.loaded = true;
        itemIconLoadState.loading = false;

        -- Sort items alphabetically (simple sort for All view)
        table.sort(itemIconLoadState.items, function(a, b)
            return a.name < b.name;
        end);

        -- Build pre-filtered lists by type for instant filtering
        itemIconLoadState.itemsByType = {};
        for _, item in ipairs(itemIconLoadState.items) do
            local itemType = item.itemType or 1;
            if not itemIconLoadState.itemsByType[itemType] then
                itemIconLoadState.itemsByType[itemType] = {};
            end
            table.insert(itemIconLoadState.itemsByType[itemType], item);
        end
    end
end

-- Start loading all item icons
local function StartItemIconLoading()
    if itemIconLoadState.loaded or itemIconLoadState.loading then
        return;
    end
    itemIconLoadState.loading = true;
    itemIconLoadState.currentId = 0;
    itemIconLoadState.items = {};
    itemIconLoadState.itemsByType = {};
    itemIconLoadState.seenNames = {};
end

-- Get loading progress percentage
local function GetItemLoadProgress()
    if itemIconLoadState.loaded then
        return 100;
    end
    return math.floor((itemIconLoadState.currentId / itemIconLoadState.maxId) * 100);
end

-- Get the custom icons directory path
local function GetCustomIconsDir()
    if not customIconsDir then
        customIconsDir = string.format('%saddons\\XIUI\\assets\\hotbar\\custom\\', AshitaCore:GetInstallPath());
    end
    return customIconsDir;
end

-- Recursively scan a directory for PNG files
-- pathPrefix: prepended to every entry's stored `path` (lets multi-root scans
--             disambiguate which root the icon came from at load time)
-- topLevelCategory: the immediate subdirectory name (for nested files)
local function ScanDirectoryForPngs(dir, relativePath, results, topLevelCategory, pathPrefix)
    relativePath = relativePath or '';
    results = results or {};
    pathPrefix = pathPrefix or '';

    local contents = ashita.fs.get_directory(dir, '.*');
    if not contents then return results; end

    for _, entry in pairs(contents) do
        local fullPath = dir .. entry;
        local relPath = relativePath ~= '' and (relativePath .. '\\' .. entry) or entry;

        -- Check if it's a PNG file
        if entry:lower():match('%.png$') then
            -- Category is: root (if at root level), or the top-level folder name
            local category = topLevelCategory or 'root';
            table.insert(results, {
                name = entry:gsub('%.png$', ''),  -- Remove .png extension for display
                path = pathPrefix .. relPath,  -- Stored path (resolved by TextureManager.ResolveCustomIconPath)
                category = category,
            });
        -- Check if it's a directory (no extension, not a file)
        elseif not entry:match('%.') then
            -- Determine the category for nested items
            -- If we're at root level, this entry IS the top-level category
            -- If we're already in a subdirectory, keep the original top-level category
            local categoryForNested = topLevelCategory or entry;
            -- Recursively scan subdirectory
            ScanDirectoryForPngs(fullPath .. '\\', relPath, results, categoryForNested, pathPrefix);
        end
    end

    return results;
end

-- Roots scanned for the icon picker's "Custom" tab. Submodule roots use a
-- pathPrefix so the resulting `customIconPath` round-trips through save/load
-- and resolves back to the correct disk location.
local function GetCustomIconRoots()
    local installPath = AshitaCore:GetInstallPath();
    return {
        {
            dir = string.format('%saddons\\XIUI\\assets\\hotbar\\custom\\', installPath),
            pathPrefix = '',
            includeEmptyFolders = true,  -- show user-created empty folders
        },
        {
            dir = string.format('%saddons\\XIUI\\submodules\\xiui-icons\\XIUI\\assets\\hotbar\\', installPath),
            pathPrefix = 'submodules\\xiui-icons\\',
            includeEmptyFolders = false,  -- skip submodule non-PNG folders (e.g. TEMPLATE)
        },
    };
end

-- Scan and cache all custom icons (across every configured root)
local function LoadCustomIcons()
    if customIconsCache then
        return customIconsCache;
    end

    customIconsCache = {};
    local roots = GetCustomIconRoots();
    for _, root in ipairs(roots) do
        ScanDirectoryForPngs(root.dir, '', customIconsCache, nil, root.pathPrefix);
    end

    -- Sort alphabetically by name
    table.sort(customIconsCache, function(a, b)
        return a.name:lower() < b.name:lower();
    end);

    -- Build category list from folders only
    CUSTOM_ICON_CATEGORIES = { 'all' };  -- 'all' is always first
    customIconsByCategoryCache = { ['all'] = customIconsCache };
    customCategoryIconCache = {};  -- Clear category icon cache

    local seenCategories = { ['all'] = true };

    -- First, scan each root for immediate subdirectories (including empty ones,
    -- if the root opts in — e.g. user-created folders under custom/)
    for _, root in ipairs(roots) do
        if root.includeEmptyFolders then
            local contents = ashita.fs.get_directory(root.dir, '.*');
            if contents then
                for _, entry in pairs(contents) do
                    -- Check if it's a directory (no file extension)
                    if not entry:match('%.') then
                        if not seenCategories[entry] then
                            seenCategories[entry] = true;
                            table.insert(CUSTOM_ICON_CATEGORIES, entry);
                            customIconsByCategoryCache[entry] = {};
                            -- Generate label from directory name
                            local label = entry:gsub('^%l', string.upper):gsub('_', ' ');
                            CUSTOM_ICON_LABELS[entry] = label;
                        end
                    end
                end
            end
        end
    end

    -- Then populate categories from found icons
    for _, icon in ipairs(customIconsCache) do
        -- Only add to categories for folders (not root-level files)
        if icon.category ~= 'root' then
            -- Add category if somehow not seen yet
            if not seenCategories[icon.category] then
                seenCategories[icon.category] = true;
                table.insert(CUSTOM_ICON_CATEGORIES, icon.category);
                customIconsByCategoryCache[icon.category] = {};
                local label = icon.category:gsub('^%l', string.upper):gsub('_', ' ');
                CUSTOM_ICON_LABELS[icon.category] = label;
            end
            -- Add to category-specific list
            table.insert(customIconsByCategoryCache[icon.category], icon);
        end
        -- Root files are only in 'all', no separate category
    end

    -- Sort categories alphanumerically (but keep 'all' first)
    table.sort(CUSTOM_ICON_CATEGORIES, function(a, b)
        if a == 'all' then return true; end
        if b == 'all' then return false; end
        return a:lower() < b:lower();
    end);

    return customIconsCache;
end

-- Get custom icons filtered by category
local function GetCustomIconsFiltered(category, filter)
    LoadCustomIcons();  -- Ensure loaded

    local sourceList;
    if category == 'all' then
        sourceList = customIconsCache;
    else
        sourceList = customIconsByCategoryCache[category] or {};
    end

    -- Apply text filter if any
    if filter and filter ~= '' then
        local filtered = {};
        filter = filter:lower();
        for _, icon in ipairs(sourceList) do
            if icon.name:lower():find(filter, 1, true) then
                table.insert(filtered, icon);
            end
        end
        return filtered;
    end

    return sourceList;
end

-- Load a custom icon texture by relative path (uses TextureManager with LRU caching)
local function LoadCustomIconTexture(relativePath)
    return TextureManager.getCustomIcon(relativePath);
end

-- Create a new custom icon folder
local function CreateCustomFolder(folderName)
    if not folderName or folderName == '' then return false; end

    -- Sanitize folder name (remove invalid characters)
    local sanitized = folderName:gsub('[<>:"/\\|?*]', ''):gsub('^%s+', ''):gsub('%s+$', '');
    if sanitized == '' then return false; end

    local folderPath = GetCustomIconsDir() .. sanitized;

    -- Create the directory
    ashita.fs.create_directory(folderPath);

    -- Clear caches to force rescan
    customIconsCache = nil;
    customIconsByCategoryCache = {};
    customCategoryIconCache = {};
    customIconsCacheKey = nil;

    -- Set the new folder as current category
    customIconCategory = sanitized;

    return true;
end

-- Cache for category filter icons
local customCategoryIconCache = {};

-- Track which categories are empty (for showing letter instead of icon)
local function IsCategoryEmpty(category)
    if category == 'all' then return false; end
    local categoryIcons = customIconsByCategoryCache[category];
    return not categoryIcons or #categoryIcons == 0;
end

-- Get a representative icon for a category (for filter buttons)
-- Returns icon, isEmptyFolder
local function GetCustomCategoryIcon(category)
    -- Check cache first (but not for empty folders - they might get icons added)
    if customCategoryIconCache[category] and not IsCategoryEmpty(category) then
        return customCategoryIconCache[category], false;
    end

    -- For 'all', use a special infinite symbol icon if available
    if category == 'all' then
        -- Try to use the 'infinite' icon from jobs folder
        local infiniteIcon = textures:Get('infinite');
        if infiniteIcon then
            customCategoryIconCache[category] = infiniteIcon;
            return infiniteIcon, false;
        end
        -- Fallback: use first icon from all icons
        if customIconsCache and #customIconsCache > 0 then
            local icon = LoadCustomIconTexture(customIconsCache[1].path);
            customCategoryIconCache[category] = icon;
            return icon, false;
        end
        return nil, false;
    end

    -- Get the first icon from this category (folder)
    local categoryIcons = customIconsByCategoryCache[category];
    if categoryIcons and #categoryIcons > 0 then
        local icon = LoadCustomIconTexture(categoryIcons[1].path);
        customCategoryIconCache[category] = icon;
        return icon, false;
    end

    -- Empty folder - return nil to signal we need to draw a letter
    return nil, true;
end

-- Open a custom icon folder in Windows Explorer
local function OpenCustomFolder(category)
    local folderPath;
    if category == 'all' or not category then
        folderPath = GetCustomIconsDir();
    else
        folderPath = GetCustomIconsDir() .. category;
    end
    ashita.misc.execute(folderPath, '');
end

-- Delete a custom icon folder and all its contents
local function DeleteCustomFolder(category)
    if not category or category == 'all' then return false; end

    local folderPath = GetCustomIconsDir() .. category;

    -- Delete all files in the folder first
    local contents = ashita.fs.get_directory(folderPath, '.*');
    if contents then
        for _, file in pairs(contents) do
            local filePath = folderPath .. '\\' .. file;
            os.remove(filePath);
        end
    end

    -- Delete the empty folder using Windows rmdir command
    os.execute('rmdir "' .. folderPath .. '"');

    -- Clear caches to force rescan
    customIconsCache = nil;
    customIconsByCategoryCache = {};
    customCategoryIconCache = {};
    customIconsCacheKey = nil;
    -- Also clear the action module's custom icon cache
    actions.ClearCustomIconCache();

    -- Reset to 'all' category
    customIconCategory = 'all';

    return true;
end

local function DrawIconButton(id, icon, size, isSelected, tooltipText)
    local clicked = false;
    local drawList = imgui.GetWindowDrawList();

    -- Style for selection
    if isSelected then
        imgui.PushStyleColor(ImGuiCol_Button, {0.2, 0.18, 0.1, 1.0});
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, {0.25, 0.22, 0.12, 1.0});
        imgui.PushStyleColor(ImGuiCol_Border, COLORS.gold);
        imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 2);
    else
        imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgDark);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.bgMedium);
        imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
        imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 1);
    end

    -- Get position before button
    local cursorPos = {imgui.GetCursorScreenPos()};

    -- Draw invisible button for click detection
    if imgui.Button(id, {size, size}) then
        clicked = true;
    end

    imgui.PopStyleVar();
    imgui.PopStyleColor(3);

    -- Draw icon on top
    if icon and icon.image and drawList then
        local iconPtr = tonumber(ffi.cast("uint32_t", icon.image));
        if iconPtr then
            local padding = 4;
            drawList:AddImage(
                iconPtr,
                {cursorPos[1] + padding, cursorPos[2] + padding},
                {cursorPos[1] + size - padding, cursorPos[2] + size - padding}
            );
        end
    end

    -- Tooltip
    if imgui.IsItemHovered() and tooltipText then
        imgui.BeginTooltip();
        imgui.Text(tooltipText);
        imgui.EndTooltip();
    end

    return clicked;
end


local function drawIconPickerTabs(macro)
        -- Tab buttons
        imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 1);

        local tabWidth = 70;

        -- Spells tab
        if iconPickerTab == ICON_TAB_SPELLS then
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgLight);
            imgui.PushStyleColor(ImGuiCol_Border, COLORS.gold);
        else
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgDark);
            imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
        end
        if imgui.Button('Spell', {tabWidth, 24}) then
            iconPickerTab = ICON_TAB_SPELLS;
        end
        imgui.PopStyleColor(2);

        imgui.SameLine();

        -- Abilities tab
        if iconPickerTab == ICON_TAB_ABILITIES then
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgLight);
            imgui.PushStyleColor(ImGuiCol_Border, COLORS.gold);
        else
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgDark);
            imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
        end
        if imgui.Button('Ability', {tabWidth, 24}) then
            iconPickerTab = ICON_TAB_ABILITIES;
        end
        imgui.PopStyleColor(2);

        imgui.SameLine();

        -- Items tab
        if iconPickerTab == ICON_TAB_ITEMS then
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgLight);
            imgui.PushStyleColor(ImGuiCol_Border, COLORS.gold);
        else
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgDark);
            imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
        end
        if imgui.Button('Item', {tabWidth, 24}) then
            iconPickerTab = ICON_TAB_ITEMS;
        end
        imgui.PopStyleColor(2);

        imgui.SameLine();

        -- Custom tab
        if iconPickerTab == ICON_TAB_CUSTOM then
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgLight);
            imgui.PushStyleColor(ImGuiCol_Border, COLORS.gold);
        else
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgDark);
            imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
        end
        if imgui.Button('Custom', {tabWidth, 24}) then
            iconPickerTab = ICON_TAB_CUSTOM;
        end
        imgui.PopStyleColor(2);

        imgui.SameLine();

        -- Clear icon button
        imgui.PushStyleColor(ImGuiCol_Button, COLORS.dangerDim);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.danger);
        imgui.PushStyleColor(ImGuiCol_Border, COLORS.danger);
        if imgui.Button('Clear', {50, 24}) then
            macro.customIconType = nil;
            macro.customIconId = nil;
            macro.customIconPath = nil;
            iconPickerOpen = false;
        end
        imgui.PopStyleColor(3);

        imgui.PopStyleVar();

        imgui.Spacing();
end

local function drawIconPickerSearch()
        -- Search filter
        imgui.TextColored(COLORS.goldDim, 'Search:');
        imgui.SameLine();
        imgui.SetNextItemWidth(200);
        imgui.InputText('##iconSearch', iconPickerFilter, INPUT_BUFFER_SIZE);

        -- Show loading status for items tab (count shown near page navigation)
        if iconPickerTab == ICON_TAB_ITEMS and itemIconLoadState.loading then
            imgui.SameLine();
            imgui.TextColored(COLORS.textMuted, string.format('Loading... %d%%', GetItemLoadProgress()));
        end

        imgui.Spacing();
end

local function drawIconPickerSpellFilters()
        -- Spell type filter buttons with icons (only for spells tab)
        if iconPickerTab == ICON_TAB_SPELLS then
            local filterIconSize = 24;
            imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 2);
            imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {3, 3});
            imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {2, 2});

            for i, spellType in ipairs(SPELL_TYPE_ORDER) do
                local tooltip = SPELL_TYPE_LABELS[spellType] or spellType;
                local isSelected = iconPickerSpellType == spellType;

                if isSelected then
                    imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgLight);
                    imgui.PushStyleColor(ImGuiCol_Border, COLORS.gold);
                else
                    imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgDark);
                    imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
                end

                -- Get job/trust icon
                local icon = GetFilterIcon(spellType);

                imgui.PopStyleColor(2);

                -- Use DrawIconButton which works on all Ashita versions
                if DrawIconButton('##spellFilter' .. i, icon, filterIconSize, isSelected, tooltip) then
                    iconPickerSpellType = spellType;
                    iconPickerPage[ICON_TAB_SPELLS] = 1;
                end

                if i < #SPELL_TYPE_ORDER then
                    imgui.SameLine();
                end
            end

            imgui.PopStyleVar(3);
            imgui.Spacing();
        end
end

local function drawIconPickerItemFilters()
        -- Item type filter buttons with icons (only for items tab)
        if iconPickerTab == ICON_TAB_ITEMS then
            local filterIconSize = 24;
            imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 2);
            imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {3, 3});
            imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {2, 2});

            for i, itemType in ipairs(ITEM_TYPE_ORDER) do
                local tooltip = ITEM_TYPE_LABELS[itemType] or tostring(itemType);
                local isSelected = iconPickerItemType == itemType;
                local itemId = ITEM_TYPE_ICONS[itemType];

                -- Get item icon texture
                local icon = actions.GetBindIcon({ actionType = 'item', itemId = itemId });

                -- Use DrawIconButton which works on all Ashita versions
                if DrawIconButton('##itemFilter' .. i, icon, filterIconSize, isSelected, tooltip) then
                    iconPickerItemType = itemType;
                    iconPickerPage[ICON_TAB_ITEMS] = 1;
                end

                if i < #ITEM_TYPE_ORDER then
                    imgui.SameLine();
                end
            end

            imgui.PopStyleVar(3);
            imgui.Spacing();
        end
end

local function drawIconPickerCustomFilters()
        -- Custom icon category filter buttons (only for custom tab)
        if iconPickerTab == ICON_TAB_CUSTOM then
            -- Load categories if not loaded
            LoadCustomIcons();

            local filterIconSize = 24;
            imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 2);
            imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {3, 3});
            imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {2, 2});

            local buttonsPerRow = 10;  -- Wrap after this many buttons
            local buttonCount = 0;
            local totalButtons = #CUSTOM_ICON_CATEGORIES + 1;  -- +1 for the "+" button

            for i, category in ipairs(CUSTOM_ICON_CATEGORIES) do
                local tooltip = CUSTOM_ICON_LABELS[category] or category;
                local isSelected = customIconCategory == category;

                -- Get a representative icon from this category
                local categoryIcon, isEmpty = GetCustomCategoryIcon(category);

                if isEmpty then
                    -- Empty folder - draw a button with first letter
                    local letter = category:sub(1, 1):upper();
                    if isSelected then
                        imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgLight);
                        imgui.PushStyleColor(ImGuiCol_Border, COLORS.gold);
                    else
                        imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgDark);
                        imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
                    end
                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.goldDim);
                    if imgui.Button(letter .. '##customFilter' .. i, {filterIconSize, filterIconSize}) then
                        customIconCategory = category;
                        iconPickerPage[ICON_TAB_CUSTOM] = 1;
                        filteredCustomIconsCacheKey = nil;
                    end
                    imgui.PopStyleColor(3);
                    if imgui.IsItemHovered() then
                        imgui.BeginTooltip();
                        imgui.Text(tooltip .. ' (empty)');
                        imgui.EndTooltip();
                    end
                else
                    -- Use DrawIconButton for categories with icons
                    if DrawIconButton('##customFilter' .. i, categoryIcon, filterIconSize, isSelected, tooltip) then
                        customIconCategory = category;
                        iconPickerPage[ICON_TAB_CUSTOM] = 1;
                        filteredCustomIconsCacheKey = nil;  -- Invalidate cache
                    end
                end

                buttonCount = buttonCount + 1;

                -- Handle row wrapping
                if buttonCount < totalButtons then
                    if buttonCount % buttonsPerRow == 0 then
                        -- Start new row
                    else
                        imgui.SameLine();
                    end
                end
            end

            -- "+" button to create new folder
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgDark);
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.bgLight);
            imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
            imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold);
            if imgui.Button('+##newCustomFolder', {filterIconSize, filterIconSize}) then
                newFolderName[1] = '';
                imgui.OpenPopup('Create Custom Folder##newFolderPopup');
            end
            imgui.PopStyleColor(4);
            if imgui.IsItemHovered() then
                imgui.BeginTooltip();
                imgui.Text('Create new folder');
                imgui.EndTooltip();
            end

            imgui.PopStyleVar(3);
            imgui.Spacing();

            -- Apply XIUI styling to popup
            imgui.PushStyleColor(ImGuiCol_PopupBg, COLORS.bgDark);
            imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
            imgui.PushStyleColor(ImGuiCol_TitleBg, COLORS.bgMedium);
            imgui.PushStyleColor(ImGuiCol_TitleBgActive, COLORS.bgMedium);
            imgui.PushStyleColor(ImGuiCol_FrameBg, COLORS.bgMedium);
            imgui.PushStyleColor(ImGuiCol_FrameBgHovered, COLORS.bgLight);
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgMedium);
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.bgLight);
            imgui.PushStyleColor(ImGuiCol_Text, COLORS.text);

            if imgui.BeginPopupModal('Create Custom Folder##newFolderPopup', nil, ImGuiWindowFlags_AlwaysAutoResize) then
                imgui.TextColored(COLORS.goldDim, 'Folder name:');
                imgui.SetNextItemWidth(250);
                imgui.InputText('##newFolderInput', newFolderName, 64);

                imgui.Spacing();

                -- Create button
                imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgLight);
                if imgui.Button('Create', {120, 24}) then
                    if CreateCustomFolder(newFolderName[1]) then
                        imgui.CloseCurrentPopup();
                    end
                end
                imgui.PopStyleColor();
                imgui.SameLine();
                -- Cancel button
                if imgui.Button('Cancel', {120, 24}) then
                    imgui.CloseCurrentPopup();
                end

                imgui.EndPopup();
            end

            imgui.PopStyleColor(9);
        end
end

local function buildIconPickerFilteredList()
        local filter = iconPickerFilter[1]:lower();
        local currentPage = iconPickerPage[iconPickerTab];

        -- Build cache key for filtered results
        local cacheKey;
        if iconPickerTab == ICON_TAB_SPELLS then
            cacheKey = filter .. ':spell:' .. iconPickerSpellType;
        elseif iconPickerTab == ICON_TAB_ABILITIES then
            cacheKey = filter .. ':ability';
        elseif iconPickerTab == ICON_TAB_ITEMS then
            cacheKey = filter .. ':item:' .. tostring(iconPickerItemType);
        elseif iconPickerTab == ICON_TAB_CUSTOM then
            cacheKey = filter .. ':custom:' .. customIconCategory;
        end

        -- Reset page and invalidate cache if filter/type changed
        if iconPickerTab == ICON_TAB_SPELLS then
            if cacheKey ~= filteredSpellsCacheKey then
                iconPickerPage[ICON_TAB_SPELLS] = 1;
                currentPage = 1;
                filteredSpellsCache = nil;
                filteredSpellsCacheKey = cacheKey;
            end
        elseif iconPickerTab == ICON_TAB_ABILITIES then
            if cacheKey ~= filteredAbilitiesCacheKey then
                iconPickerPage[ICON_TAB_ABILITIES] = 1;
                currentPage = 1;
                filteredAbilitiesCache = nil;
                filteredAbilitiesCacheKey = cacheKey;
            end
        elseif iconPickerTab == ICON_TAB_ITEMS then
            if cacheKey ~= filteredItemsCacheKey then
                iconPickerPage[ICON_TAB_ITEMS] = 1;
                currentPage = 1;
                filteredItemsCache = nil;
                filteredItemsCacheKey = cacheKey;
            end
        elseif iconPickerTab == ICON_TAB_CUSTOM then
            if cacheKey ~= filteredCustomIconsCacheKey then
                iconPickerPage[ICON_TAB_CUSTOM] = 1;
                currentPage = 1;
                filteredCustomIconsCacheKey = cacheKey;
            end
        end

        -- Build filtered list (with caching to avoid rebuilding every frame)
        local filteredItems = {};
        if iconPickerTab == ICON_TAB_SPELLS then
            if filteredSpellsCache then
                filteredItems = filteredSpellsCache;
            else
                local allSpells = GetAllSpells();
                for _, spell in ipairs(allSpells) do
                    local spellName = spell.name or '';
                    local matchesFilter = (filter == '' or spellName:lower():find(filter, 1, true));
                    local matchesType = (iconPickerSpellType == 'All' or spell.type == iconPickerSpellType);
                    if matchesFilter and matchesType and SpellHasPickerIcon(spell) then
                        table.insert(filteredItems, spell);
                    end
                end
                filteredSpellsCache = filteredItems;
            end
        elseif iconPickerTab == ICON_TAB_ABILITIES then
            if filteredAbilitiesCache then
                filteredItems = filteredAbilitiesCache;
            else
                local allAbilities = GetAllAbilities();
                for _, ability in ipairs(allAbilities) do
                    local abilityName = ability.name or '';
                    if (filter == '' or abilityName:lower():find(filter, 1, true))
                        and AbilityHasPickerIcon(ability) then
                        table.insert(filteredItems, ability);
                    end
                end
                filteredAbilitiesCache = filteredItems;
            end
        elseif iconPickerTab == ICON_TAB_ITEMS then
            -- Only use cache if: cache exists, not loading, and cache has items (or items DB is empty)
            local cacheValid = filteredItemsCache
                and not itemIconLoadState.loading
                and (#filteredItemsCache > 0 or #itemIconLoadState.items == 0);

            if cacheValid then
                filteredItems = filteredItemsCache;
            else
                -- Use pre-filtered type list if available and a specific type is selected
                local sourceItems;
                if iconPickerItemType ~= 0 and itemIconLoadState.itemsByType[iconPickerItemType] then
                    sourceItems = itemIconLoadState.itemsByType[iconPickerItemType];
                else
                    sourceItems = itemIconLoadState.items;
                end

                -- Only filter by text search (type already filtered by source list)
                if sourceItems and #sourceItems > 0 then
                    if filter == '' then
                        -- No text filter - use source directly
                        filteredItems = sourceItems;
                    else
                        -- Apply text filter
                        for _, item in ipairs(sourceItems) do
                            local itemName = item.name or '';
                            if itemName:lower():find(filter, 1, true) then
                                table.insert(filteredItems, item);
                            end
                        end
                    end
                end

                -- Only cache if loading is complete and we have results (or filter should return empty)
                if not itemIconLoadState.loading and (#filteredItems > 0 or filter ~= '') then
                    filteredItemsCache = filteredItems;
                end
            end
        elseif iconPickerTab == ICON_TAB_CUSTOM then
            -- Custom icons - use pre-filtered category list
            filteredItems = GetCustomIconsFiltered(customIconCategory, filter);
        end

    local totalItems = #filteredItems;
    local totalPages = math.max(1, math.ceil(totalItems / ICONS_PER_PAGE));
    if currentPage > totalPages then
        currentPage = totalPages;
        iconPickerPage[iconPickerTab] = currentPage;
    end
    return filteredItems, cacheKey, currentPage, totalItems, totalPages;
end

local function drawIconPickerListHeader(totalItems)
        -- Show filtered count for spells, abilities, and custom
        if iconPickerTab == ICON_TAB_SPELLS then
            local countText = string.format('%d spells', totalItems);
            if iconPickerSpellType ~= 'All' then
                countText = countText .. ' (' .. (SPELL_TYPE_LABELS[iconPickerSpellType] or iconPickerSpellType) .. ')';
            end
            imgui.TextColored(COLORS.textMuted, countText);
        elseif iconPickerTab == ICON_TAB_ABILITIES then
            imgui.TextColored(COLORS.textMuted, string.format('%d abilities', totalItems));
        elseif iconPickerTab == ICON_TAB_CUSTOM then
            local allCustom = LoadCustomIcons();
            local countText = string.format('%d of %d custom icons', totalItems, #allCustom);
            if customIconCategory ~= 'all' then
                countText = countText .. ' (' .. (CUSTOM_ICON_LABELS[customIconCategory] or customIconCategory) .. ')';
            end
            imgui.TextColored(COLORS.textMuted, countText);

            -- Delete folder button (only for specific categories, not 'all')
            if customIconCategory ~= 'all' then
                imgui.SameLine(imgui.GetWindowWidth() - 145);
                imgui.PushStyleColor(ImGuiCol_Button, COLORS.dangerDim);
                imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.danger);
                imgui.PushStyleColor(ImGuiCol_Text, COLORS.text);
                if imgui.Button('Delete##deleteFolder', {55, 18}) then
                    deleteFolderTarget = customIconCategory;
                    imgui.OpenPopup('Delete Folder##deleteFolderPopup');
                end
                imgui.PopStyleColor(3);
            end

            -- Refresh button on the right
            imgui.SameLine(imgui.GetWindowWidth() - 80);
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgDark);
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.bgLight);
            imgui.PushStyleColor(ImGuiCol_Text, COLORS.goldDim);
            if imgui.Button('Refresh##refreshCustom', {60, 18}) then
                -- Clear all caches to force rescan
                customIconsCache = nil;
                customIconsByCategoryCache = {};
                customCategoryIconCache = {};
                filteredCustomIconsCacheKey = nil;
                -- Clear TextureManager custom icons cache
                TextureManager.clearCategory('custom_icons');
                -- Also clear the action module's custom icon cache
                actions.ClearCustomIconCache();
                -- Reset progressive loading
                ResetIconLoading();
            end
            imgui.PopStyleColor(3);

            -- Delete folder confirmation popup
            imgui.PushStyleColor(ImGuiCol_PopupBg, COLORS.bgDark);
            imgui.PushStyleColor(ImGuiCol_Border, COLORS.danger);
            imgui.PushStyleColor(ImGuiCol_TitleBg, COLORS.dangerDim);
            imgui.PushStyleColor(ImGuiCol_TitleBgActive, COLORS.dangerDim);
            imgui.PushStyleColor(ImGuiCol_Text, COLORS.text);
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgMedium);
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.bgLight);

            if imgui.BeginPopupModal('Delete Folder##deleteFolderPopup', nil, ImGuiWindowFlags_AlwaysAutoResize) then
                local categoryLabel = CUSTOM_ICON_LABELS[deleteFolderTarget] or deleteFolderTarget or '';
                local iconCount = customIconsByCategoryCache[deleteFolderTarget] and #customIconsByCategoryCache[deleteFolderTarget] or 0;

                imgui.TextColored(COLORS.danger, 'Delete folder "' .. categoryLabel .. '"?');
                imgui.Spacing();

                if iconCount > 0 then
                    imgui.TextColored(COLORS.text, 'This will permanently delete ' .. iconCount .. ' icon(s).');
                else
                    imgui.TextColored(COLORS.textMuted, 'This folder is empty.');
                end
                imgui.TextColored(COLORS.textMuted, 'This action cannot be undone.');

                imgui.Spacing();
                imgui.Spacing();

                -- Delete button
                imgui.PushStyleColor(ImGuiCol_Button, COLORS.danger);
                imgui.PushStyleColor(ImGuiCol_ButtonHovered, {1.0, 0.4, 0.4, 1.0});
                if imgui.Button('Delete', {100, 24}) then
                    DeleteCustomFolder(deleteFolderTarget);
                    deleteFolderTarget = nil;
                    imgui.CloseCurrentPopup();
                end
                imgui.PopStyleColor(2);

                imgui.SameLine();

                -- Cancel button
                if imgui.Button('Cancel', {100, 24}) then
                    deleteFolderTarget = nil;
                    imgui.CloseCurrentPopup();
                end

                imgui.EndPopup();
            end

            imgui.PopStyleColor(7);
        end
end

local function drawIconPickerPagination(currentPage, totalPages, totalItems)
        -- Page navigation UI
        if totalPages > 1 then
            imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 1);
            imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);

            -- Previous button
            local canGoPrev = currentPage > 1;
            if not canGoPrev then
                imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgDark);
                imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.bgDark);
                imgui.PushStyleColor(ImGuiCol_Text, COLORS.textMuted);
            end
            if imgui.Button('<##prevPage', {30, 22}) and canGoPrev then
                iconPickerPage[iconPickerTab] = currentPage - 1;
            end
            if not canGoPrev then
                imgui.PopStyleColor(3);
            end

            imgui.SameLine();

            -- Page info
            imgui.TextColored(COLORS.text, string.format('Page %d / %d', currentPage, totalPages));

            imgui.SameLine();

            -- Next button
            local canGoNext = currentPage < totalPages;
            if not canGoNext then
                imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgDark);
                imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.bgDark);
                imgui.PushStyleColor(ImGuiCol_Text, COLORS.textMuted);
            end
            if imgui.Button('>##nextPage', {30, 22}) and canGoNext then
                iconPickerPage[iconPickerTab] = currentPage + 1;
            end
            if not canGoNext then
                imgui.PopStyleColor(3);
            end

            imgui.SameLine();
            imgui.TextColored(COLORS.textMuted, string.format('(%d total)', totalItems));

            imgui.PopStyleColor();
            imgui.PopStyleVar();

            imgui.Spacing();
        end
end

local function drawIconPickerGrid(macro, filteredItems, cacheKey, currentPage, startIdx, endIdx, totalItems)
        -- Icon grid with scrollbar - use child window with border for scrolling
        local childFlags = ImGuiWindowFlags_AlwaysVerticalScrollbar;
        imgui.PushStyleColor(ImGuiCol_ChildBg, COLORS.bgDark);
        imgui.PushStyleColor(ImGuiCol_Border, COLORS.border);
        imgui.BeginChild('IconGrid', {0, 0}, true, childFlags);

        -- Calculate dynamic column count based on available width (icons wrap to next row)
        local availableWidth = imgui.GetContentRegionAvail();
        local iconGridColumns = math.max(1, math.floor((availableWidth + ICON_GRID_GAP) / (ICON_GRID_SIZE + ICON_GRID_GAP)));

        local displayedCount = 0;

        if iconPickerTab == ICON_TAB_SPELLS then
            -- Spell icons - render current page from filtered list
            if totalItems == 0 then
                imgui.TextColored(COLORS.textMuted, 'No matching spells found');
            else
                for i = startIdx, endIdx do
                    local spell = filteredItems[i];
                    if spell then
                        local icon = GetSpellPickerIcon(spell);

                        if icon and icon.image then
                            -- Handle grid layout (dynamic columns based on window width)
                            local col = displayedCount % iconGridColumns;
                            if col > 0 then
                                imgui.SameLine(0, ICON_GRID_GAP);
                            end

                            -- Show spell type in tooltip for trusts
                            local tooltipText = spell.name;
                            if spell.type and spell.type ~= 'Unknown' then
                                tooltipText = spell.name .. ' (' .. (SPELL_TYPE_LABELS[spell.type] or spell.type) .. ')';
                            end

                            local isSelected = macro.customIconType == 'spell' and macro.customIconId == spell.id;
                            if DrawIconButton('##spell' .. spell.id, icon, ICON_GRID_SIZE, isSelected, tooltipText) then
                                macro.customIconType = 'spell';
                                macro.customIconId = spell.id;
                                iconPickerOpen = false;
                            end

                            displayedCount = displayedCount + 1;
                        end
                    end
                end
            end

        elseif iconPickerTab == ICON_TAB_ABILITIES then
            if totalItems == 0 then
                imgui.TextColored(COLORS.textMuted, 'No matching abilities found');
            else
                for i = startIdx, endIdx do
                    local ability = filteredItems[i];
                    if ability then
                        local icon = textures:GetDefaultAbilityIcon(ability.id);
                        if icon and icon.image then
                            local col = displayedCount % iconGridColumns;
                            if col > 0 then
                                imgui.SameLine(0, ICON_GRID_GAP);
                            end

                            local isSelected = macro.customIconType == 'ability'
                                and macro.customIconId == ability.id;
                            if DrawIconButton('##ability' .. ability.id, icon, ICON_GRID_SIZE, isSelected, ability.name) then
                                macro.customIconType = 'ability';
                                macro.customIconId = ability.id;
                                macro.customIconPath = nil;
                                iconPickerOpen = false;
                            end

                            displayedCount = displayedCount + 1;
                        end
                    end
                end
            end

        elseif iconPickerTab == ICON_TAB_ITEMS then
            -- Item icons - render current page from filtered list with progressive loading
            if itemIconLoadState.loading and #itemIconLoadState.items == 0 then
                imgui.TextColored(COLORS.textMuted, 'Loading item database...');
            elseif totalItems == 0 then
                imgui.TextColored(COLORS.textMuted, 'No matching items found');
            else
                -- Check if page/tab/filter changed - reset icon cache
                local loadCacheKey = cacheKey .. ':' .. tostring(currentPage);
                if iconLoadState.currentCacheKey ~= loadCacheKey then
                    iconLoadState.currentPage = currentPage;
                    iconLoadState.currentTab = iconPickerTab;
                    iconLoadState.currentCacheKey = loadCacheKey;
                    iconLoadState.loadedCount = 0;
                    iconLoadState.pageIconCache = {};
                end

                local pageItemCount = endIdx - startIdx + 1;

                -- Progressive loading: load only a few icons per frame to prevent lag
                -- Frame skip allows even more breathing room for the game
                iconLoadState.frameCounter = iconLoadState.frameCounter + 1;
                local shouldLoadThisFrame = (iconLoadState.frameCounter > iconLoadState.frameSkip);

                if shouldLoadThisFrame and iconLoadState.loadedCount < pageItemCount then
                    iconLoadState.frameCounter = 0;  -- Reset frame counter

                    local iconsToLoad = math.min(iconLoadState.iconsPerFrame, pageItemCount - iconLoadState.loadedCount);

                    for _ = 1, iconsToLoad do
                        local cacheIdx = iconLoadState.loadedCount + 1;
                        local itemIdx = startIdx + iconLoadState.loadedCount;
                        local item = filteredItems[itemIdx];

                        if item then
                            -- Use memory-only loading (no PNG creation) for browsing
                            local icon = actions.GetItemIconForBrowsing(item.id);
                            iconLoadState.pageIconCache[cacheIdx] = icon;
                        end

                        iconLoadState.loadedCount = iconLoadState.loadedCount + 1;
                    end
                end

                -- Show loading progress if still loading
                local isStillLoading = iconLoadState.loadedCount < pageItemCount;
                if isStillLoading then
                    local pct = math.floor((iconLoadState.loadedCount / pageItemCount) * 100);
                    imgui.TextColored(COLORS.gold, string.format('Loading icons... %d%%', pct));
                    imgui.Spacing();
                end

                -- Render loaded icons
                for cacheIdx = 1, iconLoadState.loadedCount do
                    local itemIdx = startIdx + cacheIdx - 1;
                    local item = filteredItems[itemIdx];
                    local icon = iconLoadState.pageIconCache[cacheIdx];

                    if item and icon and icon.image then
                        -- Handle grid layout (dynamic columns based on window width)
                        local col = displayedCount % iconGridColumns;
                        if col > 0 then
                            imgui.SameLine(0, ICON_GRID_GAP);
                        end

                        -- Show item type in tooltip
                        local tooltipText = item.name;
                        local typeLabel = ITEM_TYPE_LABELS[item.itemType];
                        if typeLabel and typeLabel ~= 'All' then
                            tooltipText = item.name .. ' (' .. typeLabel .. ')';
                        end

                        local isSelected = macro.customIconType == 'item' and macro.customIconId == item.id;
                        if DrawIconButton('##item' .. item.id, icon, ICON_GRID_SIZE, isSelected, tooltipText) then
                            macro.customIconType = 'item';
                            macro.customIconId = item.id;
                            iconPickerOpen = false;
                        end

                        displayedCount = displayedCount + 1;
                    end
                end
            end

        elseif iconPickerTab == ICON_TAB_CUSTOM then
            -- Custom icons - render from custom directory with progressive loading
            if totalItems == 0 then
                if customIconCategory ~= 'all' then
                    -- Empty category folder
                    local categoryLabel = CUSTOM_ICON_LABELS[customIconCategory] or customIconCategory;
                    imgui.TextColored(COLORS.textMuted, 'No icons in "' .. categoryLabel .. '"');
                    imgui.Spacing();
                    imgui.TextColored(COLORS.textMuted, 'Add PNG images to this folder:');
                    imgui.Spacing();

                    -- Open Folder button
                    imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgLight);
                    imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.bgLighter);
                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold);
                    if imgui.Button('Open Folder##openCustomFolder', {120, 26}) then
                        OpenCustomFolder(customIconCategory);
                    end
                    imgui.PopStyleColor(3);
                else
                    -- No custom icons at all
                    imgui.TextColored(COLORS.textMuted, 'No custom icons found');
                    imgui.Spacing();
                    imgui.TextColored(COLORS.textMuted, 'Add PNG images to:');
                    imgui.TextColored(COLORS.goldDim, 'addons/XIUI/assets/hotbar/custom/');
                    imgui.Spacing();
                    imgui.Spacing();

                    -- Open Folder button
                    imgui.PushStyleColor(ImGuiCol_Button, COLORS.bgLight);
                    imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.bgLighter);
                    imgui.PushStyleColor(ImGuiCol_Text, COLORS.gold);
                    if imgui.Button('Open Folder##openCustomFolder', {120, 26}) then
                        OpenCustomFolder('all');
                    end
                    imgui.PopStyleColor(3);
                end
            else
                -- Check if page/tab/filter changed - reset icon cache
                local loadCacheKey = cacheKey .. ':' .. tostring(currentPage);
                if iconLoadState.currentCacheKey ~= loadCacheKey or iconLoadState.currentTab ~= iconPickerTab then
                    iconLoadState.currentPage = currentPage;
                    iconLoadState.currentTab = iconPickerTab;
                    iconLoadState.currentCacheKey = loadCacheKey;
                    iconLoadState.loadedCount = 0;
                    iconLoadState.pageIconCache = {};
                end

                local pageItemCount = endIdx - startIdx + 1;

                -- Progressive loading: load only a few icons per frame to prevent lag
                iconLoadState.frameCounter = iconLoadState.frameCounter + 1;
                local shouldLoadThisFrame = (iconLoadState.frameCounter > iconLoadState.frameSkip);

                if shouldLoadThisFrame and iconLoadState.loadedCount < pageItemCount then
                    iconLoadState.frameCounter = 0;

                    local iconsToLoad = math.min(iconLoadState.iconsPerFrame, pageItemCount - iconLoadState.loadedCount);

                    for _ = 1, iconsToLoad do
                        local cacheIdx = iconLoadState.loadedCount + 1;
                        local itemIdx = startIdx + iconLoadState.loadedCount;
                        local customIcon = filteredItems[itemIdx];

                        if customIcon then
                            local icon = LoadCustomIconTexture(customIcon.path);
                            iconLoadState.pageIconCache[cacheIdx] = icon;
                        end

                        iconLoadState.loadedCount = iconLoadState.loadedCount + 1;
                    end
                end

                -- Show loading progress if still loading
                local isStillLoading = iconLoadState.loadedCount < pageItemCount;
                if isStillLoading then
                    local pct = math.floor((iconLoadState.loadedCount / pageItemCount) * 100);
                    imgui.TextColored(COLORS.gold, string.format('Loading icons... %d%%', pct));
                    imgui.Spacing();
                end

                -- Render loaded icons from cache
                for cacheIdx = 1, iconLoadState.loadedCount do
                    local itemIdx = startIdx + cacheIdx - 1;
                    local customIcon = filteredItems[itemIdx];
                    local icon = iconLoadState.pageIconCache[cacheIdx];

                    if customIcon and icon and icon.image then
                        -- Handle grid layout (dynamic columns based on window width)
                        local col = displayedCount % iconGridColumns;
                        if col > 0 then
                            imgui.SameLine(0, ICON_GRID_GAP);
                        end

                        -- Show category in tooltip
                        local tooltipText = customIcon.name;
                        if customIcon.category ~= 'root' then
                            local categoryLabel = CUSTOM_ICON_LABELS[customIcon.category] or customIcon.category;
                            tooltipText = customIcon.name .. ' (' .. categoryLabel .. ')';
                        end

                        local isSelected = macro.customIconType == 'custom' and macro.customIconPath == customIcon.path;
                        if DrawIconButton('##custom' .. itemIdx, icon, ICON_GRID_SIZE, isSelected, tooltipText) then
                            macro.customIconType = 'custom';
                            macro.customIconPath = customIcon.path;
                            macro.customIconId = nil;
                            iconPickerOpen = false;
                        end

                        displayedCount = displayedCount + 1;
                    end
                end
            end
        end

        imgui.EndChild();
        imgui.PopStyleColor(2);  -- ChildBg, Border
end

local function resetIconPickerState()
        iconPickerOpen = false;
        iconPickerFilter[1] = '';
        iconPickerPage = { 1, 1, 1, 1 };
        iconPickerLastFilter = { '', '', '', '' };
        iconPickerSpellType = 'All';
        iconPickerItemType = 0;
        customIconCategory = 'all';
        filteredSpellsCache = nil;
        filteredSpellsCacheKey = nil;
        filteredAbilitiesCache = nil;
        filteredAbilitiesCacheKey = nil;
        filteredItemsCache = nil;
        filteredItemsCacheKey = nil;
        filteredCustomIconsCacheKey = nil;
        -- Reset progressive icon loading
        ResetIconLoading();
end

-- Draw the icon picker popup
local function drawIconPicker(macro)
    if not iconPickerOpen or not macro then
        return;
    end

    if iconPickerTab == ICON_TAB_ITEMS then
        StartItemIconLoading();
        LoadItemIconBatch();
    end

    local isOpen = { true };

    local gridContentWidth = (ICON_GRID_SIZE * ICON_GRID_COLUMNS_DEFAULT) + (ICON_GRID_GAP * (ICON_GRID_COLUMNS_DEFAULT - 1));
    local defaultWindowWidth = gridContentWidth + 40;
    local windowHeight = 500;
    local minWindowWidth = (ICON_GRID_SIZE * 4) + (ICON_GRID_GAP * 3) + 40;

    imgui.SetNextWindowSize({defaultWindowWidth, windowHeight}, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({minWindowWidth, 300}, {1000, 800});

    PushWindowStyle();

    if imgui.Begin('Select Icon###IconPicker', isOpen, ImGuiWindowFlags_NoCollapse) then
        drawIconPickerTabs(macro);
        drawIconPickerSearch();
        drawIconPickerSpellFilters();
        drawIconPickerItemFilters();
        drawIconPickerCustomFilters();

        local filteredItems, cacheKey, currentPage, totalItems, totalPages = buildIconPickerFilteredList();
        drawIconPickerListHeader(totalItems);
        drawIconPickerPagination(currentPage, totalPages, totalItems);

        imgui.Separator();
        imgui.Spacing();

        local startIdx = (currentPage - 1) * ICONS_PER_PAGE + 1;
        local endIdx = math.min(currentPage * ICONS_PER_PAGE, totalItems);
        drawIconPickerGrid(macro, filteredItems, cacheKey, currentPage, startIdx, endIdx, totalItems);
    end

    imgui.End();
    PopWindowStyle();

    if not isOpen[1] then
        resetIconPickerState();
    end
end

function M.open()
    iconPickerOpen = true;
    iconPickerFilter[1] = '';
end

function M.close()
    iconPickerOpen = false;
    iconPickerFilter[1] = '';
end

function M.isOpen()
    return iconPickerOpen;
end

function M.draw(macro)
    drawIconPicker(macro);
end

return M;
