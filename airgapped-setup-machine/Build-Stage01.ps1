<#
.SYNOPSIS
  Provision STAGE-01 - the online mirror builder and development workstation.

.DESCRIPTION
  Wrapper around schtritoff/hyperv-vm-provisioning's New-HyperVCloudImageVM.ps1. Runs on the
  Hyper-V host (Windows Server 2022 on the R7515), not on STAGE-01 itself.

  What it does:
    1. reads stage-01-userdata.yaml, substitutes the SSH public key and password hash
    2. writes a temporary user-data file
    3. calls New-HyperVCloudImageVM.ps1 with the sizing from README.md section 4.2
    4. deletes the temporary file, which contains the password hash

  Why a wrapper rather than typed-out parameters: the build has to be reproducible and
  reviewable. Every value that matters is in one place and under version control.

  PREREQUISITES on the Hyper-V host:
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Tools-All -All
    git clone https://github.com/schtritoff/hyperv-vm-provisioning

  Use ImageVersion 24.04, NOT 24.04-azure. Azure images need conversion to NoCloud, which
  requires Windows 11 build 22000+. Server 2022 is build 20348, so that path does not exist
  on this host.

.PARAMETER ProvisioningScript
  Path to New-HyperVCloudImageVM.ps1 from the cloned repo.

.PARAMETER SshPubKeyFile
  Public key to install for encadmin. RSA or ECDSA - kept consistent with the enclave hosts,
  where FIPS mode refuses Ed25519.

.PARAMETER PasswordHash
  SHA-512 crypt hash for the console fallback account. Generate with:
      mkpasswd --method=SHA-512 --rounds=4096      (Linux, whois package)
      openssl passwd -6                            (Git Bash on Windows)

.PARAMETER NetAddress
  Static IPv4 for STAGE-01, in CIDR form: 10.0.20.160/24. If you pass a bare address the
  prefix is derived from -NetNetmask and appended, because netplan requires CIDR and the
  provisioning script does no conversion of its own. Omit entirely for DHCP.

.PARAMETER SwitchName
  Hyper-V virtual switch, passed through as -VirtualSwitchName. Must reach the internet -
  STAGE-01 syncs from Canonical.

.PARAMETER NetConfigType
  Optional. ENI, v1, v2, ENI-file or dhclient. Leave empty: the provisioning script defaults
  to v2 (netplan) whenever a static address is supplied, which is correct for Ubuntu 24.04.

.PARAMETER StoragePath
  Where the VM definition and the VHDX land. One path controls both: the definition goes here,
  the disk goes to <StoragePath>\<VMName>\Virtual Hard Disks\. Defaults to G:\Hyper-V.

.PARAMETER DryRun
  Print the resolved command and exit without provisioning.

.EXAMPLE
  .\Build-Stage01.ps1 -ProvisioningScript C:\src\hyperv-vm-provisioning\New-HyperVCloudImageVM.ps1 `
                      -SshPubKeyFile $env:USERPROFILE\.ssh\enclave_admin.pub `
                      -PasswordHash '$6$...' -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string] $ProvisioningScript,
    [Parameter(Mandatory=$true)][string] $SshPubKeyFile,
    [Parameter(Mandatory=$true)][string] $PasswordHash,
    [string] $VMName            = "STAGE-01",
    [string] $NetAddress        = "",
    [string] $NetGateway        = "",
    [string] $NetNetmask        = "255.255.255.0",
    [string] $SwitchName        = "",
    [string] $NetConfigType     = "",
    [uint64] $VHDSizeBytes      = 1TB,
    [int]    $VMProcessorCount  = 8,
    [uint64] $VMMemoryBytes     = 16GB,
    [string] $StoragePath       = "G:\Hyper-V",
    [switch] $DryRun
)

$ErrorActionPreference = "Stop"
function Die { param($m) Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$template = Join-Path $here "stage-01-userdata.yaml"

if (-not (Test-Path $template))           { Die "template not found: $template" }
if (-not (Test-Path $ProvisioningScript)) { Die "provisioning script not found: $ProvisioningScript" }
if (-not (Test-Path $SshPubKeyFile))      { Die "ssh public key not found: $SshPubKeyFile" }

$key = (Get-Content $SshPubKeyFile -Raw).Trim()
if ($key.StartsWith("ssh-ed25519")) {
    Die "That key is Ed25519. Use RSA 3072+ or ECDSA, to stay consistent with the FIPS enclave hosts."
}
if (-not ($key.StartsWith("ssh-rsa") -or $key.StartsWith("ecdsa-"))) {
    Die "Does not look like an OpenSSH public key: $SshPubKeyFile"
}
if (-not $PasswordHash.StartsWith('$6$')) {
    Die "PasswordHash does not look like a SHA-512 crypt hash (should start with `$6`$)"
}

# --- network address must be CIDR ---------------------------------------------------------
# New-HyperVCloudImageVM.ps1 drops $NetAddress verbatim into the netplan v2 'addresses:' list
# and never uses $NetNetmask for v2 - that parameter only applies to the older v1 format. A
# bare address like 10.0.20.160 is invalid netplan: the config is rejected, the interface
# never comes up, and the VM boots with no network at all.
if ($NetAddress -and $NetAddress -notmatch '/\d+$') {
    $bits = ($NetNetmask.Split('.') | ForEach-Object { [Convert]::ToString([int]$_, 2) }) -join ''
    $prefix = ($bits -replace '0', '').Length
    if ($prefix -lt 1 -or $prefix -gt 32) { Die "cannot derive a prefix from NetNetmask '$NetNetmask' - pass -NetAddress in CIDR form, e.g. 10.0.20.160/24" }
    $NetAddress = "$NetAddress/$prefix"
    Write-Host ("[i] NetAddress had no prefix; using {0} from netmask {1}" -f $NetAddress, $NetNetmask) -ForegroundColor Yellow
}

# --- render the user-data ---------------------------------------------------------------------
# .Replace() is literal; -replace would treat $ in the hash as a capture group.
$raw = Get-Content $template -Raw
$raw = $raw.Replace("@@SSH_KEY@@", $key)
$raw = $raw.Replace("@@PASSWORD_HASH@@", $PasswordHash)

$left = ($raw -split "`n") | Where-Object { $_ -match '@@[A-Z0-9_]+@@' }
if ($left) {
    Write-Host "[x] unsubstituted placeholders remain:" -ForegroundColor Red
    $left | ForEach-Object { Write-Host "    $($_.Trim())" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "  STAGE-01 build"
Write-Host "  --------------"
Write-Host ("  vm name    {0}" -f $VMName)
Write-Host ("  image      24.04  (NOT -azure: needs Win11 22000+, this host is Server 2022)")
Write-Host ("  cpu / ram  {0} vCPU / {1} GB" -f $VMProcessorCount, ($VMMemoryBytes/1GB))
Write-Host ("  disk       {0} GB" -f ($VHDSizeBytes/1GB))
Write-Host ("  network    {0}" -f $(if ($NetAddress) { "$NetAddress gw $NetGateway" } else { "DHCP" }))
Write-Host ("  switch     {0}" -f $(if ($SwitchName) { $SwitchName } else { "auto-detect" }))
Write-Host ("  netconfig  {0}" -f $(if ($NetConfigType) { $NetConfigType } else { "v2 (script default for static)" }))
Write-Host ("  ssh key    {0}" -f ($key -split " ")[0])
Write-Host ("  password   SET (sha512 crypt)")
Write-Host ("  userdata   {0}" -f $template)
Write-Host ("  storage    {0}" -f $StoragePath)
Write-Host ("             VHDX -> {0}\{1}\Virtual Hard Disks\{1}.vhdx" -f $StoragePath, $VMName)
Write-Host ""

if ($DryRun) { Write-Host "Dry run - nothing provisioned."; exit 0 }

# --- escape for the provisioning script's ExpandString() -------------------------------------
# New-HyperVCloudImageVM.ps1 runs the user-data through:
#     $ExecutionContext.InvokeCommand.ExpandString( Get-Content $CustomUserDataYamlFile -Raw )
# That is PowerShell variable expansion over the whole YAML. Unescaped, a SHA-512 crypt hash
# like $6$salt$hash is read as the variables $6, $salt and $hash and expands to nothing - the
# password is silently destroyed and the account becomes unusable. Same for cloud-init tokens
# such as $UPTIME.
#
# Escape backticks first, then dollars. Order matters: doing dollars first would double-escape
# the backticks this step introduces.
$escaped = $raw.Replace('`', '``').Replace('$', '`$')

$dollars = ([regex]::Matches($raw, '\$')).Count
Write-Host ("  escaped    {0} literal '$' for ExpandString" -f $dollars)
Write-Host ""

# Temp file holds the password hash - remove it whatever happens.
$tmp = Join-Path $env:TEMP ("stage-01-userdata-{0}.yaml" -f (Get-Random))
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tmp, ($escaped -replace "`r`n", "`n"), $enc)

try {
    $args = @{
        VMName                = $VMName
        ImageVersion          = "24.04"
        VMGeneration          = 2
        VMProcessorCount      = $VMProcessorCount
        VMMemoryStartupBytes  = $VMMemoryBytes
        VHDSizeBytes          = $VHDSizeBytes
        CustomUserDataYamlFile= $tmp
        VMMachine_StoragePath = $StoragePath
        KeyboardLayout        = "en"
        ShowSerialConsoleWindow = $true
    }
    if ($SwitchName)    { $args["VirtualSwitchName"] = $SwitchName }
    if ($NetConfigType) { $args["NetConfigType"]     = $NetConfigType }
    if ($NetAddress) {
        $args["NetAddress"] = $NetAddress
        $args["NetNetmask"] = $NetNetmask
        $args["NetGateway"] = $NetGateway
    }

    & $ProvisioningScript @args
}
finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host @'
Next:
  1. ssh encadmin@<address>
  2. df -h /            confirm the root filesystem filled the disk
  3. git clone this repo, run the scripts natively
  4. Attach the PAID Pro token, then airgap-update-lab.md section 5
'@
