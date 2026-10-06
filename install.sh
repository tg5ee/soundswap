#!/usr/bin/env bash
# Install user overrides only. Existing targeted files are backed up before replacement.
set -euo pipefail
[[ $# = 0 ]] || { echo 'Usage: install.sh' >&2; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}"
BIN="$HOME/.local/bin"
CONF="$CONFIG_ROOT/omarchy-sounds"
HYPR="$CONFIG_ROOT/hypr"
MAIN="$HYPR/hyprland.lua"
UNIT_DIR="$CONFIG_ROOT/systemd/user"
SHARE="$DATA_ROOT/omarchy-sounds"
HOOKS="$CONFIG_ROOT/omarchy/hooks"
PLUGIN_ID=tomg.sounds
PLUGIN_DIR="$CONFIG_ROOT/omarchy/plugins/$PLUGIN_ID"
MENU="$CONFIG_ROOT/omarchy/extensions/omarchy-menu.jsonc"
BEGIN='-- omarchy-sounds >>>'
END='-- <<< omarchy-sounds'
UNITS=(omarchy-sounds.service omarchy-sounds-shutdown.service)
say() { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# Ambiguous or incomplete fences must never be interpreted as a removable range.
[[ -f $MAIN && ! -L $MAIN ]] || fail "Expected a regular Lua config at $MAIN"
marker=$(awk -v b="$BEGIN" -v e="$END" '
  index($0,b) { if ($0 != b || starts++ || ends) bad=1 }
  index($0,e) { if ($0 != e || ends++ || starts != 1) bad=1 }
  END { if (bad || starts != ends) exit 1; print starts+0 }
' "$MAIN") || fail 'Malformed omarchy-sounds markers; repair the paired block first.'
for tool in bash flock setsid timeout luac Hyprland systemctl install cp mv mktemp awk grep sed cmp date tail mkdir find sort uniq tr rm ps journalctl dbus-monitor gdbus udevadm; do
  command -v "$tool" >/dev/null || fail "Missing required command: $tool"
done
for root in "$HOME" "$CONFIG_ROOT" "$DATA_ROOT" "$STATE_ROOT"; do
  [[ $root = /* && $root != *$'\n'* && $root != *$'\r'* && $root != *$'\t'* ]] || fail 'Installation paths must be absolute and contain no control characters.'
done
if [[ -f $MENU ]]; then
  awk '
    index($0, "omarchy-sounds shutdown >>>") { if ($0 != "  // omarchy-sounds shutdown >>>" || starts++ || inside) bad=1; inside=1; next }
    index($0, "<<< omarchy-sounds shutdown") { if ($0 != "  // <<< omarchy-sounds shutdown" || ends++ || !inside) bad=1; inside=0; next }
    END { if (bad || inside || starts != ends) exit 1 }
  ' "$MENU" || fail 'Malformed shutdown menu markers; preserve the menu and repair the marker block first.'
fi
[[ -n ${XDG_RUNTIME_DIR:-} && -d $XDG_RUNTIME_DIR && -w $XDG_RUNTIME_DIR ]] || fail 'Run from the desktop session with a writable XDG_RUNTIME_DIR.'
for file in bin/omarchy-sounds bin/omarchy-sounds-play bin/omarchy-sounds-daemon share/common.sh share/events.tsv config.default hypr/omarchy_sounds.lua plugin/manifest.json plugin/Panel.qml sounds/README.md; do
  [[ -f $SRC/$file && -r $SRC/$file ]] || fail "Missing source file: $file"
done
dupes=$(grep -o '^[A-Z_]*=' "$SRC/config.default" | sort | uniq -d | tr -d =)
[[ -z $dupes ]] || fail "Duplicate keys in config.default: $dupes"
TARGETS=("$MAIN" "$HYPR/omarchy_sounds.lua" "$CONF/config" "$CONF/sounds/README.md" "$CONFIG_ROOT/omarchy/shell.json" "$MENU")
for name in omarchy-sounds omarchy-sounds-play omarchy-sounds-daemon; do TARGETS+=("$BIN/$name"); done
for name in common.sh config.default events.tsv; do TARGETS+=("$SHARE/$name"); done
for name in "${UNITS[@]}"; do TARGETS+=("$UNIT_DIR/$name"); done
for name in battery-low theme-set post-update; do TARGETS+=("$HOOKS/$name.d/omarchy-sounds"); done
TARGETS+=("$PLUGIN_DIR/manifest.json" "$PLUGIN_DIR/Panel.qml")
for file in "${TARGETS[@]}"; do
  [[ ! -L $file && ( ! -e $file || -f $file ) ]] || fail "Refusing non-regular target: $file"
done
for file in "$SRC"/bin/* "$SRC/share/common.sh" "$SRC"/hooks/*; do bash -n "$file"; done
luac -p "$SRC/hypr/omarchy_sounds.lua" "$MAIN"

stage=$(mktemp -d /tmp/omarchy-sounds-install.XXXXXX)
trap 'rm -rf -- "$stage"' EXIT
menu_source=$MENU
[[ -f $menu_source ]] || { printf '{\n}\n' > "$stage/empty-menu.jsonc"; menu_source="$stage/empty-menu.jsonc"; }
if grep -q '"system.shutdown"[[:space:]]*:' "$menu_source" && ! grep -Fxq '  // omarchy-sounds shutdown >>>' "$menu_source"; then
  fail 'The user menu already customizes system.shutdown; preserve that action and resolve the conflict manually.'
fi
awk '
  $0 == "  // omarchy-sounds shutdown >>>" { skip=1; next }
  $0 == "  // <<< omarchy-sounds shutdown" { skip=0; next }
  !skip && !added && /^[[:space:]]*\{[[:space:]]*$/ {
    print
    print "  // omarchy-sounds shutdown >>>"
    print "  \"system.shutdown\": {\"icon\": \"󰐥\", \"label\": \"Shutdown\", \"action\": \"omarchy-sounds poweroff\"},"
    print "  // <<< omarchy-sounds shutdown"
    added=1
    next
  }
  !skip { print }
  END { if (!added || skip) exit 1 }
' "$menu_source" > "$stage/menu.jsonc" || fail 'Cannot stage the Omarchy shutdown menu override.'
loader='dofile((os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/hypr/omarchy_sounds.lua")'
awk -v b="$BEGIN" -v e="$END" -v loader="$loader" -v present="$marker" '
  $0 == b { print b; print loader; print e; skip=1; next }
  $0 == e { skip=0; next }
  !skip { print }
  END { if (!present) { print ""; print b; print loader; print e } }
' "$MAIN" > "$stage/main.lua"
cp "$SRC/hypr/omarchy_sounds.lua" "$stage/module.lua"
# Validate the new module without replacing a file watched by the live compositor.
awk -v loader="$loader" '{ if ($0 == loader) print "dofile(os.getenv(\"OMARCHY_SOUNDS_STAGED_MODULE\"))"; else print }' "$stage/main.lua" > "$stage/verify.lua"
luac -p "$stage/main.lua" "$stage/module.lua"
OMARCHY_SOUNDS_STAGED_MODULE="$stage/module.lua" timeout 15 Hyprland --verify-config --config "$stage/verify.lua" || fail 'Hyprland rejected the staged configuration; installation was not changed.'
timeout 5 systemctl --user show-environment >/dev/null || fail 'Cannot reach the user service manager; run from your desktop terminal.'
BACKUP="$STATE_ROOT/omarchy-sounds/backups/$(date +%Y%m%d-%H%M%S-%N)"
backup() {
  [[ -e $1 || -L $1 ]] || return 0
  local dest="$BACKUP/${1#/}"
  mkdir -p "${dest%/*}"
  cp -a -- "$1" "$dest"
}
put() {
  local src=$1 dest=$2 mode=$3 tmp
  mkdir -p "${dest%/*}"
  backup "$dest"
  tmp=$(mktemp "${dest%/*}/.omarchy-sounds.XXXXXX")
  install -m "$mode" -- "$src" "$tmp"
  mv -f -- "$tmp" "$dest"
}

say "Installing validated Lua configuration; backups: $BACKUP"
module_existed=0; [[ ! -f $HYPR/omarchy_sounds.lua ]] || module_existed=1
put "$SRC/hypr/omarchy_sounds.lua" "$HYPR/omarchy_sounds.lua" 644
put "$stage/main.lua" "$MAIN" 644
rollback_lua() {
  cp -a -- "$BACKUP/${MAIN#/}" "$MAIN"
  if (( module_existed )); then cp -a -- "$BACKUP/${HYPR#/}/omarchy_sounds.lua" "$HYPR/omarchy_sounds.lua"; else rm -f -- "$HYPR/omarchy_sounds.lua"; fi
}
if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  if ! timeout 5 hyprctl reload >/dev/null; then rollback_lua; fail 'Hyprland reload failed; restored the previous Lua files.'; fi
  if ! errors=$(timeout 5 hyprctl configerrors) || [[ -n ${errors//[[:space:]]/} ]]; then
    rollback_lua
    timeout 5 hyprctl reload >/dev/null || warn 'Reload the restored Hyprland config manually.'
    fail 'Hyprland reported errors; restored the previous Lua files.'
  fi
fi

say 'Installing commands, settings, hooks, and widget'
for name in omarchy-sounds omarchy-sounds-play omarchy-sounds-daemon; do put "$SRC/bin/$name" "$BIN/$name" 755; done
for name in common.sh events.tsv; do put "$SRC/share/$name" "$SHARE/$name" 644; done
put "$SRC/config.default" "$SHARE/config.default" 644
put "$stage/menu.jsonc" "$MENU" 644
mkdir -p "$CONF/sounds"
exec {config_lock}> "$CONF/config.lock"
flock -x "$config_lock"
backup "$CONF/config"
[[ -f $CONF/config ]] || cp "$SRC/config.default" "$CONF/config"
[[ ! -s $CONF/config || -z $(tail -c 1 "$CONF/config") ]] || printf '\n' >> "$CONF/config"
while IFS= read -r line || [[ -n $line ]]; do
  [[ $line =~ ^([A-Z_]+)= ]] || continue
  grep -Eq "^[[:space:]]*${BASH_REMATCH[1]}[[:space:]]*=" "$CONF/config" || printf '%s\n' "$line" >> "$CONF/config"
done < "$SRC/config.default"
flock -u "$config_lock"
exec {config_lock}>&-
put "$SRC/sounds/README.md" "$CONF/sounds/README.md" 644
while IFS= read -r -d '' sound; do
  [[ -e $CONF/sounds/${sound##*/} || -L $CONF/sounds/${sound##*/} ]] || cp -- "$sound" "$CONF/sounds/"
done < <(find "$SRC/sounds" -maxdepth 1 -type f \( -name '*.wav' -o -name '*.ogg' -o -name '*.oga' -o -name '*.flac' -o -name '*.mp3' \) -print0)
for hook in battery-low theme-set post-update; do put "$SRC/hooks/$hook" "$HOOKS/$hook.d/omarchy-sounds" 755; done
panel_changed=0
[[ ! -f $PLUGIN_DIR/Panel.qml ]] || cmp -s "$SRC/plugin/Panel.qml" "$PLUGIN_DIR/Panel.qml" || panel_changed=1
for name in manifest.json Panel.qml; do put "$SRC/plugin/$name" "$PLUGIN_DIR/$name" 644; done

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
systemctl --user disable omarchy-sounds-shutdown.service
systemctl --user daemon-reload
systemctl --user enable "${UNITS[@]}"
systemctl --user start omarchy-sounds-shutdown.service
systemctl --user restart omarchy-sounds.service

if command -v omarchy-shell >/dev/null && timeout 5 omarchy-shell shell listPlugins >/dev/null 2>&1; then
  if ! timeout 5 omarchy-shell shell rescanPlugins >/dev/null; then warn 'Widget rescan failed; reload the Omarchy shell when convenient.'; fi
  if ! grep -q '"tomg.sounds"' "$CONFIG_ROOT/omarchy/shell.json" 2>/dev/null; then
    backup "$CONFIG_ROOT/omarchy/shell.json"
    if command -v omarchy >/dev/null; then omarchy plugin enable "$PLUGIN_ID"; else warn "Enable the widget later: omarchy plugin enable $PLUGIN_ID"; fi
  fi
  (( ! panel_changed )) || warn 'If the updated panel still appears unchanged, restart the Omarchy shell when convenient.'
else
  warn "Enable the widget from your desktop later: omarchy plugin enable $PLUGIN_ID"
fi
command -v pw-play >/dev/null || command -v paplay >/dev/null || command -v mpv >/dev/null || warn 'No audio player found: install pw-play, paplay, or mpv.'
say "Done. Settings and sounds preserved in $CONF; inspect with omarchy-sounds status."
