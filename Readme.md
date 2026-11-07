# Remake Engine Game Module: LEGO Harry Potter

This game module provides research, executable reverse-engineering, format parsers, and extraction pipelines for **LEGO Harry Potter** within the [RemakeEngine](https://github.com/yggdrasil-au/RemakeEngine) ecosystem.

> **Scope Note:** In accordance with the parent engine's guidelines, this module is currently focused on **extraction, asset research, and reverse engineering**. Runtime gameplay reproduction or Godot project generation are future phases once asset pipelines stabilize.

---

## Supported Game Targets in Workspace

This module covers both the original 7th-generation PlayStation 3 retail disc releases and the remastered Steam Windows 64-bit Collection edition:

```text
Games/Lego_Harry_Potter/
├── Source/
│   ├── Orginals/
│   │   ├── PS3/
│   │   │   ├── LEGO Harry Potter - Years 1-4 (...) (v01.02)  [BLES-00779]
│   │   │   ├── LEGO Harry Potter - Years 1-4 (...) (v03.01)  [BLES-00779, Identical payload]
│   │   │   ├── LEGO Harry Potter - Years 5-7 (...)           [BLES-01297]
│   │   │   └── REA/                                          [Reverse Engineering Workstation]
│   │   │       ├── guide.md
│   │   │       ├── report.md
│   │   │       ├── Extracted_Comparison/                     [Extracted cross-platform configs/changelogs]
│   │   │       ├── LHP.gpr / LHP.rep/
│   │   │       └── TMP/
│   │   ├── Xbox_360/
│   │   │   ├── LEGO Harry Potter - Years 1-4 (USA, Europe)... [0x575207E6, Extracted XGD2 + Default.pe]
│   │   │   ├── LEGO Harry Potter - Years 5-7 (USA)...         [0x57520812, Extracted XGD3 + Default.pe]
│   │   │   └── XexTool-windows-x64/                           [XexTool.exe v7.0]
│   │   └── The Experience Disc Version 5.5 (Xbox 360)/        [0x575287FF, Kiosk Demo ISO]
│   └── Collection/
│       ├── Main/          [Launcher: LHPC.exe, HarryLauncher.exe, launcher.pkdwin]
│       ├── Years 1-4/     [Engine: harry1.exe, harry1*.datwin, shaderblob_pc.blob]
│       └── Years 5-7/     [Engine: harry2.exe, harry2*.datwin, harry2_shaderblob_pc.blob]
├── reversing/
│   └── tools/             [InspectPakDat.ps1, InspectDatwin.ps1, InspectXbox360Demo.ps1, ExtractArchive.ps1, ComparePlatforms.ps1]
├── config.toml            [Module configuration]
├── operations.toml        [RemakeEngine operations manifest]
├── Tools.toml             [External tools manifest]
├── Readme.md              [This document]
└── TODO.md                [Module development roadmap]
```

---

## Reverse Engineering Assistant (REA)

An REA project modeled directly after the *The Simpsons Game (PS3)* REA architecture is active in [`Source/Orginals/PS3/REA/`](Source/Orginals/PS3/REA/guide.md):
- **Ghidra 12.1.4 Project:** `LHP.gpr` / `LHP.rep/` configured for PPU 64-bit Big-Endian PowerPC and AMD64 executable analysis.
- **Audited Executables:**
  - `BLES-00720` (Years 1-4 PS3): Entry OPD `0x00942F58`, Text `0x00010000`, Data `0x00930000`.
  - `BLES-01348` (Years 5-7 PS3): Entry OPD `0x00B80EB0`, Text `0x00010000`, Data `0x00B80000`.
  - Steam Collection: `harry1.exe` (x64 MSVC 2019, D3D11 static) and `harry2.exe`.
- **Progress Tracking:** All research frontiers, turn logs, and format specifications are tracked in [`Source/Orginals/PS3/REA/TMP/`](Source/Orginals/PS3/REA/TMP/STATE.md).

---

## Packaging & Asset Architecture

1. **PS3 & Xbox 360 `PakDat v1.01` (`GAME*.DAT`):**
   - Header (`52` bytes): `[0x00] int32 RawTocOffset` (if `< 0`, `TocOffset = (-RawTocOffset) << 8`), `[0x04] uint32 TocSize`, and `[0x08..0x33]` `BEGIN_APP_ID_STRINGPakDat v1.01END_APP_ID_STRING\0`.
   - Every `GAME*.DAT` file is a standalone archive with a trailing TOC (`Version = -4`, `TocOffset + TocSize == FileSize`) containing `16`-byte `PakDatFileEntry[N]`, `8`-byte `PakDatNameNode[M]` directory tree, `StringTable[S]`, and `uint32 PathHashes[N]`.
   - Compressed entries (`CompressionType == 2`) use `32 KB` chunked **`LZ2K`** compression (`VA 0x1404D4A50`).
2. **PC Collection `datwin` (`*.datwin`):**
   - 16-byte header storing `int64 TocOffset` and `uint64 TocSize` pointing to a **trailing Table of Contents** (`Version = -1`, `TocSize == 8 + 28 * FileCount`).
   - Contains `24`-byte `DatwinFileEntry[N]` records (64-bit `DataOffset` at `+0x00`, canary **`0x12345678`** at `+0x08`) followed by `uint32 PathHashes[N]` hashed with `TtPathHash` (`seed 0x811C9DC5`, `prime 0x00199933`).
   - Compressed entries (`Flags == 0x04040404`, `CompressionType == 4`) use **`LZHAM`** (`0E C6` header, `DictSizeLog2 = 15`, `DecompressFlags = 5`, trailing Adler32).
3. **Xbox 360 Kiosk Demo (`The.Experience.Disc.Version.5.5.iso`):**
   - Contains the playable *LEGO Harry Potter: Years 1-4 DEMO* (`Title ID 0x575287FF`, `Media ID 0x05E535C2`) inside a `PIRS` (STFS) container at ISO offset `0x3EBAD000` (`697,393,152` bytes), embedding `Default.xex` (`XEX2`) and `GAME.DAT`..`GAME6.DAT`.
4. **Launcher Package (`launcher.pkiwin` / `launcher.pkdwin`):**
   - Paired index/data architecture using zlib compression (`0x785E`).
5. **Direct3D Shader Blobs (`*.blob`):**
   - Consolidated D3D11/12 bytecode cache (`shaderblob_pc.blob` [61.5 MB] and `harry2_shaderblob_pc.blob` [233 MB]).

---

## Toolchain & Requirements

Managed tools are declared in `Tools.toml` and resolved through RemakeEngine:
- **Blender 4.5.4:** Model and geometry extraction.
- **QuickBMS 0.12.0:** BMS script execution for legacy package analysis.
- **vgmstream-cli:** Audio stream decoding.
- **FFmpeg 8.0:** Bink / video transcoding.
- **ImageMagick:** Texture surface conversions.

