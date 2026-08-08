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

Export-ModuleMember -Function New-FlatCurvePolicy, Test-SentinelReading, Get-FanRpm, Get-ZoneTemplate, New-CalibrationProfileBody, New-CalibrationCsvRow, Connect-Bmc, Invoke-BmcApi
