<#
.SYNOPSIS
    Unified extractor for TT Games PakDat v1.01 (PS3 / Xbox 360 .DAT) and PC (.datwin) archives.
.DESCRIPTION
    Supports extracting and decompressing files from:
      - PS3 and Xbox 360 PakDat v1.01 archives (GAME*.DAT), using native LZ2K decompression
        (harry1.exe RVA 0x4D4A50) for CompressionType == 2 chunked streams.
      - PC Steam Collection .datwin archives (harry*.datwin), using native LZHAM decompression
        (harry1.exe RVA 0x5D93F0..0x5D9420) for CompressionType == 4 (0E C6) streams,
        resolving file paths via the PS3/Xbox 360 PakDat string tables and PC/PS4 remaster
        variant derivation rules.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [string]$Filter = ".*",
    [int]$MaxFiles = 0,
    [string]$ExePath = (Join-Path $PSScriptRoot "..\..\Source\Collection\Years 1-4\harry1.exe"),
    [string]$ConsoleSourceRoot = (Join-Path $PSScriptRoot "..\..\Source\Orginals")
)

$ErrorActionPreference = "Stop"

$CSharpSource = @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class TtArchiveExtractor {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryExW(string lpFileName, IntPtr hFile, uint dwFlags);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    public static extern IntPtr LoadLibraryA(string lpFileName);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Lz2kDecompressFn(byte[] src, byte[] dst, int compSize, int uncompSize, IntPtr workspace);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void LzhamSetMemCallbacksFn(IntPtr reallocCb, IntPtr msizeCb, IntPtr user);

    [StructLayout(LayoutKind.Sequential, Size = 40)]
    public struct LzhamDecompressParams {
        public uint StructSize;                  // +0x00 (40)
        public uint DictSizeLog2;                // +0x04 (15)
        public uint TableUpdateRate;             // +0x08 (0)
        public uint DecompressFlags;             // +0x0C (5 = OUTPUT_UNBUFFERED | READ_ZLIB_STREAM)
        public uint NumSeedBytes;                // +0x10
        public uint Pad0;                        // +0x14
        public IntPtr SeedBytes;                 // +0x18
        public uint TableMaxUpdateInterval;      // +0x20
        public uint TableUpdateIntervalSlowRate; // +0x24
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate IntPtr LzhamDecompressInitFn(ref LzhamDecompressParams pParams);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int LzhamDecompressFn(IntPtr state, byte[] inBuf, ref UIntPtr inBytes, byte[] outBuf, ref UIntPtr outBytes, int noMoreInputBytesFlag);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate uint LzhamDecompressDeinitFn(IntPtr state);

    private static IntPtr _hMod = IntPtr.Zero;
    private static Lz2kDecompressFn _lz2kFn;
    private static LzhamDecompressInitFn _lzhamInitFn;
    private static LzhamDecompressFn _lzhamDecompFn;
    private static LzhamDecompressDeinitFn _lzhamDeinitFn;

    public static void EnsureNativeLoaded(string ExePath) {
        if (_hMod != IntPtr.Zero) return;
        if (!File.Exists(ExePath)) throw new FileNotFoundException("Native host executable not found: " + ExePath);
        _hMod = LoadLibraryExW(ExePath, IntPtr.Zero, 0x00000001);
        if (_hMod == IntPtr.Zero) throw new InvalidOperationException("LoadLibraryExW failed for " + ExePath);

        uint OldProt;
        VirtualProtect(_hMod, (UIntPtr)0x171C000, 0x40, out OldProt);

        int ELfanew = Marshal.ReadInt32(_hMod, 0x3C);
        int ImportRva = Marshal.ReadInt32(_hMod, ELfanew + 0x90);
        for (int Off = 0; ImportRva != 0; Off += 20) {
            int OrigFirstThunk = Marshal.ReadInt32(_hMod, ImportRva + Off);
            int NameRva = Marshal.ReadInt32(_hMod, ImportRva + Off + 12);
            int FirstThunk = Marshal.ReadInt32(_hMod, ImportRva + Off + 16);
            if (NameRva == 0 && FirstThunk == 0) break;

            string DllName = Marshal.PtrToStringAnsi(IntPtr.Add(_hMod, NameRva));
            IntPtr HDll = LoadLibraryA(DllName);
            if (HDll == IntPtr.Zero) continue;
            int ThunkRva = OrigFirstThunk != 0 ? OrigFirstThunk : FirstThunk;
            for (int t = 0; ; t += 8) {
                long Val = Marshal.ReadInt64(_hMod, ThunkRva + t);
                if (Val == 0) break;
                if ((Val & (1L << 63)) == 0) {
                    string FnName = Marshal.PtrToStringAnsi(IntPtr.Add(_hMod, (int)Val + 2));
                    IntPtr FnPtr = GetProcAddress(HDll, FnName);
                    if (FnPtr != IntPtr.Zero) {
                        Marshal.WriteInt64(IntPtr.Add(_hMod, FirstThunk + t), FnPtr.ToInt64());
                    }
                }
            }
        }

        _lz2kFn = Marshal.GetDelegateForFunctionPointer<Lz2kDecompressFn>(IntPtr.Add(_hMod, 0x4D4A50));
        var SetMem = Marshal.GetDelegateForFunctionPointer<LzhamSetMemCallbacksFn>(IntPtr.Add(_hMod, 0x5D9420));
        SetMem(IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        _lzhamInitFn = Marshal.GetDelegateForFunctionPointer<LzhamDecompressInitFn>(IntPtr.Add(_hMod, 0x5D9410));
        _lzhamDecompFn = Marshal.GetDelegateForFunctionPointer<LzhamDecompressFn>(IntPtr.Add(_hMod, 0x5D93F0));
        _lzhamDeinitFn = Marshal.GetDelegateForFunctionPointer<LzhamDecompressDeinitFn>(IntPtr.Add(_hMod, 0x5D9400));
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

    public static byte[] ExtractPakDatEntry(string ExePath, Stream Stream, long DataOffset, uint CompSize, uint UncompSize, byte CompType) {
        Stream.Position = DataOffset;
        var Reader = new BinaryReader(Stream);
        if (CompType == 0 || CompSize == UncompSize) {
            return Reader.ReadBytes((int)UncompSize);
        }
        EnsureNativeLoaded(ExePath);
        byte[] Output = new byte[UncompSize];
        int OutPos = 0;
        while (OutPos < UncompSize) {
            string Magic = Encoding.ASCII.GetString(Reader.ReadBytes(4));
            if (Magic != "LZ2K") {
                throw new InvalidDataException($"Expected LZ2K chunk magic at 0x{Stream.Position - 4:X}, got '{Magic}'");
            }
            int ChunkUncomp = Reader.ReadInt32();
            int ChunkComp = Reader.ReadInt32();
            byte[] ChunkIn = Reader.ReadBytes(ChunkComp);
            if (ChunkComp == ChunkUncomp) {
                Buffer.BlockCopy(ChunkIn, 0, Output, OutPos, ChunkUncomp);
            } else {
                byte[] ChunkOut = new byte[ChunkUncomp];
                _lz2kFn(ChunkIn, ChunkOut, ChunkComp, ChunkUncomp, IntPtr.Zero);
                Buffer.BlockCopy(ChunkOut, 0, Output, OutPos, ChunkUncomp);
            }
            OutPos += ChunkUncomp;
        }
        return Output;
    }

    public static byte[] ExtractDatwinEntry(string ExePath, Stream Stream, long DataOffset, uint CompSize, uint UncompSize, uint Flags) {
        Stream.Position = DataOffset;
        var Reader = new BinaryReader(Stream);
        byte[] RawBytes = Reader.ReadBytes((int)CompSize);
        if ((Flags & 0xFF) == 0 || CompSize == UncompSize) {
            return RawBytes;
        }
        EnsureNativeLoaded(ExePath);
        var Params = new LzhamDecompressParams {
            StructSize = 40,
            DictSizeLog2 = 15,
            TableUpdateRate = 0,
            DecompressFlags = 5
        };
        IntPtr State = _lzhamInitFn(ref Params);
        byte[] Output = new byte[UncompSize];
        UIntPtr InLen = (UIntPtr)RawBytes.Length;
        UIntPtr OutLen = (UIntPtr)Output.Length;
        int Status = _lzhamDecompFn(State, RawBytes, ref InLen, Output, ref OutLen, 1);
        _lzhamDeinitFn(State);
        if (Status != 3) {
            throw new InvalidDataException($"LZHAM decompression failed at 0x{DataOffset:X} with status {Status}");
        }
        return Output;
    }
}
"@

if (-not ("TtArchiveExtractor" -as [type])) {
    Add-Type -TypeDefinition $CSharpSource
}
. (Join-Path $PSScriptRoot "InspectPakDat.ps1") -SourceRoot (Join-Path $PSScriptRoot "..\..\Source\Orginals\PS3\REA") | Out-Null

$ResolvedArchive = (Resolve-Path $ArchivePath).Path
$Ext = [System.IO.Path]::GetExtension($ResolvedArchive).ToLowerInvariant()
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

if ($Ext -eq ".dat") {
    $Ver = 0; $Nodes = 0; $StrSz = 0; $MatchesCount = 0
    $Entries = [PakDatInspector]::ReadToc($ResolvedArchive, [ref]$Ver, [ref]$Nodes, [ref]$StrSz, [ref]$MatchesCount)
    $Stream = [System.IO.File]::OpenRead($ResolvedArchive)
    $Extracted = 0
    try {
        foreach ($E in $Entries) {
            $RelPath = if ($E.FullPath) { $E.FullPath } else { ("_unmatched\0x{0:X8}.bin" -f $E.PathHash) }
            if ($RelPath -match $Filter) {
                $DestPath = Join-Path $OutputDir $RelPath
                New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($DestPath)) | Out-Null
                $Bytes = [TtArchiveExtractor]::ExtractPakDatEntry($ExePath, $Stream, $E.DataOffset, $E.CompressedSize, $E.UncompressedSize, $E.CompressionType)
                [System.IO.File]::WriteAllBytes($DestPath, $Bytes)
                $Extracted++
                Write-Host ("  [PakDat] Extracted '{0}' ({1:N0} bytes, Type={2})" -f $RelPath, $Bytes.Length, $E.CompressionType) -ForegroundColor Green
                if ($MaxFiles -gt 0 -and $Extracted -ge $MaxFiles) { break }
            }
        }
    } finally {
        $Stream.Close()
    }
    Write-Host ("Completed: Extracted {0:N0} files from {1} to {2}" -f $Extracted, [System.IO.Path]::GetFileName($ResolvedArchive), $OutputDir) -ForegroundColor Cyan
} elseif ($Ext -eq ".datwin") {
    $HashDict = @{}
    if (Test-Path $ConsoleSourceRoot) {
        $DatFiles = Get-ChildItem -Path $ConsoleSourceRoot -Recurse -Filter "GAME*.DAT"
        $Ver = 0; $Nodes = 0; $StrSz = 0; $MatchesCount = 0
        foreach ($Df in $DatFiles) {
            foreach ($E in [PakDatInspector]::ReadToc($Df.FullName, [ref]$Ver, [ref]$Nodes, [ref]$StrSz, [ref]$MatchesCount)) {
                if ($E.FullPath) {
                    $P = $E.FullPath
                    $HashDict[$E.PathHash] = $P
                    foreach ($Cand in @(
                        ($P -replace 'ps3','ps4'),
                        ($P -replace '360','ps4'),
                        ($P -replace '\.msf$','.ogg'),
                        ($P -replace '\.msf$','.wav'),
                        ($P -replace '\.xma$','.ogg'),
                        ($P -replace '\.xma$','.wav'),
                        ($P -replace '\.as$','_an3_ps4.pak'),
                        ($P -replace '\.as$','_cbs_ps4.pak'),
                        ($P -replace '\.as$','_cbs.pak'),
                        ($P -replace '\.as$','_an3.pak'),
                        ($P -replace '\.cd$','.cpd')
                    )) {
                        $Ch = [TtArchiveExtractor]::ComputeTtPathHash($Cand)
                        if (-not $HashDict.ContainsKey($Ch)) { $HashDict[$Ch] = $Cand }
                    }
                }
            }
        }
    }

    $Stream = [System.IO.File]::OpenRead($ResolvedArchive)
    $Reader = New-Object System.IO.BinaryReader($Stream)
    $Extracted = 0
    try {
        $TocOff = $Reader.ReadInt64()
        $TocSize = $Reader.ReadInt64()
        $Stream.Position = $TocOff
        $Ver = $Reader.ReadInt32()
        $Count = $Reader.ReadInt32()
        $Entries = New-Object 'System.ValueTuple[long,uint32,uint32,uint32][]' $Count
        for ($i = 0; $i -lt $Count; $i++) {
            $Off = $Reader.ReadInt64()
            $Canary = $Reader.ReadUInt32()
            $Comp = $Reader.ReadUInt32()
            $Uncomp = $Reader.ReadUInt32()
            $Flags = $Reader.ReadUInt32()
            $Entries[$i] = [ValueTuple]::Create($Off, $Comp, $Uncomp, $Flags)
        }
        $Hashes = New-Object 'uint32[]' $Count
        for ($i = 0; $i -lt $Count; $i++) {
            $Hashes[$i] = $Reader.ReadUInt32()
        }

        for ($i = 0; $i -lt $Count; $i++) {
            $H = $Hashes[$i]
            $RelPath = if ($HashDict.ContainsKey($H)) { $HashDict[$H] } else { ("_unmatched\0x{0:X8}.bin" -f $H) }
            if ($RelPath -match $Filter) {
                $E = $Entries[$i]
                $DestPath = Join-Path $OutputDir $RelPath
                New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($DestPath)) | Out-Null
                $Bytes = [TtArchiveExtractor]::ExtractDatwinEntry($ExePath, $Stream, $E.Item1, $E.Item2, $E.Item3, $E.Item4)
                [System.IO.File]::WriteAllBytes($DestPath, $Bytes)
                $Extracted++
                Write-Host ("  [datwin] Extracted '{0}' ({1:N0} bytes, Flags=0x{2:X8})" -f $RelPath, $Bytes.Length, $E.Item4) -ForegroundColor Green
                if ($MaxFiles -gt 0 -and $Extracted -ge $MaxFiles) { break }
            }
        }
    } finally {
        $Stream.Close()
    }
    Write-Host ("Completed: Extracted {0:N0} files from {1} to {2}" -f $Extracted, [System.IO.Path]::GetFileName($ResolvedArchive), $OutputDir) -ForegroundColor Cyan
} else {
    throw "Unsupported archive extension '$Ext'. Expected .DAT or .datwin."
}
