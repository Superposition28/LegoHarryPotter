# LEGO Harry Potter Module Roadmap

## Stage 1: Scaffolding, Executable Reversing & Format Discovery (Completed)
- [x] Create project scaffold and directory layout following Simpsons Game reference.
- [x] Establish REA workstation at `Source/Orginals/PS3/REA/` with Ghidra project structure (`LHP.gpr`).
- [x] Audit all executable headers, architectures, entry points, and PDB paths (PS3 `EBOOT.BIN`, Xbox 360 Demo `Default.xex`, PC `harry1.exe` / `harry2.exe`).
- [x] Reverse-engineer `datwin` trailing TOC header layout (`TocOffset + TocSize == FileSize`, `TocSize == 8 + 28 * FileCount`) and `24`-byte entry structure (`0x12345678` canary at `+0x08`).
- [x] Reverse-engineer `PakDat v1.01` header (`RawTocOffset`, `>= 2 GB` negative sector shift `(-RawTocOffset) << 8`, `TocSize`) and standalone trailing TOC (`Version = -4`, `Entries[N]`, `NameNodes[M]`, `StringTable[S]`, `PathHashes[N]`).
- [x] Decompile `PakDat v1.01` and `.datwin` archive index unpackers and `NuFileStreamDat::Read` in `harry1.exe` (`VA 0x1404D5D30`, `VA 0x14052E030`, `VA 0x1405367A0`).
- [x] Decompile `TtPathHash` (`seed 0x811C9DC5`, `prime 0x00199933` at `VA 0x140208320`), verify `100%` across `23,254` PS3/Xbox 360 paths, and cross-resolve `.datwin` `PathHashes[N]`.
- [x] Reverse-engineer and verify native decompression for both `LZ2K` (`CompressionType = 2`, `VA 0x1404D4A50`) and `LZHAM` (`CompressionType = 4`, `0E C6` header, `DictSizeLog2 = 15`, `Flags = 5`, `VA 0x1405B47B0`).

## Stage 2: Extraction Pipeline Implementation (Current)
- [x] Upgrade `InspectDatwin.ps1`, `InspectPakDat.ps1`, and `InspectXbox360Demo.ps1` with full TOC parsing, hash verification, and native LZHAM decompression.
- [ ] Implement full batch extraction scripts for `.datwin` (`LZHAM` + raw) and `PakDat v1.01` (`LZ2K` + raw).
- [ ] Harvest additional PC-only file paths from decompressed `.txt` / `.cfg` / `.led` scripts inside `.datwin` to resolve remaining `.datwin` hashes.
- [ ] Extract and inspect `.pkiwin`/`.pkdwin` launcher resources.
- [x] Declare RemakeEngine extraction operations in `operations.toml`.

## Stage 3: Asset Analysis & Conversion
- [ ] Inspect texture packaging (DirectX `.dds` surfaces vs PS3 RSX `.txd`/swizzled textures).
- [ ] Inspect audio containers (FMOD sound banks in PC vs `cellAudio` in PS3).
- [ ] Map 3D mesh containers (TT Games `.ghg` / geometry hierarchy graph models).
- [ ] Disassemble precompiled Direct3D shader cache (`shaderblob_pc.blob`).

## Stage 4: Engine Integration & Future Work
- [x] Update RemakeEngine for nested sub-module discovery (per top-level `TODO.md`).
- [ ] Evaluate Godot scene assembly and asset import pipelines once extraction stabilizes.

