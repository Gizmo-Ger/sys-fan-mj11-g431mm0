<#
.NOTES
    One-time BMC prerequisite: this tool sweeps duty on an isolated
    'calibration' fan-profile collection so it never touches the live
    default/quiet profiles. That collection does not exist on a fresh BMC
    and must be created once, manually, before the first run:

        POST /api/settings/fanprofile/collection
        Body: {"strName":"calibration", ...same shape as an existing
               collection's arrPolicy, e.g. copy the active profile's
               arrPolicy array as a starting point}

    If the collection is missing, Invoke-FanSweep's preflight check throws
    a clear error naming this exact requirement instead of silently
    failing PUT calls against a nonexistent collection.
#>
param(
    [string]$BmcHost = '192.168.178.21',
    [pscredential]$Credential,
    [ValidateNotNullOrEmpty()][int[]]$DutySteps = @(20,30,40,50,60,70,80,90,100),
    [int]$BaselineDutyPercent = 50,
    [int]$SettleSeconds = 20,
    [string]$OutDir = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FanCalibration.psm1') -Force

if (-not $Credential) {
    $Credential = Get-Credential -Message "BMC-Zugangsdaten fuer $BmcHost"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath = Join-Path $OutDir "fan-calibration-$stamp.csv"

Write-Host "Verbinde mit $BmcHost ..."
$connection = Connect-Bmc -BmcHost $BmcHost -Credential $Credential

Write-Host "Starte Sweep: Duty-Stufen $($DutySteps -join ', ')%, Settle ${SettleSeconds}s, Baseline ${BaselineDutyPercent}%"
$rows = @()
Invoke-FanSweep -Connection $connection -BmcHost $BmcHost `
    -DutySteps $DutySteps -BaselineDutyPercent $BaselineDutyPercent -SettleSeconds $SettleSeconds |
    ForEach-Object {
        Write-Host ("{0,-6} {1,4}%  {2,-10} {3} RPM" -f $_.Zone, $_.DutyPercent, $_.FanName, $_.RPM)
        $rows += $_
    }

if (-not $rows) { throw "Sweep lieferte keine Messwerte." }

$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
Write-Host "Fertig. Ergebnisse: $csvPath"
