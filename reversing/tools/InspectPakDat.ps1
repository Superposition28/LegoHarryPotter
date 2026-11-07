<#
.SYNOPSIS
    Inspects TT Games PakDat v1.01 (.DAT) archives from LEGO Harry Potter (PS3 / Xbox 360).
.DESCRIPTION
    Parses the 52-byte PakDat v1.01 header, computes the exact trailing TOC offset
    (including negative 256-byte sector-shifted offsets for archives >= 2 GB),
    validates the TocOffset + TocSize == FileSize invariant, reconstructs full file paths
    from the trailing NameNode tree and StringTable, and verifies the TT Games FNV-1a
    variant path hash (seed 0x811C9DC5, prime 0x00199933).
#>
param(
    [string]$SourceRoot = (Join-Path $PSScriptRoot "..\..\Source\Orginals\PS3"),
    [switch]$VerifyHashes,
    [switch]$SampleDecompress
)

$ErrorActionPreference = "Stop"

$CSharpSource = @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class PakDatInspector {
    public struct PakDatEntry {
        public long DataOffset;
        public uint CompressedSize;
        public uint UncompressedSize;
        public byte CompressionType;
        public ushort Padding;
        public byte SubSectorOffset;
        public uint PathHash;
        public string FullPath;
    }

    public static uint ComputeTtPathHash(string PathString) {
        uint Hash = 0x811C9DC5u;
        for (int i = 0; i < PathString.Length; i++) {
            char Ch = char.ToUpperInvariant(PathString[i]);
            if (Ch == '/') Ch = '\\';
            Hash = (Hash ^ (byte)Ch) * 0x00199933u;
        }
        return Hash;
    }

    public static List<PakDatEntry> ReadToc(string FilePath, out int Version, out int NodeCount, out int StringTableSize, out int HashMatches) {
        using var Stream = File.OpenRead(FilePath);
        using var Reader = new BinaryReader(Stream);

        int RawTocOffset = Reader.ReadInt32();
        uint TocSize = Reader.ReadUInt32();
        long TocOffset = (RawTocOffset < 0)
            ? ((long)(-RawTocOffset) << 8)
            : (long)(uint)RawTocOffset;

        Stream.Position = TocOffset;
        Version = Reader.ReadInt32();
        int FileCount = Reader.ReadInt32();

        var Entries = new PakDatEntry[FileCount];
        for (int i = 0; i < FileCount; i++) {
            uint OffsetSector = Reader.ReadUInt32();
            uint CompSize = Reader.ReadUInt32();
            uint UncompSize = Reader.ReadUInt32();
            byte CompType = Reader.ReadByte();
            ushort Pad = Reader.ReadUInt16();
            byte SubSec = Reader.ReadByte();

            Entries[i] = new PakDatEntry {
                DataOffset = ((long)OffsetSector << 8) + SubSec,
                CompressedSize = CompSize,
                UncompressedSize = UncompSize,
                CompressionType = CompType,
                Padding = Pad,
                SubSectorOffset = SubSec
            };
        }

        NodeCount = Reader.ReadInt32();
        short[] ChildOrFile = new short[NodeCount];
        short[] PrevSibling = new short[NodeCount];
        int[] NameOffset = new int[NodeCount];

        for (int k = 0; k < NodeCount; k++) {
            ChildOrFile[k] = Reader.ReadInt16();
            PrevSibling[k] = Reader.ReadInt16();
            NameOffset[k] = Reader.ReadInt32();
        }

        StringTableSize = Reader.ReadInt32();
        byte[] StringTable = Reader.ReadBytes(StringTableSize);

        for (int i = 0; i < FileCount; i++) {
            Entries[i].PathHash = Reader.ReadUInt32();
        }

        string GetName(int Off) {
            if (Off < 0 || Off >= StringTable.Length) return "";
            int End = Off;
            while (End < StringTable.Length && StringTable[End] != 0) End++;
            return Encoding.ASCII.GetString(StringTable, Off, End - Off);
        }

        int[] ParentNode = new int[NodeCount];
        ParentNode[0] = -1;
        for (int k = 1; k < NodeCount; k++) {
            if (PrevSibling[k] == 0) {
                ParentNode[k] = k - 1;
            } else {
                int Sib = PrevSibling[k];
                ParentNode[k] = (Sib >= 0 && Sib < k) ? ParentNode[Sib] : -1;
            }
        }

        var HashLookup = new Dictionary<uint, int>(FileCount);
        for (int i = 0; i < FileCount; i++) {
            HashLookup[Entries[i].PathHash] = i;
        }

        HashMatches = 0;
        for (int k = 1; k < NodeCount; k++) {
            if (ChildOrFile[k] <= 0) {
                var Parts = new List<string>();
                int Cur = k;
                while (Cur > 0) {
                    string Part = GetName(NameOffset[Cur]);
                    if (Part.Length > 0) Parts.Add(Part);
                    Cur = ParentNode[Cur];
                }
                Parts.Reverse();
                string FullPath = string.Join("\\", Parts);
                uint ComputedHash = ComputeTtPathHash(FullPath);
                if (HashLookup.TryGetValue(ComputedHash, out int EntryIdx)) {
                    Entries[EntryIdx].FullPath = FullPath;
                    HashMatches++;
                }
            }
        }

        return new List<PakDatEntry>(Entries);
    }
}
"@

if (-not ("PakDatInspector" -as [type])) {
    Add-Type -TypeDefinition $CSharpSource
}

Write-Host "=== TT Games PakDat v1.01 Archive Inspector ===" -ForegroundColor Cyan

$DatFiles = Get-ChildItem -Path $SourceRoot -Recurse -Filter "GAME*.DAT"
foreach ($File in $DatFiles) {
    $Stream = [System.IO.File]::OpenRead($File.FullName)
    $Reader = New-Object System.IO.BinaryReader($Stream)

    $RawTocOffset = $Reader.ReadInt32()
    $TocSize = $Reader.ReadUInt32()
    $SigBytes = $Reader.ReadBytes(44)
    $Signature = [System.Text.Encoding]::ASCII.GetString($SigBytes).TrimEnd([char]0)
    $Stream.Close()

    $TocOffset = if ($RawTocOffset -lt 0) {
        ([int64](-$RawTocOffset)) -shl 8
    } else {
        [int64]([uint32]$RawTocOffset)
    }

    $CalculatedEnd = $TocOffset + $TocSize
    $IsValid = ($CalculatedEnd -eq $File.Length)
    $Status = if ($IsValid) { "VALID (TocOffset + TocSize == FileSize)" } else { "MISMATCH ($CalculatedEnd != $($File.Length))" }
    $ReleaseName = $File.Directory.Parent.Parent.Name

    Write-Host "`n[$ReleaseName] $($File.Name)" -ForegroundColor Yellow
    Write-Host ("  File Size    : {0:N0} bytes (0x{0:X})" -f $File.Length)
    Write-Host ("  Signature    : {0}" -f $Signature)
    Write-Host ("  RawTocOffset : 0x{0:X8} ({1}) -> TocOffset = 0x{2:X} ({2:N0})" -f $RawTocOffset, $RawTocOffset, $TocOffset)
    Write-Host ("  TocSize      : 0x{0:X8} ({0:N0} bytes)" -f $TocSize)
    Write-Host ("  Integrity    : {0}" -f $Status) -ForegroundColor ($(if ($IsValid) { "Green" } else { "Red" }))

    if ($VerifyHashes -and $IsValid) {
        $Version = 0
        $NodeCount = 0
        $StrSize = 0
        $HashMatches = 0
        $Entries = [PakDatInspector]::ReadToc($File.FullName, [ref]$Version, [ref]$NodeCount, [ref]$StrSize, [ref]$HashMatches)
        $CompCount = ($Entries | Where-Object { $_.CompressionType -ne 0 }).Count
        Write-Host ("  TOC Summary  : Version={0}, Files={1:N0} (Compressed={2:N0}), NameNodes={3:N0}, StringTable={4:N0} B" -f $Version, $Entries.Count, $CompCount, $NodeCount, $StrSize)
        Write-Host ("  Hash Match   : {0:N0} / {1:N0} ({2:P1}) verified with TtPathHash" -f $HashMatches, $Entries.Count, ($HashMatches / [Math]::Max(1, $Entries.Count))) -ForegroundColor Green
        for ($s = 0; $s -lt [Math]::Min(3, $Entries.Count); $s++) {
            $E = $Entries[$s]
            Write-Host ("    Entry[{0}]: Offset=0x{1:X8} Comp={2,8} Uncomp={3,8} Type={4} Hash=0x{5:X8} Path='{6}'" -f $s, $E.DataOffset, $E.CompressedSize, $E.UncompressedSize, $E.CompressionType, $E.PathHash, $E.FullPath)
        }
    }
}
