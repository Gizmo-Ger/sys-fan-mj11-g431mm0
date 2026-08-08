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

Export-ModuleMember -Function New-FlatCurvePolicy, Test-SentinelReading, Get-FanRpm, Get-ZoneTemplate, New-CalibrationProfileBody
