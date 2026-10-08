# BeepBoop

System sounds for your desktop, covering the Windows sound scheme events that make
sense on a Hyprland desktop plus a few Omarchy-specific ones: 27 events in all.

```bash
./install.sh          # install (safe to re-run to update)
./uninstall.sh        # remove; add --purge to also delete your sounds/settings
```

## Adding sounds

Put files in `~/.config/beepboop/sounds/` named after the event
(`.wav .ogg .oga .flac .mp3`). Missing files are simply silent.

| File name | Event | Plays when |
|---|---|---|
| **System** | | |
| `startup` | Startup | When you log in |
| `shutdown` | Shutdown | Shut down, reboot or log out |
| `lock` | Lock | The screen locks |
| `unlock` | Unlock | You unlock the screen |
| `auth-prompt` | Password prompt | An app asks for your password |
| **Input** | | |
| `click` | Mouse click | Any mouse button |
| `super` | Super key | Tapping Super on its own |
| `volume-keys` | Volume keys | Volume up, down or mute |
| **Windows** | | |
| `window-open` | Window open | A window opens |
| `window-close` | Window close | A window closes |
| `maximize` | Fullscreen | A window goes fullscreen or maximized |
| `restore` | Leave fullscreen | A window goes back to normal size |
| `workspace` | Workspace switch | You change workspace |
| `attention` | Needs attention | A window asks for attention |
| `menu-open` | Menu open | Omarchy menu or app launcher opens |
| `menu-close` | Menu close | Omarchy menu or app launcher closes |
| **Notifications** | | |
| `notification` | Notification | A normal notification arrives |
| `notification-critical` | Critical notification | Urgent alerts and errors |
| `screenshot` | Screenshot | A screenshot is saved |
| **Devices & power** | | |
| `device-connect` | Device connected | USB or Bluetooth device plugged in |
| `device-disconnect` | Device disconnected | USB or Bluetooth device removed |
| `charger-connect` | Charger plugged in | Power cable connected |
| `charger-disconnect` | Charger unplugged | Running on battery |
| `battery-low` | Low battery | Omarchy's 10% warning |
| `battery-critical` | Critical battery | Battery at or below 5% |
| **Omarchy** | | |
| `theme-change` | Theme changed | You switch Omarchy theme |
| `update-complete` | System Update | Packages and migrations finish; other update stages may follow |

Files placed in this repo's `sounds/` folder get copied in on install
(your existing files are never overwritten).

## Bar widget

The installer adds a **BeepBoop** widget (󰝚) to the right side of the bar, built
with the same panel kit as Omarchy's Audio and Bluetooth panels.

- **Left click**: open the panel. It has a master on/off switch, a volume slider,
  and one row per event with its own switch and ▶ preview button. Window open and
  window close are separate rows with separate files.
- **Right click**: turn all sounds on/off
- **Middle click**: open the sounds folder

Keyboard, with the panel open: arrows move, Enter toggles, ←/→ change volume,
`p` previews the selected sound, `s` turns everything on/off, `o` opens the folder.

Move it with `omarchy bar move beepboop.sounds --section left|center|right`.
From scripts: `omarchy-shell beepboop.sounds toggleSounds`.

## Controlling it from the terminal

```bash
beepboop status           # what's on, which files are present
beepboop off | on | toggle
beepboop disable click    # turn off one event
beepboop volume 0.4
beepboop event-volume click 0.5  # gain multiplied by master volume
beepboop test [event]
beepboop preview <event>  # plays even if that event is switched off
beepboop events           # list every event and its trigger
beepboop log [on|off]     # watch triggers live, for troubleshooting
```

Changes take effect immediately; no Hyprland reload needed.

`config.example` records the working installation's preferences: click and
critical notifications are disabled; master volume is 0.55. Low and critical
battery sounds are enabled. Debug logging is off in the example. The installer
preserves existing settings and uses `config.default` for a new installation.
Apply individual preferences with the CLI or panel; the example is not
installed automatically.

The repository includes clips for all 27 events used by the working
installation. See
[`sounds/SOURCES.md`](sounds/SOURCES.md) for provenance and intentional reuse.

## How it works

| Source | Events |
|---|---|
| Hyprland Lua events (`hypr/beepboop.lua`) | startup, window open/close, fullscreen/restore, workspace, attention, menu open/close (`omarchy-menu` layer), password prompt (`omarchy-polkit` layer) |
| Non-consuming Hyprland binds (the key still does its job) | mouse clicks, volume keys, Super tap (release bind that only fires on a lone tap) |
| `beepboop-daemon` (`beepboop.service`) | lock/unlock (omarchy-shell's lock log in the user journal), notifications and screenshots (session D-Bus; normal ones respect Do Not Disturb), USB (udev) and Bluetooth (BlueZ) devices, charger and critical battery (UPower) |
| Omarchy hooks (`~/.config/omarchy/hooks/*.d/beepboop`) | battery-low, theme-set, post-update |
| Omarchy Shutdown menu action | Plays `shutdown` to completion before Omarchy starts poweroff. |
| `beepboop-shutdown.service` | Fallback `ExecStop` playback for other shutdown paths, reboot, and logout. Skips a duplicate after the menu action. |

Device sounds are skipped for 8 seconds after resuming from suspend and never
repeat within a second, so reconnect bursts don't machine-gun. Everything calls
`beepboop-play <event>`, which reads `~/.config/beepboop/config`.

The event list lives in `share/events.tsv`; the CLI and the bar panel both read
it, so adding an event there (plus whatever fires it) is all it takes.

### Troubleshooting

`beepboop log on`, then `beepboop log` shows every trigger as it
happens, whether or not a sound file exists for it.

### Development checks

Run from the checkout; lifecycle tests use temporary homes and fake desktop and
audio commands, so they do not shut down or alter the active desktop:

```bash
python3 -m unittest discover -s tests -v
node tests/test_panel.js
lua tests/test_hypr.lua
luac -p hypr/beepboop.lua
shellcheck bin/* share/common.sh install.sh uninstall.sh hooks/*
git diff --check
```

These checks cover parsing, playback routing, watcher cleanup, UI state changes,
and safe install/uninstall behavior. Real login, lock/unlock, reboot, logout, and
shutdown audibility require separate desktop testing. In particular, the late
shutdown-service fallback may run after session audio has begun closing.
