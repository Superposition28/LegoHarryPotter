-- Scoped to the supplied Collection launcher and Experience Disc 5.5 image.
---@type TtArchiveResearch
local Research = import("../../../operations/TtArchiveResearch.lua")
local UInt = Research.UInt
local Output = Game_Root .. "/GameFiles/container-research"
local DoExtract = argv[1] == "--extract"
assert(#argv == 0 or (#argv == 1 and DoExtract), "usage: [--extract]")
sdk.ensure_dir(Output)

-- Sample opaque shader-cache carriers without assigning an unverified schema.
local LooseRows = {"Path\tBytes\tHeadHex\tDXBCInFirst64KiB"}
for _, Relative in ipairs({"Source/Collection/Years 1-4/shaderblob_pc.blob", "Source/Collection/Years 5-7/harry2_shaderblob_pc.blob"}) do
    local Reader = assert(io.open(Game_Root .. "/" .. Relative, "rb"))
    local Size = Reader.seek("end", 0)
    Reader.seek("set", 0)
    local Bytes = Reader.read(math.min(65536, Size)) or ""
    Reader.close()
    local Hex = ""
    for Position = 1, math.min(32, #Bytes) do Hex = Hex .. string.format("%02X", UInt(Bytes, Position, 1)) end
    LooseRows[#LooseRows + 1] = Relative .. "\t" .. string.format("%.0f", Size) .. "\t" .. Hex .. "\t" .. tostring(Bytes:find("DXBC", 1, true) ~= nil)
end
sdk.write_file(Output .. "/loose-shaders.tsv", table.concat(LooseRows, "\n") .. "\n")

---@param Handle FileHandle
---@param Offset integer
---@param Size integer
---@return string Bytes
local function ReadAt(Handle, Offset, Size)
    assert(Handle.seek("set", Offset) == Offset, "container seek failed at " .. Offset)
    local Bytes = Handle.read(Size) or ""
    assert(#Bytes == Size, "truncated container read at " .. Offset)
    return Bytes
end

---@param Bytes string
---@param Position integer
---@param Width integer
---@return integer Value
local function BigEndian(Bytes, Position, Width)
    return UInt(Bytes:sub(Position, Position + Width - 1):reverse(), 1, Width)
end

local IndexPath = Game_Root .. "/Source/Collection/Main/launcher.pkiwin"
local Handle = assert(io.open(IndexPath, "rb"))
local IndexSize = Handle.seek("end", 0)
local Index = ReadAt(Handle, 0, IndexSize)
Handle.close()
assert(UInt(Index, 1, 4) == 3 and UInt(Index, 5, 4) == 0, IndexPath .. ": unsupported header")
local Count = UInt(Index, 9, 4)
assert(IndexSize == 12 + Count * 16 + 4 and UInt(Index, 13 + Count * 16, 4) == 0, IndexPath .. ": invalid index length/trailer")
local DataPath = Game_Root .. "/Source/Collection/Main/launcher.pkdwin"
Handle = assert(io.open(DataPath, "rb"))
local DataSize = Handle.seek("end", 0)
assert(ReadAt(Handle, 0, 12) == Index:sub(1, 12), "launcher index/data header mismatch")
---@type TtArchive
local Launcher = {Path = DataPath, Kind = "launcher-pair", Size = DataSize,
    TocOffset = 0, TocSize = IndexSize, Version = 3, Entries = {}}
local Rows = {"Index\tHashOrId\tOffset\tStoredBytes\tUnpackedBytes\tCompression"}
local PreviousEnd = 12
for Entry = 0, Count - 1 do
    local Position = 13 + Entry * 16
    local Size, Stored, Offset, Hash = UInt(Index, Position, 4), UInt(Index, Position + 4, 4), UInt(Index, Position + 8, 4), UInt(Index, Position + 12, 4)
    assert(Offset >= 12 and Offset <= DataSize and Stored <= DataSize - Offset, "launcher entry bounds at index offset " .. (Position - 1))
    if Offset ~= PreviousEnd then print("Launcher noncontiguous span", Entry, "offset", Offset, "previous end", PreviousEnd) end
    local Head = ReadAt(Handle, Offset, 2)
    assert(UInt(Head, 1, 1) == 0x78 and (UInt(Head, 1, 1) * 256 + UInt(Head, 2, 1)) % 31 == 0, "launcher zlib header at " .. Offset)
    Launcher.Entries[#Launcher.Entries + 1] = {Index = Entry, Hash = Hash, Offset = Offset, StoredSize = Stored, Size = Size, Compression = 3, Resolution = "unknown-id"}
    Rows[#Rows + 1] = string.format("%d\t%08X\t%d\t%d\t%d\tzlib", Entry, Hash, Offset, Stored, Size)
    PreviousEnd = Offset + Stored
end
assert(PreviousEnd == DataSize, "launcher final entry does not end at EOF")
Handle.close()
sdk.write_file(Output .. "/launcher.tsv", table.concat(Rows, "\n") .. "\n")
print("Launcher: " .. Count .. " bounded zlib streams; final span ends at EOF")
if DoExtract then print("Launcher extracted", Research.Extract(Launcher, Output .. "/launcher-assets", 0)) end

local IsoPath = Game_Root .. "/Source/Orginals/The Experience Disc Version 5.5 (Xbox 360)/The.Experience.Disc.Version.5.5.iso"
Handle = assert(io.open(IsoPath, "rb"))
local IsoSize = Handle.seek("end", 0)
assert(IsoSize == 7838695424, "this probe is scoped to the supplied Experience 5.5 ISO")
assert(ReadAt(Handle, 0x0FDA0000, 20) == "MICROSOFT*XBOX*MEDIA", "XDVDFS signature mismatch")
local PackageOffset, PackageSize = 0x3EBAD000, 697393152
local Header = ReadAt(Handle, PackageOffset, 0x600)
assert(Header:sub(1, 4) == "PIRS" and BigEndian(Header, 0x361, 4) == 0x575287FF
    and BigEndian(Header, 0x345, 4) == 0x00080000, "PIRS demo identity mismatch")

---@param Block integer Logical STFS block in this supplied read-only package.
---@return integer Offset Absolute ISO byte offset.
local function BlockOffset(Block)
    local Physical = Block + math.floor(Block / 170) + math.floor(Block / 28900)
    if Block >= 170 then Physical = Physical + 1 end
    if Block >= 28900 then Physical = Physical + 1 end
    local Offset = PackageOffset + 0xC000 + Physical * 4096
    assert(Offset >= PackageOffset and Offset + 4096 <= PackageOffset + PackageSize, "STFS block outside package: " .. Block)
    return Offset
end

local FileTable = ReadAt(Handle, PackageOffset + 0xC000, 4096)
Rows = {"Entry\tName\tFlags\tLogicalStartBlock\tBytes\tFirstIsoOffset"}
for Entry = 0, 63 do
    local Position = Entry * 64 + 1
    if UInt(FileTable, Position, 1) == 0 then break end
    local Flags = UInt(FileTable, Position + 0x28, 1)
    local Name = FileTable:sub(Position, Position + Flags % 64 - 1)
    local Start = UInt(FileTable, Position + 0x2F, 3)
    local Size = BigEndian(FileTable, Position + 0x34, 4)
    Rows[#Rows + 1] = string.format("%d\t%s\t%d\t%d\t%d\t%d", Entry, Name, Flags, Start, Size, BlockOffset(Start))
    print("STFS", Entry, Name, "flags", Flags, "start", Start, "size", Size)
    if Name:match("^GAME%d*%.DAT$") and DoExtract then
        assert(Flags >= 64 and Flags < 128, "only consecutive regular STFS files supported")
        assert(UInt(FileTable, Position + 0x29, 3) == math.ceil(Size / 4096), "STFS allocation length mismatch: " .. Name)
        sdk.ensure_dir(Output .. "/demo-archives")
        local Destination = Output .. "/demo-archives/" .. Name
        assert(not sdk.path_exists(Destination), "output already exists: " .. Destination)
        local Writer = assert(io.open(Destination, "wb"))
        local Remaining, Block, Pieces = Size, Start, {}
        while Remaining > 0 do
            local Length = math.min(Remaining, 4096)
            Pieces[#Pieces + 1] = ReadAt(Handle, BlockOffset(Block), Length)
            if #Pieces == 256 or Remaining == Length then
                Writer.write(table.concat(Pieces))
                Pieces = {}
            end
            Remaining, Block = Remaining - Length, Block + 1
        end
        Writer.close()
        local Archive = Research.Read(Destination)
        print("Demo PakDat verified", Name, #Archive.Entries)
    end
end
Handle.close()
sdk.write_file(Output .. "/demo-container.tsv", table.concat(Rows, "\n") .. "\n")
