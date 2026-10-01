# roamctl for Omarchy

**Your laptop's Wi-Fi roaming, out in the open.** An Omarchy bar widget for
[roamctl](https://github.com/jwil007/roamctl), a configurable, score-based
roaming engine that replaces wpa_supplicant's `bgscan`. Watch it think, tune
it live, and export the evidence behind every roam.

<p>
  <img src="docs/panel.png" alt="roamctl panel: live tier, signal graph with tier floors, scored APs, recent roams" width="400">
  &nbsp;
  <img src="docs/tuning.png" alt="Quick tuning: tier floors, score deltas, band preference" width="400">
</p>

```bash
omarchy plugin add https://github.com/jwil007/omarchy-roamctl.git
```

## Features

### 📶 Roaming tier at a glance
Four bars in your bar show roamctl's live roaming tier, from **Excellent**
(roaming paused) down to **Critical** (aggressive roaming). The icon turns
urgent at Critical and pulses while a roam is in flight. It reads roamctl's
IPC stream directly, with no polling of `iw` or NetworkManager.

### 🔬 See every AP roamctl is considering
One click shows the current AP, band and channel, RSSI vs average, Tx/Rx rate
and MCS, retry rate, and scan state. Below that is **every candidate AP with
its live score**, the same ranked list roamctl roams from, so you can watch
a 6 GHz AP climb past your current 5 GHz AP before the switch.

### 📈 Signal graph with your tier floors
A 90-second RSSI trace with your Excellent / Fair / Degraded floors drawn as
lines, so you can see how close you are to the next tier and why roamctl is
(or isn't) scanning.

### 🎛️ Live tuning, no sudo, no terminal
Change tier RSSI floors, per-tier score deltas, and band preference right in
the panel, then hit **Apply & restart**. Every change is checked against a
copy of roamctl's own validation rules before it touches `/etc`, so you can't
save a config the daemon won't start with. Your comments in the file are
preserved.

### ✍️ Full-config editing with a safety net
The pencil opens the whole TOML in your editor. Close it, and the plugin
validates, saves, and restarts roamctl. An invalid edit is never written:
you're offered **edit again** or **discard**. The previous version is always
kept.

### 🧾 Roam forensics export
Every roam is logged with **the exact scored scan list roamctl decided
from**, captured from the frame roamctl publishes as the roam starts, along
with roamctl's own journal lines for that roam. One click exports it all to
a CSV, one row per candidate AP per roam, ready for a spreadsheet or pandas:

| roam | tier | required Δ | candidate | rank | RSSI | score | Δ vs current | meets Δ | target |
|---|---|---|---|---|---|---|---|---|---|
| 1 | active_roaming | 6 | 02:00:5e:10:22:40 | 1 | −58 | 75 | +11 | ✅ | ✅ |
| 1 | active_roaming | 6 | 02:00:5e:10:33:30 | 2 | −52 | 69 | +5 | ❌ | |
| 1 | active_roaming | 6 | 02:00:5e:10:22:30 | 3 | −53 | 64 | 0 | (current) | |

It answers "why that AP?" (and "why not this one?") with numbers: every
score component (RSSI, SNR, band, width, utilization, PHY), the tier's
required delta, the hysteresis override threshold, penalized APs, the full
config in effect, and the connection before and after the roam. It even
flags when roamctl's own result line disagrees with where the station
actually landed.

### 🔔 Roam notifications
Get a notification for every roam: target AP, band, channel, RSSI, and how
many milliseconds it took. Failures get a louder notification.

### ⌨️ Keyboard-first, Omarchy-native
Themed with your Omarchy colors and fonts, keyboard navigable (`t` TUI ·
`e` export · `c` config · `l` logs · `r` restart · `Enter` on/off), and
scriptable over shell IPC. Middle-click the icon for `roamctl-tui`;
right-click to start or stop roaming.

### 🛠️ One-click install
The panel installs roamctl for you: it fetches the latest release, verifies
its SHA-256 checksums, installs the systemd unit, and sets up permissions so
nothing else needs sudo.

## Install

```bash
omarchy plugin add https://github.com/jwil007/omarchy-roamctl.git
```

Open the widget and click **Install roamctl**, or run
`~/.config/omarchy/plugins/jwil007.roamctl/bin/roamctl-omarchy install`.
Then flip the switch to enable roaming.

Requires NetworkManager with wpa_supplicant. iwd isn't supported, because
roamctl drives wpa_supplicant's control interface.

### What install changes
- `roamctl` and `roamctl-tui` → `/usr/local/bin`, plus the upstream
  `roamctl@.service` unit.
- A drop-in at `/etc/systemd/system/roamctl@.service.d/omarchy.conf` that
  gives the `wheel` group access to roamctl's IPC socket and config file.
  The socket is broadcast-only (roamctl never reads from it), and `wheel`
  can already sudo.
- A polkit rule at `/etc/polkit-1/rules.d/50-roamctl-omarchy.rules` letting
  an active local `wheel` session start, stop, and restart `roamctl@` units
  without a password. It covers no other unit. Enabling and disabling the
  unit still asks for authorization.

Run `install` again to upgrade. On an existing roamctl install, `setup` (or
**Enable quick tuning**) adds only the permissions. `uninstall` removes
everything except your config.

## How the roam log works

The plugin reads every IPC frame (about 100 ms apart). For each completed
roam it appends one JSON object to
`~/.local/state/roamctl-omarchy/roams-<iface>.jsonl` (rotated at 20 MB):

- **result**: target and final BSSID, duration, result flag, message
- **decision**: the scored `BSSList` from the first frame published with
  `RoamInProgress` set. roamctl scores the scan and publishes that snapshot
  as it starts the roam, so this is the list the target was chosen from.
  Roams shorter than one frame fall back to the frame just before
  (`decision.source`). Also includes the tier, required delta, hysteresis
  and health flags, and connection metrics.
- **after**: the connection once the station reports the final BSSID (or
  after 3 s; see `after.settled`)
- **journal**: roamctl's own log lines for the roam window: candidate
  evaluation with scaled score components, measured and required delta, and
  the result
- **penalties** (APs excluded after failed roams) and the full **config**

Roams are logged whenever the Omarchy shell is running, even with the panel
closed. Roams the AP requests via 802.11v BSS Transition Management aren't
scored by roamctl, so score deltas don't explain those.

## Reference

```
roamctl-omarchy install|setup|uninstall
roamctl-omarchy status|enable|disable|restart|tui|config|logs|export [iface]
roamctl-omarchy apply <iface> section.key=value...
roamctl-config get|check FILE
roamctl-config set FILE section.key=value...
roamctl-export LOG.jsonl... -o OUT.csv
```

Shell IPC:

```bash
omarchy-shell jwil007.roamctl toggle|open|close|tuning|tui|exportRoams|enable|disable|status
```

Settings (the widget's entry in `~/.config/omarchy/shell.json`):

| key              | default | meaning                                  |
|------------------|---------|------------------------------------------|
| `iface`          | `""`    | wireless interface; empty = first found  |
| `notifyRoams`    | `true`  | notify on each roam                      |
| `candidateCount` | `5`     | scored APs listed in the panel           |

## License

MIT
