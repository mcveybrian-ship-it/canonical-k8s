<#
.SYNOPSIS
  00 - Fetch and verify the Ubuntu 24.04 base images. Windows/PowerShell version.

.DESCRIPTION
  Windows equivalent of 00-fetch-verify-media.sh, for the bootstrap case: you need the ISO
  before you have any Linux machine to run the bash version on.

  Downloads the Ubuntu Server ISO and the Minimal cloud image, verifies each against the
  published SHA256SUMS, and writes MANIFEST.sha256 for the evidence trail.

  LIMITATION - read this. This script verifies CHECKSUMS but not GPG SIGNATURES. It proves
  the download is intact; it does not prove SHA256SUMS itself is authentic. Windows has no
  gpg by default. Complete the signature check on the pathfinder machine once it is up:

      gpg --keyid-format long --keyserver hkp://keyserver.ubuntu.com `
          --recv-keys 0x46181433FBB75451 0xD94AA3F0EFE21092
      gpg --keyid-format long --verify SHA256SUMS.gpg SHA256SUMS

  For the ATO evidence package you want the signature check, not just the checksum.
  See docs/00-downloads.md.

.PARAMETER Dest
  Download directory. Default: .\media

.PARAMETER ServerOnly
  Fetch only the Ubuntu Server ISO (enough to start step 01).

.PARAMETER MinimalOnly
  Fetch only the Minimal cloud image.

.EXAMPLE
  .\00-fetch-verify-media.ps1 -ServerOnly
#>
[CmdletBinding()]
param(
    [string] $Dest = ".\media",
    [switch] $ServerOnly,
    [switch] $MinimalOnly
)

$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 still negotiates TLS 1.0 by default on some builds, which modern
# Canonical endpoints refuse. Force TLS 1.2 before any download.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Verified 2026-08-27. Point releases and image serials change - re-check the index pages.
$ServerBase  = "https://releases.ubuntu.com/noble"
$ServerIso   = "ubuntu-24.04.4-live-server-amd64.iso"
$MinimalBase = "https://cloud-images.ubuntu.com/minimal/releases/noble/release"
$MinimalImg  = "ubuntu-24.04-minimal-cloudimg-amd64.img"
$MinimalMan  = "ubuntu-24.04-minimal-cloudimg-amd64.manifest"

function Say  { param($m) Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Warn { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

function Get-RemoteFile {
    param($Base, $File, $Dir)

    $target = Join-Path $Dir $File
    if (Test-Path $target) {
        Write-Host "    already present, skipping: $File"
        return
    }
    $url = "$Base/$File"
    Write-Host "    downloading $File ..."

    # BITS is fastest and shows progress. Fall back to WebClient, which streams to disk
    # without buffering the whole file in memory the way Invoke-WebRequest can.
    $ok = $false
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $url -Destination $target -ErrorAction Stop
        $ok = $true
    } catch {
        Write-Host "    (BITS unavailable, falling back) "
    }

    if (-not $ok) {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($url, $target)
            $ok = $true
        } catch {
            Die "download failed: $url  ($($_.Exception.Message))"
        }
    }

    if (-not (Test-Path $target)) { Die "download produced no file: $url" }
}

function Test-Checksum {
    param($Dir, $File)

    $sumsPath = Join-Path $Dir "SHA256SUMS"
    if (-not (Test-Path $sumsPath)) { Die "SHA256SUMS not found in $Dir" }

    $line = Select-String -Path $sumsPath -Pattern ([regex]::Escape($File)) | Select-Object -First 1
    if (-not $line) { Die "$File is not listed in SHA256SUMS" }

    $expected = ($line.Line -split '\s+')[0].ToLower()
    Write-Host "    hashing $File ..."
    $actual = (Get-FileHash -Path (Join-Path $Dir $File) -Algorithm SHA256).Hash.ToLower()

    if ($expected -ne $actual) {
        Write-Host "    expected: $expected" -ForegroundColor Red
        Write-Host "    actual:   $actual"   -ForegroundColor Red
        Die "CHECKSUM MISMATCH on $File - do not use this file"
    }
    Write-Host "    checksum OK: $File" -ForegroundColor Green
}

if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest | Out-Null }
$Dest = (Resolve-Path $Dest).Path
Say "Working in $Dest"

if (-not $MinimalOnly) {
    Say "Ubuntu Server 24.04.4 LTS - installer ISO, 3.2 GB"
    Get-RemoteFile $ServerBase $ServerIso       $Dest
    Get-RemoteFile $ServerBase "SHA256SUMS"     $Dest
    Get-RemoteFile $ServerBase "SHA256SUMS.gpg" $Dest
    Test-Checksum $Dest $ServerIso
}

if (-not $ServerOnly) {
    Say "Ubuntu Minimal 24.04 - cloud image, 253 MB"
    $mdir = Join-Path $Dest "minimal"
    if (-not (Test-Path $mdir)) { New-Item -ItemType Directory -Path $mdir | Out-Null }
    Get-RemoteFile $MinimalBase $MinimalImg      $mdir
    Get-RemoteFile $MinimalBase $MinimalMan      $mdir
    Get-RemoteFile $MinimalBase "SHA256SUMS"     $mdir
    Get-RemoteFile $MinimalBase "SHA256SUMS.gpg" $mdir
    Test-Checksum $mdir $MinimalImg
    $pkgs = (Get-Content (Join-Path $mdir $MinimalMan)).Count
    Write-Host "    package count in image: $pkgs"
}

Say "Writing manifest"
$manifest = Join-Path $Dest "MANIFEST.sha256"
$stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add("# Ubuntu 24.04 media manifest")
[void]$lines.Add("# generated: $stamp")
[void]$lines.Add("# host:      $env:COMPUTERNAME")
[void]$lines.Add("# sources:   $ServerBase")
[void]$lines.Add("#            $MinimalBase")
[void]$lines.Add("# NOTE: checksums verified; GPG signatures NOT verified on Windows.")
[void]$lines.Add("")

Get-ChildItem -Path $Dest -Recurse -Include *.iso,*.img,*.manifest |
    Sort-Object FullName |
    ForEach-Object {
        $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
        $rel = $_.FullName.Substring($Dest.Length).TrimStart("\")
        [void]$lines.Add("$h  $rel")
    }

$lines | Set-Content -Path $manifest -Encoding utf8
Get-Content $manifest

Say "Done. Manifest: $manifest"
Warn "GPG signature verification still outstanding - complete it on the pathfinder machine."

Write-Host @'

Next:
  1. Write the ISO to a USB stick (Rufus, balenaEtcher, or Ventoy).
  2. Install Ubuntu Server 24.04.4 on the bare-metal pathfinder machine (interactive is fine).
  3. Run 01-hw-inventory.sh and 01-capability-test.sh there.   <-- that is step 01
'@
