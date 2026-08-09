Import-Module (Join-Path $PSScriptRoot 'FanCalibration.psm1') -Force

Describe 'New-FlatCurvePolicy' {
    It 'flattens arrRef/arrDuty to a constant duty and preserves other fields' {
        $source = [pscustomobject]@{
            iPolicyType = 2; iInSDR = 1; iSensorCode = 1; iInitDuty = 40; iCpuTdp = 0
            iAmbientSensor = 0; iAmbientSensorTemp = 0
            arrSensor = @(1); arrFanSensor = @(184)
            arrRef = @(30,36,40,44,48,52,56,60,62,63,64,70,76)
            arrDuty = @(25,26,28,31,34,38,42,47,52,60,70,85,100)
            arrHexVendorID = @(); arrHexDeviceID = @()
            iPCIEDeviceEnable = 0; iHysteresis = 3
        }

        $result = New-FlatCurvePolicy -SourcePolicy $source -DutyPercent 50

        $result.arrRef | Should -Be @(0,100)
        $result.arrDuty | Should -Be @(50,50)
        $result.iInitDuty | Should -Be 50
        $result.arrFanSensor | Should -Be @(184)
        $result.arrSensor | Should -Be @(1)
        $result.iSensorCode | Should -Be 1
        $result.iHysteresis | Should -Be 3
    }
}

Describe 'Test-SentinelReading' {
    It 'flags the known sentinel raw_reading value' {
        Test-SentinelReading -Sensor ([pscustomobject]@{ raw_reading = 252; reading = -4.0 }) | Should -BeTrue
    }
    It 'does not flag a normal reading' {
        Test-SentinelReading -Sensor ([pscustomobject]@{ raw_reading = 60; reading = 60.0 }) | Should -BeFalse
    }
}

Describe 'Get-FanRpm' {
    BeforeAll {
        $sensors = @(
            [pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN'; raw_reading = 9; reading = 1350.0 }
            [pscustomobject]@{ sensor_number = 185; name = 'SYS_FAN1'; raw_reading = 0; reading = 0.0 }
            [pscustomobject]@{ sensor_number = 186; name = 'SYS_FAN2'; raw_reading = 252; reading = 0.0 }
        )
    }

    It 'returns the RPM for a healthy reading' {
        Get-FanRpm -Sensors $sensors -SensorNumber 184 | Should -Be 1350.0
    }
    It 'returns 0 for a genuinely stopped fan (not a sentinel)' {
        Get-FanRpm -Sensors $sensors -SensorNumber 185 | Should -Be 0.0
    }
    It 'returns $null for a sentinel reading' {
        Get-FanRpm -Sensors $sensors -SensorNumber 186 | Should -BeNullOrEmpty
    }
    It 'returns $null when the sensor number is not present' {
        Get-FanRpm -Sensors $sensors -SensorNumber 999 | Should -BeNullOrEmpty
    }
}

Describe 'Get-ZoneTemplate' {
    BeforeAll {
        $fanProfileResponse = [pscustomobject]@{
            strMode = 'quiet'
            strVersion = '1.00'
            arrProfile = @(
                [pscustomobject]@{
                    strName = 'default'; strVersion = '1.00'
                    arrPolicy = @([pscustomobject]@{ arrFanSensor = @(184); arrSensor = @(1) })
                }
                [pscustomobject]@{
                    strName = 'quiet'; strVersion = '1.00'
                    arrPolicy = @(
                        [pscustomobject]@{ arrFanSensor = @(184); arrSensor = @(1); iSensorCode = 1 }
                        [pscustomobject]@{ arrFanSensor = @(185,186); arrSensor = @(4,8,14,16); iSensorCode = 3 }
                    )
                }
            )
        }
    }

    It 'finds the CPU zone policy in the active profile' {
        $result = Get-ZoneTemplate -FanProfileResponse $fanProfileResponse -FanSensorNumber 184
        $result.arrFanSensor | Should -Be @(184)
        $result.iSensorCode | Should -Be 1
    }
    It 'finds the System zone policy in the active profile' {
        $result = Get-ZoneTemplate -FanProfileResponse $fanProfileResponse -FanSensorNumber 185
        $result.arrFanSensor | Should -Be @(185,186)
        $result.iSensorCode | Should -Be 3
    }
    It 'throws when no policy matches the requested fan sensor' {
        { Get-ZoneTemplate -FanProfileResponse $fanProfileResponse -FanSensorNumber 999 } | Should -Throw
    }
    It 'throws when the active profile is not found in arrProfile' {
        $badResponse = [pscustomobject]@{
            strMode = 'nonexistent'
            strVersion = '1.00'
            arrProfile = $fanProfileResponse.arrProfile
        }
        { Get-ZoneTemplate -FanProfileResponse $badResponse -FanSensorNumber 184 } | Should -Throw
    }
}

Describe 'New-CalibrationProfileBody' {
    It 'builds the calibration collection body from two zone policies' {
        $cpu = [pscustomobject]@{ arrFanSensor = @(184) }
        $sys = [pscustomobject]@{ arrFanSensor = @(185,186) }

        $body = New-CalibrationProfileBody -CpuZonePolicy $cpu -SystemZonePolicy $sys

        $body.strName | Should -Be 'calibration'
        $body.strVersion | Should -Be '1.00'
        $body.arrPolicy.Count | Should -Be 2
        $body.arrPolicy[0].arrFanSensor | Should -Be @(184)
        $body.arrPolicy[1].arrFanSensor | Should -Be @(185,186)
    }
}

Describe 'New-CalibrationCsvRow' {
    It 'formats a healthy reading' {
        $row = New-CalibrationCsvRow -Zone 'CPU' -DutyPercent 50 -FanName 'CPU0_FAN' -Rpm 1350.0
        $row.Zone | Should -Be 'CPU'
        $row.DutyPercent | Should -Be 50
        $row.FanName | Should -Be 'CPU0_FAN'
        $row.RPM | Should -Be '1350'
    }
    It 'formats a missing/sentinel reading as NA' {
        $row = New-CalibrationCsvRow -Zone 'System' -DutyPercent 30 -FanName 'SYS_FAN1' -Rpm $null
        $row.RPM | Should -Be 'NA'
    }
}

Describe 'Connect-Bmc' {
    It 'posts credentials and returns the session plus CSRF token' {
        Mock -ModuleName FanCalibration Invoke-RestMethod {
            return [pscustomobject]@{ CSRFToken = 'abc123'; ok = 1 }
        }

        $cred = [pscredential]::new('admin', (ConvertTo-SecureString 'password' -AsPlainText -Force))
        $conn = Connect-Bmc -BmcHost '192.168.178.21' -Credential $cred

        $conn.CsrfToken | Should -Be 'abc123'
        Should -Invoke -ModuleName FanCalibration Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -eq 'https://192.168.178.21/api/session' -and
            $Method -eq 'Post' -and
            $Body.username -eq 'admin' -and
            $Body.password -eq 'password' -and
            $Headers['X-CSRFTOKEN'] -eq 'null'
        }
    }

    It 'throws when the response has no CSRFToken' {
        Mock -ModuleName FanCalibration Invoke-RestMethod { return [pscustomobject]@{ ok = 0 } }
        $cred = [pscredential]::new('admin', (ConvertTo-SecureString 'wrong' -AsPlainText -Force))
        { Connect-Bmc -BmcHost '192.168.178.21' -Credential $cred } | Should -Throw
    }
}

Describe 'Invoke-BmcApi' {
    It 'sends a GET with the session and CSRF header' {
        Mock -ModuleName FanCalibration Invoke-RestMethod { return [pscustomobject]@{ result = 'ok' } }
        $conn = [pscustomobject]@{ WebSession = (New-Object Microsoft.PowerShell.Commands.WebRequestSession); CsrfToken = 'tok1' }

        $result = Invoke-BmcApi -Connection $conn -BmcHost '192.168.178.21' -Path '/api/sensors'

        $result.result | Should -Be 'ok'
        Should -Invoke -ModuleName FanCalibration Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -eq 'https://192.168.178.21/api/sensors' -and
            $Method -eq 'Get' -and
            $Headers['X-CSRFTOKEN'] -eq 'tok1' -and
            $Headers['X-Requested-With'] -eq 'XMLHttpRequest'
        }
    }

    It 'JSON-encodes the body for a PUT/POST' {
        Mock -ModuleName FanCalibration Invoke-RestMethod { return [pscustomobject]@{ strMode = 'calibration' } }
        $conn = [pscustomobject]@{ WebSession = (New-Object Microsoft.PowerShell.Commands.WebRequestSession); CsrfToken = 'tok1' }

        Invoke-BmcApi -Connection $conn -BmcHost '192.168.178.21' -Path '/api/settings/fanprofile/mode' -Method 'Post' -Body @{ strMode = 'calibration' } | Out-Null

        Should -Invoke -ModuleName FanCalibration Invoke-RestMethod -Times 1 -ParameterFilter {
            $Method -eq 'Post' -and
            $ContentType -eq 'application/json' -and
            $Body -eq '{"strMode":"calibration"}'
        }
    }
}

Describe 'Invoke-FanSweep' {
    BeforeEach {
        $script:modeCalls = @()
        $script:putBodies = @()
        $fanProfileResponse = [pscustomobject]@{
            strMode = 'quiet'
            strVersion = '1.00'
            arrProfile = @(
                [pscustomobject]@{
                    strName = 'quiet'; strVersion = '1.00'
                    arrPolicy = @(
                        [pscustomobject]@{ arrFanSensor = @(184); arrSensor = @(1); iSensorCode = 1; iPolicyType = 2; iInSDR = 1; iInitDuty = 40; iCpuTdp = 0; iAmbientSensor = 0; iAmbientSensorTemp = 0; arrRef = @(30,76); arrDuty = @(25,100); arrHexVendorID = @(); arrHexDeviceID = @(); iPCIEDeviceEnable = 0; iHysteresis = 3 }
                        [pscustomobject]@{ arrFanSensor = @(185,186); arrSensor = @(4,8,14,16); iSensorCode = 3; iPolicyType = 2; iInSDR = 1; iInitDuty = 40; iCpuTdp = 0; iAmbientSensor = 0; iAmbientSensorTemp = 0; arrRef = @(30,72); arrDuty = @(20,100); arrHexVendorID = @(); arrHexDeviceID = @(); iPCIEDeviceEnable = 0; iHysteresis = 4 }
                    )
                }
                [pscustomobject]@{
                    strName = 'calibration'; strVersion = '1.00'
                    arrPolicy = @()
                }
            )
        }
        $sensorsResponse = @(
            [pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN'; raw_reading = 9; reading = 1350.0 }
            [pscustomobject]@{ sensor_number = 185; name = 'SYS_FAN1'; raw_reading = 8; reading = 1200.0 }
            [pscustomobject]@{ sensor_number = 186; name = 'SYS_FAN2'; raw_reading = 6; reading = 900.0 }
        )

        Mock -ModuleName FanCalibration Invoke-BmcApi {
            switch ("$Method $Path") {
                'Get /api/settings/fanprofile' { return $fanProfileResponse }
                'Get /api/sensors'             { return $sensorsResponse }
                'Put /api/settings/fanprofile/collection/calibration' {
                    $script:putBodies += [pscustomobject]@{
                        CpuInitDuty    = $Body.arrPolicy[0].iInitDuty
                        SystemInitDuty = $Body.arrPolicy[1].iInitDuty
                    }
                    return $Body
                }
                'Post /api/settings/fanprofile/mode' { $script:modeCalls += $Body.strMode; return [pscustomobject]@{ strMode = $Body.strMode } }
                default { return $null }
            }
        }
    }

    It 'sweeps both zones, restores the original mode, and returns one row per duty per fan' {
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }
        $rows = Invoke-FanSweep -Connection $conn -BmcHost '192.168.178.21' `
            -DutySteps @(20,50,100) -BaselineDutyPercent 50 -SettleSeconds 1 `
            -SleepCommand { param($Seconds) }

        # 3 duty steps x (1 CPU fan + 2 System fans) = 9 rows
        $rows.Count | Should -Be 9
        ($rows | Where-Object FanName -eq 'CPU0_FAN').Count | Should -Be 3
        ($rows | Where-Object FanName -eq 'SYS_FAN1').Count | Should -Be 3
        ($rows | Where-Object FanName -eq 'SYS_FAN2').Count | Should -Be 3
        ($rows | Where-Object { $_.FanName -eq 'CPU0_FAN' -and $_.DutyPercent -eq 50 }).RPM | Should -Be '1350'

        # mode was switched to calibration at least once, and the LAST mode call restores 'quiet'
        $script:modeCalls | Should -Contain 'calibration'
        $script:modeCalls[-1] | Should -Be 'quiet'

        # zone isolation: 6 PUT calls total (3 duty steps x 2 zones).
        $script:putBodies.Count | Should -Be 6

        # first 3 PUTs are the CPU-zone pass: CPU duty tracks the sweep value,
        # System duty stays pinned at the baseline (50).
        $cpuPassPuts = $script:putBodies[0..2]
        $cpuPassPuts.CpuInitDuty | Should -Be @(20,50,100)
        $cpuPassPuts.SystemInitDuty | Should -Be @(50,50,50)

        # last 3 PUTs are the System-zone pass: System duty tracks the sweep
        # value, CPU duty stays pinned at the baseline (50).
        $systemPassPuts = $script:putBodies[3..5]
        $systemPassPuts.SystemInitDuty | Should -Be @(20,50,100)
        $systemPassPuts.CpuInitDuty | Should -Be @(50,50,50)
    }

    It 'still restores the original mode when a sensor read fails mid-sweep' {
        Mock -ModuleName FanCalibration Invoke-BmcApi {
            switch ("$Method $Path") {
                'Get /api/settings/fanprofile' { return $fanProfileResponse }
                'Get /api/sensors'             { throw 'simulated network failure' }
                'Post /api/settings/fanprofile/mode' { $script:modeCalls += $Body.strMode; return [pscustomobject]@{ strMode = $Body.strMode } }
                default { return $null }
            }
        }
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }

        { Invoke-FanSweep -Connection $conn -BmcHost '192.168.178.21' `
            -DutySteps @(20) -BaselineDutyPercent 50 -SettleSeconds 1 `
            -SleepCommand { param($Seconds) } } | Should -Throw

        $script:modeCalls[-1] | Should -Be 'quiet'
    }

    It 'throws immediately without touching the BMC further if a previous crashed run left strMode on calibration' {
        $stuckProfile = [pscustomobject]@{
            strMode = 'calibration'
            strVersion = '1.00'
            arrProfile = $fanProfileResponse.arrProfile
        }
        Mock -ModuleName FanCalibration Invoke-BmcApi {
            switch ("$Method $Path") {
                'Get /api/settings/fanprofile' { return $stuckProfile }
                default { throw "unexpected call: $Method $Path" }
            }
        }
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }

        { Invoke-FanSweep -Connection $conn -BmcHost '192.168.178.21' `
            -DutySteps @(20) -BaselineDutyPercent 50 -SettleSeconds 1 `
            -SleepCommand { param($Seconds) } } | Should -Throw -ExpectedMessage '*calibration*'
    }

    It 'throws when the calibration profile collection does not exist yet on the BMC' {
        $missingCalibrationProfile = [pscustomobject]@{
            strMode = 'quiet'
            strVersion = '1.00'
            arrProfile = @($fanProfileResponse.arrProfile[0])  # only 'quiet', no 'calibration' entry
        }
        Mock -ModuleName FanCalibration Invoke-BmcApi {
            switch ("$Method $Path") {
                'Get /api/settings/fanprofile' { return $missingCalibrationProfile }
                default { throw "unexpected call: $Method $Path" }
            }
        }
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }

        { Invoke-FanSweep -Connection $conn -BmcHost '192.168.178.21' `
            -DutySteps @(20) -BaselineDutyPercent 50 -SettleSeconds 1 `
            -SleepCommand { param($Seconds) } } | Should -Throw -ExpectedMessage "*calibration*"
    }

    It 'retries a sentinel sensor reading once and recovers a healthy value on the retry' {
        $script:sensorCallCount = 0
        $script:sleepCalls = @()
        Mock -ModuleName FanCalibration Invoke-BmcApi {
            switch ("$Method $Path") {
                'Get /api/settings/fanprofile' { return $fanProfileResponse }
                'Get /api/sensors' {
                    $script:sensorCallCount++
                    if ($script:sensorCallCount -eq 1) {
                        return @(
                            [pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN'; raw_reading = 252; reading = 0.0 }
                            [pscustomobject]@{ sensor_number = 185; name = 'SYS_FAN1'; raw_reading = 8; reading = 1200.0 }
                            [pscustomobject]@{ sensor_number = 186; name = 'SYS_FAN2'; raw_reading = 6; reading = 900.0 }
                        )
                    }
                    return $sensorsResponse
                }
                'Post /api/settings/fanprofile/mode' { $script:modeCalls += $Body.strMode; return [pscustomobject]@{ strMode = $Body.strMode } }
                default { return $null }
            }
        }
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }

        $rows = Invoke-FanSweep -Connection $conn -BmcHost '192.168.178.21' `
            -DutySteps @(20) -BaselineDutyPercent 50 -SettleSeconds 1 `
            -SleepCommand { param($Seconds) $script:sleepCalls += $Seconds }

        ($rows | Where-Object { $_.FanName -eq 'CPU0_FAN' -and $_.DutyPercent -eq 20 }).RPM | Should -Be '1350'
        # exactly one retry happened: 2 sensor calls for the CPU-zone step (initial+retry)
        # + 1 for the System-zone step (no retry needed, healthy on first try) = 3
        $script:sensorCallCount | Should -Be 3
        $script:sleepCalls | Should -Contain 3
    }

    It 'records NA after exactly one retry when a sensor reading is persistently sentinel' {
        $script:sensorCallCount = 0
        Mock -ModuleName FanCalibration Invoke-BmcApi {
            switch ("$Method $Path") {
                'Get /api/settings/fanprofile' { return $fanProfileResponse }
                'Get /api/sensors' {
                    $script:sensorCallCount++
                    return @(
                        [pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN'; raw_reading = 252; reading = 0.0 }
                        [pscustomobject]@{ sensor_number = 185; name = 'SYS_FAN1'; raw_reading = 8; reading = 1200.0 }
                        [pscustomobject]@{ sensor_number = 186; name = 'SYS_FAN2'; raw_reading = 6; reading = 900.0 }
                    )
                }
                'Post /api/settings/fanprofile/mode' { $script:modeCalls += $Body.strMode; return [pscustomobject]@{ strMode = $Body.strMode } }
                default { return $null }
            }
        }
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }

        $rows = Invoke-FanSweep -Connection $conn -BmcHost '192.168.178.21' `
            -DutySteps @(20) -BaselineDutyPercent 50 -SettleSeconds 1 `
            -SleepCommand { param($Seconds) }

        ($rows | Where-Object { $_.FanName -eq 'CPU0_FAN' -and $_.DutyPercent -eq 20 }).RPM | Should -Be 'NA'
        # exactly one retry (not zero, not looping): same call count (3) as the
        # recovery case above, only the outcome (still sentinel) differs.
        $script:sensorCallCount | Should -Be 3
    }
}

Describe 'Get-BmcInventory' {
    BeforeAll {
        $sensorsResponse = @(
            [pscustomobject]@{ sensor_number = 1; name = 'CPU0_TEMP'; type = 'temperature'; reading = 50.0; raw_reading = 50 }
            [pscustomobject]@{ sensor_number = 4; name = 'DIMMG0_TEMP'; type = 'temperature'; reading = 55.0; raw_reading = 55 }
            [pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN'; type = 'fan'; reading = 1350.0; raw_reading = 9 }
            [pscustomobject]@{ sensor_number = 185; name = 'SYS_FAN1'; type = 'fan'; reading = 1200.0; raw_reading = 8 }
            [pscustomobject]@{ sensor_number = 225; name = 'SEL'; type = 'event_logging_disabled'; reading = 0.0; raw_reading = 0 }
        )
    }

    It 'splits sensors into fan and temperature inventories, ignoring other types' {
        Mock -ModuleName FanCalibration Invoke-BmcApi { return $sensorsResponse }
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }

        $inventory = Get-BmcInventory -Connection $conn -BmcHost '192.168.178.21'

        $inventory.FanSensors.Count | Should -Be 2
        $inventory.TempSensors.Count | Should -Be 2
        ($inventory.FanSensors | Where-Object sensor_number -eq 184).name | Should -Be 'CPU0_FAN'
        ($inventory.TempSensors | Where-Object sensor_number -eq 1).name | Should -Be 'CPU0_TEMP'
        Should -Invoke -ModuleName FanCalibration Invoke-BmcApi -Times 1 -ParameterFilter {
            $Path -eq '/api/sensors' -and $Method -eq 'Get'
        }
    }
}

Describe 'Read-ZoneConfig and Save-ZoneConfig' {
    BeforeAll {
        $testConfigPath = Join-Path $TestDrive 'bmc-zones-test.json'
    }

    It 'returns $null when the file does not exist' {
        Read-ZoneConfig -Path (Join-Path $TestDrive 'does-not-exist.json') | Should -BeNullOrEmpty
    }

    It 'round-trips zones through Save-ZoneConfig and Read-ZoneConfig' {
        $zones = @(
            [pscustomobject]@{ Name = 'CPU0_FAN'; FanSensors = @(184); TempSensors = @(1) }
            [pscustomobject]@{ Name = 'SYS_FAN1+SYS_FAN2'; FanSensors = @(185, 186); TempSensors = @(4, 8, 14, 16) }
        )

        Save-ZoneConfig -Path $testConfigPath -Zones $zones
        $loaded = Read-ZoneConfig -Path $testConfigPath

        $loaded.Count | Should -Be 2
        $loaded[0].Name | Should -Be 'CPU0_FAN'
        $loaded[0].FanSensors | Should -Be @(184)
        $loaded[1].FanSensors | Should -Be @(185, 186)
        $loaded[1].TempSensors | Should -Be @(4, 8, 14, 16)
    }

    It 'round-trips a single zone without unwrapping to a bare object' {
        $singleZone = @([pscustomobject]@{ Name = 'Solo'; FanSensors = @(184); TempSensors = @(1) })
        Save-ZoneConfig -Path $testConfigPath -Zones $singleZone
        $loaded = Read-ZoneConfig -Path $testConfigPath
        $loaded.Count | Should -Be 1
        $loaded[0].Name | Should -Be 'Solo'
    }

    It 'round-trips an empty zone list as an empty array, not a single null element' {
        Save-ZoneConfig -Path $testConfigPath -Zones @()
        $loaded = Read-ZoneConfig -Path $testConfigPath
        $loaded.Count | Should -Be 0
    }
}

Describe 'New-ZonesFromProfile' {
    BeforeAll {
        $inventory = [pscustomobject]@{
            FanSensors  = @(
                [pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN' }
                [pscustomobject]@{ sensor_number = 185; name = 'SYS_FAN1' }
                [pscustomobject]@{ sensor_number = 186; name = 'SYS_FAN2' }
            )
            TempSensors = @(
                [pscustomobject]@{ sensor_number = 1; name = 'CPU0_TEMP' }
            )
        }
        $fanProfileResponse = [pscustomobject]@{
            strMode    = 'quiet'
            arrProfile = @(
                [pscustomobject]@{
                    strName   = 'quiet'
                    arrPolicy = @(
                        [pscustomobject]@{ arrFanSensor = @(184); arrSensor = @(1) }
                        [pscustomobject]@{ arrFanSensor = @(185, 186); arrSensor = @(4, 8, 14, 16) }
                    )
                }
            )
        }
    }

    It 'derives one zone per policy, named from joined fan sensor names' {
        $zones = New-ZonesFromProfile -FanProfileResponse $fanProfileResponse -Inventory $inventory

        $zones.Count | Should -Be 2
        $zones[0].Name | Should -Be 'CPU0_FAN'
        $zones[0].FanSensors | Should -Be @(184)
        $zones[0].TempSensors | Should -Be @(1)
        $zones[1].Name | Should -Be 'SYS_FAN1+SYS_FAN2'
        $zones[1].FanSensors | Should -Be @(185, 186)
        $zones[1].TempSensors | Should -Be @(4, 8, 14, 16)
    }

    It 'returns $null when the active profile has no policies' {
        $emptyProfile = [pscustomobject]@{
            strMode    = 'fresh'
            arrProfile = @([pscustomobject]@{ strName = 'fresh'; arrPolicy = @() })
        }
        New-ZonesFromProfile -FanProfileResponse $emptyProfile -Inventory $inventory | Should -BeNullOrEmpty
    }

    It 'returns $null when no profile matches the active strMode' {
        $noMatch = [pscustomobject]@{ strMode = 'missing'; arrProfile = @() }
        New-ZonesFromProfile -FanProfileResponse $noMatch -Inventory $inventory | Should -BeNullOrEmpty
    }

    It 'falls back to "sensorN" when a fan sensor number is missing from the inventory' {
        $profileWithUnknownFan = [pscustomobject]@{
            strMode    = 'quiet'
            arrProfile = @([pscustomobject]@{
                strName   = 'quiet'
                arrPolicy = @([pscustomobject]@{ arrFanSensor = @(999); arrSensor = @(1) })
            })
        }
        $zones = New-ZonesFromProfile -FanProfileResponse $profileWithUnknownFan -Inventory $inventory
        $zones[0].Name | Should -Be 'sensor999'
    }
}

Describe 'Read-ZoneWizard' {
    BeforeAll {
        $inventory = [pscustomobject]@{
            FanSensors  = @(
                [pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN' }
                [pscustomobject]@{ sensor_number = 185; name = 'SYS_FAN1' }
                [pscustomobject]@{ sensor_number = 186; name = 'SYS_FAN2' }
            )
            TempSensors = @(
                [pscustomobject]@{ sensor_number = 1; name = 'CPU0_TEMP' }
            )
        }
    }

    It 'builds zones from a scripted sequence of Read-Host answers, stopping on empty name' {
        $script:answers = @('CPU', '184', '1', 'System', '185,186', '4,8', '')
        $script:answerIndex = 0
        Mock -ModuleName FanCalibration Read-Host {
            $value = $script:answers[$script:answerIndex]
            $script:answerIndex++
            return $value
        }

        $zones = Read-ZoneWizard -Inventory $inventory

        $zones.Count | Should -Be 2
        $zones[0].Name | Should -Be 'CPU'
        $zones[0].FanSensors | Should -Be @(184)
        $zones[0].TempSensors | Should -Be @(1)
        $zones[1].Name | Should -Be 'System'
        $zones[1].FanSensors | Should -Be @(185, 186)
        $zones[1].TempSensors | Should -Be @(4, 8)
    }

    It 'stops as soon as every fan sensor is assigned, even without an empty-name entry' {
        $script:answers = @('AllFans', '184,185,186', '1')
        $script:answerIndex = 0
        Mock -ModuleName FanCalibration Read-Host {
            $value = $script:answers[$script:answerIndex]
            $script:answerIndex++
            return $value
        }

        $zones = Read-ZoneWizard -Inventory $inventory

        Should -Invoke -ModuleName FanCalibration Read-Host -Times 3 -Exactly

        $zones.Count | Should -Be 1
        $zones[0].FanSensors | Should -Be @(184, 185, 186)
    }

    It 'skips non-numeric sensor tokens via TryParse, warns, and does not crash' {
        $script:answers = @('Mixed', '184,abc,185,186', '1')
        $script:answerIndex = 0
        Mock -ModuleName FanCalibration Read-Host {
            $value = $script:answers[$script:answerIndex]
            $script:answerIndex++
            return $value
        }
        Mock -ModuleName FanCalibration Write-Warning {}

        $zones = Read-ZoneWizard -Inventory $inventory

        $zones.Count | Should -Be 1
        $zones[0].FanSensors | Should -Be @(184, 185, 186)
        Should -Invoke -ModuleName FanCalibration Write-Warning -Times 1 -ParameterFilter {
            $Message -match "'abc'"
        }
    }

    It 'warns about fan sensors left unassigned when the operator ends early' {
        $script:answers = @('CPU', '184', '1', '')
        $script:answerIndex = 0
        Mock -ModuleName FanCalibration Read-Host {
            $value = $script:answers[$script:answerIndex]
            $script:answerIndex++
            return $value
        }
        Mock -ModuleName FanCalibration Write-Warning {}

        Read-ZoneWizard -Inventory $inventory | Out-Null

        Should -Invoke -ModuleName FanCalibration Write-Warning -Times 1 -ParameterFilter {
            $Message -match '185' -and $Message -match '186'
        }
    }
}

Describe 'Resolve-Zones' {
    BeforeAll {
        $configPath = Join-Path $TestDrive 'bmc-zones-192.168.178.21.json'
        $sampleZones = @(
            [pscustomobject]@{ Name = 'CPU0_FAN'; FanSensors = @(184); TempSensors = @(1) }
        )
        $fanProfileWithPolicies = [pscustomobject]@{
            strMode    = 'quiet'
            arrProfile = @([pscustomobject]@{
                strName   = 'quiet'
                arrPolicy = @([pscustomobject]@{ arrFanSensor = @(184); arrSensor = @(1) })
            })
        }
        $fanProfileFresh = [pscustomobject]@{
            strMode    = 'default'
            arrProfile = @([pscustomobject]@{ strName = 'default'; arrPolicy = @() })
        }
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }
        $wizardResult = @([pscustomobject]@{ Name = 'Wizard'; FanSensors = @(184); TempSensors = @(1) })
    }

    BeforeEach {
        if (Test-Path -LiteralPath $configPath) { Remove-Item -LiteralPath $configPath -Force }
    }

    It 'loads the existing config file when present and -NewDevice is not set' {
        Save-ZoneConfig -Path $configPath -Zones $sampleZones
        Mock -ModuleName FanCalibration Get-BmcInventory { throw 'should not be called' }

        $result = Resolve-Zones -Connection $conn -BmcHost '192.168.178.21' -FanProfileResponse $fanProfileWithPolicies -ConfigPath $configPath

        $result[0].Name | Should -Be 'CPU0_FAN'
    }

    It 'derives zones from the active profile when no config exists and policies are present' {
        Mock -ModuleName FanCalibration Get-BmcInventory {
            return [pscustomobject]@{
                FanSensors  = @([pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN' })
                TempSensors = @([pscustomobject]@{ sensor_number = 1; name = 'CPU0_TEMP' })
            }
        }

        $result = Resolve-Zones -Connection $conn -BmcHost '192.168.178.21' -FanProfileResponse $fanProfileWithPolicies -ConfigPath $configPath

        $result[0].Name | Should -Be 'CPU0_FAN'
        (Read-ZoneConfig -Path $configPath)[0].Name | Should -Be 'CPU0_FAN'
    }

    It 'runs the wizard when no config exists and the active profile has no policies' {
        Mock -ModuleName FanCalibration Get-BmcInventory {
            return [pscustomobject]@{ FanSensors = @(); TempSensors = @() }
        }

        $result = Resolve-Zones -Connection $conn -BmcHost '192.168.178.21' -FanProfileResponse $fanProfileFresh `
            -ConfigPath $configPath -WizardCommand { param($Inventory) $wizardResult }

        $result[0].Name | Should -Be 'Wizard'
        (Read-ZoneConfig -Path $configPath)[0].Name | Should -Be 'Wizard'
    }

    It '-NewDevice with confirmed overwrite runs the wizard even when config/policies exist' {
        Save-ZoneConfig -Path $configPath -Zones $sampleZones
        Mock -ModuleName FanCalibration Get-BmcInventory {
            return [pscustomobject]@{ FanSensors = @(); TempSensors = @() }
        }

        $result = Resolve-Zones -Connection $conn -BmcHost '192.168.178.21' -FanProfileResponse $fanProfileWithPolicies `
            -ConfigPath $configPath -NewDevice -ConfirmCommand { param($Message) 'j' } `
            -WizardCommand { param($Inventory) $wizardResult }

        $result[0].Name | Should -Be 'Wizard'
    }

    It '-NewDevice with declined overwrite falls back to the existing config' {
        Save-ZoneConfig -Path $configPath -Zones $sampleZones

        $result = Resolve-Zones -Connection $conn -BmcHost '192.168.178.21' -FanProfileResponse $fanProfileWithPolicies `
            -ConfigPath $configPath -NewDevice -ConfirmCommand { param($Message) 'n' } `
            -WizardCommand { param($Inventory) throw 'should not run wizard' }

        $result[0].Name | Should -Be 'CPU0_FAN'
    }
}
