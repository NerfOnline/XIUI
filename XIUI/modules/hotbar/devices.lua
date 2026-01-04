--[[
* XIUI Crossbar - Device Mapping System
* Provides controller-specific button mappings for different input APIs
*
* Supported devices:
*   - xbox: XInput (Xbox controllers, most modern Windows controllers)
*   - dualsense: DirectInput (PlayStation DualSense/DualShock)
*   - switchpro: DirectInput (Nintendo Switch Pro Controller)
]]--

local M = {};

-- ============================================
-- Xbox / XInput Device Mapping
-- ============================================
local xbox = {
    XInput = true,
    DirectInput = false,
    Name = 'Xbox / XInput',

    -- XInput button IDs (bit positions in xinput_button event)
    Buttons = {
        DPAD_UP = 0, DPAD_DOWN = 1, DPAD_LEFT = 2, DPAD_RIGHT = 3,
        START = 4, BACK = 5,
        LEFT_THUMB = 6, RIGHT_THUMB = 7,
        LEFT_SHOULDER = 8, RIGHT_SHOULDER = 9,
        A = 12, B = 13, X = 14, Y = 15,
    },

    -- Button bitmasks for xinput_state
    ButtonMasks = {
        DPAD_UP = 0x0001, DPAD_DOWN = 0x0002, DPAD_LEFT = 0x0004, DPAD_RIGHT = 0x0008,
        START = 0x0010, BACK = 0x0020,
        LEFT_THUMB = 0x0040, RIGHT_THUMB = 0x0080,
        LEFT_SHOULDER = 0x0100, RIGHT_SHOULDER = 0x0200,
        A = 0x1000, B = 0x2000, X = 0x4000, Y = 0x8000,
    },
};

-- Button to slot mapping for Xbox
xbox.ButtonToSlot = {
    [xbox.Buttons.DPAD_UP] = 1,
    [xbox.Buttons.DPAD_RIGHT] = 2,
    [xbox.Buttons.DPAD_DOWN] = 3,
    [xbox.Buttons.DPAD_LEFT] = 4,
    [xbox.Buttons.Y] = 5,
    [xbox.Buttons.B] = 6,
    [xbox.Buttons.A] = 7,
    [xbox.Buttons.X] = 8,
};

xbox.CrossbarButtons = {
    [xbox.Buttons.DPAD_UP] = true, [xbox.Buttons.DPAD_DOWN] = true,
    [xbox.Buttons.DPAD_LEFT] = true, [xbox.Buttons.DPAD_RIGHT] = true,
    [xbox.Buttons.A] = true, [xbox.Buttons.B] = true,
    [xbox.Buttons.X] = true, [xbox.Buttons.Y] = true,
};

xbox.CrossbarButtonsMask = bit.bor(
    xbox.ButtonMasks.DPAD_UP, xbox.ButtonMasks.DPAD_DOWN,
    xbox.ButtonMasks.DPAD_LEFT, xbox.ButtonMasks.DPAD_RIGHT,
    xbox.ButtonMasks.A, xbox.ButtonMasks.B,
    xbox.ButtonMasks.X, xbox.ButtonMasks.Y
);

function xbox.GetSlotFromButton(buttonId)
    return xbox.ButtonToSlot[buttonId];
end

function xbox.IsCrossbarButton(buttonId)
    return xbox.CrossbarButtons[buttonId] == true;
end

function xbox.GetSlotFromButtonMask(buttons)
    if bit.band(buttons, xbox.ButtonMasks.DPAD_UP) ~= 0 then return 1; end
    if bit.band(buttons, xbox.ButtonMasks.DPAD_RIGHT) ~= 0 then return 2; end
    if bit.band(buttons, xbox.ButtonMasks.DPAD_DOWN) ~= 0 then return 3; end
    if bit.band(buttons, xbox.ButtonMasks.DPAD_LEFT) ~= 0 then return 4; end
    if bit.band(buttons, xbox.ButtonMasks.Y) ~= 0 then return 5; end
    if bit.band(buttons, xbox.ButtonMasks.B) ~= 0 then return 6; end
    if bit.band(buttons, xbox.ButtonMasks.A) ~= 0 then return 7; end
    if bit.band(buttons, xbox.ButtonMasks.X) ~= 0 then return 8; end
    return nil;
end

-- ============================================
-- DualSense / PlayStation DirectInput Mapping
-- ============================================
local dualsense = {
    XInput = false,
    DirectInput = true,
    Name = 'DualSense / PS5',

    Buttons = {
        SQUARE = 0, CROSS = 1, CIRCLE = 2, TRIANGLE = 3,
        L1 = 4, R1 = 5, L2 = 6, R2 = 7,
        CREATE = 8, OPTIONS = 9, L3 = 10, R3 = 11,
        PS = 12, TOUCHPAD = 13,
    },

    DPadAngleToSlot = {
        [0] = 1, [9000] = 2, [18000] = 3, [27000] = 4,
    },
};

dualsense.ButtonToSlot = {
    [dualsense.Buttons.TRIANGLE] = 5,
    [dualsense.Buttons.CIRCLE] = 6,
    [dualsense.Buttons.CROSS] = 7,
    [dualsense.Buttons.SQUARE] = 8,
};

dualsense.CrossbarButtons = {
    [dualsense.Buttons.TRIANGLE] = true, [dualsense.Buttons.CIRCLE] = true,
    [dualsense.Buttons.CROSS] = true, [dualsense.Buttons.SQUARE] = true,
};

function dualsense.GetSlotFromButton(buttonId)
    return dualsense.ButtonToSlot[buttonId];
end

function dualsense.GetSlotFromDPad(angle)
    if angle == nil or angle == -1 then return nil; end
    return dualsense.DPadAngleToSlot[angle];
end

function dualsense.IsCrossbarButton(buttonId)
    return dualsense.CrossbarButtons[buttonId] == true;
end

function dualsense.IsTriggerButton(buttonId)
    return buttonId == dualsense.Buttons.L2 or buttonId == dualsense.Buttons.R2;
end

function dualsense.IsL2Button(buttonId)
    return buttonId == dualsense.Buttons.L2;
end

function dualsense.IsR2Button(buttonId)
    return buttonId == dualsense.Buttons.R2;
end

-- ============================================
-- Switch Pro DirectInput Mapping
-- ============================================
local switchpro = {
    XInput = false,
    DirectInput = true,
    Name = 'Switch Pro',

    Buttons = {
        B = 0, A = 1, Y = 2, X = 3,
        L = 4, R = 5, ZL = 6, ZR = 7,
        MINUS = 8, PLUS = 9, L3 = 10, R3 = 11,
        HOME = 12, CAPTURE = 13,
    },

    DPadAngleToSlot = {
        [0] = 1, [9000] = 2, [18000] = 3, [27000] = 4,
    },
};

switchpro.ButtonToSlot = {
    [switchpro.Buttons.X] = 5,
    [switchpro.Buttons.A] = 6,
    [switchpro.Buttons.B] = 7,
    [switchpro.Buttons.Y] = 8,
};

switchpro.CrossbarButtons = {
    [switchpro.Buttons.X] = true, [switchpro.Buttons.A] = true,
    [switchpro.Buttons.B] = true, [switchpro.Buttons.Y] = true,
};

function switchpro.GetSlotFromButton(buttonId)
    return switchpro.ButtonToSlot[buttonId];
end

function switchpro.GetSlotFromDPad(angle)
    if angle == nil or angle == -1 then return nil; end
    return switchpro.DPadAngleToSlot[angle];
end

function switchpro.IsCrossbarButton(buttonId)
    return switchpro.CrossbarButtons[buttonId] == true;
end

function switchpro.IsTriggerButton(buttonId)
    return buttonId == switchpro.Buttons.ZL or buttonId == switchpro.Buttons.ZR;
end

function switchpro.IsL2Button(buttonId)
    return buttonId == switchpro.Buttons.ZL;
end

function switchpro.IsR2Button(buttonId)
    return buttonId == switchpro.Buttons.ZR;
end

-- ============================================
-- Device Registry
-- ============================================
local devices = {
    xbox = xbox,
    dualsense = dualsense,
    switchpro = switchpro,
};

function M.GetDevice(name)
    return devices[name] or devices.xbox;
end

function M.GetDeviceNames()
    return { 'xbox', 'dualsense', 'switchpro' };
end

function M.GetDeviceDisplayNames()
    return {
        xbox = 'Xbox / XInput',
        dualsense = 'DualSense / PS5',
        switchpro = 'Switch Pro',
    };
end

function M.UsesXInput(name)
    local device = M.GetDevice(name);
    return device and device.XInput == true;
end

function M.UsesDirectInput(name)
    local device = M.GetDevice(name);
    return device and device.DirectInput == true;
end

return M;
