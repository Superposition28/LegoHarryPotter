<#
.SYNOPSIS
    Inspects TT Games .datwin archives from the LEGO Harry Potter Collection (PC Steam).
.DESCRIPTION
    Reads the 16-byte header (uint64 TocOffset, uint64 TocSize), verifies the integrity
    invariant (TocOffset + TocSize == FileSize) and the exact TOC size invariant
    (TocSize == 8 + 28 * FileCount), parses the 24-byte DatwinFileEntry records and
    trailing uint32 PathHashes[FileCount] array, cross-matches hashes against PS3 PakDat
    string tables, and optionally decompresses LZHAM (0x04040404 / 0E C6) streams via harry1.exe.
#>
param(
    [string]$CollectionRoot = (Join-Path $PSScriptRoot "..\..\Source\Collection"),
    [string]$Ps3Root = (Join-Path $PSScriptRoot "..\..\Source\Orginals\PS3"),
    [switch]$ResolvePaths,
    [switch]$SampleDecompress
)

$ErrorActionPreference = "Stop"

$CSharpSource = @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class DatwinInspector {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryExW(string lpFileName, IntPtr hFile, uint dwFlags);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    public static extern IntPtr LoadLibraryA(string lpFileName);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);

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
    private static LzhamDecompressInitFn _initFn;
    private static LzhamDecompressFn _decompFn;
    private static LzhamDecompressDeinitFn _deinitFn;

    public static void EnsureLzhamLoaded(string ExePath) {
        if (_hMod != IntPtr.Zero) return;
        _hMod = LoadLibraryExW(ExePath, IntPtr.Zero, 0x00000001);
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

        var SetMem = Marshal.GetDelegateForFunctionPointer<LzhamSetMemCallbacksFn>(IntPtr.Add(_hMod, 0x5D9420));
        SetMem(IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        _initFn = Marshal.GetDelegateForFunctionPointer<LzhamDecompressInitFn>(IntPtr.Add(_hMod, 0x5D9410));
        _decompFn = Marshal.GetDelegateForFunctionPointer<LzhamDecompressFn>(IntPtr.Add(_hMod, 0x5D93F0));
        _deinitFn = Marshal.GetDelegateForFunctionPointer<LzhamDecompressDeinitFn>(IntPtr.Add(_hMod, 0x5D9400));
    }

    public static byte[] DecompressLzham(string ExePath, byte[] CompressedBytes, int UncompressedSize, out int Status, out uint Adler32) {
        EnsureLzhamLoaded(ExePath);
        var Params = new LzhamDecompressParams {
            StructSize = 40,
            DictSizeLog2 = 15,
            TableUpdateRate = 0,
            DecompressFlags = 5
        };
        IntPtr State = _initFn(ref Params);
        byte[] Output = new byte[UncompressedSize];
        UIntPtr InLen = (UIntPtr)CompressedBytes.Length;
        UIntPtr OutLen = (UIntPtr)Output.Length;
        Status = _decompFn(State, CompressedBytes, ref InLen, Output, ref OutLen, 1);
        Adler32 = _deinitFn(State);
        return Output;
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

    public static Dictionary<uint, string> BuildPs3HashDictionary(string[] DatPaths) {
        var Map = new Dictionary<uint, string>();
        foreach (string Path in DatPaths) {
            using var Stream = File.OpenRead(Path);
            using var Reader = new BinaryReader(Stream);
            int RawOff = Reader.ReadInt32();
            long TocOff = (RawOff < 0) ? ((long)(-RawOff) << 8) : (long)(uint)RawOff;
            Stream.Position = TocOff;
            int Ver = Reader.ReadInt32();
            int Count = Reader.ReadInt32();
            Stream.Position += (long)Count * 16;
            int NodeCount = Reader.ReadInt32();
            short[] ChildOrFile = new short[NodeCount];
            short[] PrevSib = new short[NodeCount];
            int[] NameOff = new int[NodeCount];
            for (int k = 0; k < NodeCount; k++) {
                ChildOrFile[k] = Reader.ReadInt16();
                PrevSib[k] = Reader.ReadInt16();
                NameOff[k] = Reader.ReadInt32();
            }
            int StrSize = Reader.ReadInt32();
            byte[] StrTab = Reader.ReadBytes(StrSize);

            string GetName(int Off) {
                if (Off < 0 || Off >= StrTab.Length) return "";
                int End = Off;
                while (End < StrTab.Length && StrTab[End] != 0) End++;
                return Encoding.ASCII.GetString(StrTab, Off, End - Off);
            }

            int[] Parent = new int[NodeCount];
            Parent[0] = -1;
            for (int k = 1; k < NodeCount; k++) {
                Parent[k] = (PrevSib[k] == 0) ? (k - 1) : ((PrevSib[k] >= 0 && PrevSib[k] < k) ? Parent[PrevSib[k]] : -1);
            }

            for (int k = 1; k < NodeCount; k++) {
                if (ChildOrFile[k] <= 0) {
                    var Parts = new List<string>();
                    int Cur = k;
                    while (Cur > 0) {
                        string P = GetName(NameOff[Cur]);
                        if (P.Length > 0) Parts.Add(P);
                        Cur = Parent[Cur];
                    }
                    Parts.Reverse();
                    string Full = string.Join("\\", Parts);
                    Map[ComputeTtPathHash(Full)] = Full;
                    string[] Variants = new string[] {
                        Full.Replace("ps3", "ps4"),
                        Full.Replace("360", "ps4"),
                        Full.EndsWith(".msf", StringComparison.OrdinalIgnoreCase) ? Full.Substring(0, Full.Length - 4) + ".ogg" : Full,
                        Full.EndsWith(".msf", StringComparison.OrdinalIgnoreCase) ? Full.Substring(0, Full.Length - 4) + ".wav" : Full,
                        Full.EndsWith(".as", StringComparison.OrdinalIgnoreCase) ? Full.Substring(0, Full.Length - 3) + "_an3_ps4.pak" : Full,
                        Full.EndsWith(".as", StringComparison.OrdinalIgnoreCase) ? Full.Substring(0, Full.Length - 3) + "_cbs_ps4.pak" : Full,
                        Full.EndsWith(".as", StringComparison.OrdinalIgnoreCase) ? Full.Substring(0, Full.Length - 3) + "_cbs.pak" : Full,
                        Full.EndsWith(".as", StringComparison.OrdinalIgnoreCase) ? Full.Substring(0, Full.Length - 3) + "_an3.pak" : Full,
                        Full.EndsWith(".cd", StringComparison.OrdinalIgnoreCase) ? Full.Substring(0, Full.Length - 3) + ".cpd" : Full
                    };
                    foreach (string V in Variants) {
                        uint VH = ComputeTtPathHash(V);
                        if (!Map.ContainsKey(VH)) Map[VH] = V;
                    }
                }
            }
        }
        return Map;
    }
}
"@

if (-not ("DatwinInspector" -as [type])) {
    Add-Type -TypeDefinition $CSharpSource
}

Write-Host "=== LEGO Harry Potter (.datwin) Package Inspector ===" -ForegroundColor Cyan

$HashDict = $null
if ($ResolvePaths -and (Test-Path $Ps3Root)) {
    $Ps3DatFiles = (Get-ChildItem -Path $Ps3Root -Recurse -Filter "GAME*.DAT").FullName
    $HashDict = [DatwinInspector]::BuildPs3HashDictionary($Ps3DatFiles)
    Write-Host ("Loaded {0:N0} unique path hashes from PS3 PakDat archives." -f $HashDict.Count) -ForegroundColor DarkCyan
}

$ExePath = Join-Path $CollectionRoot "Years 1-4\harry1.exe"
$DatwinFiles = Get-ChildItem -Path $CollectionRoot -Recurse -Filter "*.datwin"

foreach ($File in $DatwinFiles) {
    $Stream = [System.IO.File]::OpenRead($File.FullName)
    $Reader = New-Object System.IO.BinaryReader($Stream)

    $TocOffset = $Reader.ReadInt64()
    $TocSize = $Reader.ReadInt64()
    $CalculatedEnd = $TocOffset + $TocSize
    $IsValid = ($CalculatedEnd -eq $File.Length)

    $Stream.Position = $TocOffset
    $Version = $Reader.ReadInt32()
    $FileCount = $Reader.ReadUInt32()
    $ExpectedTocSize = 8 + (28 * $FileCount)

    $Entries = New-Object System.Collections.Generic.List[object]
    $CompressedCount = 0
    for ($i = 0; $i -lt $FileCount; $i++) {
        $DataOffset = $Reader.ReadInt64()
        $Canary = $Reader.ReadUInt32()
        $CompSize = $Reader.ReadUInt32()
        $UncompSize = $Reader.ReadUInt32()
        $Flags = $Reader.ReadUInt32()
        if ($Flags -ne 0) { $CompressedCount++ }
        if ($i -lt 5) {
            $Entries.Add([PSCustomObject]@{
                Index            = $i
                DataOffset       = $DataOffset
                Canary           = $Canary
                CompressedSize   = $CompSize
                UncompressedSize = $UncompSize
                Flags            = $Flags
                PathHash         = 0u
            })
        }
    }

    $ResolvedCount = 0
    for ($i = 0; $i -lt $FileCount; $i++) {
        $Hash = $Reader.ReadUInt32()
        if ($i -lt 5) {
            $Entries[$i].PathHash = $Hash
        }
        if ($null -ne $HashDict -and $HashDict.ContainsKey($Hash)) {
            $ResolvedCount++
        }
    }

    Write-Host "`n[$($File.Directory.Name)/$($File.Name)]" -ForegroundColor Yellow
    Write-Host ("  File Size    : {0:N0} bytes" -f $File.Length)
    Write-Host ("  TOC Offset   : 0x{0:X12} ({0:N0})" -f $TocOffset)
    Write-Host ("  TOC Size     : 0x{0:X8} ({0:N0} bytes) == 8 + 28 * {1:N0} (Diff={2})" -f $TocSize, $FileCount, ($TocSize - $ExpectedTocSize))
    Write-Host ("  Integrity    : {0}" -f ($(if ($IsValid) { "VALID (TocOffset + TocSize == FileSize)" } else { "MISMATCH" }))) -ForegroundColor ($(if ($IsValid) { "Green" } else { "Red" }))
    Write-Host ("  TOC Summary  : Version={0}, Files={1:N0} (LZHAM Compressed={2:N0}, Raw={3:N0})" -f $Version, $FileCount, $CompressedCount, ($FileCount - $CompressedCount))

    if ($null -ne $HashDict) {
        Write-Host ("  Path Match   : {0:N0} / {1:N0} ({2:P1}) resolved via PS3 PakDat dictionary" -f $ResolvedCount, $FileCount, ($ResolvedCount / [Math]::Max(1, $FileCount))) -ForegroundColor Green
    }

    for ($s = 0; $s -lt [Math]::Min(3, $Entries.Count); $s++) {
        $E = $Entries[$s]
        $PathStr = if ($null -ne $HashDict -and $HashDict.ContainsKey($E.PathHash)) { $HashDict[$E.PathHash] } else { "<unmatched>" }
        Write-Host ("    Entry[{0}]: Offset=0x{1:X9} Canary=0x{2:X8} Comp={3,8} Uncomp={4,8} Flags=0x{5:X8} Hash=0x{6:X8} Path='{7}'" -f $E.Index, $E.DataOffset, $E.Canary, $E.CompressedSize, $E.UncompressedSize, $E.Flags, $E.PathHash, $PathStr)
    }

    if ($SampleDecompress -and $Entries.Count -gt 0 -and (Test-Path $ExePath)) {
        $FirstComp = $Entries | Where-Object { $_.Flags -eq 0x04040404 } | Select-Object -First 1
        if ($null -ne $FirstComp) {
            $Stream.Position = $FirstComp.DataOffset
            $CompBytes = $Reader.ReadBytes($FirstComp.CompressedSize)
            $Status = 0
            $Adler = 0u
            $OutBytes = [DatwinInspector]::DecompressLzham($ExePath, $CompBytes, $FirstComp.UncompressedSize, [ref]$Status, [ref]$Adler)
            $Preview = [System.Text.Encoding]::ASCII.GetString($OutBytes, 0, [Math]::Min(64, $OutBytes.Length)).Replace("`r","\r").Replace("`n","\n").Replace("`0",".")
            Write-Host ("    [LZHAM Test] Entry[{0}]: Status={1} (3=OK), Adler32=0x{2:X8}, Preview='{3}'" -f $FirstComp.Index, $Status, $Adler, $Preview) -ForegroundColor Cyan
        }
    }

    $Stream.Close()
}
