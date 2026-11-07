<#
.SYNOPSIS
    Inspects the Xbox 360 Kiosk Demo of LEGO Harry Potter: Years 1-4 inside The.Experience.Disc.Version.5.5.iso.
.DESCRIPTION
    Locates the XDVDFS (MICROSOFT*XBOX*MEDIA) partition at offset 0x0FD90000, parses the PIRS (STFS)
    package container at offset 0x3EBAD000 (content/0000000000000000/575287FF/00080000/...),
    maps STFS data blocks to physical ISO offsets, and inspects the embedded Default.xex and
    GAME.DAT..GAME6.DAT (PakDat v1.01) archives.
#>
param(
    [string]$IsoPath = (Join-Path $PSScriptRoot "..\..\Source\Orginals\The Experience Disc Version 5.5 (Xbox 360)\The.Experience.Disc.Version.5.5.iso")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $IsoPath)) {
    Write-Error "ISO not found at: $IsoPath"
}

function ConvertFrom-BigEndianUInt32([byte[]]$Buffer, [int]$Offset) {
    return ([uint32]$Buffer[$Offset] -shl 24) -bor ([uint32]$Buffer[$Offset + 1] -shl 16) -bor ([uint32]$Buffer[$Offset + 2] -shl 8) -bor [uint32]$Buffer[$Offset + 3]
}

function ConvertFrom-Int24LE([byte[]]$Buffer, [int]$Offset) {
    return ([int]$Buffer[$Offset]) -bor ([int]$Buffer[$Offset + 1] -shl 8) -bor ([int]$Buffer[$Offset + 2] -shl 16)
}

function Get-PirsBlockOffset([long]$PackageBase, [int]$BlockIndex) {
    $NumL0 = [Math]::Floor($BlockIndex / 0xAA)
    $NumL1 = [Math]::Floor($BlockIndex / 0x70E4)
    $ExtraL1 = if ($BlockIndex -ge 0xAA) { 1 } else { 0 }
    $ExtraL2 = if ($BlockIndex -ge 0x70E4) { 1 } else { 0 }
    $PhysBlock = $BlockIndex + $NumL0 + $NumL1 + $ExtraL1 + $ExtraL2
    return $PackageBase + 0xC000L + ([long]$PhysBlock * 0x1000L)
}

$Stream = [System.IO.File]::OpenRead($IsoPath)
$Reader = New-Object System.IO.BinaryReader($Stream)

Write-Host "=== LEGO Harry Potter: Years 1-4 (Xbox 360 Kiosk Demo) Inspector ===" -ForegroundColor Cyan
Write-Host ("ISO File       : {0} ({1:N0} bytes)" -f $IsoPath, $Stream.Length)

$GamePartitionOffset = 0x0FD90000L
$Stream.Position = $GamePartitionOffset + (32 * 2048)
$XdvdfsMagic = [System.Text.Encoding]::ASCII.GetString($Reader.ReadBytes(20))
$RootSector = $Reader.ReadUInt32()
$RootSize = $Reader.ReadUInt32()
Write-Host ("XDVDFS Magic   : '{0}' at 0x{1:X8} (RootSector={2}, RootSize={3} B)" -f $XdvdfsMagic, ($GamePartitionOffset + 0x10000), $RootSector, $RootSize)

$PirsOffset = 0x3EBAD000L
$Stream.Position = $PirsOffset
$PirsHeader = $Reader.ReadBytes(0x600)
$PirsMagic = [System.Text.Encoding]::ASCII.GetString($PirsHeader, 0, 4)
$HeaderSize = ConvertFrom-BigEndianUInt32 $PirsHeader 0x340
$ContentType = ConvertFrom-BigEndianUInt32 $PirsHeader 0x344
$MediaId = ConvertFrom-BigEndianUInt32 $PirsHeader 0x354
$TitleId = ConvertFrom-BigEndianUInt32 $PirsHeader 0x360
$DisplayName = [System.Text.Encoding]::BigEndianUnicode.GetString($PirsHeader, 0x411, 128).Split([char]0)[0]

Write-Host "`n[PIRS STFS Container at ISO Offset 0x3EBAD000]" -ForegroundColor Yellow
Write-Host ("  Magic        : {0} (HeaderSize=0x{1:X4})" -f $PirsMagic, $HeaderSize)
Write-Host ("  Display Name : {0}" -f $DisplayName)
Write-Host ("  Title ID     : 0x{0:X8} | Media ID: 0x{1:X8} | ContentType: 0x{2:X8}" -f $TitleId, $MediaId, $ContentType)

$Stream.Position = $PirsOffset + 0xC000L
$FileTable = $Reader.ReadBytes(0x1000)

Write-Host "`n[Embedded Files in STFS Container]" -ForegroundColor Yellow
for ($i = 0; $i -lt 64; $i++) {
    $EntryOffset = $i * 0x40
    if ($FileTable[$EntryOffset] -eq 0) { break }
    $NameLen = $FileTable[$EntryOffset + 0x28] -band 0x3F
    $Name = [System.Text.Encoding]::ASCII.GetString($FileTable, $EntryOffset, $NameLen)
    $StartBlock = ConvertFrom-Int24LE $FileTable ($EntryOffset + 0x2F)
    $PathInd = ([int]$FileTable[$EntryOffset + 0x32] -shl 8) -bor [int]$FileTable[$EntryOffset + 0x33]
    $FileSize = ConvertFrom-BigEndianUInt32 $FileTable ($EntryOffset + 0x34)
    $DataIsoOffset = Get-PirsBlockOffset $PirsOffset $StartBlock

    $ExtraInfo = ""
    if ($Name -like "GAME*.DAT") {
        $Stream.Position = $DataIsoOffset
        $Hdr = $Reader.ReadBytes(52)
        $TocOff = [System.BitConverter]::ToUInt32($Hdr, 0)
        $TocSz = [System.BitConverter]::ToUInt32($Hdr, 4)
        $Sig = [System.Text.Encoding]::ASCII.GetString($Hdr, 8, 43).TrimEnd([char]0)
        $Valid = (($TocOff + $TocSz) -eq $FileSize)
        $ExtraInfo = " -> PakDat ($Sig) TocOff=0x$($TocOff.ToString('X8')) TocSz=0x$($TocSz.ToString('X6')) Valid=$Valid"
    } elseif ($Name -eq "Default.xex") {
        $Stream.Position = $DataIsoOffset
        $XexMagic = [System.Text.Encoding]::ASCII.GetString($Reader.ReadBytes(4))
        $ExtraInfo = " -> Executable Magic='$XexMagic'"
    }

    Write-Host ("  [{0}] {1,-14} StartBlock={2,6} ISO=0x{3:X9} Size={4,11:N0} B{5}" -f $i, $Name, $StartBlock, $DataIsoOffset, $FileSize, $ExtraInfo)
}

$Stream.Close()

