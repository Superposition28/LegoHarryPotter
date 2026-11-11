---@type TtArchiveResearch
local Research = import("../../../operations/TtArchiveResearch.lua")
local Directory = Game_Root .. "/GameFiles/parser-checks"
sdk.ensure_dir(Directory)

---@param Value integer
---@param Width integer
---@return string Bytes
local function Pack(Value, Width)
    local Pieces = {}
    for Index = 1, Width do
        Pieces[Index] = string.char(Value % 256)
        Value = math.floor(Value / 256)
    end
    return table.concat(Pieces)
end

---@param Bytes string
---@param Offset integer Zero based.
---@param Value string
---@return string Patched
local function Patch(Bytes, Offset, Value)
    return Bytes:sub(1, Offset) .. Value .. Bytes:sub(Offset + #Value + 1)
end

local Hash = Research.Hash("stuff\\icons\\paramedic_nxg.tex")
assert(Hash == 0x00022654, "real Batman stored hash control failed")
assert(Research.Hash("STUFF/icons/PARAMEDIC_NXG.TEX") == Hash, "hash normalization failed")
assert(Research.UInt(Pack(0xFFFFFFFF, 4), 1, 4) == 4294967295, "Latin1 integer decoding failed")
local Toc = Pack(0xFFFFFFFF, 4) .. Pack(1, 4) .. Pack(16, 8) .. Pack(0x12345678, 4)
    .. Pack(1, 4) .. Pack(1, 4) .. Pack(0, 4) .. Pack(0x1234, 4)
local Valid = Pack(17, 8) .. Pack(#Toc, 8) .. "X" .. Toc

---@param Name string
---@param Bytes string
---@param Expected boolean
---@param Extension string|nil
---@return nil
local function Check(Name, Bytes, Expected, Extension)
    local Path = Directory .. "/" .. Name .. "." .. (Extension or "datwin")
    local Handle = assert(io.open(Path, "wb"))
    Handle.write(Bytes)
    Handle.close()
    local Ok, Result = pcall(Research.Read, Path)
    assert(Ok == Expected, Name .. ": unexpected parser result " .. tostring(Result))
    if Ok then
        assert(#Result.Entries == 1 and Result.Entries[1].Offset == (Extension == "dat" and 57 or 16) and Result.Entries[1].Size == 1)
    else
        assert(tostring(Result):find(Path, 1, true), Name .. ": missing input-path diagnostic")
    end
    print("PASS", Name)
end

Check("valid-raw", Valid, true)
Check("bad-canary", Patch(Valid, 33, Pack(0, 4)), false)
Check("unsupported-version", Patch(Valid, 17, Pack(0xFFFFFFFE, 4)), false)
Check("excessive-count", Patch(Valid, 21, Pack(0xFFFFFFFF, 4)), false)
Check("payload-overrun", Patch(Valid, 37, Pack(100, 4)), false)
Check("payload-in-header", Patch(Valid, 25, Pack(0, 8)), false)
Check("raw-size-mismatch", Patch(Valid, 41, Pack(2, 4)), false)
Check("inconsistent-flags", Patch(Valid, 45, Pack(4, 4)), false)
Check("nonexact-offset", Patch(Valid, 0, Pack(9007199254740992, 8)), false)
for _, Length in ipairs({0, 1, 8, 15, 16, 17, 20, #Valid - 1}) do
    Check("truncated-" .. Length, Valid:sub(1, Length), false)
end
local Signature = "BEGIN_APP_ID_STRINGPakDat v1.01END_APP_ID_STRING\0"
assert(#Signature == 49)
local PakToc = Pack(0xFFFFFFFC, 4) .. Pack(1, 4)
    .. Pack(0, 4) .. Pack(1, 4) .. Pack(1, 4) .. string.char(0, 0, 0, 57)
    .. Pack(2, 4) .. Pack(1, 2) .. Pack(0, 2) .. Pack(0, 4)
    .. Pack(0, 2) .. Pack(0, 2) .. Pack(0, 4)
    .. Pack(4, 4) .. "x\0\0\0" .. Pack(Research.Hash("x"), 4) .. Pack(0, 8)
local Pak = Pack(58, 4) .. Pack(#PakToc, 4) .. Signature .. "X" .. PakToc
Check("valid-pakdat", Pak, true, "dat")
Check("pakdat-bad-signature", Patch(Pak, 8, "X"), false, "dat")
Check("pakdat-forward-sibling", Patch(Pak, 58 + 28 + 8 + 2, Pack(1, 2)), false, "dat")
Check("pakdat-name-out-of-range", Patch(Pak, 58 + 28 + 8 + 4, Pack(100, 4)), false, "dat")
Check("pakdat-bad-hash", Patch(Pak, 58 + 52, Pack(0, 4)), false, "dat")
Check("pakdat-unterminated-name", Patch(Pak, 58 + 48, "xxxx"), false, "dat")
Check("pakdat-leaf-out-of-range", Patch(Pak, 58 + 28 + 8, Pack(65535, 2)), false, "dat")
print("Parser validation: 24 cases plus hash/Latin1 controls passed")
