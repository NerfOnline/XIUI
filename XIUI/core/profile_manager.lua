local profileManager = {};
local addonName = 'xiui';
local configPath = AshitaCore:GetInstallPath() .. '\\config\\addons\\' .. addonName .. '\\';
local profilesPath = configPath .. 'profiles\\';

-- Ensure directories exist
if (not ashita.fs.exists(configPath)) then
    ashita.fs.create_directory(configPath);
end
if (not ashita.fs.exists(profilesPath)) then
    ashita.fs.create_directory(profilesPath);
end

-- Simple serializer for Lua tables
local function Serialize(t, indent)
    indent = indent or 1;
    local prefix = string.rep("    ", indent);
    local str = "{\n";
    
    -- Handle T tables by treating them as regular tables for iteration
    for k, v in pairs(t) do
        local key = k;
        if (type(k) == "string") then
            -- Handle keys that are valid identifiers vs needing brackets
            if string.match(k, "^[%a_][%w_]*$") then
                key = k;
            else
                key = string.format("['%s']", k);
            end
        elseif (type(k) == "number") then
            key = string.format("[%s]", k);
        end
        
        local valueStr = "";
        if (type(v) == "table") then
            valueStr = Serialize(v, indent + 1);
        elseif (type(v) == "string") then
            valueStr = string.format("%q", v); -- Use %q for safe string quoting
        elseif (type(v) == "boolean") then
            valueStr = (v and "true" or "false");
        elseif (type(v) == "number") then
            valueStr = tostring(v);
        end
        
        if (valueStr ~= "") then
            str = str .. prefix .. key .. " = " .. valueStr .. ",\n";
        end
    end
    
    str = str .. string.rep("    ", indent - 1) .. "}";
    return str;
end

local function SerializeLegacy(t)
    local function escapeKey(s)
        return s:gsub("\\", "\\\\"):gsub("\"", "\\\"")
    end

    local function formatKey(k)
        if type(k) == 'string' then
            return string.format("[\"%s\"]", escapeKey(k))
        end
        if type(k) == 'number' then
            return string.format("[%d]", k)
        end
        return string.format("[\"%s\"]", escapeKey(tostring(k)))
    end

    local function sortKeys(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then
            if ta == 'number' then return true end
            if tb == 'number' then return false end
            if ta == 'string' then return true end
            if tb == 'string' then return false end
            return tostring(ta) < tostring(tb)
        end
        if ta == 'number' then return a < b end
        if ta == 'string' then return a < b end
        return tostring(a) < tostring(b)
    end

    local function formatValue(v)
        local tv = type(v)
        if tv == 'string' then return string.format('%q', v) end
        if tv == 'boolean' then return v and 'true' or 'false' end
        if tv == 'number' then return tostring(v) end
        return nil
    end

    local lines = {}
    lines[#lines + 1] = "local settings = {};"
    lines[#lines + 1] = "settings[\"userSettings\"] = {};"

    local initialized = {
        ["settings"] = true,
        ["settings[\"userSettings\"]"] = true,
    }

    local function ensureTable(path)
        if initialized[path] then return end
        initialized[path] = true
        lines[#lines + 1] = string.format("%s = {};", path)
    end

    local function walkTable(tbl, path)
        local keys = {}
        for k in pairs(tbl) do
            keys[#keys + 1] = k
        end
        table.sort(keys, sortKeys)

        for _, k in ipairs(keys) do
            local v = tbl[k]
            if v ~= nil then
                local childPath = path .. formatKey(k)
                if type(v) == 'table' then
                    ensureTable(childPath)
                    walkTable(v, childPath)
                else
                    local valueStr = formatValue(v)
                    if valueStr ~= nil then
                        lines[#lines + 1] = string.format("%s = %s;", childPath, valueStr)
                    end
                end
            end
        end
    end

    walkTable(t, "settings[\"userSettings\"]")
    lines[#lines + 1] = "return settings;"
    return table.concat(lines, "\n")
end

function profileManager.SaveTable(path, t)
    local f = io.open(path, "w");
    if (f) then
        f:write("return " .. Serialize(t) .. ";");
        f:close();
        return true;
    end
    return false;
end

function profileManager.LoadTable(path)
    if (not ashita.fs.exists(path)) then return nil; end
    local func, err = loadfile(path);
    if (func) then
        local success, result = pcall(func);
        if (success) then
            return result;
        end
    end
    return nil;
end



function profileManager.GetGlobalProfiles()
    local path = configPath .. 'profilelist.lua';
    local oldPath = configPath .. 'profiles.lua';
    
    -- Rename old profiles.lua if it exists and new one doesn't
    if (ashita.fs.exists(oldPath) and not ashita.fs.exists(path)) then
        local oldContent = profileManager.LoadTable(oldPath);
        if (oldContent) then
            profileManager.SaveTable(path, oldContent);
            os.remove(oldPath);
        end
    end

    local profiles = profileManager.LoadTable(path);
    if (profiles == nil) then
        profiles = {
            names = { 'Default' },
            order = { 'Default' }
        };
        profileManager.SaveTable(path, profiles);
    end
    return profiles;
end

function profileManager.SaveGlobalProfiles(profiles)
    local path = configPath .. 'profilelist.lua';
    return profileManager.SaveTable(path, profiles);
end

function profileManager.GetProfileSettings(name)
    local path = profilesPath .. name .. '.lua';
    local t = profileManager.LoadTable(path);
    if (t and t.userSettings) then
        return t.userSettings;
    end
    return t;
end

function profileManager.SaveProfileSettings(name, settings)
    -- NOTE: Window positions are now captured live in gConfig.windowPositions by SaveWindowPosition()
    -- We no longer parse imgui.ini here because it may be stale (ImGui flushes to disk lazily).
    -- The passed 'settings' object (which is gConfig) already contains the up-to-date positions.

    local path = profilesPath .. name .. '.lua';
    local f = io.open(path, "w");
    if (f) then
        f:write(SerializeLegacy(settings));
        f:close();
        return true;
    end
    return false;
end

function profileManager.ProfileExists(name)
    local path = profilesPath .. name .. '.lua';
    return ashita.fs.exists(path);
end

function profileManager.DeleteProfile(name)
    local path = profilesPath .. name .. '.lua';
    if (ashita.fs.exists(path)) then
        os.remove(path);
        return true;
    end
    return false;
end

-- Helper to parse imgui.ini for window positions
-- Only used during legacy migration
local function ParseImguiIni()
    local iniPath = AshitaCore:GetInstallPath() .. '\\config\\imgui.ini';
    if (not ashita.fs.exists(iniPath)) then return nil; end

    local f = io.open(iniPath, 'r');
    if (not f) then return nil; end

    local positions = {};
    local currentWindow = nil;
    
    -- Known XIUI window names to look for
    local knownWindows = {
        ["PlayerBar"] = true,
        ["TargetBar"] = true,
        ["ExpBar"] = true,
        ["CastBar"] = true,
        ["EnemyList"] = true,
        ["GilTracker"] = true,
        ["InventoryTracker"] = true,
        ["MobInfo"] = true,
        ["PetBar"] = true,
        ["PetBarTarget"] = true,
        ["Notifications"] = true,
        ["TreasurePool"] = true,
        ["CastCost"] = true,
        ["PartyList"] = true,
        ["PartyList2"] = true,
        ["PartyList3"] = true,
        ["mobdb_infobar"] = true,
        ["MobDB_Detail_View"] = true,
        ["SimpleLog - v0.1.1"] = true,
        ["SimpleLog - v0.1.2"] = true,
        ["xitools.treas"] = true,
        ["xitools.tracker"] = true,
        ["xitools.inv"] = true,
        ["xitools.cast"] = true,
        ["xitools.week"] = true,
        ["xitools.crafty"] = true,
        ["xitools.fishe"] = true,
        ["st_ui"] = true,
        ["st_flags_starget"] = true,
        ["st_flags_mtarget"] = true,
        ["trials"] = true,
        ["PointsBar_Nerf"] = true,
        ["hticks"] = true,
    };

    for line in f:lines() do
        -- Check for section header [Window][WindowName]
        local section = line:match("^%[Window%](%[.*%])$");
        if (section) then
            -- Remove brackets to get name
            currentWindow = section:match("^%[(.*)%]$");
            -- Check if it's one of our windows
            if (currentWindow and not knownWindows[currentWindow]) then
                currentWindow = nil;
            end
        elseif (currentWindow) then
            -- Parse Pos=x,y
            local x, y = line:match("^Pos=(%-?%d+),(%-?%d+)$");
            if (x and y) then
                positions[currentWindow] = { x = tonumber(x), y = tonumber(y) };
                currentWindow = nil; -- We found the pos, move on
            end
        end
    end
    
    f:close();
    return positions;
end

function profileManager.GetImguiPositions()
    return ParseImguiIni();
end

return profileManager;
