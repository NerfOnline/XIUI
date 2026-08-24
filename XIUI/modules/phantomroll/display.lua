--[[
* Phantom Roll window: die, potency, duration bar, and Double-Up odds.
]]--

require('common');
require('handlers.helpers');
local imgui = require('imgui');
local imtext = require('libs.imtext');
local data = require('modules.phantomroll.data');
local dice = require('modules.phantomroll.dice');
local tracker = require('modules.phantomroll.tracker');

local M = {};

local WINDOW_NAME = 'PhantomRoll';

local TEXT = {
    label       = 0xFFC7CCD4,
    labelHot    = 0xFFFFD159,
    labelCold   = 0xFF9ED9FF,
    potency     = 0xFFF5F7FA,
    potencyHot  = 0xFFFFDB66,
    potencyCold = 0xFFB3E3FF,
    potencyBust = 0xFFFF736B,
    muted       = 0xFF8C949E,
    clock       = 0xFFFAFCFF,
    risk        = 0xFFFF7A73,
    warn        = 0xFFF7C75C,
    safe        = 0xFF8CD99E,
};

local BAR_FILL = {
    normal = { 0.36, 0.72, 0.52, 0.95 },
    warn   = { 0.88, 0.70, 0.24, 0.95 },
    low    = { 0.88, 0.36, 0.32, 0.95 },
    bust   = { 0.75, 0.36, 0.32, 0.95 },
};

local BAR_BACKDROP = { 0.10, 0.11, 0.13, 0.80 };
local BAR_BORDER = { 0, 0, 0, 1 };

-- Layout ratios. Everything except ODDS_GAP is a multiple of dieSize so the
-- whole window scales as one unit when the user changes die size.
local COLUMN_WIDTH   = 1.35;
local COLUMN_GAP     = 0.50;
local ROW_GAP        = 0.09;
local NAME_GAP       = 0.30;  -- clears the flame tips above a hot die
local ICE_HEADROOM   = 0.32;  -- room for the icicles below a cold die
local ODDS_GAP       = 0.45;  -- x oddsSize, between "Bust %" and its timer

local function FormatClock(seconds)
    if seconds == nil then return ''; end
    if seconds < 0 then return '--:--'; end

    local whole = math.floor(seconds);
    return string.format('%d:%02d', math.floor(whole / 60), whole % 60);
end

local function FormatSeconds(seconds)
    if seconds == nil or seconds < 0 then return ''; end
    return tostring(math.floor(seconds));
end

local function BarFill(seconds)
    if seconds == nil or seconds < 0 then return BAR_FILL.normal; end
    if seconds <= 30 then return BAR_FILL.low; end
    if seconds <= 60 then return BAR_FILL.warn; end
    return BAR_FILL.normal;
end

-- Bust % only while Double-Up is up; unlucky is visible on the die itself.
local function OddsText(entry, canDoubleUp)
    if entry.busted then return 'BUSTED', TEXT.risk; end
    if not canDoubleUp or entry.total == nil then return '', TEXT.muted; end

    local bust = data.BustChance(entry.total);
    if bust <= 0 then return 'Safe', TEXT.safe; end

    return string.format('Bust %d%%', math.floor(bust * 100 + 0.5)),
        (bust >= 0.5) and TEXT.risk or TEXT.warn;
end

local function DieStyle(entry, roll)
    if entry.busted then return 'bust'; end
    if data.IsLucky(roll, entry.total) then return 'hot'; end
    if data.IsUnlucky(roll, entry.total) then return 'cold'; end
    return 'normal';
end

local function BuildColumn(entry, horizonMode, canDoubleUp, doubleUpSeconds)
    local roll = data.ByAbility(entry.ability, horizonMode);
    local style = DieStyle(entry, roll);
    local seconds = tracker.SecondsLeft(entry);
    local oddsText, oddsColor = OddsText(entry, canDoubleUp);
    local oddsTimer = (canDoubleUp and oddsText ~= '') and FormatSeconds(doubleUpSeconds) or '';

    local nameColor, potencyColor = TEXT.label, TEXT.potency;
    if style == 'bust' then
        potencyColor = TEXT.potencyBust;
    elseif style == 'hot' then
        nameColor, potencyColor = TEXT.labelHot, TEXT.potencyHot;
    elseif style == 'cold' then
        nameColor, potencyColor = TEXT.labelCold, TEXT.potencyCold;
    end

    local duration = math.max(entry.duration or data.BASE_DURATION, 1);
    local fraction = (seconds ~= nil) and math.min(1, math.max(0, seconds / duration)) or 0;

    return {
        name = (roll and roll.name or (entry.busted and 'Bust' or '?')):upper(),
        potency = data.PotencyText(roll, entry.total, entry.context or data.Context(horizonMode)),
        odds = oddsText,
        oddsTimer = oddsTimer,
        clock = FormatClock(seconds),
        fraction = fraction,
        state = { total = entry.total, style = style },
        nameColor = nameColor,
        potencyColor = potencyColor,
        oddsColor = oddsColor,
        fill = (style == 'bust') and BAR_FILL.bust or BarFill(seconds),
    };
end

local function DrawBar(drawList, x, y, width, height, column)
    local rounding = height * 0.45;
    drawList:AddRectFilled({ x, y }, { x + width, y + height },
        dice.Color(BAR_BACKDROP), rounding);

    if column.fraction > 0 then
        -- Width-clipped fill (no PushClipRect): on 4.16, clip stacks on the
        -- shared BackgroundDrawList while config is open interact badly with
        -- RunWithScreenClip and can leave global ImGui layout unstable.
        local inset = 1;
        local fillWidth = width * column.fraction - inset * 2;
        if fillWidth > 0 then
            drawList:AddRectFilled(
                { x + inset, y + inset },
                { x + inset + fillWidth, y + height - inset },
                dice.Color(column.fill), math.max(0, rounding - inset));
        end
    end

    -- Same idea as player/target bars: a thin stroke around the fill.
    drawList:AddRect({ x, y }, { x + width, y + height },
        dice.Color(BAR_BORDER), rounding, ImDrawCornerFlags_All, 1.0);

    dice.CenteredText(drawList, column.clock, x + width / 2, y + height / 2,
        height * 0.86, TEXT.clock);
end

-- One roll column, drawn top-down: name, die, potency, duration bar, odds.
local function DrawColumn(drawList, settings, column, centerX, top, clock)
    local dieSize = settings.dieSize;
    local rowGap = dieSize * ROW_GAP;
    local y = top;

    dice.CenteredText(drawList, column.name, centerX, y + settings.nameSize / 2,
        settings.nameSize, column.nameColor);
    y = y + settings.nameSize + dieSize * NAME_GAP;

    dice.Draw(drawList, centerX - dieSize / 2, y, dieSize, column.state, clock,
        settings.font_settings);
    y = y + dieSize + dieSize * ICE_HEADROOM + rowGap;

    dice.CenteredText(drawList, column.potency, centerX, y + settings.potencySize / 2,
        settings.potencySize, column.potencyColor);
    y = y + settings.potencySize + rowGap;

    local columnWidth = dieSize * COLUMN_WIDTH;
    DrawBar(drawList, centerX - columnWidth / 2, y, columnWidth, settings.barHeight, column);
    y = y + settings.barHeight + rowGap;

    if column.odds == '' then return; end

    local oddsY = y + settings.oddsSize / 2;
    if column.oddsTimer == '' then
        dice.CenteredText(drawList, column.odds, centerX, oddsY,
            settings.oddsSize, column.oddsColor);
        return;
    end

    -- Odds and its countdown are centered together as one group.
    local oddsGap = settings.oddsSize * ODDS_GAP;
    local oddsW = imtext.Measure(column.odds, settings.oddsSize);
    local timerW = imtext.Measure(column.oddsTimer, settings.oddsSize);
    local left = centerX - (oddsW + oddsGap + timerW) / 2;
    dice.CenteredText(drawList, column.odds, left + oddsW / 2, oddsY,
        settings.oddsSize, column.oddsColor);
    dice.CenteredText(drawList, column.oddsTimer, left + oddsW + oddsGap + timerW / 2,
        oddsY, settings.oddsSize, TEXT.muted);
end

-- Window body. Kept separate so DrawWindow can pcall it and still guarantee
-- the matching imgui.End() / PopStyleVar().
local function DrawColumns(settings, columns, contentWidth, contentHeight)
    SaveWindowPosition(WINDOW_NAME);

    local originX, originY = imgui.GetCursorScreenPos();
    imgui.Dummy({ contentWidth, contentHeight });

    -- Window draw list (not GetUIDrawList/Background): keeps text and
    -- primitives on the same list as this window. Measuring via PushFont
    -- on 4.16 touches CurrentWindow's texture stack; drawing to the
    -- background list while config is open was splitting those targets.
    local drawList = imgui.GetWindowDrawList();
    local clock = os.clock();
    local columnWidth = settings.dieSize * COLUMN_WIDTH;
    local stride = columnWidth + settings.dieSize * COLUMN_GAP;

    for i = 1, #columns do
        DrawColumn(drawList, settings, columns[i],
            originX + (i - 1) * stride + columnWidth / 2, originY, clock);
    end
end

-- Explicit size, no AlwaysAutoResize: on legacy ImGui an always-applied
-- auto-resize fights the explicit size every frame and can make other windows
-- appear to stretch/shrink. That rules out sharing GetBaseWindowFlags().
local baseWindowFlags = nil;
local function WindowFlags(lockPositions)
    if baseWindowFlags == nil then
        baseWindowFlags = bit.bor(
            ImGuiWindowFlags_NoDecoration,
            ImGuiWindowFlags_NoFocusOnAppearing,
            ImGuiWindowFlags_NoNav,
            ImGuiWindowFlags_NoBackground,
            ImGuiWindowFlags_NoBringToFrontOnFocus,
            ImGuiWindowFlags_NoDocking
        );
    end

    if lockPositions then
        return bit.bor(baseWindowFlags, ImGuiWindowFlags_NoMove);
    end

    return baseWindowFlags;
end

M.DrawWindow = function(settings)
    imtext.SetConfigFromSettings(settings.font_settings);

    local slots = tracker.Slots();
    local doubleUpIndex, doubleUpSeconds = tracker.DoubleUp();

    local columns = {};
    for i = 1, 2 do
        if slots[i] ~= nil then
            columns[#columns + 1] = BuildColumn(
                slots[i], settings.horizonMode, i == doubleUpIndex, doubleUpSeconds);
        end
    end

    local count = #columns;
    if count == 0 then return; end

    local dieSize = settings.dieSize;
    local rowGap = dieSize * ROW_GAP;
    local columnWidth = dieSize * COLUMN_WIDTH;
    local contentWidth = columnWidth * count + dieSize * COLUMN_GAP * (count - 1);
    local contentHeight = settings.nameSize + dieSize * NAME_GAP
        + dieSize + dieSize * ICE_HEADROOM + rowGap
        + settings.potencySize + rowGap + settings.barHeight + rowGap + settings.oddsSize;

    -- Explicit size (not -1,-1) so legacy ImGui isn't re-fitting the window
    -- every frame; see WindowFlags above.
    imgui.SetNextWindowSize({ contentWidth, contentHeight }, ImGuiCond_Always);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });

    ApplyWindowPosition(WINDOW_NAME);
    local open = imgui.Begin(WINDOW_NAME, true, WindowFlags(gConfig and gConfig.lockPositions));

    -- Only the body is protected: End/PopStyleVar must run even if a draw call
    -- errors, or ImGui's window and style stacks stay unbalanced for every
    -- other addon window this frame. End() is required even when Begin() is false.
    local ok, err = true, nil;
    if open then
        ok, err = pcall(DrawColumns, settings, columns, contentWidth, contentHeight);
    end

    imgui.End();
    imgui.PopStyleVar();
    if not ok then error(err); end
end

M.ResetPositions = function()
    local defaultPositions = require('libs.defaultpositions');
    local x, y = defaultPositions.GetPhantomRollPosition();

    if gConfig and gConfig.windowPositions then
        gConfig.windowPositions[WINDOW_NAME] = { x = x, y = y };
        if gConfig.appliedPositions then
            gConfig.appliedPositions[WINDOW_NAME] = nil;
        end
    end
end

return M;
