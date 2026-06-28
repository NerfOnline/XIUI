--[[
* XIUI hotbar - Display Module
* Renders 6 independent hotbar windows with primitives and imtext
]]--
require('common');
require('handlers.helpers');
local ffi = require('ffi');
local imgui = require('imgui');
local windowBg = require('libs.windowbackground');
local drawing = require('libs.drawing');
local data = require('modules.hotbar.data');
local actions = require('modules.hotbar.actions');
local textures = require('modules.hotbar.textures');
local macropalette = require('modules.hotbar.macropalette');
local dragdrop = require('libs.dragdrop');
local recast = require('modules.hotbar.recast');
local slotrenderer = require('modules.hotbar.slotrenderer');
local hotbarConfig = require('config.hotbar');
local petpalette = require('modules.hotbar.petpalette');
local palette = require('modules.hotbar.palette');
local skillchain = require('modules.hotbar.skillchain');
local targetLib = require('libs.target');
local imtext = require('libs.imtext');
local M = {};

-- Action labels wrap onto at most this many lines (whole words only).
local MAX_LABEL_LINES = 2;
-- Default extra space (px) reserved between anchored bars when labels are shown.
-- Exposed as the per-bar "Label Spacing" slider; this is one block regardless of
-- how many lines the label wraps onto (both wrapped lines are still one label).
local DEFAULT_LABEL_SPACING = 8;
local DEFAULT_HOTBAR_SPACING = 8;

-- ============================================
-- Anchored Layout Helpers (hotbar only)
-- ============================================

local function GetHotbarBarConfig(barIndex)
    return gConfig and gConfig['hotbarBar' .. barIndex];
end
local function IsAnchoredMode()
    return gConfig.hotbarGlobal and gConfig.hotbarGlobal.positionMode == 'anchored';
end
local function IsAnchorStackDown()
    return IsAnchoredMode()
        and gConfig.hotbarGlobal.anchorStackDirection == 'down';
end
local function GetAnchoredStackBars()
    local stack = {};
    if not IsAnchoredMode() then
        return stack;
    end
    for barIndex = 1, data.NUM_BARS do
        local barConfig = GetHotbarBarConfig(barIndex);
        if (not barConfig or barConfig.enabled ~= false)
            and (not barConfig or barConfig.anchoredInStack ~= false) then
            stack[#stack + 1] = barIndex;
        end
    end
    return stack;
end
local function GetBackgroundPadding(barSettings)
    local gs = (gConfig and gConfig.globalScale) or 1.0;
    local padX = (barSettings and barSettings.backgroundPaddingX) or 0;
    local padY = (barSettings and barSettings.backgroundPaddingY) or 0;
    return padX * gs, padY * gs;
end
local function GetBarSavedPosition(barIndex, defaultX, defaultY)
    local windowName = string.format('Hotbar%d', barIndex);
    local saved = gConfig.windowPositions and gConfig.windowPositions[windowName];
    if saved then
        return saved.x, saved.y;
    end
    return defaultX, defaultY;
end

-- Forward declarations (defined after GetBarMetrics)
local GetBarMetrics;
local ComputeAnchoredLayout;
local DrawWindowBackground;
local DrawBarBackground;

-- ============================================
-- State
-- ============================================

-- Textures initialized flag
local texturesInitialized = false;

-- Force position reset flag (set by ResetPositions, cleared after applying)
local forcePositionReset = false;

-- Pre-allocated reusable tables (avoid per-frame {x,y} / metrics allocations)
local tmpVec1 = {0, 0};
local tmpVec2 = {0, 0};
local barMetricsPool = {};

-- Keybind display memoization: keybindTextCache[barIndex][slotIndex] = string or false (empty)
local keybindTextCache = {};
local function GetCachedKeybindDisplay(barIndex, slotIndex)
    local slotKey = tonumber(slotIndex) or slotIndex;
    if not keybindTextCache[barIndex] then
        keybindTextCache[barIndex] = {};
    end
    local cached = keybindTextCache[barIndex][slotKey];
    if cached ~= nil then
        return cached ~= false and cached or '';
    end
    local text = data.GetKeybindDisplay(barIndex, slotIndex);
    keybindTextCache[barIndex][slotKey] = text ~= '' and text or false;
    return text;
end
local function ClearKeybindTextCache()
    keybindTextCache = {};
end

-- Icon cache per slot: iconCache[barIndex][slotIndex] = { bindKey, icon, abbr, abbrW }
local iconCache = {};

-- ============================================
-- Palette Change Animation
-- ============================================

-- Animation state per bar
local paletteAnimation = {
    -- [barIndex] = { active, startTime, duration, phase }
};
local PALETTE_ANIM_DURATION = 0.25;  -- Total animation duration in seconds
local PALETTE_ANIM_FADE_OUT = 0.12;  -- Fade out phase duration

-- Easing function (ease out cubic)
local function EaseOutCubic(t)
    return 1 - math.pow(1 - t, 3);
end

-- Start palette change animation for a bar
local function StartPaletteAnimation(barIndex)
    paletteAnimation[barIndex] = {
        active = true,
        startTime = os.clock(),
        duration = PALETTE_ANIM_DURATION,
    };
end

-- Get animation opacity for a bar (1.0 = fully visible)
local function GetPaletteAnimationOpacity(barIndex)
    local anim = paletteAnimation[barIndex];
    if not anim or not anim.active then
        return 1.0;
    end
    local elapsed = os.clock() - anim.startTime;
    if elapsed >= anim.duration then
        anim.active = false;
        return 1.0;
    end

    -- Two-phase animation: fade out then fade in
    if elapsed < PALETTE_ANIM_FADE_OUT then
        -- Fade out phase
        local progress = elapsed / PALETTE_ANIM_FADE_OUT;
        return 1.0 - EaseOutCubic(progress) * 0.7;  -- Fade to 30% opacity
    else
        -- Fade in phase
        local fadeInElapsed = elapsed - PALETTE_ANIM_FADE_OUT;
        local fadeInDuration = anim.duration - PALETTE_ANIM_FADE_OUT;
        local progress = fadeInElapsed / fadeInDuration;
        return 0.3 + EaseOutCubic(progress) * 0.7;  -- Fade from 30% to 100%
    end
end

-- Callback registered with palette system
local function OnPaletteChanged(barIndex, oldPalette, newPalette)
    StartPaletteAnimation(barIndex);
end

-- Get cached icon (and precomputed abbreviation) for a hotbar slot.
local function GetCachedIcon(barIndex, slotIndex, bind)
    return slotrenderer.GetCachedSlotIcon(iconCache, barIndex, slotIndex, bind);
end

-- Clear icon cache (call when slots change)
local function ClearIconCache()
    iconCache = {};
    ClearKeybindTextCache();
end

-- Clear icon cache for a specific slot (call on targeted slot updates)
local function ClearIconCacheForSlot(barIndex, slotIndex)
    local slotKey = tonumber(slotIndex) or slotIndex;
    if iconCache[barIndex] then
        iconCache[barIndex][slotKey] = nil;
    end
    if keybindTextCache[barIndex] then
        keybindTextCache[barIndex][slotKey] = nil;
    end
end

-- ============================================
-- Helper Functions
-- ============================================

-- Extra space (in pixels) added between anchored bars purely because action
-- labels are enabled. Zero when labels are off (the gap disappears with them).
local function GetBarLabelAreaHeight(barSettings)
    if not (barSettings and barSettings.showActionLabels) then
        return 0;
    end
    local gs = (gConfig and gConfig.globalScale) or 1.0;
    return (barSettings.actionLabelSpacing or DEFAULT_LABEL_SPACING) * gs;
end
GetBarMetrics = function(barIndex, inAnchoredStack)
    local barSettings = data.GetBarSettings(barIndex);
    local gs = (gConfig and gConfig.globalScale) or 1.0;
    local buttonSize = (barSettings.slotSize or 32) * gs;
    local buttonGap = (barSettings.slotXPadding or data.BUTTON_GAP) * gs;
    local rowGap = (barSettings.slotYPadding or data.ROW_GAP) * gs;
    local layout = data.GetBarLayout(barIndex);
    if inAnchoredStack then
        -- The gap between rows matches the gap between bars (hotbarSpacing) plus the
        -- reserved label space, so a multi-row bar stays evenly spaced with the rest
        -- of the stack and labels never overlap the row beneath them.
        local stackSpacing = ((gConfig.hotbarGlobal and gConfig.hotbarGlobal.hotbarSpacing) or DEFAULT_HOTBAR_SPACING) * gs;
        local labelAreaH = GetBarLabelAreaHeight(barSettings);
        rowGap = stackSpacing + labelAreaH;
    end

    -- Slot grid only — no internal PADDING margin. Background padding (and the small
    -- PADDING margin on anchored stack bg) is applied outside the window origin so
    -- absolute and anchored modes share the same saved position reference point.
    local contentW = (buttonSize * layout.columns) + (buttonGap * (layout.columns - 1));
    local contentH = (buttonSize * layout.rows) + (rowGap * (layout.rows - 1));
    local metrics = barMetricsPool[barIndex];
    if not metrics then
        metrics = {};
        barMetricsPool[barIndex] = metrics;
    end
    metrics.contentW = contentW;
    metrics.contentH = contentH;
    metrics.buttonSize = buttonSize;
    metrics.buttonGap = buttonGap;
    metrics.rowGap = rowGap;
    metrics.layout = layout;
    metrics.slotPadding = 0;
    metrics.windowW = contentW;
    metrics.windowH = contentH;
    if inAnchoredStack then
        metrics.bgPadX = 0;
        metrics.bgPadY = 0;
    else
        local bgPadX, bgPadY = GetBackgroundPadding(barSettings);
        metrics.bgPadX = bgPadX;
        metrics.bgPadY = bgPadY;
    end
    return metrics;
end

-- Default absolute positions: bar 1 bottom-center; bars 2–6 stack upward using
-- hotbarSpacing + label spacing (same gap anchored mode uses between bars).
local DEFAULT_BOTTOM_MARGIN = 120;
local function GetDefaultBarPosition(barIndex)
    local screenWidth = imgui.GetIO().DisplaySize.x or 1920;
    local screenHeight = imgui.GetIO().DisplaySize.y or 1080;
    local gs = (gConfig and gConfig.globalScale) or 1.0;
    local globalSettings = gConfig and gConfig.hotbarGlobal or {};
    local stackSpacing = (globalSettings.hotbarSpacing or DEFAULT_HOTBAR_SPACING) * gs;
    local metrics1 = GetBarMetrics(1, false);
    local x = (screenWidth - metrics1.contentW) / 2;
    local y = screenHeight - DEFAULT_BOTTOM_MARGIN;
    if barIndex <= 1 then
        return x, y;
    end
    for i = 2, barIndex do
        local barSettings = data.GetBarSettings(i);
        local labelAreaH = GetBarLabelAreaHeight(barSettings);
        local metrics = GetBarMetrics(i, false);
        y = y - stackSpacing - labelAreaH - metrics.contentH;
    end
    return x, y;
end
ComputeAnchoredLayout = function(stack)
    local layout = {};
    if #stack == 0 then
        return layout;
    end
    local anchorBar = stack[1];
    local defaultX, defaultY = GetDefaultBarPosition(anchorBar);
    local anchorX, anchorY = GetBarSavedPosition(anchorBar, defaultX, defaultY);
    local globalSettings = gConfig.hotbarGlobal or {};
    local bgPadX, bgPadY = GetBackgroundPadding(globalSettings);
    local gs = (gConfig and gConfig.globalScale) or 1.0;
    local stackSpacing = (globalSettings.hotbarSpacing or DEFAULT_HOTBAR_SPACING) * gs;
    local anchorMetrics = GetBarMetrics(anchorBar, true);
    local maxContentW = anchorMetrics.contentW;
    layout[anchorBar] = { x = anchorX, y = anchorY, metrics = anchorMetrics };
    local topBarY = anchorY;
    local bottomY = anchorY + anchorMetrics.contentH + GetBarLabelAreaHeight(data.GetBarSettings(anchorBar));
    if IsAnchorStackDown() then
        local prevBottom = bottomY;
        for i = 2, #stack do
            local barIndex = stack[i];
            local metrics = GetBarMetrics(barIndex, true);
            maxContentW = math.max(maxContentW, metrics.contentW);
            local y = prevBottom + stackSpacing;
            layout[barIndex] = { x = anchorX, y = y, metrics = metrics };
            prevBottom = y + metrics.contentH + GetBarLabelAreaHeight(data.GetBarSettings(barIndex));
        end
        bottomY = prevBottom;
    else
        local prevTop = anchorY;
        for i = 2, #stack do
            local barIndex = stack[i];
            local metrics = GetBarMetrics(barIndex, true);
            maxContentW = math.max(maxContentW, metrics.contentW);
            local labelAreaH = GetBarLabelAreaHeight(data.GetBarSettings(barIndex));
            local y = prevTop - stackSpacing - labelAreaH - metrics.contentH;
            layout[barIndex] = { x = anchorX, y = y, metrics = metrics };
            prevTop = y;
        end
        topBarY = prevTop;
    end
    local padMargin = data.PADDING * gs;
    layout._stackBackground = {
        x = anchorX - bgPadX - padMargin,
        y = topBarY - bgPadY - padMargin,
        width = maxContentW + ((bgPadX + padMargin) * 2),
        height = (bottomY - topBarY) + ((bgPadY + padMargin) * 2),
    };
    return layout;
end
local function BuildWindowBgOptions(settings)
    return {
        theme = settings.backgroundTheme or '-None-',
        padding = 0,
        paddingY = 0,
        bgScale = settings.bgScale or 1.0,
        borderScale = settings.borderScale or 1.0,
        bgOpacity = settings.backgroundOpacity or 0.87,
        borderOpacity = settings.borderOpacity or 1.0,
        bgColor = settings.bgColor or 0xFFFFFFFF,
        borderColor = settings.borderColor or 0xFFFFFFFF,
    };
end
DrawWindowBackground = function(x, y, width, height, settings)
    local bgOptions = BuildWindowBgOptions(settings);
    if bgOptions.theme == '-None-' then
        return;
    end
    local drawList = GetUIDrawList();
    if not drawList then
        return;
    end
    windowBg.Draw(drawList, x, y, width, height, bgOptions);
end
DrawBarBackground = function(windowPosX, windowPosY, metrics, barSettings)
    local gs = (gConfig and gConfig.globalScale) or 1.0;
    local padMargin = data.PADDING * gs;
    local bgPadX = metrics.bgPadX or 0;
    local bgPadY = metrics.bgPadY or 0;
    local bgX = windowPosX - bgPadX - padMargin;
    local bgY = windowPosY - bgPadY - padMargin;
    local bgW = metrics.contentW + ((bgPadX + padMargin) * 2);
    local bgH = metrics.contentH + ((bgPadY + padMargin) * 2);
    DrawWindowBackground(bgX, bgY, bgW, bgH, barSettings);
end

-- Cached asset path
local assetsPath = nil;
local function GetAssetsPath()
    if not assetsPath then
        assetsPath = string.format('%saddons\\XIUI\\assets\\hotbar\\', AshitaCore:GetInstallPath());
    end
    return assetsPath;
end

-- Pre-allocated reusable table for DrawSlot
local slotParams = {};
local HOTBAR_DROP_ACCEPTS = {'macro', 'slot', 'crossbar_slot'};

-- Pre-created closures and string IDs per slot (avoids ~288 closure + 72 array allocations per frame)
local slotInteraction = {};
local function GetSlotInteraction(barIndex, slotIndex)
    if not slotInteraction[barIndex] then
        slotInteraction[barIndex] = {};
    end
    if not slotInteraction[barIndex][slotIndex] then
        slotInteraction[barIndex][slotIndex] = {
            buttonId = string.format('##hotbarslot_%d_%d', barIndex, slotIndex),
            dropZoneId = string.format('hotbar_%d_%d', barIndex, slotIndex),
            onDrop = function(payload)
                macropalette.HandleDropOnSlot(payload, barIndex, slotIndex);
            end,
            getDragData = function()
                local b = data.GetKeybindForSlot(barIndex, slotIndex);
                macropalette.StartDragSlot(barIndex, slotIndex, b);
                return nil;  -- StartDragSlot handles the drag itself
            end,
            onRightClick = function()
                macropalette.ClearSlot(barIndex, slotIndex);
            end,
        };
    end
    return slotInteraction[barIndex][slotIndex];
end

-- Draw a single hotbar slot using shared renderer
local function DrawSlot(barIndex, slotIndex, x, y, buttonSize, bind, barSettings, animOpacity, skillchainName, magicBurstName, magicBurstElement)
    -- Get icon (and pre-resolved abbreviation, if no icon) for this slot.
    -- All three are cached together; recomputed only when bind changes.
    local icon, cachedAbbr, cachedAbbrW = GetCachedIcon(barIndex, slotIndex, bind);

    -- Check if this slot is currently pressed (keyboard)
    local pressedHotbar = actions.GetPressedHotbar();
    local pressedSlot = actions.GetPressedSlot();

    -- Get pre-created interaction closures and IDs
    local interaction = GetSlotInteraction(barIndex, slotIndex);

    -- Global UI scale (applied to font sizes and pixel offsets that aren't
    -- already pre-scaled via GetBarDimensions). Position/size args (x, y,
    -- buttonSize) come in already scaled by the caller.
    local gs = (gConfig and gConfig.globalScale) or 1.0;

    -- Update reusable params table in-place
    local p = slotParams;
    -- Position/Size
    p.x = x;
    p.y = y;
    p.size = buttonSize;
    -- Action Data
    p.bind = bind;
    p.icon = icon;
    p.cachedAbbr = cachedAbbr;
    p.cachedAbbrW = cachedAbbrW;
    -- Visual Settings
    p.slotBgColor = barSettings and barSettings.slotBackgroundColor or 0xFFFFFFFF;
    p.slotOpacity = barSettings and barSettings.slotOpacity or 1.0;
    p.keybindText = (barSettings and barSettings.showKeybinds ~= false) and GetCachedKeybindDisplay(barIndex, slotIndex) or nil;
    p.keybindFontSize = (barSettings and barSettings.keybindFontSize or 10) * gs;
    p.keybindFontColor = barSettings and barSettings.keybindFontColor or 0xFFFFFFFF;
    p.keybindAnchor = barSettings and barSettings.keybindAnchor or 'topLeft';
    p.keybindOffsetX = (barSettings and barSettings.keybindOffsetX or 0) * gs;
    p.keybindOffsetY = (barSettings and barSettings.keybindOffsetY or 0) * gs;
    p.showLabel = barSettings and barSettings.showActionLabels or false;
    p.labelText = bind and (bind.displayName or bind.action or '') or '';
    p.labelOffsetX = (barSettings and barSettings.actionLabelOffsetX or 0) * gs;
    p.labelOffsetY = ((barSettings and barSettings.actionLabelOffsetY or 0) + data.LABEL_GAP) * gs;
    p.labelFontSize = (barSettings and barSettings.labelFontSize or 10) * gs;
    p.labelWrap = not barSettings or barSettings.actionLabelWrap ~= false;
    p.labelMaxLines = MAX_LABEL_LINES;
    -- Spacing between the two wrapped lines stays tied to the font (both lines are
    -- one label); the "Label Spacing" setting only affects the gap between bars.
    p.labelLineHeight = ((barSettings and barSettings.labelFontSize or 10) + 1) * gs;
    p.recastTimerFontSize = (barSettings and barSettings.recastTimerFontSize or 11) * gs;
    p.recastTimerFontColor = barSettings and barSettings.recastTimerFontColor or 0xFFFFFFFF;
    p.flashCooldownUnder5 = barSettings and barSettings.flashCooldownUnder5 or false;
    p.useHHMMCooldownFormat = barSettings and barSettings.useHHMMCooldownFormat or false;
    p.labelFontColor = barSettings and barSettings.labelFontColor or 0xFFFFFFFF;
    p.labelCooldownColor = barSettings and barSettings.labelCooldownColor or 0xFF888888;
    p.labelNoMpColor = barSettings and barSettings.labelNoMpColor or 0xFFFF4444;
    p.showFrame = barSettings and barSettings.showSlotFrame or false;
    p.customFramePath = barSettings and barSettings.customFramePath or '';
    p.isPressed = (pressedHotbar == barIndex and pressedSlot == slotIndex);
    p.showMpCost = barSettings and barSettings.showMpCost ~= false;
    p.mpCostFontSize = (barSettings and barSettings.mpCostFontSize or 10) * gs;
    p.mpCostFontColor = barSettings and barSettings.mpCostFontColor or 0xFFD4FF97;
    p.mpCostNoMpColor = barSettings and barSettings.labelNoMpColor or 0xFFFF4444;
    p.mpCostAnchor = barSettings and barSettings.mpCostAnchor or 'topRight';
    p.mpCostOffsetX = (barSettings and barSettings.mpCostOffsetX or 0) * gs;
    p.mpCostOffsetY = (barSettings and barSettings.mpCostOffsetY or 0) * gs;
    p.showQuantity = barSettings and barSettings.showQuantity ~= false;
    p.showStackQuantity = barSettings and barSettings.showStackQuantity == true;
    p.quantityFontSize = (barSettings and barSettings.quantityFontSize or 10) * gs;
    p.quantityFontColor = barSettings and barSettings.quantityFontColor or 0xFFFFFFFF;
    p.quantityAnchor = barSettings and barSettings.quantityAnchor or 'bottomRight';
    p.quantityOffsetX = (barSettings and barSettings.quantityOffsetX or 0) * gs;
    p.quantityOffsetY = (barSettings and barSettings.quantityOffsetY or 0) * gs;
    -- Interaction Config
    p.buttonId = interaction.buttonId;
    p.dropZoneId = interaction.dropZoneId;
    p.dropAccepts = HOTBAR_DROP_ACCEPTS;
    p.onDrop = interaction.onDrop;
    p.dragType = 'slot';
    p.getDragData = interaction.getDragData;
    p.onRightClick = interaction.onRightClick;
    p.showTooltip = true;
    -- Animation
    p.animOpacity = animOpacity or 1.0;
    -- Skillchain highlight
    p.skillchainName = skillchainName;
    p.skillchainColor = gConfig.hotbarGlobal.skillchainHighlightColor or 0xFFD4AA44;
    -- Magic Burst highlight
    p.magicBurstName = magicBurstName;

    -- Render slot using shared renderer (handles ALL rendering and interactions)
    local result = slotrenderer.DrawSlot(p);
    return result.isHovered;
end

-- Draw a single hotbar window
local function DrawBarWindow(barIndex, settings, drawContext)
    drawContext = drawContext or {};

    -- Get per-bar settings
    local barSettings = data.GetBarSettings(barIndex);

    -- Check if bar is enabled
    if not barSettings.enabled then
        return;
    end
    local metrics = drawContext.metrics or GetBarMetrics(barIndex);
    local barWidth = metrics.windowW;
    local barHeight = metrics.windowH;
    local buttonSize = metrics.buttonSize;
    local buttonGap = metrics.buttonGap;
    local rowGap = metrics.rowGap;
    local layout = metrics.layout;
    local defaultX, defaultY = GetDefaultBarPosition(barIndex);
    local windowName = string.format('Hotbar%d', barIndex);
    local hasSaved = gConfig.windowPositions and gConfig.windowPositions[windowName];
    local useAnchoredPosition = drawContext.resolvedPosition ~= nil;
    local skipBackground = drawContext.skipBackground == true;
    local isAnchorBar = drawContext.isAnchorBar == true;
    local savePosition = drawContext.savePosition ~= false;
    local anchorDragging = drawing.IsAnchorDragging(windowName);
    if useAnchoredPosition then
        if isAnchorBar and (anchorDragging or forcePositionReset) then
            local targetX, targetY = GetBarSavedPosition(barIndex, defaultX, defaultY);
            tmpVec1[1] = targetX; tmpVec1[2] = targetY;
            imgui.SetNextWindowPos(tmpVec1, ImGuiCond_Always);
        else
            tmpVec1[1] = drawContext.resolvedPosition.x; tmpVec1[2] = drawContext.resolvedPosition.y;
            imgui.SetNextWindowPos(tmpVec1, ImGuiCond_Always);
        end
    elseif hasSaved then
        ApplyWindowPosition(windowName);
    else
        tmpVec1[1] = defaultX; tmpVec1[2] = defaultY;
        imgui.SetNextWindowPos(tmpVec1, ImGuiCond_FirstUseEver);
    end

    -- Window flags (dummy window for positioning)
    local windowFlags = GetBaseWindowFlags(gConfig.lockPositions);
    if not useAnchoredPosition and (anchorDragging or forcePositionReset) then
        local targetX, targetY = GetBarSavedPosition(barIndex, defaultX, defaultY);
        tmpVec1[1] = targetX; tmpVec1[2] = targetY;
        imgui.SetNextWindowPos(tmpVec1, ImGuiCond_Always);
    end
    tmpVec2[1] = barWidth; tmpVec2[2] = barHeight;
    imgui.SetNextWindowSize(tmpVec2, ImGuiCond_Always);
    local windowPosX, windowPosY;

    -- Zero the window padding so slots placed at the window origin (anchored mode
    -- drops the internal padding) are never clipped out of the interactive region.
    -- Slots/backgrounds are drawn at absolute positions, so this only affects the
    -- item clip rect, not where anything is rendered.
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {0, 0});
    if imgui.Begin(windowName, true, windowFlags) then
        if savePosition then
            SaveWindowPosition(windowName);
        end
        windowPosX, windowPosY = imgui.GetWindowPos();

        -- Reserve space
        tmpVec1[1] = barWidth; tmpVec1[2] = barHeight;
        imgui.Dummy(tmpVec1);
        if not skipBackground then
            DrawBarBackground(windowPosX, windowPosY, metrics, barSettings);
        end

        -- Draw hotbar number to the LEFT of the bar (outside container)
        local showNumber = barSettings.showHotbarNumber;
        if showNumber == nil then showNumber = true; end
        if showNumber then
            local hbnOffsetX = barSettings.hotbarNumberOffsetX or 0;
            local hbnOffsetY = barSettings.hotbarNumberOffsetY or 0;
            local hbnText = tostring(barIndex);
            local hbnX = windowPosX - 16 + hbnOffsetX;
            local hbnY = windowPosY + (barHeight / 2) - 6 + hbnOffsetY;
            local hbnDrawList = GetUIDrawList();
            if hbnDrawList then
                imtext.Draw(hbnDrawList, hbnText, hbnX, hbnY, 0xFFFFFFFF, 12);
            end
        end

        -- Draw slots based on layout (rows x columns)
        slotCount = layout.slots;
        local slotIndex = 1;
        local animOpacity = GetPaletteAnimationOpacity(barIndex);
        local hideEmptySlots = barSettings.hideEmptySlots or false;
        local paletteOpen = macropalette.IsPaletteOpen();
        local keybindEditorOpen = hotbarConfig.IsKeybindModalOpen();
        local isDragging = dragdrop.IsDragging() or dragdrop.IsDragPending();
        local targetServerId = nil;
        local skillchainEnabled = gConfig.hotbarGlobal.skillchainHighlightEnabled ~= false;
        local magicBurstEnabled = gConfig.hotbarGlobal.magicBurstHighlightEnabled ~= false;
        if skillchainEnabled or magicBurstEnabled then
            local mainTargetIdx = targetLib.GetTargets();
            if mainTargetIdx and mainTargetIdx ~= 0 then
                local targetEntity = GetEntity(mainTargetIdx);
                if targetEntity then
                    targetServerId = targetEntity.ServerId;
                end
            end
        end
        for row = 1, layout.rows do
            for col = 1, layout.columns do
                if slotIndex <= slotCount then
                    local slotX = windowPosX + (col - 1) * (buttonSize + buttonGap);
                    local slotY = windowPosY + (row - 1) * (buttonSize + rowGap);
                    local bind = data.GetKeybindForSlot(barIndex, slotIndex);
                    if hideEmptySlots and not paletteOpen and not keybindEditorOpen and not isDragging and not bind then
                        -- Empty slot: skip rendering
                    else
                        local slotSkillchainName = nil;
                        if skillchainEnabled and bind and bind.actionType == 'ws' and bind.action then
                            slotSkillchainName = skillchain.GetSkillchainForSlot(targetServerId, bind.action);
                        end
                        local slotMagicBurstName = nil;
                        local slotMagicBurstElement = nil;
                        if magicBurstEnabled and bind then
                            slotMagicBurstName = skillchain.GetMagicBurstForSlot(targetServerId, bind);
                            if slotMagicBurstName then
                                slotMagicBurstElement = skillchain.GetBurstElementForSlot(bind);
                            end
                        end
                        DrawSlot(barIndex, slotIndex, slotX, slotY, buttonSize, bind, barSettings, animOpacity, slotSkillchainName, slotMagicBurstName, slotMagicBurstElement);
                    end
                end
                slotIndex = slotIndex + 1;
            end
        end
        imgui.End();
    end
    imgui.PopStyleVar();

    -- Draw pet palette indicator dot OUTSIDE window bounds (above bar number)
    local hasPetIndicator = barSettings.petAware and barSettings.showPetIndicator ~= false;
    if windowPosX and hasPetIndicator then
        local dotX = windowPosX - 12;
        local dotY = windowPosY + (barHeight / 2) - 20;
        local dotRadius = 5;
        local fgDrawList = GetUIDrawList();
        local indicatorColor = {1.0, 0.8, 0.2, 1.0};
        fgDrawList:AddCircleFilled({dotX, dotY}, dotRadius, imgui.GetColorU32(indicatorColor), 12);
        fgDrawList:AddCircle({dotX, dotY}, dotRadius, imgui.GetColorU32({0.0, 0.0, 0.0, 1.0}), 12, 1.0);
        local mouseX, mouseY = imgui.GetMousePos();
        local dx = mouseX - dotX;
        local dy = mouseY - dotY;
        local hoverRadius = dotRadius + 3;
        if (dx * dx + dy * dy) <= (hoverRadius * hoverRadius) then
            imgui.BeginTooltip();
            imgui.TextColored({1.0, 0.8, 0.2, 1.0}, 'Pet Palette Bar ' .. barIndex);
            imgui.Separator();
            local currentPet = petpalette.GetCurrentPetDisplayName();
            if currentPet then
                imgui.Text('Current Pet: ' .. currentPet);
            else
                imgui.TextColored({0.6, 0.6, 0.6, 1.0}, 'No pet summoned');
            end
            local hasOverride = petpalette.HasManualOverride(barIndex);
            if hasOverride then
                local overrideName = petpalette.GetPaletteDisplayName(barIndex, data.jobId);
                imgui.Text('Palette: ' .. overrideName .. ' (Manual)');
            else
                imgui.Text('Palette: Auto');
            end
            imgui.EndTooltip();
        end
    end

    -- Draw move anchor (only visible when config is open)
    if windowPosX ~= nil then
        local globalLocked = gConfig and gConfig.hotbarLockMovement;
        local showAnchor = not globalLocked and (not useAnchoredPosition or isAnchorBar);
        if showAnchor then
            local anchorName = string.format('Hotbar%d', barIndex);
            local anchorNewX, anchorNewY = drawing.DrawMoveAnchor(anchorName, windowPosX, windowPosY);
            if anchorNewX ~= nil then
                windowPosX = anchorNewX;
                windowPosY = anchorNewY;
                if not gConfig.windowPositions then gConfig.windowPositions = {}; end
                gConfig.windowPositions[anchorName] = { x = anchorNewX, y = anchorNewY };
            end
        end
    end
end

-- ============================================
-- Public Functions
-- ============================================

function M.DrawWindow(settings)
    -- Note: dragdrop.Update() is called from init.lua before this

    -- Initialize textures on first draw
    if not texturesInitialized then
        textures:Initialize();
        texturesInitialized = true;
    end
    local anchoredStack = GetAnchoredStackBars();
    local anchoredLayout = ComputeAnchoredLayout(anchoredStack);
    local anchorBar = anchoredStack[1];
    local stackBackground = anchoredLayout._stackBackground;
    if stackBackground then
        DrawWindowBackground(
            stackBackground.x,
            stackBackground.y,
            stackBackground.width,
            stackBackground.height,
            gConfig.hotbarGlobal or {}
        );
    end
    for barIndex = 1, data.NUM_BARS do
        local drawContext = {};
        local anchoredEntry = anchoredLayout[barIndex];
        if anchoredEntry then
            drawContext.resolvedPosition = { x = anchoredEntry.x, y = anchoredEntry.y };
            drawContext.metrics = anchoredEntry.metrics;
            drawContext.skipBackground = true;
            drawContext.isAnchorBar = (barIndex == anchorBar);
            drawContext.savePosition = (barIndex == anchorBar);
        end
        DrawBarWindow(barIndex, settings, drawContext);
    end
    if forcePositionReset then
        forcePositionReset = false;
    end

    -- Note: Macro palette, dragdrop.Render(), and outside drop handling are in init.lua
end
function M.HideWindow()
end

-- ============================================
-- Lifecycle
-- ============================================

function M.Initialize(settings)
    -- Register palette change callback for animation
    palette.OnPaletteChanged(OnPaletteChanged);
end
function M.UpdateVisuals(settings)
    -- Font/visual settings can change the measured width of cached abbreviations.
    -- Drop the per-slot cache so abbreviation strings and widths get recomputed
    -- against the new font on the next frame.
    ClearIconCache();
end
function M.SetHidden(hidden)
    if hidden then
        M.HideWindow();
    end
end
function M.Cleanup()
    texturesInitialized = false;
    -- Clear icon cache
    ClearIconCache();
    -- Clear pre-created closures so they're recreated on reinit
    slotInteraction = {};
    -- Clear slotrenderer cache
    slotrenderer.ClearAllCache();
end

-- Expose cache clear for external callers (e.g., when slot actions change)
function M.ClearIconCache()
    ClearIconCache();
end

-- Expose targeted cache clear for single slot updates (e.g., drag/drop)
function M.ClearIconCacheForSlot(barIndex, slotIndex)
    ClearIconCacheForSlot(barIndex, slotIndex);
end

-- Reset all bar positions to defaults (called when settings are reset)
-- Note: Hotbar uses forcePositionReset + nil positions instead of explicit defaults
-- because it has its own position pipeline with per-bar default calculation at render time.
function M.ResetPositions()
    forcePositionReset = true;
    if gConfig.windowPositions and gConfig.appliedPositions then
        for barIndex = 1, data.NUM_BARS do
            local windowName = string.format('Hotbar%d', barIndex);
            gConfig.windowPositions[windowName] = nil;
            gConfig.appliedPositions[windowName] = nil;
        end
    end
end
return M;
