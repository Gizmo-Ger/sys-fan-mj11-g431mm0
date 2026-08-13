# Fan PWM/RPM calibration tool

- **[Calibrate-FanCurve.ps1](Calibrate-FanCurve.ps1)** — sweeps PWM duty per
  fan zone on the BMC and records the resulting RPM to a CSV, using an
  isolated `calibration` fan-profile collection so it never touches whatever
  profile you actually run live (`default`, or a custom one you've set up —
  e.g. `quiet` isn't a stock BMC profile, just an example of a user-created
  one). Zones aren't fixed to a CPU/System split — the
  tool derives however many zones the BMC's own fan-profile policies define
  (or however many you set up in the wizard), so it works on any board behind
  this REST API.

## Required parameters

**`-BmcHost` (required)** — The IP address or hostname of the target BMC. The
tool is now generalized to any BMC, not bound to a single IP. Zone
configuration is saved and reused per BMC instance.

## Example

```powershell
pwsh ./Calibrate-FanCurve.ps1 -BmcHost <bmc-ip>
```

You'll be prompted for BMC credentials (or pass `-Credential`). Results are
written to a timestamped `fan-calibration-<date>.csv` in the script's
directory (override with `-OutDir`).

## One-time setup on a fresh BMC

The `calibration` fan-profile collection must exist before the script's API
calls will succeed. Create it once with this POST request:

```
POST /api/settings/fanprofile/collection
Content-Type: application/json
{"strName":"calibration","strVersion":"1.00","arrPolicy":[]}
```

Use your logged-in browser session's cookie + X-CSRFTOKEN header. The script's
preflight check will fail fast with an explicit error if this collection is
missing, rather than silently failing mid-sweep.

## Zone configuration and `-NewDevice`

Zone configuration (which fan sensors share a PWM line, and which temp
sensors drive them) is resolved in this order:

1. If a saved `bmc-zones-<host>.json` exists (and `-NewDevice` isn't set), it
   is loaded and reused as-is.
2. Otherwise, if the BMC already has an active fan profile with at least one
   real policy — the common case for a BMC that's already been configured —
   zones are derived from it automatically, saved to
   `bmc-zones-<host>.json`, and used. No prompts, nothing to confirm.
3. Otherwise (a genuinely fresh/unconfigured BMC, or `-NewDevice` was passed
   and there's nothing usable to derive from), an interactive wizard runs to
   map fan sensors to zones and temp sensors, and the result is saved the
   same way.

Note that this means the wizard does **not** run on every first invocation —
only when there's no saved config *and* no usable active profile to derive
zones from.

**`-NewDevice` (switch)** — Force re-resolution instead of trusting a saved
config: if a `bmc-zones-<host>.json` already exists, you're prompted to
confirm before it's overwritten (answering anything other than `y` keeps the
existing config); once confirmed (or if no config existed yet), the wizard
runs. Use this after swapping hardware (fans, temp sensors) or when
reconfiguring fan zones.
