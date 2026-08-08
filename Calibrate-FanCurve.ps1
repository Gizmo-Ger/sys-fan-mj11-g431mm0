param(
    [string]$BmcHost = '192.168.178.21',
    [pscredential]$Credential,
    [int[]]$DutySteps = @(20,30,40,50,60,70,80,90,100),
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
$rows = Invoke-FanSweep -Connection $connection -BmcHost $BmcHost `
    -DutySteps $DutySteps -BaselineDutyPercent $BaselineDutyPercent -SettleSeconds $SettleSeconds

foreach ($row in $rows) {
    Write-Host ("{0,-6} {1,4}%  {2,-10} {3} RPM" -f $row.Zone, $row.DutyPercent, $row.FanName, $row.RPM)
}

$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
Write-Host "Fertig. Ergebnisse: $csvPath"
