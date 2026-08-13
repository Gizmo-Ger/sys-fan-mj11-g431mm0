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
            strMode    = 'quiet'
            arrProfile = @(
                [pscustomobject]@{
                    strName   = 'quiet'
                    arrPolicy = @(
                        [pscustomobject]@{ arrFanSensor = @(184); arrSensor = @(1); iSensorCode = 1; iHysteresis = 3 }
                        [pscustomobject]@{ arrFanSensor = @(185, 186); arrSensor = @(4, 8, 14, 16); iSensorCode = 3; iHysteresis = 4 }
                    )
                }
            )
        }
    }

    It 'finds an existing policy whose arrFanSensor overlaps the zone' {
        $zone = [pscustomobject]@{ Name = 'CPU0_FAN'; FanSensors = @(184); TempSensors = @(1) }
        $result = Get-ZoneTemplate -FanProfileResponse $fanProfileResponse -Zone $zone
        $result.iSensorCode | Should -Be 1
        $result.iHysteresis | Should -Be 3
    }

    It 'finds an existing policy via partial overlap (zone has more fans than the policy)' {
        $zone = [pscustomobject]@{ Name = 'Sys'; FanSensors = @(185, 186, 999); TempSensors = @() }
        $result = Get-ZoneTemplate -FanProfileResponse $fanProfileResponse -Zone $zone
        $result.iSensorCode | Should -Be 3
    }

    It 'falls back to a default policy skeleton when no policy matches, single temp sensor' {
        $zone = [pscustomobject]@{ Name = 'NewZone'; FanSensors = @(999); TempSensors = @(1) }
        $result = Get-ZoneTemplate -FanProfileResponse $fanProfileResponse -Zone $zone
        $result.iPolicyType | Should -Be 2
        $result.iSensorCode | Should -Be 1
        $result.arrFanSensor | Should -Be @(999)
        $result.arrSensor | Should -Be @(1)
    }

    It 'falls back to a default policy skeleton with iSensorCode 3 for multiple temp sensors' {
        $zone = [pscustomobject]@{ Name = 'NewZone'; FanSensors = @(999); TempSensors = @(1, 4) }
        $result = Get-ZoneTemplate -FanProfileResponse $fanProfileResponse -Zone $zone
        $result.iSensorCode | Should -Be 3
    }

    It 'falls back to the default skeleton when the active profile itself is not found' {
        $noProfile = [pscustomobject]@{ strMode = 'missing'; arrProfile = @() }
        $zone = [pscustomobject]@{ Name = 'NewZone'; FanSensors = @(184); TempSensors = @(1) }
        $result = Get-ZoneTemplate -FanProfileResponse $noProfile -Zone $zone
        $result.iPolicyType | Should -Be 2
    }
}

Describe 'New-CalibrationProfileBody' {
    It 'builds the calibration collection body from any number of zone policies' {
        $cpu = [pscustomobject]@{ arrFanSensor = @(184) }
        $sys = [pscustomobject]@{ arrFanSensor = @(185, 186) }
        $extra = [pscustomobject]@{ arrFanSensor = @(187) }

        $body = New-CalibrationProfileBody -ZonePolicies @($cpu, $sys, $extra)

        $body.strName | Should -Be 'calibration'
        $body.strVersion | Should -Be '1.00'
        $body.arrPolicy.Count | Should -Be 3
        $body.arrPolicy[2].arrFanSensor | Should -Be @(187)
    }

    It 'works with exactly one zone policy' {
        $only = [pscustomobject]@{ arrFanSensor = @(184) }
        $body = New-CalibrationProfileBody -ZonePolicies @($only)
        $body.arrPolicy.Count | Should -Be 1
    }

    It 'works with zero zone policies, for the bootstrap collection' {
        $body = New-CalibrationProfileBody -ZonePolicies @()
        $body.strName | Should -Be 'calibration'
        $body.strVersion | Should -Be '1.00'
        $body.arrPolicy.Count | Should -Be 0
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
        $conn = Connect-Bmc -BmcHost 'bmc.example.test' -Credential $cred

        $conn.CsrfToken | Should -Be 'abc123'
        Should -Invoke -ModuleName FanCalibration Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -eq 'https://bmc.example.test/api/session' -and
            $Method -eq 'Post' -and
            $Body.username -eq 'admin' -and
            $Body.password -eq 'password' -and
            $Headers['X-CSRFTOKEN'] -eq 'null'
        }
    }

    It 'throws when the response has no CSRFToken' {
        Mock -ModuleName FanCalibration Invoke-RestMethod { return [pscustomobject]@{ ok = 0 } }
        $cred = [pscredential]::new('admin', (ConvertTo-SecureString 'wrong' -AsPlainText -Force))
        { Connect-Bmc -BmcHost 'bmc.example.test' -Credential $cred } | Should -Throw
    }
}

Describe 'Invoke-BmcApi' {
    It 'sends a GET with the session and CSRF header' {
        Mock -ModuleName FanCalibration Invoke-RestMethod { return [pscustomobject]@{ result = 'ok' } }
        $conn = [pscustomobject]@{ WebSession = (New-Object Microsoft.PowerShell.Commands.WebRequestSession); CsrfToken = 'tok1' }

        $result = Invoke-BmcApi -Connection $conn -BmcHost 'bmc.example.test' -Path '/api/sensors'

        $result.result | Should -Be 'ok'
        Should -Invoke -ModuleName FanCalibration Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -eq 'https://bmc.example.test/api/sensors' -and
            $Method -eq 'Get' -and
            $Headers['X-CSRFTOKEN'] -eq 'tok1' -and
            $Headers['X-Requested-With'] -eq 'XMLHttpRequest'
        }
    }

    It 'JSON-encodes the body for a PUT/POST' {
        Mock -ModuleName FanCalibration Invoke-RestMethod { return [pscustomobject]@{ strMode = 'calibration' } }
        $conn = [pscustomobject]@{ WebSession = (New-Object Microsoft.PowerShell.Commands.WebRequestSession); CsrfToken = 'tok1' }

        Invoke-BmcApi -Connection $conn -BmcHost 'bmc.example.test' -Path '/api/settings/fanprofile/mode' -Method 'Post' -Body @{ strMode = 'calibration' } | Out-Null

        Should -Invoke -ModuleName FanCalibration Invoke-RestMethod -Times 1 -ParameterFilter {
            $Method -eq 'Post' -and
            $ContentType -eq 'application/json' -and
            $Body -eq '{"strMode":"calibration"}'
        }
    }
}

Describe 'New-CalibrationCollection' {
    It 'POSTs the empty calibration collection body' {
        Mock -ModuleName FanCalibration Invoke-RestMethod { return [pscustomobject]@{ strName = 'calibration' } }
        $conn = [pscustomobject]@{ WebSession = (New-Object Microsoft.PowerShell.Commands.WebRequestSession); CsrfToken = 'tok1' }

        New-CalibrationCollection -Connection $conn -BmcHost 'bmc.example.test' | Out-Null

        Should -Invoke -ModuleName FanCalibration Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -eq 'https://bmc.example.test/api/settings/fanprofile/collection' -and
            $Method -eq 'Post' -and
            $Body -eq '{"strName":"calibration","strVersion":"1.00","arrPolicy":[]}'
        }
    }
}

Describe 'Invoke-FanSweep' {
    BeforeEach {
        $script:modeCalls = @()
        $script:putBodies = @()
        $fanProfileResponse = [pscustomobject]@{
            strMode    = 'quiet'
            arrProfile = @([pscustomobject]@{
                strName   = 'quiet'
                arrPolicy = @(
                    [pscustomobject]@{ arrFanSensor = @(184); arrSensor = @(1); iSensorCode = 1; iPolicyType = 2; iInSDR = 1; iInitDuty = 40; iCpuTdp = 0; iAmbientSensor = 0; iAmbientSensorTemp = 0; arrRef = @(30,76); arrDuty = @(25,100); arrHexVendorID = @(); arrHexDeviceID = @(); iPCIEDeviceEnable = 0; iHysteresis = 3 }
                    [pscustomobject]@{ arrFanSensor = @(185,186); arrSensor = @(4,8,14,16); iSensorCode = 3; iPolicyType = 2; iInSDR = 1; iInitDuty = 40; iCpuTdp = 0; iAmbientSensor = 0; iAmbientSensorTemp = 0; arrRef = @(30,72); arrDuty = @(20,100); arrHexVendorID = @(); arrHexDeviceID = @(); iPCIEDeviceEnable = 0; iHysteresis = 4 }
                )
            })
        }
        $fanProfileWithCalibration = [pscustomobject]@{
            strMode    = 'quiet'
            arrProfile = @($fanProfileResponse.arrProfile[0], [pscustomobject]@{ strName = 'calibration'; arrPolicy = @() })
        }
        $sensorsResponse = @(
            [pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN'; raw_reading = 9; reading = 1350.0 }
            [pscustomobject]@{ sensor_number = 185; name = 'SYS_FAN1'; raw_reading = 8; reading = 1200.0 }
            [pscustomobject]@{ sensor_number = 186; name = 'SYS_FAN2'; raw_reading = 6; reading = 900.0 }
        )
        $zones = @(
            [pscustomobject]@{ Name = 'CPU0_FAN'; FanSensors = @(184); TempSensors = @(1) }
            [pscustomobject]@{ Name = 'SYS_FAN1+SYS_FAN2'; FanSensors = @(185, 186); TempSensors = @(4, 8, 14, 16) }
        )

        Mock -ModuleName FanCalibration Invoke-BmcApi {
            switch ("$Method $Path") {
                'Get /api/settings/fanprofile' { return $fanProfileWithCalibration }
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

    It 'sweeps N zones sequentially, holding every other zone at baseline, one row per duty per fan' {
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }
        $rows = Invoke-FanSweep -Connection $conn -BmcHost 'bmc.example.test' `
            -DutySteps @(20, 50, 100) -BaselineDutyPercent 50 -SettleSeconds 1 -Zones $zones `
            -SleepCommand { param($Seconds) }

        $rows.Count | Should -Be 9
        ($rows | Where-Object FanName -eq 'CPU0_FAN').Count | Should -Be 3
        ($rows | Where-Object FanName -eq 'SYS_FAN1').Count | Should -Be 3
        ($rows | Where-Object FanName -eq 'SYS_FAN2').Count | Should -Be 3
        ($rows | Where-Object { $_.FanName -eq 'CPU0_FAN' -and $_.DutyPercent -eq 50 }).RPM | Should -Be '1350'
        $script:modeCalls | Should -Contain 'calibration'
        $script:modeCalls[-1] | Should -Be 'quiet'

        # zone isolation on the wire: 6 PUT calls total (3 duty steps x 2 zones).
        $script:putBodies.Count | Should -Be 6

        # first 3 PUTs are the CPU0_FAN-zone pass: its duty tracks the sweep
        # value, the other zone's duty stays pinned at the baseline (50).
        $cpuPassPuts = $script:putBodies[0..2]
        $cpuPassPuts.CpuInitDuty | Should -Be @(20, 50, 100)
        $cpuPassPuts.SystemInitDuty | Should -Be @(50, 50, 50)

        # last 3 PUTs are the SYS_FAN1+SYS_FAN2-zone pass: its duty tracks the
        # sweep value, the other zone's duty stays pinned at the baseline (50).
        $systemPassPuts = $script:putBodies[3..5]
        $systemPassPuts.SystemInitDuty | Should -Be @(20, 50, 100)
        $systemPassPuts.CpuInitDuty | Should -Be @(50, 50, 50)
    }

    It 'still restores the original mode when a sensor read fails mid-sweep' {
        Mock -ModuleName FanCalibration Invoke-BmcApi {
            switch ("$Method $Path") {
                'Get /api/settings/fanprofile' { return $fanProfileWithCalibration }
                'Get /api/sensors'             { throw 'simulated network failure' }
                'Post /api/settings/fanprofile/mode' { $script:modeCalls += $Body.strMode; return [pscustomobject]@{ strMode = $Body.strMode } }
                default { return $null }
            }
        }
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }

        { Invoke-FanSweep -Connection $conn -BmcHost 'bmc.example.test' `
            -DutySteps @(20) -BaselineDutyPercent 50 -SettleSeconds 1 -Zones $zones `
            -SleepCommand { param($Seconds) } } | Should -Throw

        $script:modeCalls[-1] | Should -Be 'quiet'
    }

    It 'throws immediately without touching the BMC further if a previous crashed run left strMode on calibration' {
        Mock -ModuleName FanCalibration Invoke-BmcApi {
            switch ("$Method $Path") {
                'Get /api/settings/fanprofile' { return [pscustomobject]@{ strMode = 'calibration'; arrProfile = @() } }
                default { throw "unexpected call: $Method $Path" }
            }
        }
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }

        { Invoke-FanSweep -Connection $conn -BmcHost 'bmc.example.test' `
            -DutySteps @(20) -BaselineDutyPercent 50 -SettleSeconds 1 -Zones $zones `
            -SleepCommand { param($Seconds) } } | Should -Throw -ExpectedMessage '*still set to*'
    }

    It 'throws when the calibration profile collection does not exist yet on the BMC' {
        Mock -ModuleName FanCalibration Invoke-BmcApi {
            switch ("$Method $Path") {
                'Get /api/settings/fanprofile' { return $fanProfileResponse }
                default { throw "unexpected call: $Method $Path" }
            }
        }
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }

        { Invoke-FanSweep -Connection $conn -BmcHost 'bmc.example.test' `
            -DutySteps @(20) -BaselineDutyPercent 50 -SettleSeconds 1 -Zones $zones `
            -SleepCommand { param($Seconds) } } | Should -Throw -ExpectedMessage '*does not exist*'
    }

    It 'sweeps zones independently by array position even when zone Names collide' {
        # Regression guard for the duplicate-Name data corruption bug: two
        # zones sharing the same Name (e.g. both derived with empty
        # arrFanSensor, or unvalidated wizard input) must still each get
        # their own independent duty on the wire, keyed by index not Name.
        $duplicateNamedZones = @(
            [pscustomobject]@{ Name = 'DuplicateZone'; FanSensors = @(184); TempSensors = @(1) }
            [pscustomobject]@{ Name = 'DuplicateZone'; FanSensors = @(185, 186); TempSensors = @(4, 8, 14, 16) }
        )
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }

        $rows = Invoke-FanSweep -Connection $conn -BmcHost 'bmc.example.test' `
            -DutySteps @(20, 100) -BaselineDutyPercent 50 -SettleSeconds 1 -Zones $duplicateNamedZones `
            -SleepCommand { param($Seconds) }

        $rows.Count | Should -Be 6
        $script:putBodies.Count | Should -Be 4

        # first pass (zone index 0 under test): its duty tracks the sweep,
        # the other same-named zone stays pinned at baseline.
        $firstPassPuts = $script:putBodies[0..1]
        $firstPassPuts.CpuInitDuty | Should -Be @(20, 100)
        $firstPassPuts.SystemInitDuty | Should -Be @(50, 50)

        # second pass (zone index 1 under test): duty tracks the sweep on
        # the OTHER zone now, even though both zones share the same Name.
        $secondPassPuts = $script:putBodies[2..3]
        $secondPassPuts.SystemInitDuty | Should -Be @(20, 100)
        $secondPassPuts.CpuInitDuty | Should -Be @(50, 50)
    }

    It 'retries a sentinel sensor reading once and recovers a healthy value on the retry' {
        $sentinelThenHealthy = @(
            [pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN'; raw_reading = 252; reading = -4.0 }
        )
        $healthy = @(
            [pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN'; raw_reading = 9; reading = 1350.0 }
        )
        $script:sensorCallCount = 0
        Mock -ModuleName FanCalibration Invoke-BmcApi {
            switch ("$Method $Path") {
                'Get /api/settings/fanprofile' { return $fanProfileWithCalibration }
                'Get /api/sensors' {
                    $script:sensorCallCount++
                    if ($script:sensorCallCount -eq 1) { return $sentinelThenHealthy } else { return $healthy }
                }
                'Post /api/settings/fanprofile/mode' { $script:modeCalls += $Body.strMode; return [pscustomobject]@{ strMode = $Body.strMode } }
                default { return $null }
            }
        }
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }
        $singleZone = @([pscustomobject]@{ Name = 'CPU0_FAN'; FanSensors = @(184); TempSensors = @(1) })

        $rows = Invoke-FanSweep -Connection $conn -BmcHost 'bmc.example.test' `
            -DutySteps @(50) -BaselineDutyPercent 50 -SettleSeconds 1 -Zones $singleZone `
            -SleepCommand { param($Seconds) }

        $rows[0].RPM | Should -Be '1350'
        $script:sensorCallCount | Should -Be 2
    }

    It 'records NA after exactly one retry when a sensor reading is persistently sentinel' {
        $alwaysSentinel = @(
            [pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN'; raw_reading = 252; reading = -4.0 }
        )
        $script:sensorCallCount = 0
        Mock -ModuleName FanCalibration Invoke-BmcApi {
            switch ("$Method $Path") {
                'Get /api/settings/fanprofile' { return $fanProfileWithCalibration }
                'Get /api/sensors' { $script:sensorCallCount++; return $alwaysSentinel }
                'Post /api/settings/fanprofile/mode' { $script:modeCalls += $Body.strMode; return [pscustomobject]@{ strMode = $Body.strMode } }
                default { return $null }
            }
        }
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }
        $singleZone = @([pscustomobject]@{ Name = 'CPU0_FAN'; FanSensors = @(184); TempSensors = @(1) })

        $rows = Invoke-FanSweep -Connection $conn -BmcHost 'bmc.example.test' `
            -DutySteps @(50) -BaselineDutyPercent 50 -SettleSeconds 1 -Zones $singleZone `
            -SleepCommand { param($Seconds) }

        $rows[0].RPM | Should -Be 'NA'
        $script:sensorCallCount | Should -Be 2
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

        $inventory = Get-BmcInventory -Connection $conn -BmcHost 'bmc.example.test'

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

    It 'throws a clear message naming the file when the JSON is malformed' {
        $malformedPath = Join-Path $TestDrive 'bmc-zones-malformed.json'
        Set-Content -LiteralPath $malformedPath -Value '{ "Name": "broken", ' -Encoding utf8

        { Read-ZoneConfig -Path $malformedPath } | Should -Throw -ExpectedMessage "*$malformedPath*"
    }

    It 'throws a clear message naming the file when an entry is missing required fields' {
        $missingFieldPath = Join-Path $TestDrive 'bmc-zones-missing-field.json'
        Set-Content -LiteralPath $missingFieldPath -Value '[{"Name":"CPU0_FAN","TempSensors":[1]}]' -Encoding utf8

        { Read-ZoneConfig -Path $missingFieldPath } | Should -Throw -ExpectedMessage "*$missingFieldPath*"
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
        $configPath = Join-Path $TestDrive 'bmc-zones-bmc.example.test.json'
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

        $result = Resolve-Zones -Connection $conn -BmcHost 'bmc.example.test' -FanProfileResponse $fanProfileWithPolicies -ConfigPath $configPath

        $result[0].Name | Should -Be 'CPU0_FAN'
    }

    It 'derives zones from the active profile when no config exists and policies are present' {
        Mock -ModuleName FanCalibration Get-BmcInventory {
            return [pscustomobject]@{
                FanSensors  = @([pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN' })
                TempSensors = @([pscustomobject]@{ sensor_number = 1; name = 'CPU0_TEMP' })
            }
        }

        $result = Resolve-Zones -Connection $conn -BmcHost 'bmc.example.test' -FanProfileResponse $fanProfileWithPolicies -ConfigPath $configPath

        $result[0].Name | Should -Be 'CPU0_FAN'
        (Read-ZoneConfig -Path $configPath)[0].Name | Should -Be 'CPU0_FAN'
    }

    It 'runs the wizard when no config exists and the active profile has no policies' {
        Mock -ModuleName FanCalibration Get-BmcInventory {
            return [pscustomobject]@{ FanSensors = @(); TempSensors = @() }
        }

        $result = Resolve-Zones -Connection $conn -BmcHost 'bmc.example.test' -FanProfileResponse $fanProfileFresh `
            -ConfigPath $configPath -WizardCommand { param($Inventory) $wizardResult }

        $result[0].Name | Should -Be 'Wizard'
        (Read-ZoneConfig -Path $configPath)[0].Name | Should -Be 'Wizard'
    }

    It '-NewDevice with confirmed overwrite runs the wizard even when config/policies exist' {
        Save-ZoneConfig -Path $configPath -Zones $sampleZones
        Mock -ModuleName FanCalibration Get-BmcInventory {
            return [pscustomobject]@{ FanSensors = @(); TempSensors = @() }
        }

        $result = Resolve-Zones -Connection $conn -BmcHost 'bmc.example.test' -FanProfileResponse $fanProfileWithPolicies `
            -ConfigPath $configPath -NewDevice -ConfirmCommand { param($Message) 'y' } `
            -WizardCommand { param($Inventory) $wizardResult }

        $result[0].Name | Should -Be 'Wizard'
    }

    It '-NewDevice with declined overwrite falls back to the existing config' {
        Save-ZoneConfig -Path $configPath -Zones $sampleZones

        $result = Resolve-Zones -Connection $conn -BmcHost 'bmc.example.test' -FanProfileResponse $fanProfileWithPolicies `
            -ConfigPath $configPath -NewDevice -ConfirmCommand { param($Message) 'n' } `
            -WizardCommand { param($Inventory) throw 'should not run wizard' }

        $result[0].Name | Should -Be 'CPU0_FAN'
    }

    It 'throws naming the duplicate when the wizard produces zones with the same Name' {
        Mock -ModuleName FanCalibration Get-BmcInventory {
            return [pscustomobject]@{ FanSensors = @(); TempSensors = @() }
        }
        $duplicateWizardResult = @(
            [pscustomobject]@{ Name = ''; FanSensors = @(184); TempSensors = @(1) }
            [pscustomobject]@{ Name = ''; FanSensors = @(185); TempSensors = @(4) }
        )

        { Resolve-Zones -Connection $conn -BmcHost 'bmc.example.test' -FanProfileResponse $fanProfileFresh `
            -ConfigPath $configPath -WizardCommand { param($Inventory) $duplicateWizardResult } } |
            Should -Throw -ExpectedMessage '*duplicate*'
    }

    It 'throws naming the duplicate when the profile-derived zones share the same Name' {
        $duplicateFanProfile = [pscustomobject]@{
            strMode    = 'quiet'
            arrProfile = @([pscustomobject]@{
                strName   = 'quiet'
                arrPolicy = @(
                    [pscustomobject]@{ arrFanSensor = @(); arrSensor = @(1) }
                    [pscustomobject]@{ arrFanSensor = @(); arrSensor = @(4) }
                )
            })
        }
        Mock -ModuleName FanCalibration Get-BmcInventory {
            return [pscustomobject]@{
                FanSensors  = @([pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN' })
                TempSensors = @([pscustomobject]@{ sensor_number = 1; name = 'CPU0_TEMP' })
            }
        }

        { Resolve-Zones -Connection $conn -BmcHost 'bmc.example.test' -FanProfileResponse $duplicateFanProfile `
            -ConfigPath $configPath } | Should -Throw -ExpectedMessage '*duplicate*'
    }

    It 'throws a clear message instead of propagating a null wizard result when the operator aborts with fans available' {
        Mock -ModuleName FanCalibration Get-BmcInventory {
            return [pscustomobject]@{
                FanSensors  = @([pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN' })
                TempSensors = @([pscustomobject]@{ sensor_number = 1; name = 'CPU0_TEMP' })
            }
        }

        { Resolve-Zones -Connection $conn -BmcHost 'bmc.example.test' -FanProfileResponse $fanProfileFresh `
            -ConfigPath $configPath -WizardCommand { param($Inventory) $null } } |
            Should -Throw -ExpectedMessage '*aborted*'
    }

    It 'throws a clear message distinguishing an empty BMC inventory from an aborted wizard' {
        Mock -ModuleName FanCalibration Get-BmcInventory {
            return [pscustomobject]@{ FanSensors = @(); TempSensors = @() }
        }

        { Resolve-Zones -Connection $conn -BmcHost 'bmc.example.test' -FanProfileResponse $fanProfileFresh `
            -ConfigPath $configPath -WizardCommand { param($Inventory) $null } } |
            Should -Throw -ExpectedMessage '*no fan sensors*'
    }
}
