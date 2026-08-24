--[[
* ImGui Compatibility Layer for Ashita v4beta
*
* This module provides compatibility between the current Ashita v4beta (main)
* and the upcoming Ashita 4.3 (2025_q3_update branch) which has breaking ImGui changes.
*
* "Main" here includes Ashita 4.16-final private-server installs that ship the
* older addons/libs/imgui.lua. Prefer this shim over telling users to replace
* their shared libs folder (mismatched StyleVar indices break XIUI and other addons).
*
* Auto-detect only (no manual override):
*   - Native ImGuiChildFlags_Borders present  -> current ImGui (Ashita 4.3+)
*   - Native ImGuiChildFlags_Borders missing  -> legacy ImGui (Ashita 4.16-final libs)
* Detect runs BEFORE polyfills. Callers that need the answer must read the
* returned legacyImGui flag:
*     local legacy = require('handlers.imgui_compat').legacyImGui;
* Never re-check ImGuiChildFlags_Borders yourself — the legacy path polyfills
* those constant names for call-site compatibility, so they exist on both.
*
* Changes in 4.3:
*   - BeginChild: cflags default changed, now needs explicit ImGuiChildFlags_Borders
*   - PushStyleColor: idx param no longer optional, nil check needed
*   - ImGuiCol_Tab* constants renamed (TabActive -> TabSelected, etc.)
*   - ImDrawCornerFlags renamed to ImDrawFlags_RoundCorners*
*   - BeginDisabled/EndDisabled: exists in 4.3 (ImGui 1.85+), polyfilled for main
*
* Additional legacy (4.16) / main notes:
*   - BeginChild third arg is a boolean border (not ImGuiChildFlags)
*   - Passing nil child-flag constants into BeginChild breaks config/satchel/etc.
*   - Use ImDrawCornerFlags_* in draw calls; values differ from RoundCorners* bits
]]--

local imgui = require('imgui');

-- Store original functions
local orig_imgui_BeginChild = imgui.BeginChild;

-- Auto-detect current vs legacy ImGui based on native constants
-- Current (4.3+) ships ImGuiChildFlags_Borders; legacy (4.16) stock libs do not
-- Detect BEFORE polyfills so a missing ImGuiChildFlags_Borders stays meaningful
local legacyImGui = (ImGuiChildFlags_Borders == nil);

-- ImDrawCornerFlags -> ImDrawFlags_RoundCorners* aliases
-- 4.3 uses ImDrawFlags_RoundCorners* (new naming), main uses ImDrawCornerFlags_* (old naming)
-- Create aliases so code can use ImDrawCornerFlags_* consistently on both branches
-- (Bit layouts differ: do not hardcode 0xF / 15; use ImDrawCornerFlags_All instead)
if ImDrawFlags_RoundCornersAll ~= nil then
    -- 4.3 branch: new names exist, create old name aliases pointing to new names
    ImDrawCornerFlags_None = ImDrawFlags_RoundCornersNone;
    ImDrawCornerFlags_TopLeft = ImDrawFlags_RoundCornersTopLeft;
    ImDrawCornerFlags_TopRight = ImDrawFlags_RoundCornersTopRight;
    ImDrawCornerFlags_BotLeft = ImDrawFlags_RoundCornersBottomLeft;
    ImDrawCornerFlags_BotRight = ImDrawFlags_RoundCornersBottomRight;
    ImDrawCornerFlags_Top = ImDrawFlags_RoundCornersTop;
    ImDrawCornerFlags_Bot = ImDrawFlags_RoundCornersBottom;
    ImDrawCornerFlags_Left = ImDrawFlags_RoundCornersLeft;
    ImDrawCornerFlags_Right = ImDrawFlags_RoundCornersRight;
    ImDrawCornerFlags_All = ImDrawFlags_RoundCornersAll;
end
-- On main branch: ImDrawCornerFlags_* already exist natively, no aliases needed

-- Convert current-style child flags / legacy bools into a legacy boolean border arg
local function toBoolBorder(cflags)
    if cflags == true then
        return true;
    end
    if cflags == false or cflags == nil then
        return false;
    end
    if type(cflags) == 'number' then
        -- Current ImGuiChildFlags_Borders is bit 0 (= 1)
        return bit.band(cflags, 1) ~= 0;
    end
    return false;
end

-- Convert legacy bool border args into current ImGuiChildFlags values
local function toChildFlags(cflags)
    if cflags == true then
        return ImGuiChildFlags_Borders;
    end
    if cflags == false or cflags == nil then
        return ImGuiChildFlags_None;
    end
    return cflags;
end

if not legacyImGui then
    -- Running on current ImGui (4.3+) - add backwards compatibility aliases for old constant names
    -- These were renamed in ImGui 1.90+
    -- Always set fallbacks first, then override with actual values if they exist
    ImGuiCol_Tab = ImGuiCol_Tab or ImGuiCol_Header or 0;
    ImGuiCol_TabHovered = ImGuiCol_TabHovered or ImGuiCol_HeaderHovered or 0;
    ImGuiCol_TabActive = ImGuiCol_HeaderActive or 0;  -- Will be overwritten below if TabSelected exists
    ImGuiCol_TabUnfocused = ImGuiCol_Header or 0;     -- Will be overwritten below if TabDimmed exists
    ImGuiCol_TabUnfocusedActive = ImGuiCol_HeaderActive or 0;  -- Will be overwritten below if TabDimmedSelected exists

    if ImGuiCol_TabSelected ~= nil then
        ImGuiCol_TabActive = ImGuiCol_TabSelected;
        ImGuiCol_TabUnfocused = ImGuiCol_TabDimmed;
        ImGuiCol_TabUnfocusedActive = ImGuiCol_TabDimmedSelected;
    end

    -- BeginChild: Handle boolean->flags conversion for backwards compat
    imgui.BeginChild = function(id, size, cflags, wflags)
        return orig_imgui_BeginChild(id, size, toChildFlags(cflags), wflags);
    end

else
    -- Running on legacy ImGui - apply compatibility shims for current-style code
    -- (Includes Ashita 4.16-final stock imgui.lua used by many private servers)

    -- Polyfill ImGuiChildFlags_* names so current-style call sites (config, satchel, etc.)
    -- can pass them. BeginChild below maps these back to a real boolean border.
    -- Do not treat presence of these names as proof of current ImGui after this block runs.
    if ImGuiChildFlags_None == nil then
        ImGuiChildFlags_None = 0;
        ImGuiChildFlags_Borders = 1;
        ImGuiChildFlags_AlwaysUseWindowPadding = bit.lshift(1, 1);
        ImGuiChildFlags_ResizeX = bit.lshift(1, 2);
        ImGuiChildFlags_ResizeY = bit.lshift(1, 3);
        ImGuiChildFlags_AutoResizeX = bit.lshift(1, 4);
        ImGuiChildFlags_AutoResizeY = bit.lshift(1, 5);
        ImGuiChildFlags_AlwaysAutoResize = bit.lshift(1, 6);
        ImGuiChildFlags_FrameStyle = bit.lshift(1, 7);
        ImGuiChildFlags_NavFlattened = bit.lshift(1, 8);
    end

    -- ImGuiWindowFlags_NoDocking doesn't exist on main branch (added in 4.3)
    -- Define as 0 so bit.bor() calls don't fail
    if ImGuiWindowFlags_NoDocking == nil then
        ImGuiWindowFlags_NoDocking = 0;
    end

    -- Tab color constants may not exist on older main branch versions
    -- Provide fallbacks to prevent nil idx in PushStyleColor which causes push/pop imbalance
    -- We use existing similar constants as fallbacks so styling still works reasonably
    if ImGuiCol_Tab == nil then
        ImGuiCol_Tab = ImGuiCol_Header or 0;
    end
    if ImGuiCol_TabHovered == nil then
        ImGuiCol_TabHovered = ImGuiCol_HeaderHovered or 0;
    end
    if ImGuiCol_TabActive == nil then
        ImGuiCol_TabActive = ImGuiCol_HeaderActive or 0;
    end
    if ImGuiCol_TabUnfocused == nil then
        ImGuiCol_TabUnfocused = ImGuiCol_Header or 0;
    end
    if ImGuiCol_TabUnfocusedActive == nil then
        ImGuiCol_TabUnfocusedActive = ImGuiCol_HeaderActive or 0;
    end
    if ImGuiCol_TitleBgCollapsed == nil then
        ImGuiCol_TitleBgCollapsed = ImGuiCol_TitleBg or ImGuiCol_WindowBg or 0;
    end
    if ImGuiCol_SliderGrab == nil then
        ImGuiCol_SliderGrab = ImGuiCol_ScrollbarGrab or ImGuiCol_Header or 0;
    end
    if ImGuiCol_SliderGrabActive == nil then
        ImGuiCol_SliderGrabActive = ImGuiCol_ScrollbarGrabActive or ImGuiCol_HeaderActive or 0;
    end

    -- BeginDisabled/EndDisabled shim for main branch
    -- These functions exist in ImGui 1.85+ (4.3) but not in older versions
    -- Always push/pop to maintain stack balance (matches native ImGui behavior)
    if imgui.BeginDisabled == nil then
        imgui.BeginDisabled = function(disabled)
            if disabled == false then
                -- Push with no visual effect to maintain stack balance
                imgui.PushStyleVar(ImGuiStyleVar_Alpha, imgui.GetStyle().Alpha);
            else
                -- Default: apply 50% alpha for disabled appearance
                imgui.PushStyleVar(ImGuiStyleVar_Alpha, imgui.GetStyle().Alpha * 0.5);
            end
        end
        imgui.EndDisabled = function()
            imgui.PopStyleVar();
        end
    end

    -- BeginChild: 4.3 changed default cflags behavior
    -- On legacy/4.16 the third arg is a boolean border; on current it is ImGuiChildFlags
    -- Map bools and polyfilled flag values to a real boolean (never pass nil flags)
    -- Older shim forwarded ImGuiChildFlags_* which are nil on stock 4.16 libs and
    -- broke BeginChild for config, satchel, and Phantom Roll preview windows
    imgui.BeginChild = function(id, size, cflags, wflags)
        return orig_imgui_BeginChild(id, size, toBoolBorder(cflags), wflags);
    end

    -- PushStyleColor wrapper removed - all constants now guaranteed to exist via fallbacks above
    -- This ensures push/pop counts always match

end

-- Return module info for debugging
return {
    version = '1.1.0',
    legacyImGui = legacyImGui,
    mode = legacyImGui and 'legacy' or 'current',
    description = 'ImGui compatibility layer for Ashita v4beta current/legacy (4.3 / 4.16)',
};
