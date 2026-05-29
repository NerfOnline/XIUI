--[[
* Profile share-code codec.
* Share codes: base64([compress-method byte][packed binary payload]).
]]--

local codec = {};

local ffi = require('ffi');

local BINARY_FORMAT_VERSION = 1;
local FLAG_DELTA = 0x01;
codec.FLAG_DELTA = FLAG_DELTA;

-- Typed binary tags
local TAG_FALSE = 0x00;
local TAG_TRUE = 0x01;
local TAG_INT32 = 0x02;
local TAG_DOUBLE = 0x03;
local TAG_STRING = 0x04;
local TAG_TABLE = 0x05;
local TAG_U8 = 0x06;
local TAG_U16 = 0x07;
local TAG_KEY_SHORT = 0x10;      -- uint8 len + utf8 (fallback)
local TAG_KEY_LONG = 0x11;     -- uint16 len + utf8 (fallback)
local TAG_KEY_NUMBER = 0x12;   -- uint32 index
local TAG_KEY_DICT = 0x13;     -- uint16 dict index

-- ---------------------------------------------------------------------------
-- Byte buffer writer / reader
-- ---------------------------------------------------------------------------

local function NewWriter()
    local parts = {};
    local len = 0;
    return {
        bytes = function(self, s)
            parts[#parts + 1] = s;
            len = len + #s;
        end,
        byte = function(self, b)
            parts[#parts + 1] = string.char(b);
            len = len + 1;
        end,
        u16 = function(self, n)
            self:bytes(string.char(
                math.floor(n / 256) % 256,
                n % 256
            ));
        end,
        u32 = function(self, n)
            self:bytes(string.char(
                math.floor(n / 16777216) % 256,
                math.floor(n / 65536) % 256,
                math.floor(n / 256) % 256,
                n % 256
            ));
        end,
        i32 = function(self, n)
            if (n < 0) then
                n = 0x100000000 + n;
            end
            self:u32(n);
        end,
        f64 = function(self, n)
            local buf = ffi.new('double[1]', n);
            self:bytes(ffi.string(buf, 8));
        end,
        finish = function(self)
            return table.concat(parts);
        end,
        length = function(self)
            return len;
        end,
    };
end

local function NewReader(data, dataLen)
    local pos = 1;
    dataLen = dataLen or #data;
    return {
        byte = function(self)
            if (pos > dataLen) then return nil; end
            local b = data:byte(pos);
            pos = pos + 1;
            return b;
        end,
        bytes = function(self, count)
            if (pos + count - 1 > dataLen) then return nil; end
            local s = data:sub(pos, pos + count - 1);
            pos = pos + count;
            return s;
        end,
        u16 = function(self)
            local b1, b2 = self:byte(), self:byte();
            if (b1 == nil or b2 == nil) then return nil; end
            return b1 * 256 + b2;
        end,
        u32 = function(self)
            local b1, b2, b3, b4 = self:byte(), self:byte(), self:byte(), self:byte();
            if (b4 == nil) then return nil; end
            return ((b1 * 256 + b2) * 256 + b3) * 256 + b4;
        end,
        i32 = function(self)
            local n = self:u32();
            if (n == nil) then return nil; end
            if (n >= 0x80000000) then
                n = n - 0x100000000;
            end
            return n;
        end,
        f64 = function(self)
            local raw = self:bytes(8);
            if (raw == nil) then return nil; end
            local buf = ffi.new('double[1]');
            ffi.copy(buf, raw, 8);
            return buf[0];
        end,
    };
end

-- ---------------------------------------------------------------------------
-- Table pack / unpack
-- ---------------------------------------------------------------------------

local function CollectStringKeys(tbl, keySet)
    if (type(tbl) ~= 'table') then return; end
    for k, v in pairs(tbl) do
        if (type(k) == 'string') then
            keySet[k] = true;
        end
        if (type(v) == 'table') then
            CollectStringKeys(v, keySet);
        end
    end
end

local function BuildKeyDictionary(payload)
    local keySet = {};
    CollectStringKeys(payload, keySet);

    local keys = {};
    for k in pairs(keySet) do
        keys[#keys + 1] = k;
    end
    table.sort(keys);

    local dict = keys;
    local dictIndex = {};
    for i, k in ipairs(dict) do
        dictIndex[k] = i - 1;
    end
    return dict, dictIndex;
end

local function WriteKey(w, ctx, key)
    local kt = type(key);
    if (kt == 'string') then
        local dictIdx = ctx.dictIndex[key];
        if (dictIdx ~= nil and dictIdx <= 65535) then
            w:byte(TAG_KEY_DICT);
            w:u16(dictIdx);
            return true;
        end

        local klen = #key;
        if (klen <= 255) then
            w:byte(TAG_KEY_SHORT);
            w:byte(klen);
            w:bytes(key);
        else
            w:byte(TAG_KEY_LONG);
            w:u16(klen);
            w:bytes(key);
        end
        return true;
    elseif (kt == 'number') then
        w:byte(TAG_KEY_NUMBER);
        w:u32(key);
        return true;
    end
    return false, 'unsupported table key type';
end

local function WriteValue(w, ctx, value)
    local t = type(value);
    if (t == 'boolean') then
        w:byte(value and TAG_TRUE or TAG_FALSE);
    elseif (t == 'number') then
        if (math.floor(value) == value) then
            if (value >= 0 and value <= 255) then
                w:byte(TAG_U8);
                w:byte(value);
            elseif (value >= 0 and value <= 65535) then
                w:byte(TAG_U16);
                w:u16(value);
            elseif (value >= -2147483648 and value <= 2147483647) then
                w:byte(TAG_INT32);
                w:i32(value);
            else
                w:byte(TAG_DOUBLE);
                w:f64(value);
            end
        else
            w:byte(TAG_DOUBLE);
            w:f64(value);
        end
    elseif (t == 'string') then
        w:byte(TAG_STRING);
        w:u32(#value);
        w:bytes(value);
    elseif (t == 'table') then
        w:byte(TAG_TABLE);
        local keys = {};
        for k in pairs(value) do
            keys[#keys + 1] = k;
        end
        table.sort(keys, function(a, b)
            local ta, tb = type(a), type(b);
            if (ta == 'number' and tb == 'number') then return a < b; end
            return tostring(a) < tostring(b);
        end);
        w:u32(#keys);
        for i = 1, #keys do
            local k = keys[i];
            local ok, err = WriteKey(w, ctx, k);
            if (not ok) then return false, err; end
            ok, err = WriteValue(w, ctx, value[k]);
            if (not ok) then return false, err; end
        end
    else
        return false, 'unsupported value type: ' .. t;
    end
    return true;
end

local function ReadKey(r, ctx)
    local ktag = r:byte();
    if (ktag == TAG_KEY_DICT) then
        local idx = r:u16();
        if (idx == nil) then return nil, 'truncated dict key index'; end
        local key = ctx.dict[idx + 1];
        if (key == nil) then return nil, 'invalid dict key index'; end
        return key;
    elseif (ktag == TAG_KEY_SHORT) then
        local klen = r:byte();
        return r:bytes(klen);
    elseif (ktag == TAG_KEY_LONG) then
        local klen = r:u16();
        return r:bytes(klen);
    elseif (ktag == TAG_KEY_NUMBER) then
        return r:u32();
    end
    return nil, 'invalid table key tag';
end

local function ReadValue(r, ctx)
    local tag = r:byte();
    if (tag == TAG_FALSE) then return false;
    elseif (tag == TAG_TRUE) then return true;
    elseif (tag == TAG_U8) then return r:byte();
    elseif (tag == TAG_U16) then return r:u16();
    elseif (tag == TAG_INT32) then return r:i32();
    elseif (tag == TAG_DOUBLE) then return r:f64();
    elseif (tag == TAG_STRING) then
        local slen = r:u32();
        if (slen == nil) then return nil, 'truncated string'; end
        return r:bytes(slen);
    elseif (tag == TAG_TABLE) then
        local count = r:u32();
        if (count == nil) then return nil, 'truncated table'; end
        local t = {};
        for _ = 1, count do
            local key, kerr = ReadKey(r, ctx);
            if (key == nil) then return nil, kerr; end
            local val, err = ReadValue(r, ctx);
            if (val == nil and err) then return nil, err; end
            t[key] = val;
        end
        return t;
    end
    return nil, 'invalid value tag';
end

local function WriteDictionary(w, dict)
    w:u16(#dict);
    for _, key in ipairs(dict) do
        local klen = #key;
        if (klen <= 255) then
            w:byte(klen);
            w:bytes(key);
        else
            w:byte(0);
            w:u16(klen);
            w:bytes(key);
        end
    end
end

local function ReadDictionary(r)
    local count = r:u16();
    if (count == nil) then return nil, 'truncated key dictionary'; end
    local dict = {};
    for i = 1, count do
        local klen = r:byte();
        if (klen == nil) then return nil, 'truncated dictionary key'; end
        if (klen == 0) then
            klen = r:u16();
        end
        dict[i] = r:bytes(klen);
        if (dict[i] == nil) then return nil, 'truncated dictionary key bytes'; end
    end
    return dict;
end

function codec.PruneForExport(tbl)
    if (type(tbl) ~= 'table') then return tbl; end

    local pruned = {};
    for k, v in pairs(tbl) do
        if (type(v) == 'table') then
            local child = codec.PruneForExport(v);
            if (next(child) ~= nil) then
                pruned[k] = child;
            end
        elseif (type(v) == 'string') then
            if (v ~= '') then
                pruned[k] = v;
            end
        else
            pruned[k] = v;
        end
    end
    return pruned;
end

-- ---------------------------------------------------------------------------
-- Delta diff against defaults
-- ---------------------------------------------------------------------------

local NUMBER_EPSILON = 1e-9;

local function NumbersEqual(a, b)
    if (type(a) ~= 'number' or type(b) ~= 'number') then
        return a == b;
    end
    return math.abs(a - b) <= NUMBER_EPSILON;
end

-- Compare only keys present in `value`. Missing default keys are filled on import.
local function ValueEqualsDefault(value, defaultValue)
    if (value == defaultValue) then
        return true;
    end

    local valueType = type(value);
    local defaultType = type(defaultValue);

    if (valueType ~= defaultType) then
        return false;
    end

    if (valueType ~= 'table') then
        if (valueType == 'number') then
            return NumbersEqual(value, defaultValue);
        end
        return value == defaultValue;
    end

    if (defaultType ~= 'table') then
        return false;
    end

    for k, v in pairs(value) do
        if (not ValueEqualsDefault(v, defaultValue[k])) then
            return false;
        end
    end

    return true;
end

function codec.DiffTable(value, defaults)
    if (type(value) ~= 'table') then
        if (type(defaults) == 'table') then
            return value;
        end
        if (ValueEqualsDefault(value, defaults)) then
            return nil;
        end
        return value;
    end

    if (type(defaults) ~= 'table') then
        if (next(value) == nil) then
            return nil;
        end
        return value;
    end

    local diff = {};
    local hasContent = false;

    for k, v in pairs(value) do
        local dv = defaults[k];
        if (type(v) == 'table') then
            local child = codec.DiffTable(v, type(dv) == 'table' and dv or {});
            if (child ~= nil and next(child) ~= nil) then
                diff[k] = child;
                hasContent = true;
            end
        elseif (not ValueEqualsDefault(v, dv)) then
            diff[k] = v;
            hasContent = true;
        end
    end

    if (not hasContent) then return nil; end
    return diff;
end

function codec.ApplyDelta(defaults, patch)
    local result = deep_copy_table(defaults);
    if (type(patch) ~= 'table') then return result; end

    local function merge(target, source)
        for k, v in pairs(source) do
            if (type(v) == 'table' and type(target[k]) == 'table') then
                merge(target[k], v);
            else
                if (type(v) == 'table') then
                    target[k] = deep_copy_table(v);
                else
                    target[k] = v;
                end
            end
        end
    end

    merge(result, patch);
    return result;
end

function codec.PackPayload(payload, useDelta)
    local dict, dictIndex = BuildKeyDictionary(payload);
    local ctx = { dict = dict, dictIndex = dictIndex };

    local w = NewWriter();
    w:byte(BINARY_FORMAT_VERSION);
    local flags = 0;
    if (useDelta) then flags = bit.bor(flags, FLAG_DELTA); end
    w:byte(flags);
    WriteDictionary(w, dict);

    local ok, err = WriteValue(w, ctx, payload);
    if (not ok) then return nil, err; end
    return w:finish(), w:length();
end

function codec.UnpackPayload(data, dataLen)
    local r = NewReader(data, dataLen);
    local version = r:byte();
    if (version ~= BINARY_FORMAT_VERSION) then
        return nil, nil, 'unsupported binary format version';
    end
    local flags = r:byte();
    if (flags == nil) then
        return nil, nil, 'truncated binary header';
    end

    local dict, derr = ReadDictionary(r);
    if (not dict) then return nil, nil, derr; end

    local ctx = { dict = dict };
    local payload, err = ReadValue(r, ctx);
    if (payload == nil) then return nil, nil, err; end
    return payload, flags;
end

-- ---------------------------------------------------------------------------
-- Base64
-- ---------------------------------------------------------------------------

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

local function B64CharAt(n, shift)
    local idx = math.floor(n / shift) % 64 + 1;
    return b64chars:sub(idx, idx);
end

local function Base64Encode(data, dataLen)
    local out = {};
    local outLen = 0;
    local i = 1;
    dataLen = dataLen or #data;

    while i <= dataLen do
        local a = data:byte(i) or 0;
        local b = (i + 1 <= dataLen) and data:byte(i + 1) or 0;
        local c = (i + 2 <= dataLen) and data:byte(i + 2) or 0;
        local n = a * 65536 + b * 256 + c;

        outLen = outLen + 1;
        out[outLen] = B64CharAt(n, 262144);

        if (i + 1 > dataLen) then
            outLen = outLen + 1;
            out[outLen] = B64CharAt(n, 4096);
            outLen = outLen + 1;
            out[outLen] = '=';
            outLen = outLen + 1;
            out[outLen] = '=';
            break;
        end

        outLen = outLen + 1;
        out[outLen] = B64CharAt(n, 4096);

        if (i + 2 > dataLen) then
            outLen = outLen + 1;
            out[outLen] = B64CharAt(n, 64);
            outLen = outLen + 1;
            out[outLen] = '=';
            break;
        end

        outLen = outLen + 1;
        out[outLen] = B64CharAt(n, 64);
        outLen = outLen + 1;
        out[outLen] = B64CharAt(n, 1);
        i = i + 3;
    end

    return table.concat(out);
end

local b64lookup = {};
for i = 1, #b64chars do
    b64lookup[b64chars:byte(i)] = i - 1;
end
b64lookup[string.byte('=')] = -1;

local function Base64Decode(data)
    data = data:gsub('%s+', '');
    if (#data == 0) then return nil, 0, 'empty base64 data'; end
    if (#data % 4 ~= 0) then return nil, 0, 'invalid base64 length'; end

    local out = {};
    local outLen = 0;
    local i = 1;
    local b64Len = #data;

    while i <= b64Len do
        local c1 = b64lookup[data:byte(i)];
        local c2 = b64lookup[data:byte(i + 1)];
        local c3 = b64lookup[data:byte(i + 2)];
        local c4 = b64lookup[data:byte(i + 3)];

        if (c1 == nil or c1 < 0) then
            return nil, 0, 'invalid base64 character';
        end

        -- Ambiguous legacy tail (X=A=); Decode retries the last byte afterward.
        if (c2 ~= nil and c2 < 0 and c3 ~= nil and c3 >= 0 and c4 ~= nil and c4 < 0) then
            outLen = outLen + 1;
            out[outLen] = string.char(c1 * 4);
        elseif (c2 == nil or c2 < 0) then
            return nil, 0, 'invalid base64 character';
        else
            local n = c1 * 262144 + c2 * 4096;
            if (c3 ~= nil and c3 >= 0) then
                n = n + c3 * 64;
                if (c4 ~= nil and c4 >= 0) then
                    n = n + c4;
                    outLen = outLen + 1;
                    out[outLen] = string.char(math.floor(n / 65536) % 256);
                    outLen = outLen + 1;
                    out[outLen] = string.char(math.floor(n / 256) % 256);
                    outLen = outLen + 1;
                    out[outLen] = string.char(n % 256);
                else
                    outLen = outLen + 1;
                    out[outLen] = string.char(math.floor(n / 65536) % 256);
                    outLen = outLen + 1;
                    out[outLen] = string.char(math.floor(n / 256) % 256);
                end
            else
                outLen = outLen + 1;
                out[outLen] = string.char(math.floor(n / 65536) % 256);
            end
        end
        i = i + 4;
    end

    return table.concat(out), outLen;
end

-- ---------------------------------------------------------------------------
-- Compression (bundled zstd + zlib fallback)
-- ---------------------------------------------------------------------------

local COMPRESS_RAW = 0;
local COMPRESS_ZLIB = 1;
local COMPRESS_ZSTD = 2;
local ZSTD_LEVEL = 22;
local MAX_DECOMPRESS_SIZE = 16 * 1024 * 1024;

local zstdLib = nil;
local zstdInitialized = false;
local zlibLib = nil;
local zlibInitialized = false;
local zlibHasCompress2 = false;

local function GetBundledLibraryPaths(filename)
    local paths = {};
    if (addon and addon.path) then
        local base = addon.path:gsub('\\\\', '\\');
        table.insert(paths, base .. 'libs\\' .. filename);
    end
    if (AshitaCore and AshitaCore.GetInstallPath) then
        local install = AshitaCore:GetInstallPath();
        table.insert(paths, install .. 'addons\\XIUI\\libs\\' .. filename);
    end
    return paths;
end

local function TryLoadZstd()
    if (zstdLib ~= nil) then
        return zstdLib ~= false;
    end

    local paths = {};
    for _, bundled in ipairs(GetBundledLibraryPaths('libzstd.dll')) do
        table.insert(paths, bundled);
    end
    table.insert(paths, 'libzstd');

    for _, path in ipairs(paths) do
        local ok, lib = pcall(ffi.load, path);
        if (ok and lib) then
            zstdLib = lib;
            return true;
        end
    end

    zstdLib = false;
    return false;
end

local function InitZstd()
    if (zstdInitialized) then
        return zstdLib ~= false;
    end
    zstdInitialized = true;

    if (not TryLoadZstd()) then
        return false;
    end

    ffi.cdef[[
        typedef size_t zstd_size_t;
        typedef unsigned long long zstd_ull;
        zstd_size_t ZSTD_compressBound(zstd_size_t srcSize);
        zstd_size_t ZSTD_compress(void* dst, zstd_size_t dstCapacity, const void* src, zstd_size_t srcSize, int compressionLevel);
        zstd_size_t ZSTD_decompress(void* dst, zstd_size_t dstCapacity, const void* src, zstd_size_t compressedSize);
        zstd_ull ZSTD_getFrameContentSize(const void* src, zstd_size_t srcSize);
        unsigned ZSTD_isError(zstd_size_t code);
        const char* ZSTD_getErrorName(zstd_size_t code);
    ]];

    return zstdLib.ZSTD_compress ~= nil and zstdLib.ZSTD_decompress ~= nil;
end

local function ZstdCompress(data, sourceLen)
    if (not InitZstd()) then
        return nil, 0;
    end

    sourceLen = sourceLen or #data;
    if (sourceLen == 0) then
        return nil, 0;
    end

    local bound = tonumber(zstdLib.ZSTD_compressBound(sourceLen));
    if (not bound or bound <= 0) then
        return nil, 0;
    end

    local src = ffi.new('char[?]', sourceLen);
    ffi.copy(src, data, sourceLen);

    local dest = ffi.new('char[?]', bound);
    local result = zstdLib.ZSTD_compress(dest, bound, src, sourceLen, ZSTD_LEVEL);
    if (zstdLib.ZSTD_isError(result) ~= 0) then
        return nil, 0;
    end

    local outLen = tonumber(result);
    return ffi.string(dest, outLen), outLen;
end

local function ZstdDecompress(data, compLen)
    if (not InitZstd()) then
        return nil, 0, 'zstd not available';
    end

    compLen = compLen or #data;
    if (compLen == 0) then
        return nil, 0, 'empty zstd payload';
    end

    local src = ffi.new('char[?]', compLen);
    ffi.copy(src, data, compLen);

    local destCapacity = MAX_DECOMPRESS_SIZE;
    local contentSize = zstdLib.ZSTD_getFrameContentSize(src, compLen);
    if (zstdLib.ZSTD_isError(contentSize) == 0) then
        local decodedSize = tonumber(contentSize);
        -- Reject unknown/error sentinel values; use frame size when valid
        if (decodedSize ~= nil and decodedSize > 0 and decodedSize < MAX_DECOMPRESS_SIZE) then
            destCapacity = decodedSize;
        end
    end

    local dest = ffi.new('char[?]', destCapacity);
    local result = zstdLib.ZSTD_decompress(dest, destCapacity, src, compLen);
    if (zstdLib.ZSTD_isError(result) ~= 0) then
        local errName = 'unknown';
        if (zstdLib.ZSTD_getErrorName ~= nil) then
            errName = ffi.string(zstdLib.ZSTD_getErrorName(result));
        end
        return nil, 0, 'zstd decompress failed: ' .. errName;
    end

    local outLen = tonumber(result);
    return ffi.string(dest, outLen), outLen;
end

local function TryLoadZlib()
    if (zlibLib ~= nil) then
        return zlibLib ~= false;
    end

    local paths = { 'zlib1', 'zlib' };
    if (AshitaCore and AshitaCore.GetInstallPath) then
        local base = AshitaCore:GetInstallPath();
        table.insert(paths, 1, base .. 'plugins\\zlib1.dll');
        table.insert(paths, 2, base .. 'plugins\\zlib.dll');
    end

    for _, name in ipairs(paths) do
        local ok, lib = pcall(ffi.load, name);
        if (ok and lib) then
            zlibLib = lib;
            return true;
        end
    end

    zlibLib = false;
    return false;
end

local function InitZlib()
    if (zlibInitialized) then
        return zlibLib ~= false;
    end
    zlibInitialized = true;

    if (not TryLoadZlib()) then
        return false;
    end

    ffi.cdef[[
        typedef unsigned long zlib_uLong;
        typedef unsigned char zlib_Byte;
        int compress(zlib_Byte *dest, zlib_uLong *destLen, const zlib_Byte *source, zlib_uLong sourceLen);
        int compress2(zlib_Byte *dest, zlib_uLong *destLen, const zlib_Byte *source, zlib_uLong sourceLen, int level);
        int uncompress(zlib_Byte *dest, zlib_uLong *destLen, const zlib_Byte *source, zlib_uLong sourceLen);
    ]];

    zlibHasCompress2 = zlibLib.compress2 ~= nil;
    return zlibLib.compress ~= nil and zlibLib.uncompress ~= nil;
end

local function ZlibCompressBound(sourceLen)
    return sourceLen + math.floor(sourceLen / 4096) + 16;
end

local function ZlibCompress(data, sourceLen)
    if (not InitZlib()) then
        return nil, 0;
    end

    sourceLen = sourceLen or #data;
    local destLen = ZlibCompressBound(sourceLen);
    local dest = ffi.new('zlib_Byte[?]', destLen);
    local destLenRef = ffi.new('zlib_uLong[1]', destLen);

    local candidates = {};

    local r1 = zlibLib.compress(dest, destLenRef, data, sourceLen);
    if (r1 == 0) then
        local outLen = tonumber(destLenRef[0]);
        candidates[#candidates + 1] = { ffi.string(dest, outLen), outLen };
    end

    if (zlibHasCompress2) then
        destLenRef[0] = destLen;
        local r2 = zlibLib.compress2(dest, destLenRef, data, sourceLen, 9);
        if (r2 == 0) then
            local outLen = tonumber(destLenRef[0]);
            candidates[#candidates + 1] = { ffi.string(dest, outLen), outLen };
        end
    end

    if (#candidates == 0) then
        return nil, 0;
    end

    local best = candidates[1][1];
    local bestLen = candidates[1][2];
    for i = 2, #candidates do
        if (candidates[i][2] < bestLen) then
            best = candidates[i][1];
            bestLen = candidates[i][2];
        end
    end
    return best, bestLen;
end

local function ZlibDecompress(data, compLen)
    if (not InitZlib()) then
        return nil, 0, 'zlib not available';
    end

    compLen = compLen or #data;
    local dest = ffi.new('zlib_Byte[?]', MAX_DECOMPRESS_SIZE);
    local destLenRef = ffi.new('zlib_uLong[1]', MAX_DECOMPRESS_SIZE);

    local result = zlibLib.uncompress(dest, destLenRef, data, compLen);
    if (result ~= 0) then
        return nil, 0, 'zlib decompress failed';
    end

    local outLen = tonumber(destLenRef[0]);
    return ffi.string(dest, outLen), outLen;
end

-- ---------------------------------------------------------------------------
-- Share-code envelope: [method byte][payload] -> base64
-- ---------------------------------------------------------------------------

local function CompressBest(data, dataLen)
    dataLen = dataLen or #data;
    local bestMethod = COMPRESS_RAW;
    local bestPayload = data;
    local bestLen = dataLen;

    local zstdPayload, zstdLen = ZstdCompress(data, dataLen);
    if (zstdPayload and zstdLen < bestLen) then
        bestMethod = COMPRESS_ZSTD;
        bestPayload = zstdPayload;
        bestLen = zstdLen;
    end

    local zlibPayload, zlibLen = ZlibCompress(data, dataLen);
    if (zlibPayload and zlibLen < bestLen) then
        bestMethod = COMPRESS_ZLIB;
        bestPayload = zlibPayload;
        bestLen = zlibLen;
    end

    return bestMethod, bestPayload, bestLen;
end

local function DecompressEnvelope(binary, binaryLen)
    binaryLen = binaryLen or #binary;
    if (binary == nil or binaryLen == 0) then
        return nil, 0, 'empty compressed payload';
    end

    local method = binary:byte(1);
    local payloadLen = binaryLen - 1;

    if (payloadLen <= 0) then
        return nil, 0, 'empty compressed payload';
    end

    local payload = binary:sub(2, binaryLen);

    if (method == COMPRESS_ZSTD) then
        return ZstdDecompress(payload, payloadLen);
    end

    if (method == COMPRESS_ZLIB) then
        return ZlibDecompress(payload, payloadLen);
    end

    if (method == COMPRESS_RAW) then
        return payload, payloadLen;
    end

    return nil, 0, 'unknown compression method';
end

function codec.EncodeBinary(binaryData, binaryLen)
    binaryLen = binaryLen or #binaryData;
    local method, payload, payloadLen = CompressBest(binaryData, binaryLen);
    return Base64Encode(string.char(method) .. payload, 1 + payloadLen);
end

function codec.NormalizeShareCode(shareCode)
    if (type(shareCode) ~= 'string') then
        return nil;
    end
    -- Strip whitespace and any non-base64 characters from paste
    return shareCode:gsub('%s+', ''):gsub('[^%w%+/=]', '');
end

-- ---------------------------------------------------------------------------
-- Legacy share-code repair (early export padding bugs)
-- ---------------------------------------------------------------------------

local function HasAmbiguousLegacyTail(shareCode)
    return #shareCode >= 4
        and shareCode:byte(-3) == string.byte('=')
        and shareCode:byte(-1) == string.byte('=')
        and shareCode:byte(-2) ~= string.byte('=');
end

local function FixTruncatedBase64Tail(shareCode)
    if (#shareCode % 4 ~= 3 or shareCode:sub(-2) ~= '==') then
        return shareCode;
    end

    local c1 = shareCode:sub(-3, -3);
    if (c1 == '=') then
        return shareCode;
    end

    local prefix = shareCode:sub(1, #shareCode - 3);
    for i = 1, #b64chars do
        local candidate = prefix .. c1 .. b64chars:sub(i, i) .. '==';
        local binary, binLen = Base64Decode(candidate);
        if (binary and select(1, DecompressEnvelope(binary, binLen))) then
            return candidate;
        end
    end

    return shareCode;
end

local function RetryDecompressAmbiguousTail(shareCode, binary, binLen, err)
    if (not HasAmbiguousLegacyTail(shareCode) or binLen < 2 or binary:byte(1) ~= COMPRESS_ZSTD) then
        return nil, 0, err;
    end

    local c1 = b64lookup[shareCode:byte(-4)];
    if (c1 == nil or c1 < 0) then
        return nil, 0, err;
    end

    local prefix = binary:sub(1, binLen - 1);
    for k = 0, 3 do
        local decompressed, decompLen = DecompressEnvelope(prefix .. string.char(c1 * 4 + k), binLen);
        if (decompressed) then
            return decompressed, decompLen;
        end
    end

    return nil, 0, err;
end

local function DecompressShareBinary(binary, binLen, shareCode)
    local decompressed, decompLen, err = DecompressEnvelope(binary, binLen);
    if (decompressed) then
        return decompressed, decompLen;
    end
    return RetryDecompressAmbiguousTail(shareCode, binary, binLen, err);
end

function codec.Decode(shareCode)
    shareCode = codec.NormalizeShareCode(shareCode);
    if (not shareCode or shareCode == '') then
        return nil, 0, 'invalid share code';
    end

    shareCode = FixTruncatedBase64Tail(shareCode);

    local binary, binLen, b64Err = Base64Decode(shareCode);
    if (not binary) then
        return nil, 0, b64Err or 'base64 decode failed';
    end

    local decompressed, decompLen, err = DecompressShareBinary(binary, binLen, shareCode);
    if (not decompressed) then
        return nil, 0, err or 'decompress failed';
    end

    return decompressed, decompLen;
end

function codec.FormatForDisplay(shareCode, lineLen)
    lineLen = lineLen or 76;
    if (#shareCode <= lineLen) then
        return shareCode;
    end
    local parts = {};
    local i = 1;
    while i <= #shareCode do
        parts[#parts + 1] = shareCode:sub(i, i + lineLen - 1);
        i = i + lineLen;
    end
    return table.concat(parts, '\n');
end

return codec;
