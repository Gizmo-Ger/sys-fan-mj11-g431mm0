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
