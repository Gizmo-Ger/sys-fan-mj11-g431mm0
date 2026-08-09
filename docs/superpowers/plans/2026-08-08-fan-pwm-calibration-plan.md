# Fan PWM/RPM Calibration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Calibrate-FanCurve.ps1`, a PowerShell tool that sweeps PWM duty per fan zone on the Gigabyte MJ11-EC1/G431-MM0 BMC and records the resulting RPM per fan, without touching the live `default`/`quiet` fan profiles.

**Architecture:** A pure-logic PowerShell module (`FanCalibration.psm1`) holds everything unit-testable with Pester — BMC REST client, curve/body builders, sentinel detection, CSV formatting, and the sweep orchestration (with its HTTP calls mockable). A thin CLI script (`Calibrate-FanCurve.ps1`) parses parameters, imports the module, runs the sweep, and writes output. This keeps the one genuinely hardware-dependent piece (the actual live sweep) as the only step that needs manual verification against real hardware — everything else is covered by fast, network-free tests.

**Tech Stack:** PowerShell 7 (`pwsh`), `Invoke-RestMethod`/`Invoke-WebRequest` with `-SessionVariable`/`-SkipCertificateCheck` (no `curl.exe` shelling — avoids the PowerShell-to-native-argv quoting corruption risk that broke the first attempt's `--data-binary $payload` calls), Pester 5.x for tests.

## Global Constraints

- Never write to the `default`/`quiet` fan profile collections — all sweeping happens on a separate `calibration` collection (spec: isolated-profile safety strategy).
- Sweep zones sequentially, never concurrently — CPU zone (fan sensor 184) and System zone (fan sensors 185+186) are swept one at a time so an RPM change can be attributed to the zone under test.
- Duty sweep range: 20–100% in 10% steps. Settle time: 20 seconds per step.
- A sensor reading with `raw_reading -eq 252` is a known sentinel/error value (observed live this session across unrelated sensors simultaneously) — never trust it as real; treat as `NA`.
- The original active `strMode` must be restored via `POST /api/settings/fanprofile/mode` in a `finally` block — on success, error, or interrupt.
- Confirmed API surface (reverse-engineered this session, all against `https://192.168.178.21`):
  - `POST /api/session` — form body `username=<user>&password=<pass>`, header `X-CSRFTOKEN: null`, `Content-Type: application/x-www-form-urlencoded`. Response JSON includes `CSRFToken`; `QSESSIONID` cookie arrives via `Set-Cookie` on the same response.
  - `GET /api/settings/fanprofile` — returns `{strMode, strVersion, arrProfile: [{strName, strVersion, arrPolicy: [...]}]}`.
  - `PUT /api/settings/fanprofile/collection/<name>` — body `{strName, strVersion, arrPolicy: [...]}`, replaces that named profile's policies wholesale.
  - `POST /api/settings/fanprofile/mode` — body `{"strMode":"<name>"}`, confirmed live this session (200 OK, echoes `{"strMode":"<name>"}`). This is the reload trigger — the first calibration attempt likely failed because it PUT the active collection directly without ever calling this, so the running fan daemon never picked up the change.
  - `GET /api/sensors` — array of sensor objects; relevant fields `sensor_number` (int), `reading` (double, RPM for fan sensors), `raw_reading` (sentinel check).
  - Fan sensor numbers: `184`=CPU0_FAN, `185`=SYS_FAN1, `186`=SYS_FAN2.
  - All authenticated calls need `X-CSRFTOKEN: <token>` and `X-Requested-With: XMLHttpRequest` headers plus the session cookie.

---

## File Structure

- Create: `FanCalibration.psm1` — all logic (BMC client, pure builders, sweep orchestration)
- Create: `FanCalibration.Tests.ps1` — Pester tests for every function in the module
- Create: `Calibrate-FanCurve.ps1` — thin CLI entry point
- All three at the repo root of `sys-fan-mj11-g431mm0`, matching the existing flat layout (`build_sku_bin.sh` also lives at root).

---

### Task 1: Module scaffold + `New-FlatCurvePolicy`

**Files:**
- Create: `FanCalibration.psm1`
- Create: `FanCalibration.Tests.ps1`

**Interfaces:**
- Produces: `New-FlatCurvePolicy(-SourcePolicy <pscustomobject>, -DutyPercent <int>) -> pscustomobject` — a policy object with `arrRef=@(0,100)`, `arrDuty=@($DutyPercent,$DutyPercent)`, `iInitDuty=$DutyPercent`, all other fields copied unchanged from `$SourcePolicy`.

- [ ] **Step 1: Confirm Pester 5.x is available**

Run: `pwsh -NoProfile -Command "Get-Module -ListAvailable Pester | Select-Object Name,Version"`
Expected: a `Pester` entry with `Version` 5.x or higher. If missing or older:
Run: `pwsh -NoProfile -Command "Install-Module -Name Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser -SkipPublisherCheck"`

- [ ] **Step 2: Write the failing test**

Create `FanCalibration.Tests.ps1`:

```powershell
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — `New-FlatCurvePolicy` is not recognized (module file is empty/doesn't export it yet).

- [ ] **Step 4: Write minimal implementation**

Create `FanCalibration.psm1` with:

```powershell
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

Export-ModuleMember -Function New-FlatCurvePolicy
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "feat: add New-FlatCurvePolicy for fan calibration sweep"
```

---

### Task 2: `Test-SentinelReading`

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `Test-SentinelReading(-Sensor <pscustomobject>) -> bool` — `$true` when `$Sensor.raw_reading -eq 252`.

- [ ] **Step 1: Write the failing test**

Append to `FanCalibration.Tests.ps1`:

```powershell
Describe 'Test-SentinelReading' {
    It 'flags the known sentinel raw_reading value' {
        Test-SentinelReading -Sensor ([pscustomobject]@{ raw_reading = 252; reading = -4.0 }) | Should -BeTrue
    }
    It 'does not flag a normal reading' {
        Test-SentinelReading -Sensor ([pscustomobject]@{ raw_reading = 60; reading = 60.0 }) | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Test-SentinelReading` not recognized.

- [ ] **Step 3: Write minimal implementation**

Add to `FanCalibration.psm1`:

```powershell
function Test-SentinelReading {
    param([Parameter(Mandatory)][pscustomobject]$Sensor)
    return $Sensor.raw_reading -eq 252
}
```

Update the `Export-ModuleMember` line:

```powershell
Export-ModuleMember -Function New-FlatCurvePolicy, Test-SentinelReading
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS (3 tests total, all green)

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "feat: add Test-SentinelReading sentinel detection"
```

---

### Task 3: `Get-FanRpm`

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Consumes: `Test-SentinelReading` from Task 2.
- Produces: `Get-FanRpm(-Sensors <array>, -SensorNumber <int>) -> [Nullable[double]]` — the fan's `reading` value, or `$null` if the sensor isn't found or its reading is a sentinel.

- [ ] **Step 1: Write the failing test**

Append to `FanCalibration.Tests.ps1`:

```powershell
Describe 'Get-FanRpm' {
    $sensors = @(
        [pscustomobject]@{ sensor_number = 184; name = 'CPU0_FAN'; raw_reading = 9; reading = 1350.0 }
        [pscustomobject]@{ sensor_number = 185; name = 'SYS_FAN1'; raw_reading = 0; reading = 0.0 }
        [pscustomobject]@{ sensor_number = 186; name = 'SYS_FAN2'; raw_reading = 252; reading = 0.0 }
    )

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-FanRpm` not recognized.

- [ ] **Step 3: Write minimal implementation**

Add to `FanCalibration.psm1`:

```powershell
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
```

Update `Export-ModuleMember`:

```powershell
Export-ModuleMember -Function New-FlatCurvePolicy, Test-SentinelReading, Get-FanRpm
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS (7 tests total)

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "feat: add Get-FanRpm sensor lookup with sentinel guard"
```

---

### Task 4: `Get-ZoneTemplate` and `New-CalibrationProfileBody`

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Consumes: nothing from prior tasks (pure data-shape functions).
- Produces:
  - `Get-ZoneTemplate(-FanProfileResponse <pscustomobject>, -FanSensorNumber <int>) -> pscustomobject` — finds the active profile's policy whose `arrFanSensor` contains `$FanSensorNumber`. Throws if the active profile or a matching policy can't be found.
  - `New-CalibrationProfileBody(-CpuZonePolicy <pscustomobject>, -SystemZonePolicy <pscustomobject>) -> pscustomobject` — `{strName='calibration'; strVersion='1.00'; arrPolicy=@($CpuZonePolicy, $SystemZonePolicy)}`.

- [ ] **Step 1: Write the failing tests**

Append to `FanCalibration.Tests.ps1`:

```powershell
Describe 'Get-ZoneTemplate' {
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — both functions not recognized.

- [ ] **Step 3: Write minimal implementation**

Add to `FanCalibration.psm1`:

```powershell
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
```

Update `Export-ModuleMember`:

```powershell
Export-ModuleMember -Function New-FlatCurvePolicy, Test-SentinelReading, Get-FanRpm, Get-ZoneTemplate, New-CalibrationProfileBody
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS (11 tests total)

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "feat: add Get-ZoneTemplate and New-CalibrationProfileBody"
```

---

### Task 5: `New-CalibrationCsvRow`

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Consumes: nothing from prior tasks.
- Produces: `New-CalibrationCsvRow(-Zone <string>, -DutyPercent <int>, -FanName <string>, -Rpm <Nullable[double]>) -> pscustomobject` with properties `Zone, DutyPercent, FanName, RPM` where `RPM` is `'NA'` (string) when `$Rpm` is `$null`, otherwise the numeric value.

- [ ] **Step 1: Write the failing test**

Append to `FanCalibration.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — `New-CalibrationCsvRow` not recognized.

- [ ] **Step 3: Write minimal implementation**

Add to `FanCalibration.psm1`:

```powershell
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
```

Update `Export-ModuleMember`:

```powershell
Export-ModuleMember -Function New-FlatCurvePolicy, Test-SentinelReading, Get-FanRpm, Get-ZoneTemplate, New-CalibrationProfileBody, New-CalibrationCsvRow
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS (13 tests total)

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "feat: add New-CalibrationCsvRow output formatting"
```

---

### Task 6: `Connect-Bmc` and `Invoke-BmcApi`

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Consumes: nothing from prior tasks.
- Produces:
  - `Connect-Bmc(-BmcHost <string>, -Credential <pscredential>) -> pscustomobject` — `{WebSession=<Microsoft.PowerShell.Commands.WebRequestSession>; CsrfToken=<string>}`. Throws if the login response has no `CSRFToken`.
  - `Invoke-BmcApi(-Connection <pscustomobject>, -BmcHost <string>, -Path <string>, [-Method <string> = 'Get'], [-Body <object> = $null]) -> object` — wraps `Invoke-RestMethod` with the session, CSRF header, `X-Requested-With`, `-SkipCertificateCheck`, `-TimeoutSec 15`. JSON-encodes `$Body` when present.

- [ ] **Step 1: Write the failing tests**

Append to `FanCalibration.Tests.ps1`:

```powershell
Describe 'Connect-Bmc' {
    It 'posts credentials and returns the session plus CSRF token' {
        Mock -ModuleName FanCalibration Invoke-RestMethod {
            $script:capturedConnectArgs = $args
            $script:capturedConnectParams = $PSBoundParameters
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Connect-Bmc`/`Invoke-BmcApi` not recognized.

- [ ] **Step 3: Write minimal implementation**

Add to `FanCalibration.psm1`:

```powershell
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
```

Update `Export-ModuleMember`:

```powershell
Export-ModuleMember -Function New-FlatCurvePolicy, Test-SentinelReading, Get-FanRpm, Get-ZoneTemplate, New-CalibrationProfileBody, New-CalibrationCsvRow, Connect-Bmc, Invoke-BmcApi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS (16 tests total)

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "feat: add Connect-Bmc and Invoke-BmcApi REST client"
```

---

### Task 7: `Invoke-FanSweep` orchestration

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Consumes: `Get-ZoneTemplate`, `New-FlatCurvePolicy`, `New-CalibrationProfileBody`, `Get-FanRpm`, `New-CalibrationCsvRow`, `Invoke-BmcApi` (all mockable — `Invoke-BmcApi` is mocked in this task's tests so no real network or `Invoke-RestMethod` call happens).
- Produces: `Invoke-FanSweep(-Connection <pscustomobject>, -BmcHost <string>, -DutySteps <int[]>, -BaselineDutyPercent <int>, -SettleSeconds <int>, [-SleepCommand <scriptblock>]) -> pscustomobject[]` — array of CSV-row objects (from `New-CalibrationCsvRow`), one per (duty step × fan) measurement across both zones. Restores the original `strMode` in a `finally` block regardless of success or failure. `-SleepCommand` defaults to `{ param($Seconds) Start-Sleep -Seconds $Seconds }` and exists purely so tests can inject a no-op.

- [ ] **Step 1: Write the failing tests**

Append to `FanCalibration.Tests.ps1`:

```powershell
Describe 'Invoke-FanSweep' {
    BeforeEach {
        $script:modeCalls = @()
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Invoke-FanSweep` not recognized.

- [ ] **Step 3: Write minimal implementation**

Add to `FanCalibration.psm1`:

```powershell
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

    $fanProfile = Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost -Path '/api/settings/fanprofile'
    $originalMode = $fanProfile.strMode
    $cpuTemplate = Get-ZoneTemplate -FanProfileResponse $fanProfile -FanSensorNumber 184
    $systemTemplate = Get-ZoneTemplate -FanProfileResponse $fanProfile -FanSensorNumber 185

    $rows = @()

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

                $sensors = Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost -Path '/api/sensors'

                foreach ($sensorNumber in $zone.FanSensorNumbers) {
                    $rpm = Get-FanRpm -Sensors $sensors -SensorNumber $sensorNumber
                    $rows += New-CalibrationCsvRow -Zone $zone.Name -DutyPercent $duty `
                        -FanName $fanNames[$sensorNumber] -Rpm $rpm
                }
            }
        }
    }
    finally {
        Invoke-BmcApi -Connection $Connection -BmcHost $BmcHost `
            -Path '/api/settings/fanprofile/mode' -Method 'Post' -Body @{ strMode = $originalMode } | Out-Null
    }

    return $rows
}
```

Update `Export-ModuleMember`:

```powershell
Export-ModuleMember -Function New-FlatCurvePolicy, Test-SentinelReading, Get-FanRpm, Get-ZoneTemplate, New-CalibrationProfileBody, New-CalibrationCsvRow, Connect-Bmc, Invoke-BmcApi, Invoke-FanSweep
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS (18 tests total)

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "feat: add Invoke-FanSweep sweep orchestration with mode restore"
```

---

### Task 8: CLI entry point `Calibrate-FanCurve.ps1`

**Files:**
- Create: `Calibrate-FanCurve.ps1`

**Interfaces:**
- Consumes: `Connect-Bmc`, `Invoke-FanSweep` from the module.
- Produces: a runnable script; no further consumers.

- [ ] **Step 1: Write the script**

```powershell
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
```

- [ ] **Step 2: Manual dry-run verification against the real BMC**

This step is hardware-dependent and cannot run under Pester — verify manually:

Run: `pwsh -NoProfile -File .\Calibrate-FanCurve.ps1 -DutySteps @(30,50) -SettleSeconds 15`

Before running, note the current active mode: `curl.exe -k -s -b "<cookie>" -H "X-CSRFTOKEN: <token>" https://192.168.178.21/api/settings/fanprofile` and check `strMode` (expected `quiet` per this session's state).

Expected during the run:
- Console prints one line per (zone, duty, fan) measurement — 2 duty steps × 3 fans = 6 lines.
- A `fan-calibration-<timestamp>.csv` file appears in the repo root with a header row `Zone,DutyPercent,FanName,RPM` and 6 data rows.
- CPU0_FAN's RPM visibly changes between the 30% and 50% measurements (it's the only fan driven during the CPU-zone pass); SYS_FAN1/SYS_FAN2 stay near the baseline-duty RPM during the CPU-zone pass, and vice versa during the System-zone pass.

Expected after the run (whether it succeeded or you interrupt it with Ctrl+C partway through):
Run the same `strMode` check again — `strMode` must read `quiet` again, confirming the `finally` restore fired.

- [ ] **Step 3: Commit**

```bash
git add Calibrate-FanCurve.ps1
git commit -m "feat: add Calibrate-FanCurve.ps1 CLI entry point"
```

---

## Self-Review Notes

- **Spec coverage:** login flow (Task 6), isolated `calibration` profile + mode-switch reload trigger (Task 7), sequential zone sweep (Task 7's `foreach ($zone in $zones)` outer loop), sentinel handling (Tasks 2–3), CSV + live console output (Task 8), mode restore via `finally` including on error (Task 7, tested explicitly in Task 7's second test) — all covered.
- **Type consistency:** `Get-FanRpm` and `New-CalibrationCsvRow` both use `[Nullable[double]]`/`$null` consistently for "no reading" across Tasks 3, 5, and 7's consumption of both. `Invoke-BmcApi`'s `-Body` parameter accepts a hashtable/pscustomobject and is used identically in Task 6's tests and Task 7's implementation.
- **No placeholders:** every step has runnable code and a concrete expected result; Task 8's manual-verification step names exact commands and exact expected console/file output instead of "test manually".
