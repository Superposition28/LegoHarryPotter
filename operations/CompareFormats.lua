-- Cross-title research consumes Batman's exported inventory; Batman extraction
-- itself stays in the Batman module and its own engine context.
---@type TtArchiveResearch
local Research = import("../../../operations/TtArchiveResearch.lua")
---@class TtComparisonGroup
---@field Name string
---@field Entries integer
---@field Extensions table<string, integer>
---@field Names table<string, boolean>
---@field Samples table<string, TtEntry>
---@field Sources table<string, string>
---@type table<string, TtComparisonGroup>
local Groups = {}
---@type table<string, boolean>
local SeenArchives = {}
local Output = Game_Root .. "/GameFiles/format-comparison"
sdk.ensure_dir(Output)

---@param Line string
---@return string[] Fields
local function Fields(Line)
    local Values = {}
    local Position = 1
    while true do
        local Next = Line:find("\t", Position, true)
        if not Next then Values[#Values + 1] = Line:sub(Position); break end
        Values[#Values + 1], Position = Line:sub(Position, Next - 1), Next + 1
    end
    return Values
end

---@param Path string
---@return string Name
local function GroupName(Path)
    if Path:find("container-research", 1, true) then return "hp1-demo-360" end
    if Path:find("WinSteam", 1, true) then return "batman2-win" end
    local Game = Path:find("Years 5-7", 1, true) and "hp2" or "hp1"
    local Platform = Path:find("Collection", 1, true) and "collection" or (Path:find("PS3", 1, true) and "ps3" or "360")
    return Game .. "-" .. Platform
end

---@param Archive TtArchive
---@return nil
local function AddArchive(Archive)
    if SeenArchives[Archive.Path] then return end
    SeenArchives[Archive.Path] = true
    -- v01.02 was inspected as an additional control, but is outside the requested
    -- comparison set; do not double count it alongside the supplied v03.01.
    if Archive.Path:find("v01.02", 1, true) then return end
    local Name = GroupName(Archive.Path)
    ---@type TtComparisonGroup
    local Group = Groups[Name] or {Name = Name, Entries = 0, Extensions = {}, Names = {}, Samples = {}, Sources = {}}
    Groups[Name] = Group
    for _, Entry in ipairs(Archive.Entries) do
        Group.Entries = Group.Entries + 1
        if Entry.Name then
            local Normal = Entry.Name:lower():gsub("\\", "/")
            Group.Names[Normal] = true
            local Extension = Normal:match("%.([^./]+)$") or "[no-extension]"
            Group.Extensions[Extension] = (Group.Extensions[Extension] or 0) + 1
            local Previous = Group.Samples[Extension]
            if Entry.Size > 0 and Entry.Size <= 8388608 and (not Previous or Entry.Size < Previous.Size) then
                Group.Samples[Extension], Group.Sources[Extension] = Entry, Archive.Path
            end
        end
    end
end

---@param Module string
---@return nil
local function LoadInventory(Module)
    local Root = Module .. "/GameFiles/cross-reference"
    local Summary = assert(sdk.read_file(Root .. "/archives.tsv"), "run inventory first: " .. Module)
    for Line in Summary:gmatch("[^\r\n]+") do
        local Meta = Fields(Line)
        if Meta[1] ~= "Archive" then
            local Relative = Meta[1]
            local Key = Relative:gsub("[\\/]", "__"):gsub("[^%w%._%-]", "_")
            ---@type TtArchive
            local Archive = {Path = Module .. "/" .. Relative, Kind = "inventory", Size = tonumber(Meta[2]), TocOffset = tonumber(Meta[3]), TocSize = tonumber(Meta[4]), Version = tonumber(Meta[5]), Entries = {}}
            local Content = assert(sdk.read_file(Root .. "/" .. Key .. ".tsv"))
            for Row in Content:gmatch("[^\r\n]+") do
                local Values = Fields(Row)
                if Values[1] ~= "Index" then
                    Archive.Entries[#Archive.Entries + 1] = {Index = tonumber(Values[1]), Hash = tonumber(Values[2], 16), Offset = tonumber(Values[3]), StoredSize = tonumber(Values[4]), Size = tonumber(Values[5]), Compression = tonumber(Values[6]), Resolution = Values[7], Name = Values[8] ~= "" and Values[8] or nil}
                end
            end
            AddArchive(Archive)
        end
    end
end

LoadInventory(Game_Root)
LoadInventory(Game_Root .. "/../Lego_Batman")
local DemoFiles = {}
Research.Walk(Game_Root .. "/GameFiles/container-research/demo-archives", DemoFiles)
for _, Path in ipairs(DemoFiles) do AddArchive(Research.Read(Path)) end

local Names, Extensions = {}, {}
for Name, Group in pairs(Groups) do
    Names[#Names + 1] = Name
    for Extension in pairs(Group.Extensions) do Extensions[Extension] = true end
end
table.sort(Names)
local OrderedExtensions = {}
for Extension in pairs(Extensions) do OrderedExtensions[#OrderedExtensions + 1] = Extension end
table.sort(OrderedExtensions)
local Rows = {"Extension\t" .. table.concat(Names, "\t")}
local Common = {}
for _, Extension in ipairs(OrderedExtensions) do
    local Values, Present = {Extension}, 0
    for _, Name in ipairs(Names) do
        local Count = Groups[Name].Extensions[Extension] or 0
        Values[#Values + 1] = tostring(Count)
        if Count > 0 then Present = Present + 1 end
    end
    Rows[#Rows + 1] = table.concat(Values, "\t")
    if Present == #Names then Common[#Common + 1] = Extension end
end
sdk.write_file(Output .. "/extensions.tsv", table.concat(Rows, "\n") .. "\n")
print("Common named extensions in all " .. #Names .. " datasets: " .. table.concat(Common, ", "))

Rows = {"Left\tRight\tIdenticalNamedPaths"}
for Left = 1, #Names do
    print("Dataset", Names[Left], Groups[Names[Left]].Entries)
    for Right = Left + 1, #Names do
        local Count = 0
        for Name in pairs(Groups[Names[Left]].Names) do
            if Groups[Names[Right]].Names[Name] then Count = Count + 1 end
        end
        Rows[#Rows + 1] = Names[Left] .. "\t" .. Names[Right] .. "\t" .. Count
    end
end
sdk.write_file(Output .. "/path-overlap.tsv", table.concat(Rows, "\n") .. "\n")

Rows = {"Dataset\tExtension\tSourceArchive\tIndex\tHash\tPath\tSize\tDecodedHeadHex\tDecodedHeadText\tSha1"}
---@type table<string, string[]>
local SampleHashes = {}
for _, Name in ipairs(Names) do
    local Group = Groups[Name]
    for _, Extension in ipairs(OrderedExtensions) do
        local Entry = Group.Samples[Extension]
        if Entry then
            local Directory = Output .. "/samples/" .. Name .. "/" .. Extension
            ---@type TtArchive
            local Archive = {Path = Group.Sources[Extension], Kind = "sample", Size = 0, TocOffset = 0, TocSize = 0, Version = 0, Entries = {Entry}}
            if not sdk.path_exists(Directory) then Research.Extract(Archive, Directory, 0) end
            local SamplePath = Directory .. "/" .. Entry.Name:gsub("\\", "/")
            local Handle = assert(io.open(SamplePath, "rb"))
            assert(Handle.seek("end", 0) == Entry.Size, "existing sample size mismatch: " .. SamplePath)
            Handle.seek("set", 0)
            local Head = Handle.read(math.min(32, Entry.Size)) or ""
            Handle.close()
            local Hex, Text = "", ""
            for Index = 1, #Head do
                local Value = Research.UInt(Head, Index, 1)
                Hex = Hex .. string.format("%02X", Value)
                Text = Text .. (Value >= 32 and Value <= 126 and Head:sub(Index, Index) or ".")
            end
            local Digest = assert(sdk.sha1_file(SamplePath))
            SampleHashes[Digest] = SampleHashes[Digest] or {}
            SampleHashes[Digest][#SampleHashes[Digest] + 1] = Name .. ":" .. Extension
            Rows[#Rows + 1] = string.format("%s\t%s\t%s\t%d\t%08X\t%s\t%d\t%s\t%s\t%s", Name, Extension, Archive.Path, Entry.Index, Entry.Hash, Entry.Name, Entry.Size, Hex, Text, Digest)
        end
    end
end
sdk.write_file(Output .. "/sample-signatures.tsv", table.concat(Rows, "\n") .. "\n")
Rows = {}
for Digest, Samples in pairs(SampleHashes) do
    if #Samples > 1 then Rows[#Rows + 1] = Digest .. "\t" .. table.concat(Samples, ",") end
end
table.sort(Rows)
table.insert(Rows, 1, "Sha1\tEqualSamples")
sdk.write_file(Output .. "/equal-samples.tsv", table.concat(Rows, "\n") .. "\n")
print("Comparison written to " .. Output)
