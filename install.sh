#!/usr/bin/env bash
# Install user overrides only. Existing targeted files are backed up before replacement.
# On upgrade from BeepBoop or omarchy-sounds, legacy data is migrated and old
# integrations are removed so sounds cannot fire twice.
set -euo pipefail
[[ $# = 0 ]] || { echo 'Usage: install.sh' >&2; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}"
BIN="$HOME/.local/bin"
CONF="$CONFIG_ROOT/soundswap"
HYPR="$CONFIG_ROOT/hypr"
MAIN="$HYPR/hyprland.lua"
UNIT_DIR="$CONFIG_ROOT/systemd/user"
SHARE="$DATA_ROOT/soundswap"
HOOKS="$CONFIG_ROOT/omarchy/hooks"
PLUGIN_ID=soundswap.sounds
PLUGIN_DIR="$CONFIG_ROOT/omarchy/plugins/$PLUGIN_ID"
MENU="$CONFIG_ROOT/omarchy/extensions/omarchy-menu.jsonc"
BEGIN='-- soundswap >>>'
END='-- <<< soundswap'
OLD_BEGIN='-- beepboop >>>'
OLD_END='-- <<< beepboop'
OLDER_BEGIN='-- omarchy-sounds >>>'
OLDER_END='-- <<< omarchy-sounds'
MENU_BEGIN='  // soundswap shutdown >>>'
MENU_END='  // <<< soundswap shutdown'
OLD_MENU_BEGIN='  // beepboop shutdown >>>'
OLD_MENU_END='  // <<< beepboop shutdown'
OLDER_MENU_BEGIN='  // omarchy-sounds shutdown >>>'
OLDER_MENU_END='  // <<< omarchy-sounds shutdown'
UNITS=(soundswap.service soundswap-shutdown.service)
OLD_WATCHER_UNITS=(beepboop.service omarchy-sounds.service)
OLD_SHUTDOWN_UNITS=(beepboop-shutdown.service omarchy-sounds-shutdown.service)
OLD_BINARIES=(beepboop beepboop-play beepboop-daemon omarchy-sounds omarchy-sounds-play omarchy-sounds-daemon)
OLD_HOOK_NAMES=(beepboop omarchy-sounds)
OLD_PLUGIN_IDS=(beepboop.sounds tomg.sounds)
say() { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

required_tools=(bash flock setsid timeout luac Hyprland systemctl install cp mv mktemp awk grep sed cmp date tail mkdir find sort uniq tr rm ps journalctl dbus-monitor gdbus udevadm)
missing_tools=()
for tool in "${required_tools[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if ((${#missing_tools[@]})); then
  for tool in "${missing_tools[@]}"; do
    printf 'FAIL: required command missing: %s\n  Fix: run pacman -F %s, install its package, then rerun ./install.sh.\n' "$tool" "$tool" >&2
  done
  exit 1
fi
say 'PASS: required installer and runtime commands are available'

if [[ -n ${XDG_RUNTIME_DIR:-} && -d $XDG_RUNTIME_DIR && -w $XDG_RUNTIME_DIR ]]; then
  say 'PASS: writable desktop runtime directory is available'
else
  printf 'FAIL: writable XDG_RUNTIME_DIR is unavailable.\n  Fix: run ./install.sh from an active Omarchy desktop session.\n' >&2
  exit 1
fi
if command -v omarchy-shell >/dev/null 2>&1; then
  say 'PASS: omarchy-shell is available'
else
  printf 'WARN: omarchy-shell is unavailable; notification DND detection and panel management will be limited.\n  Fix: run from Omarchy with omarchy-shell on PATH.\n'
fi
audio_backend=
for tool in pw-play paplay mpv; do
  if command -v "$tool" >/dev/null 2>&1; then audio_backend=$tool; break; fi
done
if [[ -n $audio_backend ]]; then
  say "PASS: audio playback command available ($audio_backend)"
else
  printf 'WARN: no audio playback command found (pw-play, paplay, or mpv); SoundSwap cannot play sounds.\n  Fix: install an audio player such as PipeWire (pw-play), PulseAudio (paplay), or mpv, then rerun ./install.sh.\n'
fi
# Ambiguous or incomplete fences must never be interpreted as a removable range.
[[ -f $MAIN && ! -L $MAIN ]] || fail "Expected a regular Lua config at $MAIN"

marker_count() {
  awk -v b="$2" -v e="$3" '
    index($0,b) || index($0,e) {
      if ($0 == b && !open && !seen) { open=1; seen=1; next }
      if ($0 == e && open) { open=0; closed=1; next }
      bad=1
    }
    END { if (bad || open || seen != closed) exit 1; print seen + 0 }
  ' "$1"
}
marker_count "$MAIN" "$BEGIN" "$END" >/dev/null || fail 'Malformed soundswap markers; repair the paired block first.'
marker_count "$MAIN" "$OLD_BEGIN" "$OLD_END" >/dev/null || fail 'Malformed legacy beepboop markers; repair the paired block first.'
marker_count "$MAIN" "$OLDER_BEGIN" "$OLDER_END" >/dev/null || fail 'Malformed legacy omarchy-sounds markers; repair the paired block first.'

for root in "$HOME" "$CONFIG_ROOT" "$DATA_ROOT" "$STATE_ROOT"; do
  [[ $root = /* && $root != *$'\n'* && $root != *$'\r'* && $root != *$'\t'* ]] || fail 'Installation paths must be absolute and contain no control characters.'
done

if [[ -f $MENU ]]; then
  marker_count "$MENU" "$MENU_BEGIN" "$MENU_END" >/dev/null || fail 'Malformed SoundSwap shutdown menu markers; preserve the menu and repair the marker block first.'
  marker_count "$MENU" "$OLD_MENU_BEGIN" "$OLD_MENU_END" >/dev/null || fail 'Malformed BeepBoop shutdown menu markers; preserve the menu and repair the marker block first.'
  marker_count "$MENU" "$OLDER_MENU_BEGIN" "$OLDER_MENU_END" >/dev/null || fail 'Malformed omarchy-sounds shutdown menu markers; preserve the menu and repair the marker block first.'
fi

for file in bin/soundswap bin/soundswap-play bin/soundswap-daemon share/common.sh share/events.tsv config.default hypr/soundswap.lua plugin/manifest.json plugin/Panel.qml plugin/soundswap.svg sounds/README.md; do
  [[ -f $SRC/$file && -r $SRC/$file ]] || fail "Missing source file: $file"
done
dupes=$(grep -o '^[A-Z_]*=' "$SRC/config.default" | sort | uniq -d | tr -d =)
[[ -z $dupes ]] || fail "Duplicate keys in config.default: $dupes"
TARGETS=("$MAIN" "$HYPR/soundswap.lua" "$CONF/config" "$CONF/sounds/README.md" "$CONFIG_ROOT/omarchy/shell.json" "$MENU")
for name in soundswap soundswap-play soundswap-daemon; do TARGETS+=("$BIN/$name"); done
for name in common.sh config.default events.tsv; do TARGETS+=("$SHARE/$name"); done
for name in "${UNITS[@]}"; do TARGETS+=("$UNIT_DIR/$name"); done
for name in battery-low theme-set post-update; do TARGETS+=("$HOOKS/$name.d/soundswap"); done
TARGETS+=("$PLUGIN_DIR/manifest.json" "$PLUGIN_DIR/Panel.qml" "$PLUGIN_DIR/soundswap.svg")
for file in "${TARGETS[@]}"; do
  [[ ! -L $file && ( ! -e $file || -f $file ) ]] || fail "Refusing non-regular target: $file"
done
for dir in "$CONF" "$CONF/sounds" "$SHARE" "$SHARE/original" "$STATE_ROOT/soundswap"; do
  [[ ! -L $dir && ( ! -e $dir || -d $dir ) ]] || fail "Refusing non-directory target: $dir"
done
for dir in "$CONFIG_ROOT/beepboop" "$CONFIG_ROOT/omarchy-sounds" "$DATA_ROOT/beepboop" "$DATA_ROOT/omarchy-sounds" "$STATE_ROOT/beepboop" "$STATE_ROOT/omarchy-sounds"; do
  [[ ( ! -e $dir && ! -L $dir ) || ( -d $dir && ! -L $dir ) ]] || fail "Refusing unsafe legacy directory: $dir"
done
for file in "$SRC"/bin/* "$SRC/share/common.sh" "$SRC"/hooks/*; do bash -n "$file"; done
luac -p "$SRC/hypr/soundswap.lua" "$MAIN"

stage=$(mktemp -d /tmp/soundswap-install.XXXXXX)
trap 'rm -rf -- "$stage"' EXIT

# -----------------------------------------------------------------------------
# Stage menu and Hyprland changes before touching any installed files.
# -----------------------------------------------------------------------------
menu_source=$MENU
[[ -f $menu_source ]] || { printf '{\n}\n' > "$stage/empty-menu.jsonc"; menu_source="$stage/empty-menu.jsonc"; }
awk -v b="$MENU_BEGIN" -v e="$MENU_END" -v ob="$OLD_MENU_BEGIN" -v oe="$OLD_MENU_END" -v xb="$OLDER_MENU_BEGIN" -v xe="$OLDER_MENU_END" '
  $0 == ob || $0 == xb || $0 == b { skip=1; next }
  $0 == oe || $0 == xe || $0 == e { skip=0; next }
  !skip { print }
' "$menu_source" > "$stage/menu-unowned.jsonc"
for menu_action in logout reboot shutdown; do
  if grep -q "\"system.$menu_action\"[[:space:]]*:" "$stage/menu-unowned.jsonc"; then
    fail "The user menu already customizes system.$menu_action; preserve that action and resolve the conflict manually."
  fi
done
awk -v b="$MENU_BEGIN" -v e="$MENU_END" -v ob="$OLD_MENU_BEGIN" -v oe="$OLD_MENU_END" -v xb="$OLDER_MENU_BEGIN" -v xe="$OLDER_MENU_END" '
  $0 == ob || $0 == xb || $0 == b { skip=1; next }
  $0 == oe || $0 == xe || $0 == e { skip=0; next }
  !skip && !added && /^[[:space:]]*\{[[:space:]]*$/ {
    print
    print b
    print "  \"system.logout\": {\"icon\": \"󰍃\", \"label\": \"Logout\", \"action\": \"soundswap logout\"},"
    print "  \"system.reboot\": {\"icon\": \"󰜉\", \"label\": \"Reboot\", \"action\": \"soundswap reboot\"},"
    print "  \"system.shutdown\": {\"icon\": \"󰐥\", \"label\": \"Shutdown\", \"action\": \"soundswap poweroff\"},"
    print e
    added=1
    next
  }
  !skip { print }
  END { if (!added || skip) exit 1 }
' "$menu_source" > "$stage/menu.jsonc" || fail 'Cannot stage the SoundSwap shutdown menu override.'

loader='dofile((os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/hypr/soundswap.lua")'
awk -v b="$BEGIN" -v e="$END" -v ob="$OLD_BEGIN" -v oe="$OLD_END" -v xb="$OLDER_BEGIN" -v xe="$OLDER_END" -v loader="$loader" '
  $0 == b || $0 == ob || $0 == xb { if (!added) { print b; print loader; print e; added=1 }; skip=1; next }
  $0 == e || $0 == oe || $0 == xe { skip=0; next }
  !skip { print }
  END { if (!added) { print ""; print b; print loader; print e } }
' "$MAIN" > "$stage/main.lua"
cp "$SRC/hypr/soundswap.lua" "$stage/module.lua"
# Validate the new module without replacing a file watched by the live compositor.
awk -v loader="$loader" '{ if ($0 == loader) print "dofile(os.getenv(\"SOUNDSWAP_STAGED_MODULE\"))"; else print }' "$stage/main.lua" > "$stage/verify.lua"
luac -p "$stage/main.lua" "$stage/module.lua"
SOUNDSWAP_STAGED_MODULE="$stage/module.lua" timeout 15 Hyprland --verify-config --config "$stage/verify.lua" || fail 'Hyprland rejected the staged configuration; installation was not changed.'
if timeout 5 systemctl --user show-environment >/dev/null 2>&1; then
  say 'PASS: user systemd service manager is reachable'
else
  printf 'FAIL: user systemd service manager is unavailable.\n  Fix: log into the Omarchy desktop session and rerun ./install.sh from its terminal.\n' >&2
  exit 1
fi
active_audio_services=()
for unit in pipewire.service pipewire-pulse.service wireplumber.service pulseaudio.service; do
  if timeout 5 systemctl --user is-active --quiet "$unit"; then active_audio_services+=("$unit"); fi
done
if ((${#active_audio_services[@]})); then
  say "PASS: active user audio service(s): ${active_audio_services[*]}"
else
  printf 'WARN: no PipeWire or PulseAudio user service is active.\n  Fix: check with systemctl --user status pipewire pipewire-pulse wireplumber; start the audio stack if needed.\n'
fi

# -----------------------------------------------------------------------------
# Legacy migration: move settings/data/state if the new locations do not exist,
# then remove old binaries, services, hooks and plugin so sounds fire only once.
# Validation above already passed, so a failure here leaves old artifacts intact.
# -----------------------------------------------------------------------------
BACKUP="$STATE_ROOT/soundswap/backups/$(date +%Y%m%d-%H%M%S-%N)"
backup() {
  [[ -e $1 || -L $1 ]] || return 0
  local dest="$BACKUP/${1#/}"
  mkdir -p "${dest%/*}"
  cp -a -- "$1" "$dest"
}

migrate_first() {
  local dest=$1 src
  shift
  for src in "$@"; do
    [[ -e $src ]] || continue
    if [[ -e $dest ]]; then
      warn "Both $src and $dest exist; leaving $src for manual cleanup."
      continue
    fi
    mkdir -p "${dest%/*}"
    mv -- "$src" "$dest"
  done
}

migrate_first "$STATE_ROOT/soundswap" "$STATE_ROOT/beepboop" "$STATE_ROOT/omarchy-sounds"
[[ ! -L $STATE_ROOT/soundswap && ( ! -e $STATE_ROOT/soundswap || -d $STATE_ROOT/soundswap ) ]] || fail "Refusing migrated non-directory target: $STATE_ROOT/soundswap"

put() {
  local src=$1 dest=$2 mode=$3 tmp
  mkdir -p "${dest%/*}"
  backup "$dest"
  tmp=$(mktemp "${dest%/*}/.soundswap.XXXXXX")
  install -m "$mode" -- "$src" "$tmp"
  mv -f -- "$tmp" "$dest"
}

say "Installing validated Lua configuration; backups: $BACKUP"
module_existed=0; [[ ! -f $HYPR/soundswap.lua ]] || module_existed=1
put "$SRC/hypr/soundswap.lua" "$HYPR/soundswap.lua" 644
put "$stage/main.lua" "$MAIN" 644
rollback_lua() {
  cp -a -- "$BACKUP/${MAIN#/}" "$MAIN"
  if (( module_existed )); then cp -a -- "$BACKUP/${HYPR#/}/soundswap.lua" "$HYPR/soundswap.lua"; else rm -f -- "$HYPR/soundswap.lua"; fi
}
if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  if ! timeout 5 hyprctl reload >/dev/null; then rollback_lua; fail 'Hyprland reload failed; restored the previous Lua files.'; fi
  if ! errors=$(timeout 5 hyprctl configerrors) || [[ -n ${errors//[[:space:]]/} ]]; then
    rollback_lua
    timeout 5 hyprctl reload >/dev/null || warn 'Reload the restored Hyprland config manually.'
    fail 'Hyprland reported errors; restored the previous Lua files.'
  fi
fi

migrate_first "$CONF" "$CONFIG_ROOT/beepboop" "$CONFIG_ROOT/omarchy-sounds"
migrate_first "$SHARE" "$DATA_ROOT/beepboop" "$DATA_ROOT/omarchy-sounds"
for dir in "$CONF" "$CONF/sounds" "$SHARE" "$SHARE/original"; do
  [[ ! -L $dir && ( ! -e $dir || -d $dir ) ]] || fail "Refusing migrated non-directory target: $dir"
done

# Retire legacy integrations only after the new Hyprland configuration is live.
for unit in "${OLD_WATCHER_UNITS[@]}"; do
  if [[ -f $UNIT_DIR/$unit ]]; then
    backup "$UNIT_DIR/$unit"
    systemctl --user stop "$unit" 2>/dev/null || true
    systemctl --user disable "$unit" 2>/dev/null || true
  fi
done
for name in "${OLD_BINARIES[@]}"; do
  [[ -f $BIN/$name ]] && { backup "$BIN/$name"; rm -f -- "$BIN/$name"; }
done
for unit in "${OLD_SHUTDOWN_UNITS[@]}"; do
  if [[ -f $UNIT_DIR/$unit ]]; then
    backup "$UNIT_DIR/$unit"
    systemctl --user stop "$unit" 2>/dev/null || true
    systemctl --user disable "$unit" 2>/dev/null || true
  fi
done
for unit in "${OLD_WATCHER_UNITS[@]}" "${OLD_SHUTDOWN_UNITS[@]}"; do rm -f -- "$UNIT_DIR/$unit"; done
for hook in battery-low theme-set post-update; do
  for name in "${OLD_HOOK_NAMES[@]}"; do
    [[ -f $HOOKS/$hook.d/$name ]] && { backup "$HOOKS/$hook.d/$name"; rm -f -- "$HOOKS/$hook.d/$name"; }
  done
done
backup "$CONFIG_ROOT/omarchy/shell.json"
for id in "${OLD_PLUGIN_IDS[@]}"; do
  command -v omarchy >/dev/null && omarchy plugin disable "$id" 2>/dev/null || true
  if [[ -d $CONFIG_ROOT/omarchy/plugins/$id ]]; then
    backup "$CONFIG_ROOT/omarchy/plugins/$id"
    rm -rf -- "$CONFIG_ROOT/omarchy/plugins/$id"
  fi
done
[[ -f $HYPR/beepboop.lua ]] && { backup "$HYPR/beepboop.lua"; rm -f -- "$HYPR/beepboop.lua"; }
[[ -f $HYPR/omarchy_sounds.lua ]] && { backup "$HYPR/omarchy_sounds.lua"; rm -f -- "$HYPR/omarchy_sounds.lua"; }

say 'Installing commands, settings, hooks, and widget'
for name in soundswap soundswap-play soundswap-daemon; do put "$SRC/bin/$name" "$BIN/$name" 755; done
for name in common.sh events.tsv; do put "$SRC/share/$name" "$SHARE/$name" 644; done
put "$SRC/config.default" "$SHARE/config.default" 644
put "$stage/menu.jsonc" "$MENU" 644
mkdir -p "$CONF/sounds"
exec {config_lock}> "$CONF/config.lock"
flock -x "$config_lock"
backup "$CONF/config"
[[ -f $CONF/config ]] || cp "$SRC/config.default" "$CONF/config"
# Replace known stale legacy comments while preserving all settings and unknown lines.
awk '
  $0 == "# BeepBoop settings. Change with `beepboop` or the bar panel, or edit by hand." {
    print "# SoundSwap settings. Change with `soundswap` or the bar panel, or edit by hand."
    next
  }
  $0 == "# Omarchy Sounds settings. Change with `omarchy-sounds` or the bar panel, or edit by hand." {
    print "# SoundSwap settings. Change with `soundswap` or the bar panel, or edit by hand."
    next
  }
  $0 == "# Record every trigger to $XDG_RUNTIME_DIR/beepboop/events.log (beepboop log)" {
    print "# Record every trigger to $XDG_RUNTIME_DIR/soundswap/events.log (soundswap log)"
    next
  }
  $0 == "# Record every trigger to $XDG_RUNTIME_DIR/omarchy-sounds/events.log (omarchy-sounds log)" {
    print "# Record every trigger to $XDG_RUNTIME_DIR/soundswap/events.log (soundswap log)"
    next
  }
  { print }
' "$CONF/config" > "$stage/config-comments" && mv -- "$stage/config-comments" "$CONF/config"
[[ ! -s $CONF/config || -z $(tail -c 1 "$CONF/config") ]] || printf '\n' >> "$CONF/config"
while IFS= read -r line || [[ -n $line ]]; do
  [[ $line =~ ^([A-Z_]+)= ]] || continue
  grep -Eq "^[[:space:]]*${BASH_REMATCH[1]}[[:space:]]*=" "$CONF/config" || printf '%s\n' "$line" >> "$CONF/config"
done < "$SRC/config.default"
flock -u "$config_lock"
exec {config_lock}>&-
put "$SRC/sounds/README.md" "$CONF/sounds/README.md" 644
mkdir -p "$SHARE/original"
while IFS=$'\t' read -r event _; do
  [[ -n $event && $event != \#* ]] || continue
  working_sound=0
  for ext in wav ogg oga flac mp3; do
    [[ -e $CONF/sounds/$event.$ext || -L $CONF/sounds/$event.$ext ]] && working_sound=1
  done
  for ext in wav ogg oga flac mp3; do
    sound="$SRC/sounds/$event.$ext"
    [[ -f $sound ]] || continue
    put "$sound" "$SHARE/original/${sound##*/}" 644
    (( working_sound )) || cp -- "$sound" "$CONF/sounds/"
    break
  done
done < "$SRC/share/events.tsv"
for hook in battery-low theme-set post-update; do put "$SRC/hooks/$hook" "$HOOKS/$hook.d/soundswap" 755; done
panel_changed=0
for name in Panel.qml soundswap.svg; do
  [[ ! -f $PLUGIN_DIR/$name ]] || cmp -s "$SRC/plugin/$name" "$PLUGIN_DIR/$name" || panel_changed=1
done
for name in manifest.json Panel.qml soundswap.svg; do put "$SRC/plugin/$name" "$PLUGIN_DIR/$name" 644; done

unit_escape() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "${s//%/%%}"; }
for unit in "${UNITS[@]}"; do
  while IFS= read -r line; do
    printf '%s\n' "$line"
    if [[ $line = '[Service]' ]]; then
      for key in XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME; do
        case $key in XDG_CONFIG_HOME) value=$CONFIG_ROOT ;; XDG_DATA_HOME) value=$DATA_ROOT ;; *) value=$STATE_ROOT ;; esac
        printf 'Environment="%s=%s"\n' "$key" "$(unit_escape "$value")"
      done
    fi
  done < "$SRC/systemd/$unit" > "$stage/$unit"
  put "$stage/$unit" "$UNIT_DIR/$unit" 644
done
# Remove old default.target enablement without stopping its active shutdown chime.
systemctl --user disable soundswap-shutdown.service
systemctl --user daemon-reload
systemctl --user reset-failed "${OLD_WATCHER_UNITS[@]}" "${OLD_SHUTDOWN_UNITS[@]}" 2>/dev/null || true
systemctl --user enable "${UNITS[@]}"
systemctl --user start soundswap-shutdown.service
systemctl --user restart soundswap.service

if command -v omarchy-shell >/dev/null && timeout 5 omarchy-shell shell listPlugins >/dev/null 2>&1; then
  if ! timeout 5 omarchy-shell shell rescanPlugins >/dev/null; then warn 'Widget rescan failed; reload the Omarchy shell when convenient.'; fi
  if ! grep -q '"soundswap.sounds"' "$CONFIG_ROOT/omarchy/shell.json" 2>/dev/null; then
    backup "$CONFIG_ROOT/omarchy/shell.json"
    if command -v omarchy >/dev/null; then
      omarchy plugin enable "$PLUGIN_ID" || warn "Widget enabling failed; enable it later: omarchy plugin enable $PLUGIN_ID"
    else
      warn "Enable the widget later: omarchy plugin enable $PLUGIN_ID"
    fi
  fi
  (( ! panel_changed )) || warn 'If the updated panel still appears unchanged, restart the Omarchy shell when convenient.'
else
  warn "Enable the widget from your desktop later: omarchy plugin enable $PLUGIN_ID"
fi
say "Done. Settings and sounds preserved in $CONF; inspect with soundswap status."
