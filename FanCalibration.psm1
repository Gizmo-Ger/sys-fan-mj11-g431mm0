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
        [Parameter(Mandatory)][pscustomobject]$Zone
    )
    $activeProfile = $FanProfileResponse.arrProfile |
        Where-Object { $_.strName -eq $FanProfileResponse.strMode } |
        Select-Object -First 1

    if ($activeProfile) {
        $policy = $activeProfile.arrPolicy | Where-Object {
            $policyFans = @($_.arrFanSensor)
            @($Zone.FanSensors | Where-Object { $_ -in $policyFans }).Count -gt 0
        } | Select-Object -First 1
        if ($policy) { return $policy }
    }

    return [pscustomobject]@{
        iPolicyType        = 2
        iInSDR             = 1
        iSensorCode        = if (@($Zone.TempSensors).Count -gt 1) { 3 } else { 1 }
        iInitDuty          = 40
        iCpuTdp            = 0
        iAmbientSensor     = 0
        iAmbientSensorTemp = 0
        arrSensor          = @($Zone.TempSensors)
        arrFanSensor       = @($Zone.FanSensors)
        arrRef             = @()
        arrDuty            = @()
        arrHexVendorID     = @()
        arrHexDeviceID     = @()
        iPCIEDeviceEnable  = 0
        iHysteresis        = 0
    }
}

function New-CalibrationProfileBody {
    param(
        [Parameter(Mandatory)][array]$ZonePolicies
    )
    return [pscustomobject]@{
        strName    = 'calibration'
        strVersion = '1.00'
        arrPolicy  = @($ZonePolicies)
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
        [Parameter(Mandatory)][array]$Zones,
        [scriptblock]$SleepCommand = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )

    $fanProfile = Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost -Path '/api/settings/fanprofile' -Method 'Get'
    $originalMode = $fanProfile.strMode

    if ($originalMode -eq 'calibration') {
        throw "BMC steht noch auf 'calibration' (vorheriger Lauf abgebrochen). Bitte erst manuell auf 'quiet'/'default' zurueckschalten."
    }
    if (-not ($fanProfile.arrProfile | Where-Object { $_.strName -eq 'calibration' })) {
        throw "Profil 'calibration' existiert nicht auf dem BMC. Einmalig anlegen: POST /api/settings/fanprofile/collection mit Body {`"strName`":`"calibration`",...}"
    }

    $zoneTemplates = @($Zones | ForEach-Object { Get-ZoneTemplate -FanProfileResponse $fanProfile -Zone $_ })

    try {
        for ($zoneUnderTestIndex = 0; $zoneUnderTestIndex -lt $Zones.Count; $zoneUnderTestIndex++) {
            $zoneUnderTest = $Zones[$zoneUnderTestIndex]
            foreach ($duty in $DutySteps) {
                $zonePolicies = for ($i = 0; $i -lt $Zones.Count; $i++) {
                    $d = if ($i -eq $zoneUnderTestIndex) { $duty } else { $BaselineDutyPercent }
                    New-FlatCurvePolicy -SourcePolicy $zoneTemplates[$i] -DutyPercent $d
                }
                $body = New-CalibrationProfileBody -ZonePolicies $zonePolicies

                Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost `
                    -Path '/api/settings/fanprofile/collection/calibration' -Method 'Put' -Body $body | Out-Null
                Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost `
                    -Path '/api/settings/fanprofile/mode' -Method 'Post' -Body @{ strMode = 'calibration' } | Out-Null

                & $SleepCommand $SettleSeconds

                $sensors = Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost -Path '/api/sensors' -Method 'Get'

                $missingSensorNumbers = @($zoneUnderTest.FanSensors | Where-Object {
                    $null -eq (Get-FanRpm -Sensors $sensors -SensorNumber $_)
                })
                if ($missingSensorNumbers.Count -gt 0) {
                    & $SleepCommand 3
                    $retrySensors = Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost -Path '/api/sensors' -Method 'Get'
                    foreach ($sensorNumber in $missingSensorNumbers) {
                        $retryReading = $retrySensors | Where-Object { $_.sensor_number -eq $sensorNumber } | Select-Object -First 1
                        if ($retryReading -and $null -ne (Get-FanRpm -Sensors $retrySensors -SensorNumber $sensorNumber)) {
                            $sensors = @($sensors | Where-Object { $_.sensor_number -ne $sensorNumber }) + @($retryReading)
                        }
                    }
                }

                foreach ($sensorNumber in $zoneUnderTest.FanSensors) {
                    $sensorObj = $sensors | Where-Object { $_.sensor_number -eq $sensorNumber } | Select-Object -First 1
                    $fanName = if ($sensorObj) { $sensorObj.name } else { "sensor$sensorNumber" }
                    $rpm = Get-FanRpm -Sensors $sensors -SensorNumber $sensorNumber
                    New-CalibrationCsvRow -Zone $zoneUnderTest.Name -DutyPercent $duty -FanName $fanName -Rpm $rpm
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

function Read-ZoneConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    try {
        $parsed = @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }
    catch {
        throw "Zonen-Config '$Path' konnte nicht gelesen werden (ungueltiges JSON): $_"
    }
    foreach ($entry in $parsed) {
        if ($null -eq $entry.Name -or $entry.FanSensors -isnot [array] -or $entry.TempSensors -isnot [array]) {
            throw "Zonen-Config '$Path' ist fehlerhaft: jeder Eintrag braucht Name, FanSensors (Array) und TempSensors (Array)."
        }
    }
    return $parsed
}

function Save-ZoneConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Zones
    )
    ConvertTo-Json -InputObject $Zones -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-ZonesFromProfile {
    param(
        [Parameter(Mandatory)][pscustomobject]$FanProfileResponse,
        [Parameter(Mandatory)][pscustomobject]$Inventory
    )
    $activeProfile = $FanProfileResponse.arrProfile |
        Where-Object { $_.strName -eq $FanProfileResponse.strMode } |
        Select-Object -First 1
    if (-not $activeProfile -or @($activeProfile.arrPolicy).Count -eq 0) {
        return $null
    }

    $zones = foreach ($policy in $activeProfile.arrPolicy) {
        $fanSensors = @($policy.arrFanSensor)
        $names = foreach ($fs in $fanSensors) {
            $match = $Inventory.FanSensors | Where-Object { $_.sensor_number -eq $fs } | Select-Object -First 1
            if ($match) { $match.name } else { "sensor$fs" }
        }
        [pscustomobject]@{
            Name        = ($names -join '+')
            FanSensors  = $fanSensors
            TempSensors = @($policy.arrSensor)
        }
    }
    return @($zones)
}

function Read-ZoneWizard {
    param([Parameter(Mandatory)][pscustomobject]$Inventory)

    Write-Host 'Fan-Sensoren:'
    foreach ($f in $Inventory.FanSensors) { Write-Host ("  {0}: {1}" -f $f.sensor_number, $f.name) }
    Write-Host 'Temp-Sensoren:'
    foreach ($t in $Inventory.TempSensors) { Write-Host ("  {0}: {1}" -f $t.sensor_number, $t.name) }

    $zones = @()
    $assignedFans = @()
    $allFanNumbers = @($Inventory.FanSensors.sensor_number)

    while (@($allFanNumbers | Where-Object { $_ -notin $assignedFans }).Count -gt 0) {
        $name = Read-Host 'Zone-Name (leer = fertig)'
        if ([string]::IsNullOrWhiteSpace($name)) { break }

        $fanInput = Read-Host 'Fan-Sensor-Nummern (kommagetrennt)'
        $fanNums = @($fanInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object {
            $parsed = 0
            if ([int]::TryParse($_, [ref]$parsed)) {
                $parsed
            } else {
                Write-Warning "Ungueltige Sensor-Nummer ignoriert: '$_'"
            }
        })

        $tempInput = Read-Host 'Temp-Sensor-Nummern (kommagetrennt, optional)'
        $tempNums = @($tempInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object {
            $parsed = 0
            if ([int]::TryParse($_, [ref]$parsed)) {
                $parsed
            } else {
                Write-Warning "Ungueltige Sensor-Nummer ignoriert: '$_'"
            }
        })

        $zones += [pscustomobject]@{ Name = $name; FanSensors = $fanNums; TempSensors = $tempNums }
        $assignedFans += $fanNums
    }

    $unassigned = @($allFanNumbers | Where-Object { $_ -notin $assignedFans })
    if ($unassigned.Count -gt 0) {
        Write-Warning "Folgende Fan-Sensoren wurden keiner Zone zugeordnet: $($unassigned -join ', ')"
    }

    # Use the unary comma operator to keep this a single array object on the
    # pipeline. A plain `return @($zones)` unrolls an empty array to zero
    # pipeline objects, which the caller sees as $null instead of @().
    return ,@($zones)
}

function Resolve-Zones {
    param(
        [Parameter(Mandatory)][pscustomobject]$Connection,
        [Parameter(Mandatory)][string]$BmcHost,
        [Parameter(Mandatory)][pscustomobject]$FanProfileResponse,
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$NewDevice,
        [scriptblock]$ConfirmCommand = { param($Message) Read-Host $Message },
        [scriptblock]$WizardCommand = { param($Inventory) Read-ZoneWizard -Inventory $Inventory }
    )

    $existing = Read-ZoneConfig -Path $ConfigPath
    $result = $null

    if ($existing -and -not $NewDevice) {
        $result = $existing
    }
    elseif ($existing -and $NewDevice) {
        $answer = & $ConfirmCommand 'Bestehende Zonen-Config gefunden, wirklich ueberschreiben? (j/n)'
        if ($answer -ne 'j') {
            $result = $existing
        }
    }

    if (-not $result) {
        $inventory = Get-BmcInventory -Connection $Connection -BmcHost $BmcHost

        $derived = $null
        if (-not $NewDevice) {
            $derived = New-ZonesFromProfile -FanProfileResponse $FanProfileResponse -Inventory $inventory
        }

        if ($derived) {
            Save-ZoneConfig -Path $ConfigPath -Zones $derived
            $result = $derived
        }
        else {
            $wizardZones = & $WizardCommand $inventory
            if ($null -eq $wizardZones -or @($wizardZones).Count -eq 0) {
                if (@($inventory.FanSensors).Count -eq 0) {
                    throw "BMC meldet keine Fan-Sensoren - Zonen-Konfiguration nicht moeglich."
                }
                throw "Zonen-Assistent abgebrochen - keine Zonen konfiguriert."
            }
            Save-ZoneConfig -Path $ConfigPath -Zones $wizardZones
            $result = $wizardZones
        }
    }

    # Single choke point for all 4 return paths above: reject duplicate zone
    # Names here, since Invoke-FanSweep's index-based fix avoids data
    # corruption but duplicate names are still confusing/wrong in CSV output.
    $duplicateNames = @($result | Group-Object -Property Name | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($duplicateNames.Count -gt 0) {
        throw "Zonen-Konfiguration enthaelt doppelte Zonen-Namen: $($duplicateNames -join ', ')"
    }

    return $result
}

Export-ModuleMember -Function New-FlatCurvePolicy, Test-SentinelReading, Get-FanRpm, Get-ZoneTemplate, New-CalibrationProfileBody, New-CalibrationCsvRow, Connect-Bmc, Invoke-BmcApi, Invoke-FanSweep, Get-BmcInventory, Read-ZoneConfig, Save-ZoneConfig, New-ZonesFromProfile, Read-ZoneWizard, Resolve-Zones
