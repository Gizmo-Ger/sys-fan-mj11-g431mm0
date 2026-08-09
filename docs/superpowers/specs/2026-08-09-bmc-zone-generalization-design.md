# BMC Fan-Zone Generalization — Design

## Goal

Generalize `Calibrate-FanCurve.ps1`/`FanCalibration.psm1` beyond the
MJ11-EC1's hardcoded fan-sensor numbers (184/185/186) and fixed two-zone
split ("CPU"/"System"), so the tool works on any board reachable through
this BMC REST API — including one that has never been configured (no
existing fan profile to derive groupings from) and one with a different
number of fan headers than this board.

## Problem

The current implementation hardcodes, in `Invoke-FanSweep`:
- Exactly two zones, named `'CPU'` and `'System'`.
- Fan sensor numbers `184` (CPU) and `185`/`186` (System).
- A `$fanNames` lookup table mapping those three numbers to display names.

This only works on this specific MJ11-EC1 board, and only because it
already ships pre-configured `default`/`quiet` profiles whose policies
happen to group fans sensibly. A fresh/never-configured BMC has no
policies to read groupings from at all — fan-to-PWM-zone grouping is a
hardware fact (which fan headers share one PWM control line) that cannot
be inferred from the sensor list alone; it either lives in an
already-written profile, or only the human operator (board documentation)
knows it.

## Zone resolution (`Resolve-Zones`)

New orchestrating function, called once per run before the sweep starts.
Takes `$BmcHost`, the already-fetched `$FanProfileResponse` (from
`GET /api/settings/fanprofile`), and a `-NewDevice` switch.

1. **Config file exists, `-NewDevice` not set** → load `bmc-zones-<BmcHost>.json`
   and return its contents. No BMC-derived logic runs.
2. **`-NewDevice` set, config file exists** → prompt
   `"Bestehende Zonen-Config gefunden, wirklich ueberschreiben? (j/n)"`
   (via `Read-Host`). `j` → run the wizard (step 4) and overwrite the file.
   Anything else → fall back to loading the existing file (step 1's
   behavior), so declining the overwrite doesn't leave the tool without
   zones.
3. **No config file, `-NewDevice` not set, active profile has at least one
   real policy** (`$FanProfileResponse.arrProfile` has an entry matching
   `$FanProfileResponse.strMode` with a non-empty `arrPolicy`) → derive
   zones automatically: one zone per policy, `FanSensors` = that policy's
   `arrFanSensor`, `TempSensors` = that policy's `arrSensor`, `Name` = the
   joined fan sensor names (see Naming below, resolved via the inventory
   from step 0 below). Save to the config file for next time.
4. **No config file and no usable policy** (genuinely fresh/never-configured
   BMC) → run the wizard unconditionally, regardless of `-NewDevice`. Save
   the result.

**Step 0, always first:** `Get-BmcInventory` — `GET /api/sensors`, split
into `FanSensors` (`type -eq 'fan'`) and `TempSensors`
(`type -eq 'temperature'`), each as `{sensor_number, name}` pairs. Used by
both the profile-derivation naming step and the wizard's displayed list.

## Zone naming

A zone's `Name` is its fan sensor names joined with `+` — e.g. a
single-fan zone is just `"CPU0_FAN"`, a two-fan zone is
`"SYS_FAN1+SYS_FAN2"`. Resolved from the inventory's `FanSensors` list by
sensor number, not hardcoded.

## The wizard (`Read-ZoneWizard`)

Console-interactive (`Read-Host`), only invoked per Zone resolution steps
2/4 above:

1. Print the full inventory: fan sensors and temp sensors, each as
   `<sensor_number>: <name>`.
2. Loop, once per zone:
   - Ask `"Zone-Name?"` (free text; empty input ends the loop — this is
     the "done" signal).
   - Ask `"Fan-Sensor-Nummern (kommagetrennt)?"` — parsed as
     comma-separated integers.
   - Ask `"Temp-Sensor-Nummern (kommagetrennt)?"` — same parsing; may be
     empty (a policy can reference zero temp sensors, though that's
     unusual).
   - Append `{Name, FanSensors, TempSensors}` to the result list.
3. Loop ends when the user enters an empty zone name, OR when every fan
   sensor number from the inventory has been assigned to some zone
   (whichever comes first) — after the loop, warn (don't fail) about any
   inventory fan sensors that ended up in no zone, so the operator notices
   an omission before running a 6-minute sweep that silently skips a fan.

## Zone config file

One file per BMC, `bmc-zones-<BmcHost>.json` (e.g.
`bmc-zones-192.168.178.21.json`), at the repo root alongside the scripts.
Gitignored (per-operator/per-device data, not source). JSON array:

```json
[
  { "Name": "CPU0_FAN", "FanSensors": [184], "TempSensors": [1] },
  { "Name": "SYS_FAN1+SYS_FAN2", "FanSensors": [185, 186], "TempSensors": [4, 8, 14, 16] }
]
```

## Policy template fallback

`Get-ZoneTemplate` (existing function) finds a real policy in the active
profile to copy field defaults from (`iPolicyType`, `iHysteresis`, etc.) —
this only works when the zone's fans already appear in an existing policy
(the profile-derived path, step 3 above). A wizard-defined zone (step 2/4)
has no such existing policy to copy from, since it may not match how the
BMC's current profiles are grouped, or the BMC may have no profiles worth
copying from at all.

For a zone with no matching existing policy, build a default policy
skeleton instead:
```powershell
@{
    iPolicyType = 2
    iInSDR = 1
    iSensorCode = if (@($Zone.TempSensors).Count -gt 1) { 3 } else { 1 }
    iInitDuty = 40
    iCpuTdp = 0
    iAmbientSensor = 0
    iAmbientSensorTemp = 0
    arrSensor = @($Zone.TempSensors)
    arrFanSensor = @($Zone.FanSensors)
    arrRef = @()
    arrDuty = @()
    arrHexVendorID = @()
    arrHexDeviceID = @()
    iPCIEDeviceEnable = 0
    iHysteresis = 0
}
```
(`arrRef`/`arrDuty` are always overwritten by `New-FlatCurvePolicy` before
use, so their placeholder values here don't matter.) `iSensorCode`
mirrors the existing multi-sensor gotcha documented in
`SYS_FAN_HOWTO.md` (must be `3`, not `1`, when more than one temp sensor
is listed).

`Get-ZoneTemplate` becomes: try to find a matching existing policy first
(current behavior, now matched by "any fan sensor in the zone's
`FanSensors` overlaps this policy's `arrFanSensor`" rather than a single
hardcoded sensor number); if none found, build the default skeleton above
instead of throwing. (Previously it threw on no match — that behavior
was correct when the caller always asked about a fan sensor known to
exist in the active profile. Now the caller may legitimately be asking
about a zone the active profile has never heard of, so "no match" becomes
a fallback path instead of an error.)

## Ripple effects on existing functions

- **`New-CalibrationProfileBody`**: signature changes from
  `(-CpuZonePolicy, -SystemZonePolicy)` to `(-ZonePolicies <array>)` —
  `arrPolicy = $ZonePolicies` directly, any number of entries.
- **`Invoke-FanSweep`**: the hardcoded `$zones`/`$fanNames` tables are
  replaced by the result of `Resolve-Zones`. The sweep's outer loop
  becomes `foreach ($zone in $resolvedZones)`; the "other zones held at
  baseline" logic generalizes from "the one other zone" to "every zone
  that isn't the one currently under test."
- **`Get-FanRpm`/`Test-SentinelReading`/`New-CalibrationCsvRow`**: unchanged
  — they already operate on arbitrary sensor numbers and don't know about
  zones at all.

## Testing

All new functions (`Get-BmcInventory`, `Resolve-Zones`,
`Read-ZoneWizard`, `Save-ZoneConfig`/`Read-ZoneConfig`, the updated
`Get-ZoneTemplate` fallback, the updated `New-CalibrationProfileBody`) are
pure-logic-testable via Pester with mocked `Invoke-BmcApi` (for anything
hitting the BMC) and mocked `Read-Host`/`Write-Host` (for the wizard) —
same pattern as the existing test suite. `Read-ZoneWizard`'s tests inject
a scripted sequence of `Read-Host` responses (Pester can mock `Read-Host`
directly) covering: normal multi-zone entry, empty-name-ends-loop, and
the "some fan sensor never assigned" warning path.

## Also in this change

`-BmcHost` becomes a required parameter on `Calibrate-FanCurve.ps1` with
no default, replacing the current hardcoded `192.168.178.21` — a
one-line change, since a hardcoded IP is itself board-specific and
contradicts the point of this generalization.

## Out of scope

- Auto-discovering which fans physically share a PWM line by empirically
  testing them (set one, watch which others move) — the wizard asks the
  operator instead, who can read the board's documentation. Noted as a
  possible future enhancement, not built now.
- BMC IP auto-discovery (network scanning) — not attempted; see "Also in
  this change" above for the actual fix (require the parameter instead).
- The temp-sensor-to-zone mapping captured here is stored for reuse by a
  planned separate curve-suggestion tool (not built in this piece of
  work) — this spec only captures and persists it; nothing in this
  codebase reads `TempSensors` for any purpose beyond building the
  wizard-path policy skeleton's `arrSensor`/`iSensorCode` fields above.
