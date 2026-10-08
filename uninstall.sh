#!/usr/bin/env bash
# Remove owned integration files; settings and sounds remain unless --purge is explicit.
# Also cleans up BeepBoop and omarchy-sounds integrations so old installs cannot keep firing.
set -euo pipefail
[[ $# = 0 || ( $# = 1 && $1 = --purge ) ]] || { echo 'Usage: uninstall.sh [--purge]' >&2; exit 1; }

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}"
CONF="$CONFIG_ROOT/soundswap"
HYPR="$CONFIG_ROOT/hypr"
MAIN="$HYPR/hyprland.lua"
BIN="$HOME/.local/bin"
SHARE="$DATA_ROOT/soundswap"
UNIT_DIR="$CONFIG_ROOT/systemd/user"
PLUGIN_DIR="$CONFIG_ROOT/omarchy/plugins/soundswap.sounds"
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

marker=0
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
[[ ! -L $MAIN && ( ! -e $MAIN || -f $MAIN ) ]] || fail "Refusing non-regular Lua config: $MAIN"
if [[ -f $MAIN ]]; then
  marker=$(marker_count "$MAIN" "$BEGIN" "$END") || fail 'Malformed soundswap markers; repair the paired block first.'
  old_marker=$(marker_count "$MAIN" "$OLD_BEGIN" "$OLD_END") || fail 'Malformed legacy beepboop markers; repair the paired block first.'
  older_marker=$(marker_count "$MAIN" "$OLDER_BEGIN" "$OLDER_END") || fail 'Malformed legacy omarchy-sounds markers; repair the paired block first.'
  marker=$((marker + old_marker + older_marker))
fi
for tool in bash timeout systemctl cp mv mktemp awk mkdir date rm rmdir; do
  command -v "$tool" >/dev/null || fail "Missing required command: $tool"
done
for root in "$HOME" "$CONFIG_ROOT" "$DATA_ROOT" "$STATE_ROOT"; do
  [[ $root = /* && $root != *$'\n'* && $root != *$'\r'* && $root != *$'\t'* ]] || fail 'Installation paths must be absolute and contain no control characters.'
done
if [[ -f $MENU ]]; then
  marker_count "$MENU" "$MENU_BEGIN" "$MENU_END" >/dev/null || fail 'Malformed SoundSwap shutdown menu markers; preserve the menu and repair the marker block first.'
  marker_count "$MENU" "$OLD_MENU_BEGIN" "$OLD_MENU_END" >/dev/null || fail 'Malformed BeepBoop shutdown menu markers; preserve the menu and repair the marker block first.'
  marker_count "$MENU" "$OLDER_MENU_BEGIN" "$OLDER_MENU_END" >/dev/null || fail 'Malformed omarchy-sounds shutdown menu markers; preserve the menu and repair the marker block first.'
fi
FILES=("$HYPR/soundswap.lua" "$PLUGIN_DIR/manifest.json" "$PLUGIN_DIR/Panel.qml" "$PLUGIN_DIR/soundswap.svg")
for name in soundswap soundswap-play soundswap-daemon; do FILES+=("$BIN/$name"); done
for name in common.sh config.default events.tsv; do FILES+=("$SHARE/$name"); done
for name in "${UNITS[@]}"; do FILES+=("$UNIT_DIR/$name"); done
for name in battery-low theme-set post-update; do FILES+=("$CONFIG_ROOT/omarchy/hooks/$name.d/soundswap"); done
for file in "${FILES[@]}" "$CONFIG_ROOT/omarchy/shell.json" "$MENU"; do
  [[ ! -L $file && ( ! -e $file || -f $file ) ]] || fail "Refusing non-regular target: $file"
done
[[ ! -L $CONF ]] || fail "Refusing a symlinked settings directory: $CONF"
[[ ! -L $STATE_ROOT/soundswap && ( ! -e $STATE_ROOT/soundswap || -d $STATE_ROOT/soundswap ) ]] || fail "Refusing a symlinked state directory: $STATE_ROOT/soundswap"
stage=$(mktemp -d /tmp/soundswap-uninstall.XXXXXX)
trap 'rm -rf -- "$stage"' EXIT

BACKUP="$STATE_ROOT/soundswap/backups/$(date +%Y%m%d-%H%M%S-%N)"
backup() {
  [[ -e $1 || -L $1 ]] || return 0
  local dest="$BACKUP/${1#/}"
  mkdir -p "${dest%/*}"
  cp -a -- "$1" "$dest"
}

if (( marker )); then
  for tool in luac Hyprland; do command -v "$tool" >/dev/null || fail "Missing required command: $tool"; done
  [[ -n ${XDG_RUNTIME_DIR:-} && -d $XDG_RUNTIME_DIR && -w $XDG_RUNTIME_DIR ]] || fail 'Run from the desktop session with a writable XDG_RUNTIME_DIR.'
  awk -v b="$BEGIN" -v e="$END" -v ob="$OLD_BEGIN" -v oe="$OLD_END" -v xb="$OLDER_BEGIN" -v xe="$OLDER_END" '
    $0 == b || $0 == ob || $0 == xb { skip=1; next }
    $0 == e || $0 == oe || $0 == xe { skip=0; next }
    !skip { print }
  ' "$MAIN" > "$stage/main.lua"
  luac -p "$stage/main.lua"
  timeout 15 Hyprland --verify-config --config "$stage/main.lua" || fail 'Hyprland rejected the staged removal; installation was not changed.'
fi
timeout 5 systemctl --user show-environment >/dev/null || fail 'Cannot reach the user service manager; run from your desktop terminal.'

if (( marker )); then
  backup "$MAIN"
  replacement=$(mktemp "$HYPR/.soundswap.XXXXXX")
  cp -p -- "$MAIN" "$replacement"
  cat "$stage/main.lua" > "$replacement"
  mv -f -- "$replacement" "$MAIN"
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    reload_ok=1
    timeout 5 hyprctl reload >/dev/null || reload_ok=0
    errors=$(timeout 5 hyprctl configerrors) || reload_ok=0
    if (( ! reload_ok )) || [[ -n ${errors//[[:space:]]/} ]]; then
      cp -a -- "$BACKUP/${MAIN#/}" "$MAIN"
      timeout 5 hyprctl reload >/dev/null || warn 'Reload the restored Hyprland config manually.'
      fail 'Hyprland reload failed; restored the previous config and retained the installation.'
    fi
  fi
fi
backup "$CONFIG_ROOT/omarchy/shell.json"
if [[ -f $MENU ]] && (grep -Fxq "$OLDER_MENU_BEGIN" "$MENU" || grep -Fxq "$OLD_MENU_BEGIN" "$MENU" || grep -Fxq "$MENU_BEGIN" "$MENU"); then
  backup "$MENU"
  awk -v b="$MENU_BEGIN" -v e="$MENU_END" -v ob="$OLD_MENU_BEGIN" -v oe="$OLD_MENU_END" -v xb="$OLDER_MENU_BEGIN" -v xe="$OLDER_MENU_END" '
    $0 == b || $0 == ob || $0 == xb { skip=1; next }
    $0 == e || $0 == oe || $0 == xe { skip=0; next }
    !skip { print }
    END { if (skip) exit 1 }
  ' "$MENU" > "$stage/menu.jsonc" || fail 'Cannot remove the shutdown menu override.'
  replacement=$(mktemp "${MENU%/*}/.soundswap.XXXXXX")
  cat "$stage/menu.jsonc" > "$replacement"
  mv -f -- "$replacement" "$MENU"
fi
if command -v omarchy >/dev/null; then
  omarchy plugin disable soundswap.sounds || warn 'Widget disabling failed; remove its bar entry manually.'
  for id in "${OLD_PLUGIN_IDS[@]}"; do omarchy plugin disable "$id" 2>/dev/null || true; done
fi
# Remove only bundled event files. Unknown files under original/ are retained.
if [[ -f $SHARE/events.tsv && -d $SHARE/original && ! -L $SHARE/original ]]; then
  while IFS=$'\t' read -r event _; do
    [[ -n $event && $event != \#* ]] || continue
    for ext in wav ogg oga flac mp3; do rm -f -- "$SHARE/original/$event.$ext"; done
  done < "$SHARE/events.tsv"
  rmdir "$SHARE/original" 2>/dev/null || true
fi
# Stop watchers first; removing the player before the shutdown unit prevents an uninstall chime.
systemctl --user stop soundswap.service || warn 'Event watcher stop failed.'
backup "$BIN/soundswap-play"
rm -f -- "$BIN/soundswap-play"
systemctl --user disable --now "${UNITS[@]}" || warn 'Service disabling failed; inspect the user journal.'
# Remove legacy players before stopping old shutdown units to prevent a chime.
for name in "${OLD_BINARIES[@]}"; do [[ -f $BIN/$name ]] && { backup "$BIN/$name"; rm -f -- "$BIN/$name"; }; done
for unit in "${OLD_WATCHER_UNITS[@]}" "${OLD_SHUTDOWN_UNITS[@]}"; do
  systemctl --user stop "$unit" 2>/dev/null || true
  systemctl --user disable "$unit" 2>/dev/null || true
  [[ -f $UNIT_DIR/$unit ]] && { backup "$UNIT_DIR/$unit"; rm -f -- "$UNIT_DIR/$unit"; }
done
for file in "${FILES[@]}"; do backup "$file"; rm -f -- "$file"; done
# Legacy cleanup.
for hook in battery-low theme-set post-update; do
  for name in "${OLD_HOOK_NAMES[@]}"; do
    [[ -f $CONFIG_ROOT/omarchy/hooks/$hook.d/$name ]] && { backup "$CONFIG_ROOT/omarchy/hooks/$hook.d/$name"; rm -f -- "$CONFIG_ROOT/omarchy/hooks/$hook.d/$name"; }
  done
done
for id in "${OLD_PLUGIN_IDS[@]}"; do
  [[ -d $CONFIG_ROOT/omarchy/plugins/$id ]] && { backup "$CONFIG_ROOT/omarchy/plugins/$id"; rm -rf -- "$CONFIG_ROOT/omarchy/plugins/$id"; }
done
[[ -f $HYPR/beepboop.lua ]] && { backup "$HYPR/beepboop.lua"; rm -f -- "$HYPR/beepboop.lua"; }
[[ -f $HYPR/omarchy_sounds.lua ]] && { backup "$HYPR/omarchy_sounds.lua"; rm -f -- "$HYPR/omarchy_sounds.lua"; }
rmdir "$PLUGIN_DIR" "$SHARE" 2>/dev/null || true
systemctl --user daemon-reload
if command -v omarchy-shell >/dev/null; then
  timeout 5 omarchy-shell shell rescanPlugins >/dev/null || warn 'Widget rescan failed; reload the Omarchy shell when convenient.'
fi
if [[ ${1:-} = --purge ]]; then
  backup "$CONF"
  rm -rf -- "$CONF"
  say "Removed settings and sounds; backups: $BACKUP"
else
  say "Removed integrations; retained settings and sounds in $CONF. Backups: $BACKUP"
fi
