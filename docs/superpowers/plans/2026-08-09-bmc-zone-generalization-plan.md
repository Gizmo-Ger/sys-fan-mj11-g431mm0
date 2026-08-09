# BMC Fan-Zone Generalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `Calibrate-FanCurve.ps1`/`FanCalibration.psm1`'s hardcoded MJ11-EC1 fan-sensor numbers (184/185/186) and fixed two-zone split with zones derived from the BMC's own configuration, or an interactive wizard when the BMC has never been configured — so the tool works on any board behind this REST API.

**Architecture:** New pure/mockable functions (`Get-BmcInventory`, `Read-ZoneConfig`/`Save-ZoneConfig`, `New-ZonesFromProfile`, `Read-ZoneWizard`, `Resolve-Zones`) added to `FanCalibration.psm1` alongside targeted signature changes to two existing functions (`Get-ZoneTemplate`, `New-CalibrationProfileBody`) and a rewrite of `Invoke-FanSweep`'s zone handling from fixed-2 to N-ary. `Calibrate-FanCurve.ps1` gains a `-NewDevice` switch and loses its hardcoded `-BmcHost` default.

**Tech Stack:** PowerShell 7 (`pwsh`), Pester 6.x (existing suite — 24 tests passing at the start of this plan).

## Global Constraints

- `Get-BmcInventory` returns `{FanSensors: [{sensor_number,name}...], TempSensors: [{sensor_number,name}...]}` from `GET /api/sensors`, filtering `type -eq 'fan'` / `type -eq 'temperature'`.
- Zone config file: `bmc-zones-<BmcHost>.json` — one file per BMC, JSON array of `{Name, FanSensors:[int], TempSensors:[int]}`. Gitignored (per-device data, not source).
- `Resolve-Zones` decision order (exact, from the spec): (1) config file exists and `-NewDevice` not set → load and return it; (2) config file exists and `-NewDevice` set → confirm overwrite, `j` → wizard, anything else → load existing; (3) no config file, `-NewDevice` not set, active profile has ≥1 real policy → derive zones from it, save, return; (4) no config file and (`-NewDevice` set OR no usable policy) → wizard, save, return.
- Zone name = its fan sensor names joined with `+` (e.g. `"SYS_FAN1+SYS_FAN2"`), resolved from `Get-BmcInventory`'s `FanSensors` list.
- `Get-ZoneTemplate` no longer throws when no matching policy exists — it falls back to a default policy skeleton (`iPolicyType=2`, `iSensorCode` = `3` if the zone has >1 temp sensor else `1`, `iInitDuty=40`, all other numeric fields `0`, `arrHexVendorID`/`arrHexDeviceID` empty). This is an intentional behavior change from the current plan/spec — **update its existing tests to match, don't just add new ones.**
- `New-CalibrationProfileBody` takes `-ZonePolicies <array>` (any count) instead of `-CpuZonePolicy`/`-SystemZonePolicy`. **Update its existing test to match.**
- `Invoke-FanSweep` takes a new mandatory `-Zones <array>` parameter (the resolved zone list) and sweeps them generically — no hardcoded `$zones`/`$fanNames` tables remain. **Its existing tests need a substantial rewrite**, not incremental addition, since the fixed 2-zone fixture no longer matches the function's contract.
- `-BmcHost` on `Calibrate-FanCurve.ps1` becomes mandatory with no default (currently defaults to `'192.168.178.21'`).
- Fan names for CSV rows are read from each `GET /api/sensors` response's own `name` field per sensor, not from a hardcoded lookup table.
- All new functions follow this module's existing conventions: `Export-ModuleMember` updated every task, `BeforeAll` blocks for shared Pester fixtures (Pester 6 requirement already established in this codebase), German user-facing strings (matches existing `throw`/`Write-Warning` messages in the module).

---

## File Structure

- Modify: `FanCalibration.psm1` — add 6 new functions, change 2 existing signatures, rewrite `Invoke-FanSweep`'s zone handling.
- Modify: `FanCalibration.Tests.ps1` — add tests for new functions, replace tests for the 2 changed functions and the rewritten `Invoke-FanSweep`.
- Modify: `Calibrate-FanCurve.ps1` — add `-NewDevice`, remove `-BmcHost` default, call `Resolve-Zones` before `Invoke-FanSweep`.
- Modify: `README.md` — document the zone wizard, `-NewDevice`, and the now-required `-BmcHost`.
- Modify: `.gitignore` — add `bmc-zones-*.json`.

---

### Task 1: `Get-BmcInventory`

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-BmcApi` (Task 6 from the prior plan — already exported).
- Produces: `Get-BmcInventory(-Connection <pscustomobject>, -BmcHost <string>) -> pscustomobject` — `{FanSensors: [{sensor_number,name}], TempSensors: [{sensor_number,name}]}`, both always arrays (never a bare scalar when exactly one match).

- [ ] **Step 1: Write the failing test**

Append to `FanCalibration.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-BmcInventory` not recognized.

- [ ] **Step 3: Write minimal implementation**

Add to `FanCalibration.psm1`:

```powershell
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
```

Update `Export-ModuleMember` to add `Get-BmcInventory`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS (25 tests total)

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "feat: add Get-BmcInventory for fan/temp sensor discovery"
```

---

### Task 2: `Read-ZoneConfig` / `Save-ZoneConfig`

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Produces:
  - `Read-ZoneConfig(-Path <string>) -> array|$null` — `$null` if the file doesn't exist, otherwise the parsed JSON array.
  - `Save-ZoneConfig(-Path <string>, -Zones <array>) -> void` — writes the array as JSON to `Path`.

- [ ] **Step 1: Write the failing test**

Append to `FanCalibration.Tests.ps1`:

```powershell
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
}
```

(`$TestDrive` is a Pester-provided temp directory, auto-cleaned after the run — no manual cleanup needed.)

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — functions not recognized.

- [ ] **Step 3: Write minimal implementation**

Add to `FanCalibration.psm1`:

```powershell
function Read-ZoneConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Save-ZoneConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][array]$Zones
    )
    $Zones | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
}
```

Update `Export-ModuleMember` to add `Read-ZoneConfig`, `Save-ZoneConfig`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS (27 tests total)

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "feat: add Read-ZoneConfig/Save-ZoneConfig for per-device zone persistence"
```

---

### Task 3: `New-ZonesFromProfile`

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Consumes: nothing from prior tasks (pure data transform, though it's the natural counterpart to `Get-BmcInventory`'s output shape).
- Produces: `New-ZonesFromProfile(-FanProfileResponse <pscustomobject>, -Inventory <pscustomobject>) -> array|$null` — one zone per policy in the active profile (`arrProfile` entry whose `strName` matches `strMode`), `$null` if there's no active profile or it has zero policies.

- [ ] **Step 1: Write the failing test**

Append to `FanCalibration.Tests.ps1`:

```powershell
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — `New-ZonesFromProfile` not recognized.

- [ ] **Step 3: Write minimal implementation**

Add to `FanCalibration.psm1`:

```powershell
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
```

Update `Export-ModuleMember` to add `New-ZonesFromProfile`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS (30 tests total)

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "feat: add New-ZonesFromProfile to derive zones from an existing profile"
```

---

### Task 4: `Read-ZoneWizard`

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Produces: `Read-ZoneWizard(-Inventory <pscustomobject>) -> array` — interactively built zone list via `Read-Host`/`Write-Host`. Loop ends on an empty zone-name entry OR once every fan sensor from `Inventory.FanSensors` has been assigned, whichever first. Warns (via `Write-Warning`, doesn't throw) about any fan sensors left unassigned when the loop ends.

- [ ] **Step 1: Write the failing test**

Append to `FanCalibration.Tests.ps1`:

```powershell
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

        $zones.Count | Should -Be 1
        $zones[0].FanSensors | Should -Be @(184, 185, 186)
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Read-ZoneWizard` not recognized.

- [ ] **Step 3: Write minimal implementation**

Add to `FanCalibration.psm1`:

```powershell
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
        $fanNums = @($fanInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })

        $tempInput = Read-Host 'Temp-Sensor-Nummern (kommagetrennt, optional)'
        $tempNums = @($tempInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })

        $zones += [pscustomobject]@{ Name = $name; FanSensors = $fanNums; TempSensors = $tempNums }
        $assignedFans += $fanNums
    }

    $unassigned = @($allFanNumbers | Where-Object { $_ -notin $assignedFans })
    if ($unassigned.Count -gt 0) {
        Write-Warning "Folgende Fan-Sensoren wurden keiner Zone zugeordnet: $($unassigned -join ', ')"
    }

    return @($zones)
}
```

Update `Export-ModuleMember` to add `Read-ZoneWizard`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS (33 tests total)

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "feat: add Read-ZoneWizard interactive zone setup"
```

---

### Task 5: `Resolve-Zones`

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Consumes: `Get-BmcInventory` (Task 1), `Read-ZoneConfig`/`Save-ZoneConfig` (Task 2), `New-ZonesFromProfile` (Task 3), `Read-ZoneWizard` (Task 4, via the injectable `-WizardCommand` seam).
- Produces: `Resolve-Zones(-Connection <pscustomobject>, -BmcHost <string>, -FanProfileResponse <pscustomobject>, -ConfigPath <string>, [-NewDevice], [-ConfirmCommand <scriptblock>], [-WizardCommand <scriptblock>]) -> array` — implements the 4-case decision order from Global Constraints. `-ConfirmCommand` defaults to `{ param($Message) Read-Host $Message }`, `-WizardCommand` defaults to `{ param($Inventory) Read-ZoneWizard -Inventory $Inventory }` — both exist purely so tests can inject fakes instead of hitting the console.

- [ ] **Step 1: Write the failing tests**

Append to `FanCalibration.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Resolve-Zones` not recognized.

- [ ] **Step 3: Write minimal implementation**

Add to `FanCalibration.psm1`:

```powershell
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

    if ($existing -and -not $NewDevice) {
        return $existing
    }

    if ($existing -and $NewDevice) {
        $answer = & $ConfirmCommand 'Bestehende Zonen-Config gefunden, wirklich ueberschreiben? (j/n)'
        if ($answer -ne 'j') {
            return $existing
        }
    }

    $inventory = Get-BmcInventory -Connection $Connection -BmcHost $BmcHost

    if (-not $NewDevice) {
        $derived = New-ZonesFromProfile -FanProfileResponse $FanProfileResponse -Inventory $inventory
        if ($derived) {
            Save-ZoneConfig -Path $ConfigPath -Zones $derived
            return $derived
        }
    }

    $wizardZones = & $WizardCommand $inventory
    Save-ZoneConfig -Path $ConfigPath -Zones $wizardZones
    return $wizardZones
}
```

Update `Export-ModuleMember` to add `Resolve-Zones`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS (38 tests total)

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "feat: add Resolve-Zones orchestrator for config/profile/wizard zone resolution"
```

---

### Task 6: Generalize `Get-ZoneTemplate` (breaking change — replace its tests)

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Produces: `Get-ZoneTemplate(-FanProfileResponse <pscustomobject>, -Zone <pscustomobject>) -> pscustomobject` — **signature changed** from `-FanSensorNumber <int>` to `-Zone <pscustomobject>` (a zone object with `.FanSensors`/`.TempSensors`, matching `Resolve-Zones`' output shape). Finds an existing policy in the active profile whose `arrFanSensor` overlaps `Zone.FanSensors`; if none found, **no longer throws** — returns a default policy skeleton instead.

- [ ] **Step 1: Replace the existing `Get-ZoneTemplate` Describe block**

Find the existing `Describe 'Get-ZoneTemplate' { ... }` block in `FanCalibration.Tests.ps1` (from the prior plan — it currently tests `-FanSensorNumber` and asserts `Should -Throw` on no match). **Delete that entire block** and replace it with:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-ZoneTemplate` still has the old signature/behavior (this is the "red" step for the *changed* behavior, even though the function already exists).

- [ ] **Step 3: Replace the `Get-ZoneTemplate` implementation**

In `FanCalibration.psm1`, replace the existing `Get-ZoneTemplate` function body entirely with:

```powershell
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
```

(The function's *name* stays exported the same as before — no `Export-ModuleMember` change needed this task.)

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS — count will be lower than a pure addition would suggest, since 3 old tests were deleted and 5 new ones added (net +2 from this task's replacement; verify against whatever the actual running total is rather than a predicted number, since exact prior counts depend on Task 1-5 having landed first).

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "refactor: generalize Get-ZoneTemplate to any zone, fall back instead of throwing"
```

---

### Task 7: Generalize `New-CalibrationProfileBody` (breaking change — replace its test)

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Produces: `New-CalibrationProfileBody(-ZonePolicies <array>) -> pscustomobject` — **signature changed** from `-CpuZonePolicy`/`-SystemZonePolicy` to a single `-ZonePolicies` array of any length. `arrPolicy` is that array directly.

- [ ] **Step 1: Replace the existing `New-CalibrationProfileBody` test**

Find the existing `Describe 'New-CalibrationProfileBody' { ... }` block and replace it with:

```powershell
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — old signature doesn't accept `-ZonePolicies`.

- [ ] **Step 3: Replace the implementation**

In `FanCalibration.psm1`, replace `New-CalibrationProfileBody` with:

```powershell
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "refactor: generalize New-CalibrationProfileBody to N zone policies"
```

---

### Task 8: Rewrite `Invoke-FanSweep` for N-ary zones (breaking change — replace its tests)

**Files:**
- Modify: `FanCalibration.psm1`
- Modify: `FanCalibration.Tests.ps1`

**Interfaces:**
- Consumes: `Get-ZoneTemplate` (Task 6, new signature), `New-CalibrationProfileBody` (Task 7, new signature), `New-FlatCurvePolicy`, `Get-FanRpm`, `New-CalibrationCsvRow`, `Invoke-BmcApi` — all pre-existing, called the same way as before except where noted.
- Produces: `Invoke-FanSweep(-Connection <pscustomobject>, -BmcHost <string>, -DutySteps <int[]>, -BaselineDutyPercent <int>, -SettleSeconds <int>, -Zones <array>, [-SleepCommand <scriptblock>]) -> pscustomobject[]` (streamed to the pipeline, per the existing streaming behavior from the prior plan's final-review fix — **do not reintroduce a `$rows` accumulator or a `return` statement for it**). **New mandatory `-Zones` parameter.** Sweeps zones sequentially (unchanged constraint); for the zone under test, its duty is swept through `$DutySteps`; every OTHER zone (not just "the one other zone") is held at `$BaselineDutyPercent`. Fan names for CSV rows come from the live `/api/sensors` response's own `name` field, looked up by `sensor_number` — the hardcoded `$fanNames` table is deleted entirely.

- [ ] **Step 1: Replace the existing `Invoke-FanSweep` Describe block**

Find the existing `Describe 'Invoke-FanSweep' { ... }` block (it currently hardcodes a 2-zone `$zones` array inside the module and doesn't take a `-Zones` parameter) and replace the whole block with:

```powershell
Describe 'Invoke-FanSweep' {
    BeforeEach {
        $script:modeCalls = @()
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
                'Post /api/settings/fanprofile/mode' { $script:modeCalls += $Body.strMode; return [pscustomobject]@{ strMode = $Body.strMode } }
                default { return $null }
            }
        }
    }

    It 'sweeps N zones sequentially, holding every other zone at baseline, one row per duty per fan' {
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }
        $rows = Invoke-FanSweep -Connection $conn -BmcHost '192.168.178.21' `
            -DutySteps @(20, 50, 100) -BaselineDutyPercent 50 -SettleSeconds 1 -Zones $zones `
            -SleepCommand { param($Seconds) }

        $rows.Count | Should -Be 9
        ($rows | Where-Object FanName -eq 'CPU0_FAN').Count | Should -Be 3
        ($rows | Where-Object FanName -eq 'SYS_FAN1').Count | Should -Be 3
        ($rows | Where-Object FanName -eq 'SYS_FAN2').Count | Should -Be 3
        ($rows | Where-Object { $_.FanName -eq 'CPU0_FAN' -and $_.DutyPercent -eq 50 }).RPM | Should -Be '1350'
        $script:modeCalls | Should -Contain 'calibration'
        $script:modeCalls[-1] | Should -Be 'quiet'
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

        { Invoke-FanSweep -Connection $conn -BmcHost '192.168.178.21' `
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

        { Invoke-FanSweep -Connection $conn -BmcHost '192.168.178.21' `
            -DutySteps @(20) -BaselineDutyPercent 50 -SettleSeconds 1 -Zones $zones `
            -SleepCommand { param($Seconds) } } | Should -Throw
    }

    It 'throws when the calibration profile collection does not exist yet on the BMC' {
        Mock -ModuleName FanCalibration Invoke-BmcApi {
            switch ("$Method $Path") {
                'Get /api/settings/fanprofile' { return $fanProfileResponse }
                default { throw "unexpected call: $Method $Path" }
            }
        }
        $conn = [pscustomobject]@{ WebSession = $null; CsrfToken = 'tok1' }

        { Invoke-FanSweep -Connection $conn -BmcHost '192.168.178.21' `
            -DutySteps @(20) -BaselineDutyPercent 50 -SettleSeconds 1 -Zones $zones `
            -SleepCommand { param($Seconds) } } | Should -Throw
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

        $rows = Invoke-FanSweep -Connection $conn -BmcHost '192.168.178.21' `
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

        $rows = Invoke-FanSweep -Connection $conn -BmcHost '192.168.178.21' `
            -DutySteps @(50) -BaselineDutyPercent 50 -SettleSeconds 1 -Zones $singleZone `
            -SleepCommand { param($Seconds) }

        $rows[0].RPM | Should -Be 'NA'
        $script:sensorCallCount | Should -Be 2
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Invoke-FanSweep` doesn't accept `-Zones`, doesn't have the crash-guard/preflight/retry behavior yet under this shape.

- [ ] **Step 3: Replace the `Invoke-FanSweep` implementation**

In `FanCalibration.psm1`, replace the entire `Invoke-FanSweep` function with:

```powershell
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

    $zoneTemplates = @{}
    foreach ($zone in $Zones) {
        $zoneTemplates[$zone.Name] = Get-ZoneTemplate -FanProfileResponse $fanProfile -Zone $zone
    }

    try {
        foreach ($zoneUnderTest in $Zones) {
            foreach ($duty in $DutySteps) {
                $zonePolicies = foreach ($zone in $Zones) {
                    $d = if ($zone.Name -eq $zoneUnderTest.Name) { $duty } else { $BaselineDutyPercent }
                    New-FlatCurvePolicy -SourcePolicy $zoneTemplates[$zone.Name] -DutyPercent $d
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
```

Note this keeps the streaming behavior (each `New-CalibrationCsvRow` call's result flows to the pipeline directly, no `$rows` accumulator, no explicit `return`) from the prior plan's final-review fix — do not reintroduce buffering.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path FanCalibration.Tests.ps1 -Output Detailed"`
Expected: PASS — all tests green, including every other Describe block in the file (this is the most invasive change in the plan; a regression anywhere else in the suite means something in this rewrite broke a contract another function depends on).

- [ ] **Step 5: Commit**

```bash
git add FanCalibration.psm1 FanCalibration.Tests.ps1
git commit -m "refactor: rewrite Invoke-FanSweep to sweep N zones instead of hardcoded CPU/System"
```

---

### Task 9: Wire `-NewDevice` and zone resolution into `Calibrate-FanCurve.ps1`

**Files:**
- Modify: `Calibrate-FanCurve.ps1`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `Connect-Bmc`, `Get-BmcInventory` (indirectly, via `Resolve-Zones`), `Resolve-Zones`, `Invoke-FanSweep` — all from the module.
- Produces: an updated CLI script; no further consumers in this plan.

- [ ] **Step 1: Replace `Calibrate-FanCurve.ps1`**

Replace the entire file with:

```powershell
param(
    [Parameter(Mandatory)][string]$BmcHost,
    [pscredential]$Credential,
    [int[]]$DutySteps = @(20,30,40,50,60,70,80,90,100),
    [int]$BaselineDutyPercent = 50,
    [int]$SettleSeconds = 20,
    [string]$OutDir = $PSScriptRoot,
    [switch]$NewDevice
)

<#
.NOTES
    Prerequisite (one-time, per BMC): the 'calibration' fan-profile collection
    must already exist before this script can write to it. If it doesn't yet,
    create it once with:

        POST /api/settings/fanprofile/collection
        Content-Type: application/json
        {"strName":"calibration","strVersion":"1.00","arrPolicy":[]}

    (with whatever session cookie + X-CSRFTOKEN header your logged-in browser
    session is using — see README.md for the full walkthrough). Invoke-FanSweep
    will throw a clear error naming this requirement if it's missing.

    Zone configuration (which fan sensors share a PWM line, and which temp
    sensors drive them) is either read from an already-configured BMC's active
    profile, loaded from a saved bmc-zones-<BmcHost>.json, or gathered via an
    interactive wizard on first run against a fresh BMC. Use -NewDevice to
    force re-running the wizard (e.g. after swapping hardware).
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FanCalibration.psm1') -Force

if (-not $Credential) {
    $Credential = Get-Credential -Message "BMC-Zugangsdaten fuer $BmcHost"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath = Join-Path $OutDir "fan-calibration-$stamp.csv"
$zoneConfigPath = Join-Path $PSScriptRoot "bmc-zones-$BmcHost.json"

Write-Host "Verbinde mit $BmcHost ..."
$connection = Connect-Bmc -BmcHost $BmcHost -Credential $Credential

$fanProfile = Invoke-BmcApi -Connection $connection -BmcHost $BmcHost -Path '/api/settings/fanprofile' -Method 'Get'
$zones = Resolve-Zones -Connection $connection -BmcHost $BmcHost -FanProfileResponse $fanProfile `
    -ConfigPath $zoneConfigPath -NewDevice:$NewDevice

Write-Host "Zonen: $($zones.Name -join ', ')"
Write-Host "Starte Sweep: Duty-Stufen $($DutySteps -join ', ')%, Settle ${SettleSeconds}s, Baseline ${BaselineDutyPercent}%"

$rows = @()
Invoke-FanSweep -Connection $connection -BmcHost $BmcHost `
    -DutySteps $DutySteps -BaselineDutyPercent $BaselineDutyPercent -SettleSeconds $SettleSeconds -Zones $zones |
    ForEach-Object {
        Write-Host ("{0,-20} {1,4}%  {2,-10} {3} RPM" -f $_.Zone, $_.DutyPercent, $_.FanName, $_.RPM)
        $rows += $_
    }

if (-not $rows) {
    throw "Sweep lieferte keine Messwerte."
}

$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
Write-Host "Fertig. Ergebnisse: $csvPath"
```

Note the console format string's zone-name column widened from `{0,-6}` to `{0,-20}` since zone names are no longer fixed 3-6 character strings like `"CPU"` — they're now joined fan names like `"SYS_FAN1+SYS_FAN2"`.

- [ ] **Step 2: Update `.gitignore`**

Add a line: `bmc-zones-*.json`

- [ ] **Step 3: Verify the script parses cleanly**

Run:
```powershell
pwsh -NoProfile -Command "$errors = $null; [System.Management.Automation.Language.Parser]::ParseFile('Calibrate-FanCurve.ps1', [ref]$null, [ref]$errors); if ($errors.Count -gt 0) { $errors } else { 'No syntax errors' }"
```
Expected: `No syntax errors`

- [ ] **Step 4: Commit**

```bash
git add Calibrate-FanCurve.ps1 .gitignore
git commit -m "feat: wire zone resolution and -NewDevice into Calibrate-FanCurve.ps1"
```

---

### Task 10: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a section documenting the generalized tool**

Read the existing `README.md` first to match its heading style and tone (check its existing sections before writing — don't guess the format). Add a section covering:
- `-BmcHost` is now required (no default), since the tool is no longer tied to one specific IP.
- The one-time `calibration` collection prerequisite and the exact `POST` body to create it (same content as the `.NOTES` block added in Task 9 — keep both in sync).
- What `-NewDevice` does and when to use it (fresh BMC, or reconfiguring fan zones after a hardware change).
- That zone configuration is saved per-BMC in `bmc-zones-<host>.json` (gitignored) and reused automatically on subsequent runs.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document -NewDevice, required -BmcHost, and the zone wizard"
```

---

### Task 11: Manual hardware verification

**Files:** none (verification only)

- [ ] **Step 1: Regression check — existing device, no config file yet**

Since `bmc-zones-192.168.178.21.json` doesn't exist yet on this machine, the first run against the real MJ11 board should hit the profile-derivation path (Task 5's case 3) and reproduce the same zone grouping the hardcoded version used (`CPU0_FAN` alone, `SYS_FAN1+SYS_FAN2` together), because that's what the `quiet` profile's own policies already encode.

Run: `pwsh -NoProfile -File .\Calibrate-FanCurve.ps1 -BmcHost 192.168.178.21 -DutySteps @(30,50) -SettleSeconds 15`

Expected:
- Console prints `Zonen: CPU0_FAN, SYS_FAN1+SYS_FAN2` (or equivalent join order).
- `bmc-zones-192.168.178.21.json` is created after the run.
- RPM values are consistent with the prior plan's dry-run (CPU0_FAN ~1050@30%/~1800@50%, SYS_FAN1 ~600/~1050, SYS_FAN2 ~450/~750 — exact values may drift slightly run to run, but should be in the same range, not wildly different).
- `strMode` is `quiet` again after the run (check via `GET /api/settings/fanprofile`).

- [ ] **Step 2: Second run — config file now exists**

Run the same command again immediately.

Expected: console shows the same zones, but this run took a config-file-load path (case 1), not profile-derivation — functionally identical output, just confirms the persistence round-trip works. (No separate observable difference from Step 1's output is expected or required; this step exists to confirm the second run doesn't error or behave differently, not to prove which code path fired — if you want to confirm the *path*, that's what Task 5's Pester tests already verify.)

- [ ] **Step 3: `-NewDevice` prompts before overwriting**

Run: `pwsh -NoProfile -File .\Calibrate-FanCurve.ps1 -BmcHost 192.168.178.21 -NewDevice -DutySteps @(50) -SettleSeconds 10`

When prompted `Bestehende Zonen-Config gefunden, wirklich ueberschreiben? (j/n)`, answer `n`.

Expected: sweep proceeds using the existing zones (no wizard questions asked), same as a normal run.

- [ ] **Step 4: Commit nothing — this task is verification-only.** If any step's actual behavior diverges from what's expected here, treat it as a finding to fix before considering this plan done, not something to note and move past.

---

## Self-Review Notes

- **Spec coverage:** all four `Resolve-Zones` decision-order cases are exercised by Task 5's tests; the wizard's stop conditions (empty name, all fans assigned) and unassigned-fan warning are covered by Task 4; the `Get-ZoneTemplate` fallback-instead-of-throw change and `New-CalibrationProfileBody`'s N-ary signature are both covered with explicit "replace, don't add" instructions so no stale contradictory tests survive; `Invoke-FanSweep`'s carried-over safety behaviors (crash-guard, preflight, retry, mode-restore-with-warning) from the prior plan's final-review fix are all re-verified under the new N-zone shape in Task 8, not silently dropped during the rewrite.
- **Type consistency:** `Zone` objects (`{Name, FanSensors, TempSensors}`) have the same shape everywhere they're produced (`New-ZonesFromProfile`, `Read-ZoneWizard`, `Resolve-Zones`'s return) and consumed (`Get-ZoneTemplate`, `Invoke-FanSweep`). `Get-ZoneTemplate`'s new `-Zone` parameter and `New-CalibrationProfileBody`'s new `-ZonePolicies` parameter are named consistently between their own tests and their caller inside `Invoke-FanSweep`.
- **No placeholders:** every task's code is complete and runnable as written; Task 11's manual steps name exact commands and exact expected output ranges instead of "verify it works."
