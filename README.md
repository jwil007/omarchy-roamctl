# roamctl for Omarchy

Omarchy shell plugin for [roamctl](https://github.com/jwil007/roamctl), the
wpa_supplicant-based Wi-Fi roaming daemon.

<img src="docs/panel.png" alt="roamctl panel in the Omarchy bar" width="420">

- **Bar widget.** Four signal bars show roamctl's live roaming tier
  (Excellent → Critical). Critical turns urgent, and the bars pulse while a
  roam is in flight. Dimmed means the service is stopped.
  Click opens the panel, middle-click opens `roamctl-tui`, right-click
  starts or stops the service.
- **Panel.** On/off switch (`systemctl enable --now` / `disable --now`
  roamctl@iface, authorized through the Omarchy polkit agent), current AP,
  channel, signal, rates, retries, a 90 s RSSI sparkline, the top scored
  APs from roamctl's candidate list, and a log of recent roams.
  Keys: `t` TUI · `e` export · `c` edit config · `l` logs · `r` restart ·
  `Enter` toggle.
- **Tuning.** Edit tier RSSI floors, per-tier score deltas, and band
  preference in the panel, then **Apply & restart**. Values are checked
  against roamctl's own validation rules before anything is written, and the
  tier floors are drawn on the signal graph. The pencil button opens the full
  config in your editor; when you close it, the file is validated, saved,
  and roamctl restarts. Invalid edits are never written. The previous
  version is kept in `~/.local/state/roamctl-omarchy/`.
- **Roam export.** Every roam is logged with the scored scan list roamctl
  chose from. The spreadsheet button exports the log to a CSV in
  `~/Downloads` (see below).
- **Roam notifications.** Each completed roam posts a notification with the
  target AP, band, channel, RSSI, and roam time. Turn this off with the
  `notifyRoams` setting.

The live data comes straight from roamctl's IPC socket
(`/run/roamctl/<iface>.sock`, one JSON `ProcessState` per signal poll).

## Install

```bash
omarchy plugin add https://github.com/jwil007/omarchy-roamctl.git
```

Then open the widget's panel and click **Install roamctl**, or run
`~/.config/omarchy/plugins/jwil007.roamctl/bin/roamctl-omarchy install`.

`install` downloads the latest release, verifies its checksums, installs
`roamctl` and `roamctl-tui` to `/usr/local/bin`, and installs the upstream
`roamctl@.service` unit. It also adds a drop-in
(`/etc/systemd/system/roamctl@.service.d/omarchy.conf`) that hands the IPC
socket and config to the `wheel` group, plus a polkit rule that lets an
active local `wheel` session start, stop, and restart `roamctl@` units
without a password. That way the widget, `roamctl-tui`, and quick tuning
work without sudo. Enabling and disabling the unit still asks for
authorization. Run `install` again to upgrade. On an existing install, run
`roamctl-omarchy setup` (or click **Enable quick tuning**) to add just the
permissions.

roamctl needs NetworkManager/wpa_supplicant. It does not work with iwd.

## Roam log and export

The plugin watches every IPC frame (about 100 ms apart). When a roam
completes, it logs one JSON object to
`~/.local/state/roamctl-omarchy/roams-<iface>.jsonl` (rotated at 20 MB). The
object holds:

- the roam result: target and final BSSID, duration, result flag, message
- a **decision snapshot**: the last frame published before the roam
  started, including the full scored `BSSList` with per-component scores,
  the tier, hysteresis and health flags, and the connection metrics at that
  moment. `snapshotAgeMs` records how long before the roam landed it was
  captured.
- the connection after the roam
- roamctl's AP penalty list (APs excluded from scoring after failed roams)
- the full config in effect

Logging happens whenever the shell is running, even with the panel closed.
Roams that happen while the shell isn't running aren't captured.

**Export** (spreadsheet button, `e`, or `roamctl-omarchy export`) flattens
the log into a CSV with one row per candidate AP per roam. Roam-level
columns repeat on every row, so you can filter or pivot by `roam_id`. Per
candidate, it includes rank, RSSI/SNR/utilization/clients, every score
component, `cand_delta_vs_current`, and `cand_meets_required_delta`.
roamctl only tries the top-ranked candidate, and only if its score beats
the current AP by the tier's `required_delta`. RSSI hysteresis blocks the
roam unless the gap is at least `hysteresis_override_delta`. Roams the AP
requested via BSS Transition Management (802.11v) aren't scored by roamctl,
so their deltas don't explain the choice.

## Helper

```
roamctl-omarchy install|setup|uninstall
roamctl-omarchy status|enable|disable|restart|tui|config|logs|export [iface]
roamctl-omarchy apply <iface> section.key=value...
roamctl-config get|check FILE
roamctl-config set FILE section.key=value...
roamctl-export LOG.jsonl... -o OUT.csv
```

## Settings (shell.json bar entry)

| key              | default | meaning                                  |
|------------------|---------|------------------------------------------|
| `iface`          | `""`    | wireless interface; empty = first found  |
| `notifyRoams`    | `true`  | notify on each roam                      |
| `candidateCount` | `5`     | scored APs listed in the panel           |

## Shell IPC

```bash
omarchy-shell jwil007.roamctl toggle|open|close|tuning|tui|exportRoams|enable|disable|status
```
