# Automated Fan PWM/RPM Calibration — Design

## Goal

`Calibrate-FanCurve.ps1`: sweep each fan zone's PWM duty across a range,
measure the resulting RPM per fan via the BMC REST API, and produce a
PWM→RPM table per installed fan — without touching the live `default`/`quiet`
fan profiles.

Target: Gigabyte MJ11-EC1/G431-MM0 BMC (AMI MegaRAC, AST2500), same REST API
documented in `SYS_FAN_HOWTO.md`.

## Confirmed API surface (reverse-engineered this session)

- **Login**: `POST /api/session`, `Content-Type: application/x-www-form-urlencoded`,
  body `username=<user>&password=<pass>`, header `X-CSRFTOKEN: null` (no
  token exists yet at login time). Cookies `i18next=de-de; lang=de-de` sent
  along (harmless, UI locale prefs).
  Response JSON includes `CSRFToken`; `QSESSIONID` arrives via `Set-Cookie`
  on the same response.
- **Read sensors**: `GET /api/sensors` — full sensor array (temps, voltages,
  fan RPM). Requires `Cookie: QSESSIONID=...` + `X-CSRFTOKEN: <token>` +
  `X-Requested-With: XMLHttpRequest`.
- **Read fan profile**: `GET /api/settings/fanprofile` — returns
  `{strMode, strVersion, arrProfile: [{strName, arrPolicy: [...]}]}`.
- **Write fan profile collection**: `PUT /api/settings/fanprofile/collection/<name>`
  — body `{strName, strVersion, arrPolicy: [...]}`, replaces that named
  profile's policies wholesale (not a patch).
- **Switch active mode**: `POST /api/settings/fanprofile/mode` (exact body
  schema unconfirmed — verify via DevTools when building; expected
  `{"strMode":"<name>"}` by analogy with the collection route).
- Sensor IDs on this board: `1`=CPU0_TEMP, `4`=DIMMG0_TEMP, `8`=MB_TEMP1,
  `14`=VR_P0_TEMP, `16`=VR_DIMMG0_TEMP, `184`=CPU0_FAN, `185`=SYS_FAN1,
  `186`=SYS_FAN2.
- Confirmed via firmware RE (this session, `IPMIMain_prod`,
  `libipmimsghndlr_prod.so`, `libipmiamioemserviceconf.so`): **no IPMI OEM
  raw command exists for fan/PWM control on this firmware** — it is
  REST-only. No `ipmitool raw` equivalent to chase.

## Hardware topology

Two independent PWM zones, not three:
- **CPU zone**: drives `CPU0_FAN` (184) only.
- **System zone**: drives `SYS_FAN1` (185) and `SYS_FAN2` (186) *together*
  — one shared PWM duty value, two independent RPM tachometers. Their RPM
  can be measured independently; their duty cannot be driven independently.

Calibration therefore produces per-fan RPM curves, but only two independent
duty axes (CPU zone, System zone).

## Safety strategy: isolated profile, no restore-on-content risk

Rather than overwrite `default`/`quiet` and restore their JSON afterward,
the script:

1. `GET /api/settings/fanprofile`, records the current `strMode` (e.g.
   `"quiet"`) as the value to restore.
2. `PUT`s a **new** profile named `calibration` — `default`/`quiet` content
   is never modified.
3. Switches active mode to `calibration` for the duration of the sweep.
4. In a `finally` block (runs on normal completion, error, or Ctrl+C):
   switches mode back to the original `strMode`. The now-unused
   `calibration` profile is left in place (harmless, inactive) — no
   deletion needed.

This means a crash mid-sweep can only leave the BMC in `calibration` mode
(fans possibly stuck at a test duty) until the next run or manual mode
switch — it can never corrupt the user's tuned `default`/`quiet` curves.

## Sweep algorithm

For each zone (CPU, System), sequentially — not concurrently, so an RPM
change can be attributed to the zone under test:

```
for duty in 20, 30, 40, 50, 60, 70, 80, 90, 100:
    PUT calibration profile: this zone's policy → arrRef=[0,100], arrDuty=[duty,duty]
    (other zone's policy left at its last-set/steady value)
    sleep 20s (settle time)
    GET /api/sensors
    extract RPM for this zone's fan sensor(s)
    if reading looks like a sentinel/error value (e.g. raw_reading duplicated
      across unrelated sensors, as observed live this session): retry once
      after a short pause; if still bad, record RPM as "NA" for that point
    print row to console table
    append row to CSV
```

9 duty points × 2 zones × ~20s ≈ 6 minutes total, plus settle time for the
very first transition into the calibration profile.

## Output

CSV file `fan-calibration-<timestamp>.csv`, columns:
`Zone, DutyPercent, FanName, RPM`

One row per (duty step, fan) — so the System zone contributes two rows per
duty step (SYS_FAN1 and SYS_FAN2 RPM at that shared duty).

Console: live table, one line printed per measurement as it's taken, so
progress is visible during the ~6 minute run.

## Error handling

- Login failure (bad credentials, unreachable host): abort immediately,
  clear error message, no profile is created or mode switched.
- Every API call uses a bounded timeout; a failed call mid-sweep still hits
  the `finally` block and restores the original mode.
- A sensor reading that looks like the sentinel/batch-error pattern observed
  earlier this session (identical `raw_reading` across unrelated sensors) is
  retried once, then logged as `NA` rather than trusted.

## Out of scope

- Concurrent zone sweeping (rejected — makes RPM attribution ambiguous).
- Deleting the `calibration` profile after the run (harmless to leave).
- Raw IPMI/`ipmitool` fan control (confirmed not to exist on this firmware).
- Restoring exact original curve content for `default`/`quiet` (never
  touched in the first place, so nothing to restore).
