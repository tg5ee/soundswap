# Drop your sounds here

Name each file after its event, e.g. `window-open.wav`. Any of .wav .ogg .oga
.flac .mp3 works (if several exist, the first in that order wins). Missing files
are just silent, so add as many or as few as you like.

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
| `update-complete` | Update finished | omarchy update completes |

Keep click, Super, volume-key and window sounds short (under ~150 ms) so they
feel snappy. Preview any of them from the bar panel, or `beepboop test <event>`.
