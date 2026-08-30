<#
.SYNOPSIS
  02 - Write an autoinstall seed to a USB stick. Windows/PowerShell version.

.DESCRIPTION
  One template, one stick, rewritten per host. The seed is a FAT32 USB stick labelled CIDATA
  holding user-data and meta-data; cloud-init's NoCloud datasource finds it by that label.
  No ISO tooling needed. The Linux equivalent is 02-build-seed.sh.

  Per-host values come from -HostName and -Address. Everything shared - gateway, DNS, the
  password hash and the SSH key - comes from host-params.env, which is gitignored.

  Format the stick once (this is also where the label gets set):
      Format-Volume -DriveLetter F -FileSystem FAT32 -NewFileSystemLabel CIDATA

  Safety: refuses non-USB drives, the wrong filesystem, a wrong label, an Ed25519 key
  (FIPS mode rejects those), and any template placeholder left unsubstituted. Writes
  user-data with UNIX line endings - CRLF breaks cloud-init parsing.

.PARAMETER HostName
  Hostname for this seed, e.g. h1

.PARAMETER Address
  IPv4 address without prefix, e.g. 10.0.20.115

.PARAMETER DriveLetter
  Target USB drive letter, e.g. F. Omit with -DryRun.

.PARAMETER DryRun
  Print the resolved values and exit without writing.

.EXAMPLE
  .\02-build-seed.ps1 -HostName h1 -Address 10.0.20.115 -DriveLetter F

.EXAMPLE
  .\02-build-seed.ps1 -HostName h1 -Address 10.0.20.115 -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string] $HostName,
    [Parameter(Mandatory=$true)][string] $Address,
    [string] $DriveLetter,
    [string] $ParamsFile,
    [string] $Template,
    [switch] $DryRun
)

$ErrorActionPreference = "Stop"
function Die { param($m) Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ParamsFile) { $ParamsFile = Join-Path $here "02-host-autoinstall\host-params.env" }
if (-not $Template)   { $Template   = Join-Path $here "02-host-autoinstall\user-data.template" }

if ($Address -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    Die "-Address must be a bare IPv4 address, no prefix: $Address"
}
if (-not (Test-Path $Template))   { Die "template not found: $Template" }
if (-not (Test-Path $ParamsFile)) {
    Die "params file not found: $ParamsFile`n    Copy host-params.env.example to host-params.env and fill it in."
}

# --- read host-params.env -----------------------------------------------------------------
$P = @{}
foreach ($line in Get-Content $ParamsFile) {
    $l = $line.Trim()
    if ($l -eq "" -or $l.StartsWith("#")) { continue }
    $i = $l.IndexOf("=")
    if ($i -lt 1) { continue }
    $k = $l.Substring(0, $i).Trim()
    $v = $l.Substring($i + 1).Trim().Trim("'").Trim('"')
    $P[$k] = $v
}
foreach ($k in @("NIC_MATCH", "PREFIX", "GATEWAY", "DNS", "PASSWORD_HASH")) {
    if (-not $P.ContainsKey($k) -or -not $P[$k]) { Die "$k is unset in $ParamsFile" }
}
if (-not $P["PASSWORD_HASH"].StartsWith('$6$')) {
    Die "PASSWORD_HASH does not look like a SHA-512 crypt hash"
}

function Val($k, $default) {
    if ($P.ContainsKey($k) -and $P[$k]) { return $P[$k] } else { return $default }
}

$UserName       = Val "USERNAME" "encadmin"
$LvRoot         = Val "LV_ROOT" "40G"
$LvHome         = Val "LV_HOME" "10G"
$LvVar          = Val "LV_VAR" "30G"
$LvVarLog       = Val "LV_VARLOG" "20G"
$LvVarLogAudit  = Val "LV_VARLOGAUDIT" "20G"
$LvTmp          = Val "LV_TMP" "10G"

# --- disk encryption ---------------------------------------------------------------------
$Encrypt = (Val "ENCRYPT_DISKS" "true").ToLower()
if ($Encrypt -ne "true" -and $Encrypt -ne "false") {
    Die "ENCRYPT_DISKS must be true or false, got '$Encrypt'"
}
if ($Encrypt -eq "true") {
    $pass = Val "LUKS_PASSPHRASE" ""
    if (-not $pass)              { Die "ENCRYPT_DISKS=true but LUKS_PASSPHRASE is unset in $ParamsFile" }
    if ($pass -like "*REPLACE-ME*") { Die "LUKS_PASSPHRASE still holds a placeholder" }
    if ($pass.Length -lt 12)     { Die "LUKS_PASSPHRASE is under 12 characters" }
    $CryptOs   = "      - id: crypt-os`n        type: dm_crypt`n        dm_name: crypt-os`n        volume: p-pv`n        key: '$pass'`n"
    $CryptData = "      - id: crypt-data`n        type: dm_crypt`n        dm_name: crypt-data`n        volume: p-data`n        key: '$pass'`n"
    $Vg0Dev = "crypt-os"; $VgDataDev = "crypt-data"
    $EncSummary = "LUKS on both volume groups"
} else {
    $CryptOs = ""; $CryptData = ""
    $Vg0Dev = "p-pv"; $VgDataDev = "p-data"
    $EncSummary = "NONE - plaintext disks"
}

$AllowPw = (Val "ALLOW_PW" "true").ToLower()
if ($AllowPw -ne "true" -and $AllowPw -ne "false") {
    Die "ALLOW_PW must be true or false, got '$AllowPw'"
}

# Collect SSH_KEY_1..N, plus a legacy bare SSH_KEY. Each becomes one authorized-keys entry.
$keyNames = @("SSH_KEY") + (1..8 | ForEach-Object { "SSH_KEY_$_" })
$keys = @()
foreach ($n in $keyNames) {
    if (-not $P.ContainsKey($n)) { continue }
    $k = $P[$n]
    if (-not $k) { continue }
    if ($k.StartsWith("ssh-ed25519")) {
        Die "$n is Ed25519. FIPS mode refuses those - use RSA 3072+ or ECDSA."
    }
    if (-not ($k.StartsWith("ssh-rsa") -or $k.StartsWith("ecdsa-"))) {
        Die "$n does not look like an OpenSSH RSA or ECDSA public key"
    }
    $keys += $k
}
if ($keys.Count -eq 0) { Die "no SSH keys set in $ParamsFile - define SSH_KEY_1" }
$SshKeysYaml = ($keys | ForEach-Object { "      - '$_'" }) -join "`n"

# --- substitute ------------------------------------------------------------------------------
# .Replace() is literal. -replace would treat $ in the password hash as a capture group.
$raw = Get-Content -Path $Template -Raw
$raw = $raw.Replace("@@HOSTNAME@@",      $HostName)
$raw = $raw.Replace("@@ADDRESS@@",       $Address)
$raw = $raw.Replace("@@NIC_MATCH@@",     $P["NIC_MATCH"])
$raw = $raw.Replace("@@PREFIX@@",        $P["PREFIX"])
$raw = $raw.Replace("@@GATEWAY@@",       $P["GATEWAY"])
$raw = $raw.Replace("@@DNS@@",           $P["DNS"])
$raw = $raw.Replace("@@PASSWORD_HASH@@", $P["PASSWORD_HASH"])
$raw = $raw.Replace("@@ALLOW_PW@@",      $AllowPw)
$raw = $raw.Replace("@@SSH_KEYS@@",      $SshKeysYaml)
$raw = $raw.Replace("@@USERNAME@@",      $UserName)
$raw = $raw.Replace("@@LV_ROOT@@",       $LvRoot)
$raw = $raw.Replace("@@LV_HOME@@",       $LvHome)
$raw = $raw.Replace("@@LV_VAR@@",        $LvVar)
$raw = $raw.Replace("@@LV_VARLOG@@",     $LvVarLog)
$raw = $raw.Replace("@@LV_VARLOGAUDIT@@",$LvVarLogAudit)
$raw = $raw.Replace("@@LV_TMP@@",        $LvTmp)
$raw = $raw.Replace("@@CRYPT_OS@@",      $CryptOs)
$raw = $raw.Replace("@@CRYPT_DATA@@",    $CryptData)
$raw = $raw.Replace("@@VG0_DEV@@",       $Vg0Dev)
$raw = $raw.Replace("@@VGDATA_DEV@@",    $VgDataDev)

$left = ($raw -split "`n") | Where-Object { $_ -match '@@[A-Z0-9_]+@@' }
if ($left) {
    Write-Host "[x] unsubstituted placeholders remain:" -ForegroundColor Red
    $left | ForEach-Object { Write-Host "    $($_.Trim())" -ForegroundColor Red }
    exit 1
}

# --- pre-flight ---------------------------------------------------------------------------------

Write-Host ""
Write-Host "  Resolved values"
Write-Host "  ---------------"
Write-Host ("  hostname   {0}" -f $HostName)
Write-Host ("  address    {0}/{1}" -f $Address, $P["PREFIX"])
Write-Host ("  gateway    {0}" -f $P["GATEWAY"])
Write-Host ("  dns        {0}" -f $P["DNS"])
Write-Host ("  nic match  {0}" -f $P["NIC_MATCH"])
Write-Host ("  username   {0}" -f $UserName)
Write-Host  "  password   SET (sha512 crypt)"
Write-Host ("  allow-pw   {0}" -f $AllowPw)
Write-Host ("  encryption {0}" -f $EncSummary)
Write-Host ("  ssh keys   {0}" -f $keys.Count)
foreach ($k in $keys) {
    $parts = $k -split " "
    $label = if ($parts.Count -ge 3) { $parts[2] } else { "(no comment)" }
    Write-Host ("             {0}  {1}" -f $parts[0], $label)
}
Write-Host  "  OS disk    id_path *-ata-*   (SATA; never USB)"
Write-Host  "  data disk  id_path *-nvme-*  (NVMe)"
Write-Host ("  LV sizes   root={0} home={1} var={2} varlog={3} audit={4} tmp={5}" -f `
    $LvRoot, $LvHome, $LvVar, $LvVarLog, $LvVarLogAudit, $LvTmp)
Write-Host ""

if ($DryRun) { Write-Host "Dry run - nothing written."; exit 0 }
if (-not $DriveLetter) { Die "-DriveLetter is required (or use -DryRun)" }

# --- safety: removable target, right filesystem, right label -------------------------------------
$DriveLetter = $DriveLetter.TrimEnd(':').ToUpper()
$vol = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
if (-not $vol) { Die "no volume at ${DriveLetter}:" }
$disk = Get-Partition -DriveLetter $DriveLetter | Get-Disk

Write-Host ("  Target     {0}:  {1}  {2:N1} GB  bus={3}  fs={4}  label={5}" -f `
    $DriveLetter, $disk.FriendlyName, ($disk.Size/1GB), $disk.BusType, $vol.FileSystem, $vol.FileSystemLabel)
Write-Host ""

if ($disk.BusType -ne 'USB') {
    Die "${DriveLetter}: is not on a USB bus (BusType=$($disk.BusType)). Refusing."
}
if ($vol.FileSystem -ne 'FAT32' -and $vol.FileSystem -ne 'FAT') {
    Die "filesystem is '$($vol.FileSystem)', expected FAT32:`n    Format-Volume -DriveLetter $DriveLetter -FileSystem FAT32 -NewFileSystemLabel CIDATA"
}
# cloud-init accepts 'cidata' or 'CIDATA' - case does not matter.
if ($vol.FileSystemLabel -inotmatch '^cidata$') {
    Die "volume label is '$($vol.FileSystemLabel)', must be CIDATA:`n    Set-Volume -DriveLetter $DriveLetter -NewFileSystemLabel CIDATA"
}

# --- write, with UNIX line endings ----------------------------------------------------------------
$raw = $raw -replace "`r`n", "`n"
$enc = New-Object System.Text.UTF8Encoding($false)   # no BOM
[System.IO.File]::WriteAllText("${DriveLetter}:\user-data", $raw, $enc)
[System.IO.File]::WriteAllText("${DriveLetter}:\meta-data", "", $enc)

Write-Host "Wrote user-data and meta-data to ${DriveLetter}:" -ForegroundColor Green
Get-ChildItem "${DriveLetter}:\" | Select-Object Name, Length | Format-Table -AutoSize
Write-Host @'
Next:
  1. Insert BOTH sticks (Ubuntu installer + this one) and boot the installer.
  2. At GRUB press e, append "autoinstall" to the linux line, Ctrl-X.
     First run: omit "autoinstall" for a dry run that stops before touching disks.
  3. For the next host, re-run with -HostName h2 -Address <its address>
     and rewrite the same stick.
'@
