# XIUI Hotbar Crash Investigation Report

**Date:** January 4, 2026
**Symptom:** Crash when pressing a hotkey for the hotbar
**Scope:** Comprehensive code review of `XIUI/modules/hotbar/` and related files

---

## Executive Summary

After a thorough investigation of the hotbar module (~450 KB across 18 files), I identified **multiple critical issues** that could cause crashes when pressing hotkeys. The most likely crash candidates are:

1. **Disabled FFI call in macros.lua** - The `macros.stop()` function has its FFI call commented out with a note saying it was "causing crashes"
2. **Nil access on slotData in crossbar.lua:716** - Accessing `.displayName` on potentially nil slotData
3. **Missing gConfig validation in actions.lua** - `FindMatchingKeybind()` assumes gConfig structure exists
4. **Unvalidated FFI memory reads in macros.lua** - Double pointer dereference without validation

---

## Critical Issues (Crash Risk: HIGH)

### Issue 1: macros.stop() FFI Call Disabled Due to Crashes

**File:** `XIUI/libs/ffxi/macros.lua:328-339`

```lua
macrolib.stop = function ()
    local obj = macrolib.get_fsmacro();
    print('[macros.stop] obj=' .. tostring(obj) .. ' ptrs.stop=' .. tostring(macrolib.ptrs.stop));
    if (obj == nil or obj == 0) then
        print('[macros.stop] obj invalid, returning early');
        return;
    end

    -- TEMPORARILY DISABLED: FFI call causing crashes, investigating
    print('[macros.stop] FFI call DISABLED for debugging');
    -- ffi.cast('FsMacroContainer_stopMacro_f', macrolib.ptrs.stop)(obj);
end
```

**Analysis:** The FFI call is already commented out with a note that it was "causing crashes." This is a major red flag indicating known instability in the macro-stop pathway. If `StopNativeMacros()` in actions.lua is being called during hotkey execution, this could be the source of crashes.

**Call Path:**
```
Hotkey Press → HandleKey() → HandleKeybind() → ExecuteCommandString()
→ (optionally) StopNativeMacros() → macros.stop() → [CRASH]
```

---

### Issue 2: Nil slotData Access in Crossbar Tooltip

**File:** `XIUI/modules/hotbar/crossbar.lua:716`

```lua
labelText = slotData.displayName or slotData.action or '',
```

**Problem:** `slotData` can be nil if the slot is empty (returned from `data.GetCrossbarSlotData()`), but this line accesses `.displayName` without a nil check.

**Fix Required:**
```lua
labelText = slotData and (slotData.displayName or slotData.action or '') or '',
```

---

### Issue 3: FindMatchingKeybind Assumes gConfig Structure

**File:** `XIUI/modules/hotbar/actions.lua:876-898`

```lua
local function FindMatchingKeybind(keyCode, ctrl, alt, shift)
    for barIndex = 1, 6 do
        local configKey = 'hotbarBar' .. barIndex;
        local barSettings = gConfig and gConfig[configKey];  -- Only checks gConfig exists
        if barSettings and barSettings.enabled and barSettings.keyBindings then
            for slotIndex, binding in pairs(barSettings.keyBindings) do
                -- No validation that binding is a valid table
```

**Problems:**
1. Only checks if `gConfig` exists, not if it's a valid table
2. No validation that `binding` is a valid table before accessing `binding.key`
3. If `barSettings.keyBindings` is corrupted (not a table), `pairs()` will fail

---

### Issue 4: Double Memory Read Without Pointer Validation

**File:** `XIUI/libs/ffxi/macros.lua:121-125`

```lua
macrolib.get_fsmacro = function ()
    local addr = ashita.memory.read_uint32(macrolib.ptrs.macro);
    if (addr == 0) then return 0; end
    return ashita.memory.read_uint32(addr);  -- CRASH if addr is freed/invalid
end
```

**Problem:** The code checks for 0 but not for invalid/freed memory addresses. If the first read returns a garbage pointer, the second read will segfault.

---

### Issue 5: FFI String Conversion Without Null Check

**File:** `XIUI/libs/ffxi/macros.lua:173-190`

```lua
macrolib.get_name = function (idx)
    local obj = macrolib.get_fsmacro();
    if (obj == nil or obj == 0) then return ''; end

    local str = ffi.cast('FsMacroContainer_getName_f', macrolib.ptrs.get_name)(obj, idx);
    if (str == nil) then return ''; end
    str = ffi.string(str);  -- Can crash if str pointer is garbage
    if (str == nil) then return ''; end
    return str;
end
```

**Problem:** The FFI cast returns a C pointer. If that pointer is garbage/freed, `ffi.string()` will segfault reading from invalid memory.

---

### Issue 6: gConfig.hotbarCrossbar Accessed Without Validation

**File:** `XIUI/modules/hotbar/init.lua:281-287`

```lua
controller.Initialize({
    expandedCrossbarEnabled = gConfig.hotbarCrossbar.enableExpandedCrossbar ~= false,
    doubleTapEnabled = gConfig.hotbarCrossbar.enableDoubleTap or false,
    doubleTapWindow = gConfig.hotbarCrossbar.doubleTapWindow or 0.3,
    controllerScheme = gConfig.hotbarCrossbar.controllerScheme or 'xbox',
});
```

**Problem:** Directly accesses `gConfig.hotbarCrossbar` attributes without checking if `gConfig.hotbarCrossbar` exists. If nil, this throws an error during controller initialization.

---

### Issue 7: require('config.hotbar') With No Nil Check

**File:** `XIUI/modules/hotbar/actions.lua:925`

```lua
local hotbarConfig = require('config.hotbar');
if hotbarConfig.IsCapturingKeybind() then
```

**Problem:** No nil check after require. If the require fails for any reason, calling `.IsCapturingKeybind()` on nil will crash.

---

### Issue 8: Bar Settings Not Nil-Checked Before Use

**File:** `XIUI/modules/hotbar/init.lua:135-139`

```lua
for barIndex = 1, data.NUM_BARS do
    local barSettings = data.GetBarSettings(barIndex);
    local bgTheme = barSettings.backgroundTheme or '-None-';  -- CRASH if barSettings is nil
    local bgScale = barSettings.bgScale or 1.0;
```

**Problem:** `data.GetBarSettings()` could return nil if `gConfig['hotbarBar' .. barIndex]` doesn't exist, but code immediately accesses `.backgroundTheme` without a nil check.

---

## High Priority Issues

### Issue 9: AshitaCore:GetInstallPath() Could Return Nil

**File:** `XIUI/modules/hotbar/crossbar.lua:359`

```lua
local function GetAssetsPath()
    return string.format('%saddons\\XIUI\\assets\\hotbar\\', AshitaCore:GetInstallPath());
end
```

**Problem:** If `GetInstallPath()` returns nil, `string.format()` will fail. Similar issues exist at `actions.lua:592,622`.

---

### Issue 10: GetForegroundDrawList() Not Always Checked

**File:** `XIUI/modules/hotbar/crossbar.lua:1089+`

```lua
local drawList = imgui.GetForegroundDrawList();
-- Used in lines 1131, 1135, 1148, etc. without consistent nil checks
```

**Problem:** While some uses are guarded (`if drawList and ...`), others are not. If `GetForegroundDrawList()` returns nil, subsequent `drawList:AddLine()` calls crash.

---

### Issue 11: Drag Payload Not Fully Validated

**File:** `XIUI/modules/hotbar/crossbar.lua:735`

```lua
elseif payload.type == 'crossbar_slot' then
    local targetData = data.GetCrossbarSlotData(comboMode, slotIndex);
    data.SetCrossbarSlotData(comboMode, slotIndex, payload.data);
    data.SetCrossbarSlotData(payload.comboMode, payload.slotIndex, targetData);  -- Not validated
```

**Problem:** `payload.comboMode` and `payload.slotIndex` are not validated before being passed to `SetCrossbarSlotData()`. Malformed payloads could cause crashes.

---

### Issue 12: Missing Lower Bound Checks in Macro Index Validation

**File:** `XIUI/libs/ffxi/macros.lua:156-165`

```lua
macrolib.clear = function (idx)
    if (idx >= 20) then return false; end  -- Only upper bound checked
    -- No check for idx < 0
```

**Problem:** Negative indices aren't validated. Passing `idx = -1` could cause buffer underflow in FFI calls.

---

## Medium Priority Issues

### Issue 13: data.jobId Could Be Nil on First Frame

**File:** `XIUI/modules/hotbar/actions.lua:572`

```lua
local paletteKey = bind.macroPaletteKey or data.jobId or 1;
```

**Problem:** `data.jobId` is initialized as nil at module load. If accessed before job data is available, silently falls back to 1, masking initialization bugs.

---

### Issue 14: Icon Texture Loading Returns Nil Without Logging

**File:** `XIUI/modules/hotbar/actions.lua:570-729` (GetBindIcon function)

**Problem:** The function tries multiple icon sources and returns nil if all fail, with no logging. Silent failures make debugging difficult.

---

### Issue 15: Command Building Doesn't Escape Quotes

**File:** `XIUI/modules/hotbar/actions.lua:750-756`

```lua
if bind.actionType == 'ma' then
    command = '/ma "' .. bind.action .. '" <' .. bind.target .. '>';
```

**Problem:** If `bind.action` contains a quote character, the command syntax breaks. Not a crash, but causes action execution failure.

---

### Issue 16: Path Traversal Vulnerability

**File:** `XIUI/modules/hotbar/actions.lua:592,622`

```lua
local customDir = string.format('%saddons\\XIUI\\assets\\hotbar\\custom\\', AshitaCore:GetInstallPath());
icon = textures:LoadTextureFromPath(customDir .. bind.customIconPath);
```

**Problem:** `customIconPath` is user-supplied and could contain `../` to escape the intended directory.

---

## Architectural Issues (Lower Crash Risk)

### Issue 17: Circular Dependencies Requiring Lazy Loading

Several modules have circular dependencies:
- `display ↔ macropalette`
- `petpalette ↔ data`

These use lazy loading to avoid initialization crashes, but the pattern is fragile.

---

### Issue 18: Duplicated Storage Key Normalization

**Files:** `data.lua:97-173`, `crossbar.lua:29-61`

Identical helper functions (`normalizeJobId()`, `getStorageKey()`, etc.) are duplicated across files. If implementations diverge, bugs occur.

---

### Issue 19: Texture VRAM Leaks

**File:** `XIUI/modules/hotbar/textures.lua`

Textures loaded via D3D8 are cached but never explicitly `Release()`d. On addon reload, duplicate references may leak VRAM.

---

### Issue 20: No Centralized Cache Manager

Multiple cache systems exist with different invalidation strategies:
- Icon cache (display.lua)
- Slot renderer cache (slotrenderer.lua)
- MP cost cache (slotrenderer.lua)
- Availability cache (slotrenderer.lua)

Risk of stale caches showing outdated data if invalidation is missed.

---

## Hotkey Execution Flow Analysis

When a hotkey is pressed, this is the critical path:

```
1. HandleKey(event) [actions.lua:900]
   ↓
2. parseKeyEventFlags() - determine press/release
   ↓
3. GetModifierStates() - query OS key state via FFI
   ↓
4. FindMatchingKeybind() [actions.lua:876] ← CRASH POINT: gConfig access
   ↓
5. HandleKeybind(hotbar, slot) [actions.lua:863]
   ↓
6. data.GetKeybindForSlot() - retrieve action data
   ↓
7. BuildCommand(bind) [actions.lua:737]
   ↓
8. ExecuteCommandString(command) [actions.lua:790]
   ↓
9. (optional) StopNativeMacros() ← CRASH POINT: FFI call
   ↓
10. AshitaCore:GetChatManager():QueueCommand() - execute
```

**Most Likely Crash Points:**
- Step 4: If gConfig structure is invalid
- Step 9: If macros.stop() FFI call is re-enabled or related memory is accessed

---

## Recommendations

### Immediate Fixes (Before Re-enabling)

1. **Validate gConfig structure** at the start of `FindMatchingKeybind()`:
   ```lua
   if not gConfig or type(gConfig) ~= 'table' then return nil, nil; end
   ```

2. **Add nil check to crossbar.lua:716**:
   ```lua
   labelText = slotData and (slotData.displayName or slotData.action or '') or '',
   ```

3. **Investigate macros.stop() crash** - the disabled FFI call is a major indicator of memory safety issues

4. **Add nil checks around bar settings access** in init.lua

5. **Validate gConfig.hotbarCrossbar** before accessing attributes in init.lua:281-287

### Medium-Term Fixes

1. Add explicit nil checks after all `require()` calls
2. Validate all FFI pointers before dereferencing
3. Add lower bound checks (idx >= 0) for macro index validation
4. Add logging when icon loading fails silently
5. Sanitize customIconPath to prevent directory traversal

### Long-Term Improvements

1. Centralize cache management
2. Extract duplicated storage key logic to shared module
3. Add explicit D3D texture cleanup on unload
4. Consider reducing circular dependencies

---

## Files Reviewed

| File | Size | Status |
|------|------|--------|
| modules/hotbar/init.lua | 30 KB | Multiple gConfig issues |
| modules/hotbar/actions.lua | 39 KB | Critical gConfig and require issues |
| modules/hotbar/controller.lua | 29 KB | Mostly safe, minor issues |
| modules/hotbar/crossbar.lua | 61 KB | Critical nil access on line 716 |
| modules/hotbar/data.lua | 31 KB | Reviewed for storage key handling |
| modules/hotbar/slotrenderer.lua | 45 KB | Cache management concerns |
| modules/hotbar/macropalette.lua | 147 KB | Circular dependency, lazy loading |
| modules/hotbar/display.lua | 28 KB | Cache invalidation reviewed |
| modules/hotbar/textures.lua | 18 KB | VRAM leak potential |
| libs/ffxi/macros.lua | ~12 KB | **CRITICAL** - Disabled FFI call |
| config/hotbar.lua | ~25 KB | Missing gConfig nil checks |

---

## Conclusion

The most likely cause of the crash is one of:

1. **Memory corruption from macros library FFI calls** - the disabled `macros.stop()` call is evidence of known instability
2. **Nil access on gConfig or slotData** - multiple code paths assume these exist without validation
3. **Invalid FFI pointer dereference** in the macros library when reading macro data

**Recommended First Step:** Add defensive nil checks around gConfig access in `FindMatchingKeybind()` and test. If crashes persist, investigate the macros library FFI calls more thoroughly.
