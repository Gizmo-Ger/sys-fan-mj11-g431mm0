param(
    [Parameter(Mandatory)][string]$BmcHost,
    [pscredential]$Credential,
    [ValidateNotNullOrEmpty()][int[]]$DutySteps = @(20,30,40,50,60,70,80,90,100),
    [int]$BaselineDutyPercent = 50,
    [int]$SettleSeconds = 20,
    [string]$OutDir = $PSScriptRoot,
    [switch]$NewDevice
)

<#
.NOTES
    Prerequisite (one-time, per BMC): the 'calibration' fan-profile collection
    must already exist before this script can write to it. If it doesn't yet,
    create it once with:

        $conn = Connect-Bmc -BmcHost $BmcHost -Credential (Get-Credential)
        New-CalibrationCollection -Connection $conn -BmcHost $BmcHost

    (see FanCalibration.md for the full walkthrough, including the raw REST
    fallback if you'd rather not import the module for this one-off step).
    Invoke-FanSweep will throw a clear error naming this requirement if it's
    missing.

    Zone configuration (which fan sensors share a PWM line, and which temp
    sensors drive them) is either read from an already-configured BMC's active
    profile, loaded from a saved bmc-zones-<BmcHost>.json, or gathered via an
    interactive wizard on first run against a fresh BMC. Use -NewDevice to
    force re-running the wizard (e.g. after swapping hardware).
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FanCalibration.psm1') -Force

if (-not $Credential) {
    $Credential = Get-Credential -Message "BMC credentials for $BmcHost"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath = Join-Path $OutDir "fan-calibration-$stamp.csv"
$zoneConfigPath = Join-Path $PSScriptRoot "bmc-zones-$BmcHost.json"

Write-Host "Connecting to $BmcHost ..."
$connection = Connect-Bmc -BmcHost $BmcHost -Credential $Credential

$fanProfile = Invoke-BmcApi -Connection $connection -BmcHost $BmcHost -Path '/api/settings/fanprofile' -Method 'Get'
$zones = Resolve-Zones -Connection $connection -BmcHost $BmcHost -FanProfileResponse $fanProfile `
    -ConfigPath $zoneConfigPath -NewDevice:$NewDevice

Write-Host "Zones: $($zones.Name -join ', ')"
Write-Host "Starting sweep: duty steps $($DutySteps -join ', ')%, settle ${SettleSeconds}s, baseline ${BaselineDutyPercent}%"

$rows = @()
Invoke-FanSweep -Connection $connection -BmcHost $BmcHost `
    -DutySteps $DutySteps -BaselineDutyPercent $BaselineDutyPercent -SettleSeconds $SettleSeconds -Zones $zones |
    ForEach-Object {
        Write-Host ("{0,-20} {1,4}%  {2,-10} {3} RPM" -f $_.Zone, $_.DutyPercent, $_.FanName, $_.RPM)
        $rows += $_
    }

if (-not $rows) {
    throw "Sweep produced no measurements."
}

$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
Write-Host "Done. Results: $csvPath"
