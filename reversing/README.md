# Reverse Engineering Utilities: LEGO Harry Potter

This directory contains standalone, sandbox-native reverse engineering scripts, inspectors, and format validators for LEGO Harry Potter.

## Available Tools

- [`tools/InspectDatwin.ps1`](tools/InspectDatwin.ps1) — Fast PowerShell/C# inspector for `.datwin` archives. Reads the 16-byte header, resolves the trailing TOC offset, verifies the `TocOffset + TocSize == FileSize` invariant, and scans for file entry canaries (`0x12345678`).
- [`tools/InspectPakDat.ps1`](tools/InspectPakDat.ps1) — Inspector for PlayStation 3 `PakDat v1.01` archives (`GAME*.DAT`). Validates the `BEGIN_APP_ID_STRING` signature and displays volume slicing descriptors.

## Usage

Run any tool directly inside PowerShell:

```powershell
& 'A:\RemakeEngine\Main\EngineApps\Games\Lego\Games\Lego_Harry_Potter\reversing\tools\InspectDatwin.ps1'
```

