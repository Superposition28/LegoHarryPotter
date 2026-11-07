<#
.SYNOPSIS
    Performs a quantitative 3-way comparison across PS3, Xbox 360, and PC (Steam Collection)
    builds of LEGO Harry Potter: Years 1-4 and Years 5-7.
.DESCRIPTION
    Compares archive structures (GAME*.DAT vs .datwin), TOC entry counts, shared path overlap,
    uncompressed/compressed byte size identity between PS3 (Cell PPU) and Xbox 360 (Xenon PPC64),
    and platform-specific counterpart files (.cu2 cutscenes, .msf vs .xma vs .ogg/.wav audio,
    and PC/PS4 remaster _an3_ps4.pak / _cbs_ps4.pak / .cpd additions).
#>
param(
    [string]$Ps3Root = (Join-Path $PSScriptRoot "..\..\Source\Orginals\PS3"),
    [string]$Xbox360Root = (Join-Path $PSScriptRoot "..\..\Source\Orginals\Xbox_360"),
    [string]$PcRoot = (Join-Path $PSScriptRoot "..\..\Source\Collection")
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "InspectPakDat.ps1") -SourceRoot (Join-Path $PSScriptRoot "..\..\Source\Orginals\PS3\REA") | Out-Null

function Get-PakDatInventory {
    param([string]$Folder)
    $Map = @{}
    $Ver = 0; $Nodes = 0; $StrSz = 0; $MatchesCount = 0
    foreach ($Dat in (Get-ChildItem -Path $Folder -Filter "GAME*.DAT" | Sort-Object Name)) {
        foreach ($E in [PakDatInspector]::ReadToc($Dat.FullName, [ref]$Ver, [ref]$Nodes, [ref]$StrSz, [ref]$MatchesCount)) {
            $Key = $E.FullPath.ToLowerInvariant()
            $Map[$Key] = [PSCustomObject]@{
                Archive          = $Dat.Name
                FullPath         = $E.FullPath
                PathHash         = $E.PathHash
                DataOffset       = $E.DataOffset
                CompressedSize   = $E.CompressedSize
                UncompressedSize = $E.UncompressedSize
                CompressionType  = $E.CompressionType
            }
        }
    }
    return $Map
}

function Get-DatwinInventory {
    param([string]$Folder)
    $Map = @{}
    foreach ($Dw in (Get-ChildItem -Path $Folder -Filter "*.datwin" | Sort-Object Name)) {
        $Stream = [System.IO.File]::OpenRead($Dw.FullName)
        $Reader = New-Object System.IO.BinaryReader($Stream)
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
        for ($i = 0; $i -lt $Count; $i++) {
            $H = $Reader.ReadUInt32()
            $E = $Entries[$i]
            $Map[$H] = [PSCustomObject]@{
                Archive          = $Dw.Name
                PathHash         = $H
                DataOffset       = $E.Item1
                CompressedSize   = $E.Item2
                UncompressedSize = $E.Item3
                CompressionFlags = $E.Item4
            }
        }
        $Stream.Close()
    }
    return $Map
}

function Compare-TitleAcrossPlatforms {
    param(
        [string]$TitleName,
        [string]$Ps3Folder,
        [string]$XboxFolder,
        [string]$PcFolder
    )
    Write-Host "`n=========================================================================" -ForegroundColor Cyan
    Write-Host "  3-WAY PLATFORM COMPARISON: $TitleName" -ForegroundColor Cyan
    Write-Host "=========================================================================" -ForegroundColor Cyan

    $Ps3Inv = Get-PakDatInventory -Folder $Ps3Folder
    $XboxInv = Get-PakDatInventory -Folder $XboxFolder
    $PcInv = Get-DatwinInventory -Folder $PcFolder

    $SharedConsole = 0
    $IdenticalUncomp = 0
    $IdenticalComp = 0
    $Ps3Only = New-Object System.Collections.Generic.List[string]
    $XboxOnly = New-Object System.Collections.Generic.List[string]

    foreach ($K in $Ps3Inv.Keys) {
        if ($XboxInv.ContainsKey($K)) {
            $SharedConsole++
            if ($Ps3Inv[$K].UncompressedSize -eq $XboxInv[$K].UncompressedSize) { $IdenticalUncomp++ }
            if ($Ps3Inv[$K].CompressedSize -eq $XboxInv[$K].CompressedSize) { $IdenticalComp++ }
        } else {
            $Ps3Only.Add($K)
        }
    }
    foreach ($K in $XboxInv.Keys) {
        if (-not $Ps3Inv.ContainsKey($K)) {
            $XboxOnly.Add($K)
        }
    }

    # Build PC hash dictionary from Console + Remaster Variant Rules
    $PcHashLookup = @{}
    foreach ($Entry in $Ps3Inv.Values) {
        $P = $Entry.FullPath
        $PcHashLookup[$Entry.PathHash] = @{ Path = $P; Kind = "Direct"; ConsoleUncomp = $Entry.UncompressedSize }
        foreach ($Cand in @(
            ($P -replace 'ps3','ps4'),
            ($P -replace '\.msf$','.ogg'),
            ($P -replace '\.msf$','.wav'),
            ($P -replace '\.as$','_an3_ps4.pak'),
            ($P -replace '\.as$','_cbs_ps4.pak'),
            ($P -replace '\.as$','_cbs.pak'),
            ($P -replace '\.as$','_an3.pak'),
            ($P -replace '\.cd$','.cpd')
        )) {
            if ($Cand -ne $P) {
                $Ch = [PakDatInspector]::ComputeTtPathHash($Cand)
                if (-not $PcHashLookup.ContainsKey($Ch)) {
                    $PcHashLookup[$Ch] = @{ Path = $Cand; Kind = "Variant"; ConsoleUncomp = $Entry.UncompressedSize }
                }
            }
        }
    }

    $PcDirectMatches = 0
    $PcVariantMatches = 0
    $PcSameUncomp = 0
    foreach ($H in $PcInv.Keys) {
        if ($PcHashLookup.ContainsKey($H)) {
            $Info = $PcHashLookup[$H]
            if ($Info.Kind -eq "Direct") {
                $PcDirectMatches++
                if ($PcInv[$H].UncompressedSize -eq $Info.ConsoleUncomp) { $PcSameUncomp++ }
            } else {
                $PcVariantMatches++
            }
        }
    }

    Write-Host ("  Unique Files       : PS3 = {0:N0} | Xbox 360 = {1:N0} | PC (.datwin) = {2:N0}" -f $Ps3Inv.Count, $XboxInv.Count, $PcInv.Count) -ForegroundColor Yellow
    Write-Host ("  PS3 <-> Xbox 360   : {0:N0} shared paths ({1:P1} of Xbox 360)" -f $SharedConsole, ($SharedConsole / $XboxInv.Count)) -ForegroundColor Green
    Write-Host ("    Same UncompSize  : {0:N0} / {1:N0} ({2:P2})" -f $IdenticalUncomp, $SharedConsole, ($IdenticalUncomp / $SharedConsole))
    Write-Host ("    Same CompSize    : {0:N0} / {1:N0} ({2:P2})" -f $IdenticalComp, $SharedConsole, ($IdenticalComp / $SharedConsole))
    Write-Host ("    PS3-Only Paths   : {0:N0} (.cu2={1}, .msf={2})" -f $Ps3Only.Count, ($Ps3Only | Where-Object { $_ -match '\.cu2$' }).Count, ($Ps3Only | Where-Object { $_ -match '\.msf$' }).Count)
    Write-Host ("    Xbox-Only Paths  : {0:N0} (.cu2={1}, .xma={2})" -f $XboxOnly.Count, ($XboxOnly | Where-Object { $_ -match '\.cu2$' }).Count, ($XboxOnly | Where-Object { $_ -match '\.xma$' }).Count)
    Write-Host ("  Console <-> PC     : {0:N0} Direct + {1:N0} Remaster Variants = {2:N0} / {3:N0} ({4:P1} of PC)" -f $PcDirectMatches, $PcVariantMatches, ($PcDirectMatches + $PcVariantMatches), $PcInv.Count, (($PcDirectMatches + $PcVariantMatches) / $PcInv.Count)) -ForegroundColor Green
    Write-Host ("    PC Direct SameUncomp: {0:N0} / {1:N0} ({2:P1})" -f $PcSameUncomp, $PcDirectMatches, ($PcSameUncomp / $PcDirectMatches))
}

Compare-TitleAcrossPlatforms `
    -TitleName "LEGO Harry Potter: Years 1-4" `
    -Ps3Folder (Join-Path $Ps3Root "LEGO Harry Potter - Years 1-4 (Europe) (En,Fr,De,Es,It,Da) (v01.02)\PS3_GAME\USRDIR") `
    -XboxFolder (Join-Path $Xbox360Root "LEGO Harry Potter - Years 1-4 (USA, Europe) (En,Fr,De,Es,It,Da)") `
    -PcFolder (Join-Path $PcRoot "Years 1-4")

Compare-TitleAcrossPlatforms `
    -TitleName "LEGO Harry Potter: Years 5-7" `
    -Ps3Folder (Join-Path $Ps3Root "LEGO Harry Potter - Years 5-7 (Europe) (En,Fr,De,Es,It,Nl,Da)\PS3_GAME\USRDIR") `
    -XboxFolder (Join-Path $Xbox360Root "LEGO Harry Potter - Years 5-7 (USA) (En,Fr,De,Es,It,Nl,Pt,Da)") `
    -PcFolder (Join-Path $PcRoot "Years 5-7")

