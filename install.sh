#!/usr/bin/env bash
# Install user overrides only. Existing targeted files are backed up before replacement.
# On upgrade from omarchy-sounds, legacy paths are migrated and old hooks/services/binaries
# are removed so sounds cannot fire twice.
set -euo pipefail
[[ $# = 0 ]] || { echo 'Usage: install.sh' >&2; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}"
BIN="$HOME/.local/bin"
CONF="$CONFIG_ROOT/beepboop"
HYPR="$CONFIG_ROOT/hypr"
MAIN="$HYPR/hyprland.lua"
UNIT_DIR="$CONFIG_ROOT/systemd/user"
SHARE="$DATA_ROOT/beepboop"
HOOKS="$CONFIG_ROOT/omarchy/hooks"
PLUGIN_ID=beepboop.sounds
PLUGIN_DIR="$CONFIG_ROOT/omarchy/plugins/$PLUGIN_ID"
MENU="$CONFIG_ROOT/omarchy/extensions/omarchy-menu.jsonc"
BEGIN='-- beepboop >>>'
END='-- <<< beepboop'
OLD_BEGIN='-- omarchy-sounds >>>'
OLD_END='-- <<< omarchy-sounds'
MENU_BEGIN='  // beepboop shutdown >>>'
MENU_END='  // <<< beepboop shutdown'
OLD_MENU_BEGIN='  // omarchy-sounds shutdown >>>'
OLD_MENU_END='  // <<< omarchy-sounds shutdown'
UNITS=(beepboop.service beepboop-shutdown.service)
OLD_UNITS=(omarchy-sounds.service omarchy-sounds-shutdown.service)
OLD_BINARIES=(omarchy-sounds omarchy-sounds-play omarchy-sounds-daemon)
OLD_HOOK_NAME=omarchy-sounds
OLD_PLUGIN_ID=tomg.sounds
say() { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# Ambiguous or incomplete fences must never be interpreted as a removable range.
[[ -f $MAIN && ! -L $MAIN ]] || fail "Expected a regular Lua config at $MAIN"

# Validate both legacy and current Hyprland markers.
marker=$(awk -v b="$BEGIN" -v e="$END" -v ob="$OLD_BEGIN" -v oe="$OLD_END" '
  function check(tag, line,    s, e_, bad) {
    s=0; e_=0; bad=0
    for (i=1; i<=n[tag]; i++) {
      if (lines[tag,i] == b_m[tag]) { if (s || e_) bad=1; s++ }
      else if (lines[tag,i] == e_m[tag]) { if (!s || e_) bad=1; e_++; s-- }
      else bad=1
    }
    if (bad || s != 0 || e_ != n[tag]/2) return 1
    return 0
  }
  BEGIN { n["old"]=0; n["new"]=0; b_m["old"]=ob; e_m["old"]=oe; b_m["new"]=b; e_m["new"]=e }
  index($0,ob) || index($0,oe) || index($0,b) || index($0,e) {
    tag = (index($0,ob) || index($0,oe)) ? "old" : "new"
    n[tag]++; lines[tag,n[tag]]=$0
  }
  END {
    if (check("old") || check("new")) exit 1
    print (n["new"]/2)
  }
' "$MAIN") || fail 'Malformed beepboop or legacy omarchy-sounds markers; repair the paired block first.'

for tool in bash flock setsid timeout luac Hyprland systemctl install cp mv mktemp awk grep sed cmp date tail mkdir find sort uniq tr rm ps journalctl dbus-monitor gdbus udevadm; do
  command -v "$tool" >/dev/null || fail "Missing required command: $tool"
done
for root in "$HOME" "$CONFIG_ROOT" "$DATA_ROOT" "$STATE_ROOT"; do
  [[ $root = /* && $root != *$'\n'* && $root != *$'\r'* && $root != *$'\t'* ]] || fail 'Installation paths must be absolute and contain no control characters.'
done

if [[ -f $MENU ]]; then
  awk -v b="$MENU_BEGIN" -v e="$MENU_END" -v ob="$OLD_MENU_BEGIN" -v oe="$OLD_MENU_END" '
    function check(tag,    s, e_, bad) {
      s=0; e_=0; bad=0
      for (i=1; i<=n[tag]; i++) {
        if (lines[tag,i] == b_m[tag]) { if (s || e_) bad=1; s++ }
        else if (lines[tag,i] == e_m[tag]) { if (!s || e_) bad=1; e_++; s-- }
        else bad=1
      }
      if (bad || s != 0 || e_ != n[tag]/2) return 1
      return 0
    }
    BEGIN { n["old"]=0; n["new"]=0; b_m["old"]=ob; e_m["old"]=oe; b_m["new"]=b; e_m["new"]=e }
    $0 == ob || $0 == oe || $0 == b || $0 == e {
      tag = ($0 == ob || $0 == oe) ? "old" : "new"
      n[tag]++; lines[tag,n[tag]]=$0
    }
    END { if (check("old") || check("new")) exit 1 }
  ' "$MENU" || fail 'Malformed shutdown menu markers; preserve the menu and repair the marker block first.'
fi

[[ -n ${XDG_RUNTIME_DIR:-} && -d $XDG_RUNTIME_DIR && -w $XDG_RUNTIME_DIR ]] || fail 'Run from the desktop session with a writable XDG_RUNTIME_DIR.'
for file in bin/beepboop bin/beepboop-play bin/beepboop-daemon share/common.sh share/events.tsv config.default hypr/beepboop.lua plugin/manifest.json plugin/Panel.qml plugin/beepboop.svg sounds/README.md; do
  [[ -f $SRC/$file && -r $SRC/$file ]] || fail "Missing source file: $file"
done
dupes=$(grep -o '^[A-Z_]*=' "$SRC/config.default" | sort | uniq -d | tr -d =)
[[ -z $dupes ]] || fail "Duplicate keys in config.default: $dupes"
TARGETS=("$MAIN" "$HYPR/beepboop.lua" "$CONF/config" "$CONF/sounds/README.md" "$CONFIG_ROOT/omarchy/shell.json" "$MENU")
for name in beepboop beepboop-play beepboop-daemon; do TARGETS+=("$BIN/$name"); done
for name in common.sh config.default events.tsv; do TARGETS+=("$SHARE/$name"); done
for name in "${UNITS[@]}"; do TARGETS+=("$UNIT_DIR/$name"); done
for name in battery-low theme-set post-update; do TARGETS+=("$HOOKS/$name.d/beepboop"); done
TARGETS+=("$PLUGIN_DIR/manifest.json" "$PLUGIN_DIR/Panel.qml" "$PLUGIN_DIR/beepboop.svg")
for file in "${TARGETS[@]}"; do
  [[ ! -L $file && ( ! -e $file || -f $file ) ]] || fail "Refusing non-regular target: $file"
done
for file in "$SRC"/bin/* "$SRC/share/common.sh" "$SRC"/hooks/*; do bash -n "$file"; done
luac -p "$SRC/hypr/beepboop.lua" "$MAIN"

stage=$(mktemp -d /tmp/beepboop-install.XXXXXX)
trap 'rm -rf -- "$stage"' EXIT

# -----------------------------------------------------------------------------
# Stage menu and Hyprland changes before touching any installed files.
# -----------------------------------------------------------------------------
menu_source=$MENU
[[ -f $menu_source ]] || { printf '{\n}\n' > "$stage/empty-menu.jsonc"; menu_source="$stage/empty-menu.jsonc"; }
if grep -q '"system.shutdown"[[:space:]]*:' "$menu_source" && ! grep -Fxq -- "$MENU_BEGIN" "$menu_source" && ! grep -Fxq -- "$OLD_MENU_BEGIN" "$menu_source"; then
  fail 'The user menu already customizes system.shutdown; preserve that action and resolve the conflict manually.'
fi
awk -v b="$MENU_BEGIN" -v e="$MENU_END" -v ob="$OLD_MENU_BEGIN" -v oe="$OLD_MENU_END" '
  $0 == ob || $0 == b { skip=1; next }
  $0 == oe || $0 == e { skip=0; next }
  !skip && !added && /^[[:space:]]*\{[[:space:]]*$/ {
    print
    print b
    print "  \"system.shutdown\": {\"icon\": \"󰐥\", \"label\": \"Shutdown\", \"action\": \"beepboop poweroff\"},"
    print e
    added=1
    next
  }
  !skip { print }
  END { if (!added || skip) exit 1 }
' "$menu_source" > "$stage/menu.jsonc" || fail 'Cannot stage the BeepBoop shutdown menu override.'

loader='dofile((os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/hypr/beepboop.lua")'
awk -v b="$BEGIN" -v e="$END" -v loader="$loader" -v present="$marker" '
  $0 == b { print b; print loader; print e; skip=1; next }
  $0 == e { skip=0; next }
  !skip { print }
  END { if (!present) { print ""; print b; print loader; print e } }
' "$MAIN" > "$stage/main.lua"
cp "$SRC/hypr/beepboop.lua" "$stage/module.lua"
# Validate the new module without replacing a file watched by the live compositor.
awk -v loader="$loader" '{ if ($0 == loader) print "dofile(os.getenv(\"BEEPBOOP_STAGED_MODULE\"))"; else print }' "$stage/main.lua" > "$stage/verify.lua"
luac -p "$stage/main.lua" "$stage/module.lua"
BEEPBOOP_STAGED_MODULE="$stage/module.lua" timeout 15 Hyprland --verify-config --config "$stage/verify.lua" || fail 'Hyprland rejected the staged configuration; installation was not changed.'
timeout 5 systemctl --user show-environment >/dev/null || fail 'Cannot reach the user service manager; run from your desktop terminal.'

# -----------------------------------------------------------------------------
# Legacy migration: move settings/data/state if the new locations do not exist,
# then remove old binaries, services, hooks and plugin so sounds fire only once.
# Validation above already passed, so a failure here leaves old artifacts intact.
# -----------------------------------------------------------------------------
BACKUP="$STATE_ROOT/beepboop/backups/$(date +%Y%m%d-%H%M%S-%N)"
backup() {
  [[ -e $1 || -L $1 ]] || return 0
  local dest="$BACKUP/${1#/}"
  mkdir -p "${dest%/*}"
  cp -a -- "$1" "$dest"
}

migrate_dir() {
  local src=$1 dest=$2
  [[ -e $src ]] || return 0
  [[ -e $dest ]] && { warn "Both $src and $dest exist; leaving $src for manual cleanup."; return 0; }
  mkdir -p "${dest%/*}"
  mv -- "$src" "$dest"
}

migrate_dir "$CONFIG_ROOT/omarchy-sounds" "$CONF"
migrate_dir "$DATA_ROOT/omarchy-sounds" "$SHARE"
migrate_dir "$STATE_ROOT/omarchy-sounds" "$STATE_ROOT/beepboop"

# Remove old systemd units first so the manager forgets them before daemon-reload.
for unit in "${OLD_UNITS[@]}"; do
  if [[ -f $UNIT_DIR/$unit ]]; then
    backup "$UNIT_DIR/$unit"
    systemctl --user stop "$unit" 2>/dev/null || true
    systemctl --user disable "$unit" 2>/dev/null || true
    rm -f -- "$UNIT_DIR/$unit"
  fi
done
for name in "${OLD_BINARIES[@]}"; do
  [[ -f $BIN/$name ]] && { backup "$BIN/$name"; rm -f -- "$BIN/$name"; }
done
for hook in battery-low theme-set post-update; do
  [[ -f $HOOKS/$hook.d/$OLD_HOOK_NAME ]] && { backup "$HOOKS/$hook.d/$OLD_HOOK_NAME"; rm -f -- "$HOOKS/$hook.d/$OLD_HOOK_NAME"; }
done
[[ -d $CONFIG_ROOT/omarchy/plugins/$OLD_PLUGIN_ID ]] && { backup "$CONFIG_ROOT/omarchy/plugins/$OLD_PLUGIN_ID"; rm -rf -- "$CONFIG_ROOT/omarchy/plugins/$OLD_PLUGIN_ID"; }
[[ -f $HYPR/omarchy_sounds.lua ]] && { backup "$HYPR/omarchy_sounds.lua"; rm -f -- "$HYPR/omarchy_sounds.lua"; }

put() {
  local src=$1 dest=$2 mode=$3 tmp
  mkdir -p "${dest%/*}"
  backup "$dest"
  tmp=$(mktemp "${dest%/*}/.beepboop.XXXXXX")
  install -m "$mode" -- "$src" "$tmp"
  mv -f -- "$tmp" "$dest"
}

say "Installing validated Lua configuration; backups: $BACKUP"
module_existed=0; [[ ! -f $HYPR/beepboop.lua ]] || module_existed=1
put "$SRC/hypr/beepboop.lua" "$HYPR/beepboop.lua" 644
put "$stage/main.lua" "$MAIN" 644
rollback_lua() {
  cp -a -- "$BACKUP/${MAIN#/}" "$MAIN"
  if (( module_existed )); then cp -a -- "$BACKUP/${HYPR#/}/beepboop.lua" "$HYPR/beepboop.lua"; else rm -f -- "$HYPR/beepboop.lua"; fi
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
for name in beepboop beepboop-play beepboop-daemon; do put "$SRC/bin/$name" "$BIN/$name" 755; done
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
  $0 == "# Omarchy Sounds settings. Change with `omarchy-sounds` or the bar panel, or edit by hand." {
    print "# BeepBoop settings. Change with `beepboop` or the bar panel, or edit by hand."
    next
  }
  $0 == "# Record every trigger to $XDG_RUNTIME_DIR/omarchy-sounds/events.log (omarchy-sounds log)" {
    print "# Record every trigger to $XDG_RUNTIME_DIR/beepboop/events.log (beepboop log)"
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
while IFS= read -r -d '' sound; do
  [[ -e $CONF/sounds/${sound##*/} || -L $CONF/sounds/${sound##*/} ]] || cp -- "$sound" "$CONF/sounds/"
done < <(find "$SRC/sounds" -maxdepth 1 -type f \( -name '*.wav' -o -name '*.ogg' -o -name '*.oga' -o -name '*.flac' -o -name '*.mp3' \) -print0)
for hook in battery-low theme-set post-update; do put "$SRC/hooks/$hook" "$HOOKS/$hook.d/beepboop" 755; done
panel_changed=0
for name in Panel.qml beepboop.svg; do
  [[ ! -f $PLUGIN_DIR/$name ]] || cmp -s "$SRC/plugin/$name" "$PLUGIN_DIR/$name" || panel_changed=1
done
for name in manifest.json Panel.qml beepboop.svg; do put "$SRC/plugin/$name" "$PLUGIN_DIR/$name" 644; done

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
systemctl --user disable beepboop-shutdown.service
systemctl --user daemon-reload
systemctl --user enable "${UNITS[@]}"
systemctl --user start beepboop-shutdown.service
systemctl --user restart beepboop.service

if command -v omarchy-shell >/dev/null && timeout 5 omarchy-shell shell listPlugins >/dev/null 2>&1; then
  if ! timeout 5 omarchy-shell shell rescanPlugins >/dev/null; then warn 'Widget rescan failed; reload the Omarchy shell when convenient.'; fi
  if ! grep -q '"beepboop.sounds"' "$CONFIG_ROOT/omarchy/shell.json" 2>/dev/null; then
    backup "$CONFIG_ROOT/omarchy/shell.json"
    if command -v omarchy >/dev/null; then omarchy plugin enable "$PLUGIN_ID"; else warn "Enable the widget later: omarchy plugin enable $PLUGIN_ID"; fi
  fi
  (( ! panel_changed )) || warn 'If the updated panel still appears unchanged, restart the Omarchy shell when convenient.'
else
  warn "Enable the widget from your desktop later: omarchy plugin enable $PLUGIN_ID"
fi
command -v pw-play >/dev/null || command -v paplay >/dev/null || command -v mpv >/dev/null || warn 'No audio player found: install pw-play, paplay, or mpv.'
say "Done. Settings and sounds preserved in $CONF; inspect with beepboop status."
