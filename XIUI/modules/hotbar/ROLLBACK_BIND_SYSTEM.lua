--[[
* ROLLBACK FILE: Ashita /bind Keybind System
*
* This file contains the original /bind-based keybind implementation.
* If the new macros.stop() approach doesn't work well, use this to restore.
*
* ROLLBACK INSTRUCTIONS:
* ======================
*
* 1. In actions.lua, add this code block BEFORE "return M" at the end:
*    (Copy everything between "-- BEGIN BIND SYSTEM --" and "-- END BIND SYSTEM --")
*
* 2. In init.lua, restore these calls:
*    - In Initialize() after data.Initialize(): actions.RegisterKeybinds();
*    - In UpdateVisuals() in the hotbar enable/disable logic:
*        if wasHotbarEnabled and not isHotbarEnabled then
*            actions.ClearAllBinds();
*        elseif isHotbarEnabled then
*            actions.RegisterKeybinds();
*        end
*    - In Cleanup(): actions.UnregisterKeybinds();
*
* 3. In config/hotbar.lua, restore these calls after saving keybinds:
*    - After clearing a keybind (line ~588): actions.RegisterKeybinds();
*    - After capturing a keybind (line ~675): actions.RegisterKeybinds();
*
* 4. In actions.lua HandleKey(), REMOVE the macros.stop() call if present
*
* 5. Delete or comment out: local macrosLib = require('libs.ffxi.macros');
]]--

-- BEGIN BIND SYSTEM --

-- ============================================
-- Ashita Keybind Registration
-- Uses /bind to intercept keys at a lower level than addon keyboard events,
-- which properly blocks native FFXI macros from firing
-- ============================================

-- SAFETY: Set to false to completely disable /bind registration
-- This prevents native macro blocking but avoids potential crashes
local ENABLE_ASHITA_BINDS = true;

-- Track registered binds so we can unbind them on cleanup/change
local registeredBinds = {};

-- Track if silent mode is enabled
local silentModeEnabled = false;

-- Track if module is being cleaned up (prevents registration during unload)
local isCleaningUp = false;

-- Convert modifier flags + key code to Ashita bind format
-- Ashita uses: ^ for Ctrl, ! for Alt, + for Shift
local function FormatBindKey(keyCode, ctrl, alt, shift)
    local prefix = '';
    if ctrl then prefix = prefix .. '^'; end
    if alt then prefix = prefix .. '!'; end
    if shift then prefix = prefix .. '+'; end

    -- Convert virtual key code to Ashita key name
    -- Reference: https://wiki.ashitaxi.com/doku.php?id=ashitav3:keybinds
    local keyName = nil;

    -- Number keys 0-9 (VK 48-57)
    if keyCode >= 48 and keyCode <= 57 then
        keyName = tostring(keyCode - 48);
    -- Letter keys A-Z (VK 65-90)
    elseif keyCode >= 65 and keyCode <= 90 then
        keyName = string.char(keyCode);
    -- Function keys F1-F12 (VK 112-123)
    elseif keyCode >= 112 and keyCode <= 123 then
        keyName = 'F' .. tostring(keyCode - 111);
    -- Numpad 0-9 (VK 96-105)
    elseif keyCode >= 96 and keyCode <= 105 then
        keyName = 'NUMPAD' .. tostring(keyCode - 96);
    -- Main keyboard minus (VK 189) - only supported WITH modifiers (Ctrl/Alt/Shift)
    -- Bare minus conflicts with native FFXI menus, but modifier combos are fine
    elseif keyCode == 189 then
        -- Only allow if a modifier is present (checked via prefix)
        if ctrl or alt or shift then
            keyName = '-';
        end
    -- Numpad minus (VK 109)
    elseif keyCode == 109 then
        keyName = 'NUMPAD-';
    -- Main keyboard equals/plus (VK 187)
    elseif keyCode == 187 then
        keyName = '=';
    -- Numpad plus (VK 107)
    elseif keyCode == 107 then
        keyName = 'NUMPAD+';
    -- Numpad multiply (VK 106)
    elseif keyCode == 106 then
        keyName = 'NUMPAD*';
    -- Numpad divide (VK 111)
    elseif keyCode == 111 then
        keyName = 'NUMPAD/';
    -- Numpad decimal (VK 110)
    elseif keyCode == 110 then
        keyName = 'NUMPAD.';
    -- Space (VK 32)
    elseif keyCode == 32 then
        keyName = 'SPACE';
    -- Tab (VK 9)
    elseif keyCode == 9 then
        keyName = 'TAB';
    -- Escape (VK 27)
    elseif keyCode == 27 then
        keyName = 'ESCAPE';
    -- Backspace (VK 8)
    elseif keyCode == 8 then
        keyName = 'BACK';
    -- Enter (VK 13)
    elseif keyCode == 13 then
        keyName = 'RETURN';
    -- Backtick/tilde (VK 192)
    elseif keyCode == 192 then
        keyName = '`';
    -- [ (VK 219)
    elseif keyCode == 219 then
        keyName = '[';
    -- ] (VK 221)
    elseif keyCode == 221 then
        keyName = ']';
    -- \ (VK 220)
    elseif keyCode == 220 then
        keyName = '\\';
    -- ; (VK 186)
    elseif keyCode == 186 then
        keyName = ';';
    -- ' (VK 222)
    elseif keyCode == 222 then
        keyName = "'";
    -- , (VK 188)
    elseif keyCode == 188 then
        keyName = ',';
    -- . (VK 190)
    elseif keyCode == 190 then
        keyName = '.';
    -- / (VK 191)
    elseif keyCode == 191 then
        keyName = '/';
    end

    if not keyName then
        return nil;
    end

    return prefix .. keyName;
end

--- Register all configured keybinds with Ashita's /bind system
--- This blocks native FFXI macros from firing on those keys
function M.RegisterKeybinds()
    -- Safety checks
    if not ENABLE_ASHITA_BINDS then return; end
    if isCleaningUp then return; end

    -- Check if hotbar is globally disabled - clear binds instead of registering
    if gConfig and gConfig.hotbarEnabled == false then
        M.ClearAllBinds();
        return;
    end

    -- Wrap everything in pcall for safety
    local ok, err = pcall(function()
        local chatManager = AshitaCore:GetChatManager();
        if not chatManager then return; end

        -- Enable silent mode once and leave it on permanently
        -- This avoids timing issues with async command queue
        if not silentModeEnabled then
            chatManager:QueueCommand(-1, '/bind silent 1');
            silentModeEnabled = true;

            -- Explicitly unbind bare minus key to clear any stale binds
            -- The minus key without modifiers conflicts with native FFXI menus
            -- Ctrl+- and Alt+- are allowed
            chatManager:QueueCommand(-1, '/unbind -');
        end

        -- Build list of new binds we want to register
        local newBinds = {};

        if gConfig then
            for barIndex = 1, 6 do
                local configKey = 'hotbarBar' .. barIndex;
                local barSettings = gConfig[configKey];

                if barSettings and barSettings.enabled and barSettings.keyBindings then
                    for slotIndex, binding in pairs(barSettings.keyBindings) do
                        if binding and binding.key then
                            local bindKey = FormatBindKey(
                                binding.key,
                                binding.ctrl or false,
                                binding.alt or false,
                                binding.shift or false
                            );

                            if bindKey then
                                table.insert(newBinds, {
                                    key = bindKey,
                                    barIndex = barIndex,
                                    slotIndex = slotIndex,
                                });
                            end
                        end
                    end
                end
            end
        end

        -- Unbind old binds that aren't in the new set
        local newBindSet = {};
        for _, bind in ipairs(newBinds) do
            newBindSet[bind.key] = true;
        end

        for _, bindKey in ipairs(registeredBinds) do
            if not newBindSet[bindKey] then
                chatManager:QueueCommand(-1, '/unbind ' .. bindKey);
            end
        end

        -- Register new binds (overwrites existing binds with same key)
        registeredBinds = {};
        for _, bind in ipairs(newBinds) do
            local bindCommand = string.format(
                '/bind %s /xiui hotbar %d %d',
                bind.key, bind.barIndex, bind.slotIndex
            );
            chatManager:QueueCommand(-1, bindCommand);
            table.insert(registeredBinds, bind.key);
        end
    end);

    if not ok then
        print('[XIUI] Warning: Failed to register keybinds: ' .. tostring(err));
    end
end

--- Clear all registered keybinds (used when hotbar is disabled)
--- Sends /unbind commands for all registered binds
function M.ClearAllBinds()
    local ok, err = pcall(function()
        local chatManager = AshitaCore:GetChatManager();
        if not chatManager then return; end

        for _, bindKey in ipairs(registeredBinds) do
            chatManager:QueueCommand(-1, '/unbind ' .. bindKey);
        end
        registeredBinds = {};
    end);

    if not ok then
        print('[XIUI] Warning: Failed to clear keybinds: ' .. tostring(err));
    end
end

--- Unregister all previously registered keybinds (called on addon unload)
--- NOTE: This is intentionally minimal to avoid command queue issues during reload.
--- The binds will either be overwritten by the next load or cleaned up manually.
function M.UnregisterKeybinds()
    -- Set cleanup flag to prevent re-registration during unload
    isCleaningUp = true;

    -- Clear local tracking only
    -- We intentionally DON'T send /unbind commands here because:
    -- 1. During addon reload, commands can interleave unpredictably
    -- 2. The new module will overwrite binds with same keys anyway
    -- 3. Sending many commands during unload can cause instability
    registeredBinds = {};

    -- Reset silent mode tracking so the next load will re-enable it
    silentModeEnabled = false;
end

-- END BIND SYSTEM --

--[[
CALL SITES TO RESTORE IN init.lua:
==================================

1. In Initialize() around line 311:
   -- Register keybinds with Ashita's /bind system (only if hotbar is enabled)
   -- This blocks native FFXI macros from firing on bound keys
   if gConfig.hotbarEnabled ~= false then
       actions.RegisterKeybinds();
   end

2. In UpdateVisuals() around line 428-434:
   if wasHotbarEnabled and not isHotbarEnabled then
       -- Transitioning from enabled to disabled - clear all keybinds
       actions.ClearAllBinds();
   elseif isHotbarEnabled then
       -- Hotbar is enabled - re-register keybinds in case they changed
       actions.RegisterKeybinds();
   end

3. In Cleanup() around line 640:
   -- Unregister Ashita keybinds to restore native behavior
   actions.UnregisterKeybinds();


CALL SITES TO RESTORE IN config/hotbar.lua:
===========================================

1. After clearing keybind (around line 588):
   -- Re-register Ashita keybinds
   actions.RegisterKeybinds();

2. After capturing keybind (around line 675):
   -- Re-register Ashita keybinds to apply the change
   actions.RegisterKeybinds();
]]--
