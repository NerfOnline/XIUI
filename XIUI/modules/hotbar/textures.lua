--[[
* XIUI hotbar - Texture Loading Module
* Loads and caches spell/ability icons and item icons
]]--
require('handlers.helpers');
local ffi = require('ffi');
local d3d8 = require('d3d8');
local pngencoder = require('libs.pngencoder');
local actiondb = require('modules.hotbar.actiondb');

-- Item icon cache directory (initialized lazily)
local itemCacheDir = nil;

-- Hotbar asset root (set during Initialize; used for on-demand icon loads)
local hotbarAssetsDirectory = nil;

-- cachePrefix -> assets/hotbar subfolder for list-icon PNGs
local LIST_ICON_SUBDIRS = {
    abilities = 'abilities\\',
    weaponskills = 'weaponskills\\',
    petcommands = 'petcommands\\',
};

-- Load texture from full file path with high quality (no filtering)
-- Returns: { image = IDirect3DTexture8*, path = filePath, width, height }
local function LoadTextureFromPath(filePath)
    local device = GetD3D8Device();
    if (device == nil) then return nil; end
    local textureData = T{};
    local texture_ptr = ffi.new('IDirect3DTexture8*[1]');

    -- Use D3DXCreateTextureFromFileExA with D3DX_FILTER_NONE for best quality
    local res = ffi.C.D3DXCreateTextureFromFileExA(
        device, filePath,
        0xFFFFFFFF, 0xFFFFFFFF,  -- D3DX_DEFAULT size
        1,                        -- MipLevels
        0,                        -- Usage
        ffi.C.D3DFMT_A8R8G8B8,   -- Format with alpha
        ffi.C.D3DPOOL_MANAGED,   -- Pool
        1,                        -- D3DX_FILTER_NONE
        1,                        -- D3DX_FILTER_NONE for mips
        0,                        -- No color key
        nil, nil,
        texture_ptr
    );
    if (res ~= ffi.C.S_OK) then
        return nil;
    end
    textureData.image = ffi.new('IDirect3DTexture8*', texture_ptr[0]);
    d3d8.gc_safe_release(textureData.image);

    -- Store path for primitive rendering
    textureData.path = filePath;

    -- Default size (spell icons are typically 40x40)
    textureData.width = 40;
    textureData.height = 40;
    return textureData;
end
local function EnsureCache(self)
    if not self.Cache then
        self:Initialize();
    end
end

--- Load a bundled PNG on first use; cache hits and misses avoid repeat disk/GPU work.
local function GetOrLoadCachedAsset(self, cacheKey, filePath)
    EnsureCache(self);
    local entry = self.Cache[cacheKey];
    if entry == false then
        return nil;
    end
    if entry then
        return entry;
    end
    if not ashita.fs.exists(filePath) then
        self.Cache[cacheKey] = false;
        return nil;
    end
    local texture = LoadTextureFromPath(filePath);
    if texture then
        self.Cache[cacheKey] = texture;
        return texture;
    end
    self.Cache[cacheKey] = false;
    return nil;
end
local textures = {};
textures.Initialize = function(self)
    if self.Cache then
        return;
    end
    self.Cache = {};

    -- Only preload small fixed UI assets. Spell/ability/WS/pet PNGs load on demand.
    hotbarAssetsDirectory = string.format('%saddons\\XIUI\\assets\\hotbar\\', AshitaCore:GetInstallPath());
    local assetsDirectory = hotbarAssetsDirectory;
    local slotBg = LoadTextureFromPath(assetsDirectory .. 'slot.png');
    if slotBg then
        self.Cache['slot'] = slotBg;
    end
    local frame = LoadTextureFromPath(assetsDirectory .. 'frame.png');
    if frame then
        self.Cache['frame'] = frame;
    end

    -- Load native FFXI ability icons, named by IAbility.Id (00528.png = Mighty
    -- Strikes) and cached under 'abilities<id>' (e.g. 'abilities00528').
    local abilityDirectory = string.format('%saddons\\XIUI\\assets\\hotbar\\abilities\\', AshitaCore:GetInstallPath());
    local abilityContents = ashita.fs.get_directory(abilityDirectory, '.*\\.png$');
    if abilityContents then
        for _, file in pairs(abilityContents) do
            local base = file:match('^(.-)%.png$');  -- icon id stem, e.g. "00066"
            if base then
                local key = 'abilities' .. base;
                if not self.Cache[key] then
                    local texture = LoadTextureFromPath(abilityDirectory .. file);
                    if texture then
                        self.Cache[key] = texture;
                    end
                end
            end
        end
    end

    -- Load controller button icons for crossbar (from subdirectories)
    local controllerDirectory = assetsDirectory .. 'controller\\';

    -- D-pad and triggers are in Shared folder
    local sharedIcons = { 'UP', 'DOWN', 'LEFT', 'RIGHT', 'L1', 'L2', 'R1', 'R2' };
    for _, iconName in ipairs(sharedIcons) do
        local fullPath = controllerDirectory .. 'Shared\\' .. iconName .. '.png';
        local texture = LoadTextureFromPath(fullPath);
        if texture then
            self.Cache['controller_' .. iconName] = texture;
        end
    end

    -- PlayStation face buttons
    local playstationIcons = { 'X', 'Square', 'Triangle', 'Circle' };
    for _, iconName in ipairs(playstationIcons) do
        local fullPath = controllerDirectory .. 'PlayStation\\' .. iconName .. '.png';
        local texture = LoadTextureFromPath(fullPath);
        if texture then
            self.Cache['controller_' .. iconName] = texture;
        end
    end

    -- Xbox face buttons (alternative naming)
    local xboxIcons = { 'A', 'B', 'X', 'Y' };
    for _, iconName in ipairs(xboxIcons) do
        local fullPath = controllerDirectory .. 'Xbox\\' .. iconName .. '.png';
        local texture = LoadTextureFromPath(fullPath);
        if texture then
            -- Store under generic controller_<name> keys (consistent with PlayStation/Nintendo/Stadia)
            self.Cache['controller_' .. iconName] = texture;
        end
    end

    -- Nintendo / Pro controller face buttons (load into generic controller_<name> keys like PlayStation)
    local nintendoIcons = { 'A', 'B', 'X', 'Y' };
    for _, iconName in ipairs(nintendoIcons) do
        local fullPath = controllerDirectory .. 'Nintendo\\' .. iconName .. '.png';
        local texture = LoadTextureFromPath(fullPath);
        if texture then
            -- Store under the same key pattern used for PlayStation (controller_X, controller_A, etc.)
            self.Cache['controller_' .. iconName] = texture;
        end
    end

    -- Stadia face buttons (load into generic controller_<name> keys like PlayStation)
    local stadiaIcons = { 'A', 'B', 'X', 'Y' };
    for _, iconName in ipairs(stadiaIcons) do
        local fullPath = controllerDirectory .. 'Stadia\\' .. iconName .. '.png';
        local texture = LoadTextureFromPath(fullPath);
        if texture then
            self.Cache['controller_' .. iconName] = texture;
        end
    end

    -- UI indicator icons from assets/icons
    local iconsDirectory = string.format('%saddons\\XIUI\\assets\\icons\\', AshitaCore:GetInstallPath());
    local uiIcons = {
        { file = 'refresh', key = 'ui_refresh' },
    };
    for _, icon in ipairs(uiIcons) do
        local fullPath = iconsDirectory .. icon.file .. '.png';
        local texture = LoadTextureFromPath(fullPath);
        if texture then
            self.Cache[icon.key] = texture;
        end
    end

    -- Skillchain icons for WS slot highlighting
    local skillchainDirectory = string.format('%saddons\\XIUI\\assets\\hotbar\\skillchain\\', AshitaCore:GetInstallPath());
    local skillchainNames = {
        'Compression', 'Darkness', 'Detonation', 'Distortion',
        'Fragmentation', 'Fusion', 'Gravitation', 'Impaction',
        'Induration', 'Light', 'Liquefaction', 'Reverberation',
        'Scission', 'Transfixion',
    };
    for _, name in ipairs(skillchainNames) do
        local fullPath = skillchainDirectory .. name .. '.png';
        local texture = LoadTextureFromPath(fullPath);
        if texture then
            self.Cache['skillchain_' .. name] = texture;
        end
    end
end
textures.Release = function(self)
    if self.Cache then
        self.Cache = nil;
    end
end

-- Get texture by filename or key
textures.Get = function(self, key)
    if not self.Cache then
        return nil;
    end
    local entry = self.Cache[key];
    if entry == false then
        return nil;
    end
    return entry;
end

--- Spell PNG from assets/hotbar/spells/{spellId}.png (duplicate ids redirect to canonical icon).
--- SummonerPact spells use GetSummonerPactAsset instead.
textures.GetSpellAsset = function(self, spellId)
    if not spellId then
        return nil;
    end
    EnsureCache(self);
    if not hotbarAssetsDirectory then
        return nil;
    end
    local iconSpellId = actiondb.ResolveSpellIconId(spellId);
    if not iconSpellId then
        return nil;
    end
    local cacheKey = 'spells' .. tostring(iconSpellId);
    local filePath = hotbarAssetsDirectory .. 'spells\\' .. tostring(iconSpellId) .. '.png';
    return GetOrLoadCachedAsset(self, cacheKey, filePath);
end

--- Bundled PNG by list icon id prefix (e.g. abilities404, weaponskills598).
textures.GetListIconAsset = function(self, cachePrefix, listIconId)
    if not listIconId or listIconId <= 0 then
        return nil;
    end
    EnsureCache(self);
    if not hotbarAssetsDirectory then
        return nil;
    end
    local subdir = LIST_ICON_SUBDIRS[cachePrefix];
    if not subdir then
        return nil;
    end
    local cacheKey = cachePrefix .. tostring(listIconId);
    local filePath = hotbarAssetsDirectory .. subdir .. tostring(listIconId) .. '.png';
    return GetOrLoadCachedAsset(self, cacheKey, filePath);
end

--- Job ability icon from assets/hotbar/abilities (dat list icon id + remaps).
textures.GetAbilityAsset = function(self, abilityId)
    if not abilityId then
        return nil;
    end
    local resourceMgr = AshitaCore:GetResourceManager();
    local ability = resourceMgr and resourceMgr:GetAbilityById(abilityId);
    local listIconId = actiondb.GetAbilityListIconId(abilityId, ability);
    return self:GetListIconAsset('abilities', listIconId);
end

--- Weaponskill icon from assets/hotbar/weaponskills (dat list icon id + remaps).
textures.GetWeaponskillAsset = function(self, abilityId)
    if not abilityId then
        return nil;
    end
    local resourceMgr = AshitaCore:GetResourceManager();
    local ability = resourceMgr and resourceMgr:GetAbilityById(abilityId);
    local listIconId = actiondb.GetWeaponskillListIconId(abilityId, ability);
    return self:GetListIconAsset('weaponskills', listIconId);
end

--- Pet command icon from assets/hotbar/petcommands (dat list icon id + remaps).
textures.GetPetCommandAsset = function(self, abilityId)
    if not abilityId then
        return nil;
    end
    local resourceMgr = AshitaCore:GetResourceManager();
    local ability = resourceMgr and resourceMgr:GetAbilityById(abilityId);
    local listIconId = actiondb.GetPetCommandListIconId(abilityId, ability);
    return self:GetListIconAsset('petcommands', listIconId);
end

--- SummonerPact spell icon from assets/hotbar/petcommands (spell dat list icon id).
textures.GetSummonerPactAsset = function(self, spellId, listIconId)
    if (not listIconId or listIconId <= 0) and spellId then
        local resourceMgr = AshitaCore:GetResourceManager();
        local spell = resourceMgr and resourceMgr:GetSpellById(spellId);
        listIconId = actiondb.GetSummonerPactListIconId(spell);
    end
    return self:GetListIconAsset('petcommands', listIconId);
end

--- Default bundled icon for an ability dat row (folder by ability type + database/icon_redirect).
textures.GetDefaultAbilityIcon = function(self, abilityId, ability)
    if not abilityId then
        return nil;
    end
    local resourceMgr = AshitaCore:GetResourceManager();
    ability = ability or (resourceMgr and resourceMgr:GetAbilityById(abilityId));
    if not ability then
        return nil;
    end
    local abilityType = ability.Type or 0;
    if actiondb.IsWeaponskillAbilityType(abilityType) then
        return self:GetWeaponskillAsset(abilityId);
    end
    if actiondb.IsPetAbilityType(abilityType) then
        return self:GetPetCommandAsset(abilityId);
    end
    return self:GetAbilityAsset(abilityId);
end

-- Get texture path by key (for primitive rendering)
textures.GetPath = function(self, key)
    if not self.Cache then return nil; end
    local entry = self.Cache[key];
    if entry and entry ~= false and entry.path then
        return entry.path;
    end
    return nil;
end

-- Get controller button icon by name
-- iconName: 'X', 'Square', 'Triangle', 'Circle', 'L1', 'L2', 'R1', 'R2', 'UP', 'DOWN', 'LEFT', 'RIGHT'
textures.GetControllerIcon = function(self, iconName)
    if not self.Cache then
        return nil;
    end
    return self.Cache['controller_' .. iconName];
end

-- Map crossbar slot index to controller button name
-- Slots 1-4 are d-pad (UP, RIGHT, DOWN, LEFT in diamond order)
-- Slots 5-8 are face buttons (Triangle, Circle, X, Square in diamond order)
textures.GetButtonNameForSlot = function(self, slotIndex)
    local buttonMap = {
        [1] = 'UP',
        [2] = 'RIGHT',
        [3] = 'DOWN',
        [4] = 'LEFT',
        [5] = 'Triangle',
        [6] = 'Circle',
        [7] = 'X',
        [8] = 'Square',
    };
    return buttonMap[slotIndex];
end

-- ============================================
-- Item Icon File Cache System
-- Saves item bitmaps to disk for primitive rendering
-- ============================================

-- Get the item icon cache directory (creates if needed)
local function GetItemCacheDir()
    if not itemCacheDir then
        itemCacheDir = string.format('%saddons\\XIUI\\assets\\hotbar\\items\\', AshitaCore:GetInstallPath());
        -- Create directory if it doesn't exist
        ashita.fs.create_directory(itemCacheDir);
    end
    return itemCacheDir;
end

-- Get cached item icon path, creating cache file if needed
-- Loads texture with color key, extracts pixels, saves as PNG with alpha
-- @param itemId: The item ID to get icon for
-- @return: File path string if successfully cached, nil otherwise
textures.GetItemIconPath = function(self, itemId)
    if not itemId or itemId == 0 or itemId == 65535 then
        return nil;
    end
    local cacheDir = GetItemCacheDir();
    local fileName = string.format('%05d.png', itemId);
    local filePath = cacheDir .. fileName;

    -- Check if already cached on disk
    if ashita.fs.exists(filePath) then
        return filePath;
    end

    -- Get device
    local device = GetD3D8Device();
    if not device then return nil; end

    -- Get item bitmap from game resources
    local resMgr = AshitaCore:GetResourceManager();
    if not resMgr then return nil; end
    local item = resMgr:GetItemById(itemId);
    if not item then return nil; end
    if not item.Bitmap or not item.ImageSize or item.ImageSize <= 0 then
        return nil;
    end

    -- Load texture from memory with color key (black = transparent)
    -- D3DPOOL_SCRATCH (2) is lockable for pixel extraction
    local dx_texture_ptr = ffi.new('IDirect3DTexture8*[1]');
    local loadRes = ffi.C.D3DXCreateTextureFromFileInMemoryEx(
        device, item.Bitmap, item.ImageSize,
        0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
        ffi.C.D3DFMT_A8R8G8B8,
        2,  -- D3DPOOL_SCRATCH
        1, 1,  -- D3DX_FILTER_NONE
        0xFF000000,  -- Color key: black = transparent
        nil, nil, dx_texture_ptr
    );
    if loadRes ~= ffi.C.S_OK or dx_texture_ptr[0] == nil then
        return nil;
    end
    local texture = dx_texture_ptr[0];

    -- Get texture dimensions
    local descRes, desc = texture:GetLevelDesc(0);
    if descRes ~= ffi.C.S_OK or desc == nil then
        texture:Release();
        return nil;
    end
    local texWidth = desc.Width;
    local texHeight = desc.Height;

    -- Lock texture to read pixels
    local lockRes, lockedRect = texture:LockRect(0, nil, 0);
    if lockRes ~= ffi.C.S_OK or lockedRect == nil then
        texture:Release();
        return nil;
    end

    -- Upscale to 40x40 (matching spell icon size) with bilinear interpolation
    -- This improves quality because primitives use point sampling when scaling
    local targetSize = 40;
    local success, err = pngencoder.SavePNGFromLockedRectUpscaled(
        filePath,
        texWidth,
        texHeight,
        lockedRect.pBits,
        lockedRect.Pitch,
        targetSize,
        targetSize
    );
    texture:UnlockRect(0);
    texture:Release();
    if success and ashita.fs.exists(filePath) then
        return filePath;
    end
    return nil;
end

-- Load item icon with file path for primitive rendering
-- @param itemId: The item ID to load icon for
-- @return: Texture table { image, path, width, height } or nil
textures.LoadItemIcon = function(self, itemId)
    -- Get or create cached file path
    local iconPath = self:GetItemIconPath(itemId);
    if not iconPath then
        return nil;
    end

    -- Load PNG file (alpha already baked in, no color key needed)
    return LoadTextureFromPath(iconPath);
end

-- Load item icon from memory only (no PNG file creation)
-- For use in icon picker browsing - returns texture with NO path field
-- @param itemId: The item ID to load icon for
-- @return: Texture table { image, width, height } or nil (no path field)
textures.LoadItemIconFromMemory = function(self, itemId)
    if not itemId or itemId == 0 or itemId == 65535 then
        return nil;
    end
    local device = GetD3D8Device();
    if not device then return nil; end
    local resMgr = AshitaCore:GetResourceManager();
    if not resMgr then return nil; end
    local item = resMgr:GetItemById(itemId);
    if not item or not item.Bitmap or not item.ImageSize or item.ImageSize <= 0 then
        return nil;
    end

    -- Load texture from memory with color key (black = transparent)
    local dx_texture_ptr = ffi.new('IDirect3DTexture8*[1]');
    local loadRes = ffi.C.D3DXCreateTextureFromFileInMemoryEx(
        device, item.Bitmap, item.ImageSize,
        0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
        ffi.C.D3DFMT_A8R8G8B8,
        ffi.C.D3DPOOL_MANAGED,
        ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT,
        0xFF000000,  -- Color key: black = transparent
        nil, nil, dx_texture_ptr
    );
    if loadRes ~= ffi.C.S_OK or dx_texture_ptr[0] == nil then
        return nil;
    end

    -- Return texture WITHOUT path field (will use ImGui fallback in slotrenderer)
    return {
        image = d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', dx_texture_ptr[0])),
        width = 32,  -- FFXI item icons are 32x32
        height = 32,
        -- Note: No 'path' field - this tells renderers to use ImGui fallback
    };
end

-- Expose LoadTextureFromPath for external use
textures.LoadTextureFromPath = function(self, filePath)
    return LoadTextureFromPath(filePath);
end
return textures;
