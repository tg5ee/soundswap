# Local asset selections

Selected from `~/Downloads/sounds` after format, duration, loudness, duplicate, and metadata inspection. Originals are preserved byte for byte. The first two selections below used their existing stereo PCM WAVs without conversion. Selection uses measured duration and source descriptions; subjective listening remains a user preference.

Embedded attribution is retained. Source metadata names Epic Stock Media; no
separate redistribution grant was present in the inspected folders. On
2026-10-06 the project owner explicitly confirmed redistribution rights for the
clips and authorized their inclusion in the GitHub push. This records the
owner's confirmation; the plugin manifest's MIT label does not relicense
third-party audio.

## device-connect.wav

- Original: `ESM_HCGUI_fx_positive_item_unlocked_bright_bellish_01.wav`
- Reason: Short positive connection confirmation; 0.844 seconds.
- SHA256: `e37bf5ce20c1b67f95adf83d3bf61283afcfa788d4bcd9f9bff527831c8dc8ba`

## theme-change.wav

- Original: `ESM_Hi-Tech_Game_Interface_2__Futuristic_Mobile_App_Sci_fi_Mechanical_Glitch_Tap_Slide_Lock_Unlock_Press_Push_Activate.wav`
- Reason: Restrained technology UI cue for an infrequent theme change; 0.979 seconds.
- SHA256: `02d43ef994b2dc870be76b3b9d05e58acc6d6c2397a4a938f47c195dd7e8fd4d`

## Additional local event sounds (2026-10-03)

These files are 48 kHz, 16-bit stereo WAVs. Each downloaded clip was shortened
with a fade and reduced in level for its event. The originals remain in
`~/Downloads/sounds`. Installed copies were added only where the event filename
was absent; existing event sounds and settings were preserved.

| Event file | Original | Edit |
|---|---|---|
| `volume-keys.wav` | `ESM_EM2_FX_hit_ui_button_cute_pitched_11.wav` | First 0.18 s, fade from 0.11 s, -8 dB |
| `maximize.wav` | `ESM_Game_Cube_Block_Hit_UI__Futuristic_Mobile_App_Sci_fi_Mechanical_Glitch_Tap_Slide_Lock_Unlock_Press_Push_Activate.wav` | First 0.28 s, fade from 0.20 s, -5 dB |
| `restore.wav` | `ESM_Bubble_Pop_Shoot_v2_Game_Organic_Cartoon.wav` | First 0.20 s, fade from 0.12 s, -3 dB |
| `workspace.wav` | `ESM_One_Shot_FX_Interface_Tech_Cute_Future_04_Scroll_Button_Alert_Transition_Beep_Chirp_Hi_Tech_Alien_A#.wav` | First 0.13 s, fade from 0.08 s, -16 dB; the original reaches full scale |
| `menu-open.wav` | `ESM_One_Shot_FX_Notification_UI_Tech_Cute_Spacey_Droid_02_Electric_Expressive_HUD_Robot_Am.wav` | First 0.30 s, fade from 0.22 s, -6 dB |
| `screenshot.wav` | `ESM_Game_Notification_83_Coin_Blip_Select_Tap_Button.wav` | First 0.65 s, fade from 0.50 s, -5 dB |
| `menu-close.wav` | Existing installed `window-close.wav` | Exact copy of the short existing close cue |

`battery-low` and `battery-critical` remain without files: none of the downloaded
clips clearly conveys a warning. The wooden door and long water notification
clips were also left unused because the existing short event sounds fit better.

## Working installation synchronization (2026-10-06)

All 25 canonical event WAVs match the working installation byte for byte. Seven
previously absent files were recovered from the installed sound directory:
`attention`, `auth-prompt`, `charger-connect`, `charger-disconnect`,
`update-complete`, `window-close`, and `window-open`. The installed
`notification.wav` replaced the checkout's older selection. No audio was
reprocessed during this synchronization.

The installed `notification.wav` matches `ComputerBeep_S011SF.196.wav`, and
`update-complete.wav` matches `HoverRobotPassBy_S011SF.427.wav`. Other recovered
files retain their installed names and embedded metadata; no unverified source
attribution is inferred.

`menu-close.wav` and `window-close.wav` intentionally contain identical audio:
the resolver uses separate event filenames. Unmapped original-name clips and
the misspelled `notification-critrical.wav` are not published. Originals remain
local. All 11 downloaded clips were compared; the three unused clips were not
imported, and the other eight were already represented directly or through the
documented edits above.
