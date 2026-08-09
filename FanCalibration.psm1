function New-FlatCurvePolicy {
    param(
        [Parameter(Mandatory)][pscustomobject]$SourcePolicy,
        [Parameter(Mandatory)][int]$DutyPercent
    )
    $policy = $SourcePolicy | Select-Object *
    $policy.arrRef = @(0, 100)
    $policy.arrDuty = @($DutyPercent, $DutyPercent)
    $policy.iInitDuty = $DutyPercent
    return $policy
}

function Test-SentinelReading {
    param([Parameter(Mandatory)][pscustomobject]$Sensor)
    return $Sensor.raw_reading -eq 252
}

function Get-FanRpm {
    param(
        [Parameter(Mandatory)][array]$Sensors,
        [Parameter(Mandatory)][int]$SensorNumber
    )
    $sensor = $Sensors | Where-Object { $_.sensor_number -eq $SensorNumber } | Select-Object -First 1
    if (-not $sensor) { return $null }
    if (Test-SentinelReading -Sensor $sensor) { return $null }
    return [double]$sensor.reading
}

function Get-ZoneTemplate {
    param(
        [Parameter(Mandatory)][pscustomobject]$FanProfileResponse,
        [Parameter(Mandatory)][int]$FanSensorNumber
    )
    $activeProfile = $FanProfileResponse.arrProfile |
        Where-Object { $_.strName -eq $FanProfileResponse.strMode } |
        Select-Object -First 1
    if (-not $activeProfile) {
        throw "Aktives Profil '$($FanProfileResponse.strMode)' nicht in arrProfile gefunden."
    }
    $policy = $activeProfile.arrPolicy |
        Where-Object { $FanSensorNumber -in $_.arrFanSensor } |
        Select-Object -First 1
    if (-not $policy) {
        throw "Keine Policy fuer Fan-Sensor $FanSensorNumber im aktiven Profil gefunden."
    }
    return $policy
}

function New-CalibrationProfileBody {
    param(
        [Parameter(Mandatory)][pscustomobject]$CpuZonePolicy,
        [Parameter(Mandatory)][pscustomobject]$SystemZonePolicy
    )
    return [pscustomobject]@{
        strName    = 'calibration'
        strVersion = '1.00'
        arrPolicy  = @($CpuZonePolicy, $SystemZonePolicy)
    }
}

function New-CalibrationCsvRow {
    param(
        [Parameter(Mandatory)][string]$Zone,
        [Parameter(Mandatory)][int]$DutyPercent,
        [Parameter(Mandatory)][string]$FanName,
        [AllowNull()][Nullable[double]]$Rpm
    )
    $rpmValue = if ($null -eq $Rpm) { 'NA' } else { [string]$Rpm }
    return [pscustomobject]@{
        Zone        = $Zone
        DutyPercent = $DutyPercent
        FanName     = $FanName
        RPM         = $rpmValue
    }
}

function Connect-Bmc {
    param(
        [Parameter(Mandatory)][string]$BmcHost,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $body = @{
        username = $Credential.UserName
        password = $Credential.GetNetworkCredential().Password
    }
    $headers = @{ 'X-CSRFTOKEN' = 'null'; 'X-Requested-With' = 'XMLHttpRequest' }
    $response = Invoke-RestMethod -Uri "https://$BmcHost/api/session" -Method Post -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -Headers $headers `
        -SessionVariable bmcSession -SkipCertificateCheck -TimeoutSec 15

    if (-not $response.CSRFToken) {
        throw "BMC-Login fehlgeschlagen: keine CSRFToken in der Antwort."
    }
    return [pscustomobject]@{
        WebSession = $bmcSession
        CsrfToken  = $response.CSRFToken
    }
}

function Invoke-BmcApi {
    param(
        [Parameter(Mandatory)][pscustomobject]$Connection,
        [Parameter(Mandatory)][string]$BmcHost,
        [Parameter(Mandatory)][string]$Path,
        [string]$Method = 'Get',
        $Body = $null
    )
    $headers = @{ 'X-CSRFTOKEN' = $Connection.CsrfToken; 'X-Requested-With' = 'XMLHttpRequest' }
    $params = @{
        Uri                  = "https://$BmcHost$Path"
        Method               = $Method
        WebSession           = $Connection.WebSession
        Headers              = $headers
        SkipCertificateCheck = $true
        TimeoutSec           = 15
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
        $params.ContentType = 'application/json'
    }
    return Invoke-RestMethod @params
}

function Invoke-FanSweep {
    param(
        [Parameter(Mandatory)][pscustomobject]$Connection,
        [Parameter(Mandatory)][string]$BmcHost,
        [Parameter(Mandatory)][int[]]$DutySteps,
        [Parameter(Mandatory)][int]$BaselineDutyPercent,
        [Parameter(Mandatory)][int]$SettleSeconds,
        [scriptblock]$SleepCommand = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )

    $zones = @(
        @{ Name = 'CPU';    FanSensorNumbers = @(184) }
        @{ Name = 'System'; FanSensorNumbers = @(185, 186) }
    )
    $fanNames = @{ 184 = 'CPU0_FAN'; 185 = 'SYS_FAN1'; 186 = 'SYS_FAN2' }

    $fanProfile = Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost -Path '/api/settings/fanprofile' -Method 'Get'
    $originalMode = $fanProfile.strMode

    if ($originalMode -eq 'calibration') {
        throw "BMC steht noch auf 'calibration' (vorheriger Lauf abgebrochen). Bitte erst manuell auf 'quiet'/'default' zurueckschalten."
    }

    if (-not ($fanProfile.arrProfile | Where-Object { $_.strName -eq 'calibration' })) {
        throw "Profil 'calibration' existiert nicht auf dem BMC. Einmalig anlegen: POST /api/settings/fanprofile/collection mit Body {`"strName`":`"calibration`",...}"
    }

    $cpuTemplate = Get-ZoneTemplate -FanProfileResponse $fanProfile -FanSensorNumber 184
    $systemTemplate = Get-ZoneTemplate -FanProfileResponse $fanProfile -FanSensorNumber 185

    try {
        foreach ($zone in $zones) {
            foreach ($duty in $DutySteps) {
                $cpuDuty = if ($zone.Name -eq 'CPU') { $duty } else { $BaselineDutyPercent }
                $sysDuty = if ($zone.Name -eq 'System') { $duty } else { $BaselineDutyPercent }

                $cpuPolicy = New-FlatCurvePolicy -SourcePolicy $cpuTemplate -DutyPercent $cpuDuty
                $sysPolicy = New-FlatCurvePolicy -SourcePolicy $systemTemplate -DutyPercent $sysDuty
                $body = New-CalibrationProfileBody -CpuZonePolicy $cpuPolicy -SystemZonePolicy $sysPolicy

                Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost `
                    -Path '/api/settings/fanprofile/collection/calibration' -Method 'Put' -Body $body | Out-Null
                Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost `
                    -Path '/api/settings/fanprofile/mode' -Method 'Post' -Body @{ strMode = 'calibration' } | Out-Null

                & $SleepCommand $SettleSeconds

                $sensors = Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost -Path '/api/sensors' -Method 'Get'

                $rpmBySensor = @{}
                $missingSensorNumbers = @()
                foreach ($sensorNumber in $zone.FanSensorNumbers) {
                    $rpm = Get-FanRpm -Sensors $sensors -SensorNumber $sensorNumber
                    $rpmBySensor[$sensorNumber] = $rpm
                    if ($null -eq $rpm) { $missingSensorNumbers += $sensorNumber }
                }

                if ($missingSensorNumbers.Count -gt 0) {
                    & $SleepCommand 3
                    $retrySensors = Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost -Path '/api/sensors' -Method 'Get'
                    foreach ($sensorNumber in $missingSensorNumbers) {
                        $rpmBySensor[$sensorNumber] = Get-FanRpm -Sensors $retrySensors -SensorNumber $sensorNumber
                    }
                }

                foreach ($sensorNumber in $zone.FanSensorNumbers) {
                    New-CalibrationCsvRow -Zone $zone.Name -DutyPercent $duty `
                        -FanName $fanNames[$sensorNumber] -Rpm $rpmBySensor[$sensorNumber]
                }
            }
        }
    }
    finally {
        try {
            Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost `
                -Path '/api/settings/fanprofile/mode' -Method 'Post' -Body @{ strMode = $originalMode } | Out-Null
        }
        catch {
            Write-Warning "ACHTUNG: Modus konnte nicht auf '$originalMode' zurueckgesetzt werden - BMC laeuft weiter auf 'calibration'! Manuell zuruecksetzen. ($_)"
        }
    }
}

function Get-BmcInventory {
    param(
        [Parameter(Mandatory)][pscustomobject]$Connection,
        [Parameter(Mandatory)][string]$BmcHost
    )
    $sensors = Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost -Path '/api/sensors' -Method 'Get'
    $fanSensors = @($sensors | Where-Object { $_.type -eq 'fan' } | ForEach-Object {
        [pscustomobject]@{ sensor_number = $_.sensor_number; name = $_.name }
    })
    $tempSensors = @($sensors | Where-Object { $_.type -eq 'temperature' } | ForEach-Object {
        [pscustomobject]@{ sensor_number = $_.sensor_number; name = $_.name }
    })
    return [pscustomobject]@{
        FanSensors  = $fanSensors
        TempSensors = $tempSensors
    }
}

Export-ModuleMember -Function New-FlatCurvePolicy, Test-SentinelReading, Get-FanRpm, Get-ZoneTemplate, New-CalibrationProfileBody, New-CalibrationCsvRow, Connect-Bmc, Invoke-BmcApi, Invoke-FanSweep, Get-BmcInventory
