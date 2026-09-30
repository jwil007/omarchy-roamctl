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
  Keys: `t` TUI · `c` edit config · `l` logs · `r` restart · `Enter` toggle.
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
socket to the `wheel` group, so the widget and `roamctl-tui` work without
sudo. Run it again to upgrade.

roamctl needs NetworkManager/wpa_supplicant. It does not work with iwd.

## Helper

```
roamctl-omarchy install|uninstall
roamctl-omarchy status|enable|disable|restart|tui|config|logs [iface]
```

## Settings (shell.json bar entry)

| key              | default | meaning                                  |
|------------------|---------|------------------------------------------|
| `iface`          | `""`    | wireless interface; empty = first found  |
| `notifyRoams`    | `true`  | notify on each roam                      |
| `candidateCount` | `5`     | scored APs listed in the panel           |

## Shell IPC

```bash
omarchy-shell jwil007.roamctl toggle|open|close|tui|enable|disable|status
```
