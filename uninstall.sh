#!/usr/bin/env bash
# Remove owned integration files; settings and sounds remain unless --purge is explicit.
set -euo pipefail
[[ $# = 0 || ( $# = 1 && $1 = --purge ) ]] || { echo 'Usage: uninstall.sh [--purge]' >&2; exit 1; }
CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}"
CONF="$CONFIG_ROOT/omarchy-sounds"
HYPR="$CONFIG_ROOT/hypr"
MAIN="$HYPR/hyprland.lua"
BIN="$HOME/.local/bin"
SHARE="$DATA_ROOT/omarchy-sounds"
UNIT_DIR="$CONFIG_ROOT/systemd/user"
PLUGIN_DIR="$CONFIG_ROOT/omarchy/plugins/tomg.sounds"
MENU="$CONFIG_ROOT/omarchy/extensions/omarchy-menu.jsonc"
BEGIN='-- omarchy-sounds >>>'
END='-- <<< omarchy-sounds'
UNITS=(omarchy-sounds.service omarchy-sounds-shutdown.service)
say() { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

marker=0
[[ ! -L $MAIN && ( ! -e $MAIN || -f $MAIN ) ]] || fail "Refusing non-regular Lua config: $MAIN"
if [[ -f $MAIN ]]; then
  marker=$(awk -v b="$BEGIN" -v e="$END" '
    index($0,b) { if ($0 != b || starts++ || ends) bad=1 }
    index($0,e) { if ($0 != e || ends++ || starts != 1) bad=1 }
    END { if (bad || starts != ends) exit 1; print starts+0 }
  ' "$MAIN") || fail 'Malformed omarchy-sounds markers; repair the paired block first.'
fi
for tool in bash timeout systemctl cp mv mktemp awk mkdir date rm rmdir; do
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
FILES=("$HYPR/omarchy_sounds.lua" "$PLUGIN_DIR/manifest.json" "$PLUGIN_DIR/Panel.qml")
for name in omarchy-sounds omarchy-sounds-play omarchy-sounds-daemon; do FILES+=("$BIN/$name"); done
for name in common.sh config.default events.tsv; do FILES+=("$SHARE/$name"); done
for name in "${UNITS[@]}"; do FILES+=("$UNIT_DIR/$name"); done
for name in battery-low theme-set post-update; do FILES+=("$CONFIG_ROOT/omarchy/hooks/$name.d/omarchy-sounds"); done
for file in "${FILES[@]}" "$CONFIG_ROOT/omarchy/shell.json" "$MENU"; do
  [[ ! -L $file && ( ! -e $file || -f $file ) ]] || fail "Refusing non-regular target: $file"
done
[[ ! -L $CONF ]] || fail "Refusing a symlinked settings directory: $CONF"
stage=$(mktemp -d /tmp/omarchy-sounds-uninstall.XXXXXX)
trap 'rm -rf -- "$stage"' EXIT
if (( marker )); then
  for tool in luac Hyprland; do command -v "$tool" >/dev/null || fail "Missing required command: $tool"; done
  [[ -n ${XDG_RUNTIME_DIR:-} && -d $XDG_RUNTIME_DIR && -w $XDG_RUNTIME_DIR ]] || fail 'Run from the desktop session with a writable XDG_RUNTIME_DIR.'
  awk -v b="$BEGIN" -v e="$END" '$0 == b { skip=1; next } $0 == e { skip=0; next } !skip { print }' "$MAIN" > "$stage/main.lua"
  luac -p "$stage/main.lua"
  timeout 15 Hyprland --verify-config --config "$stage/main.lua" || fail 'Hyprland rejected the staged removal; installation was not changed.'
fi
timeout 5 systemctl --user show-environment >/dev/null || fail 'Cannot reach the user service manager; run from your desktop terminal.'
BACKUP="$STATE_ROOT/omarchy-sounds/backups/$(date +%Y%m%d-%H%M%S-%N)"
backup() {
  [[ -e $1 || -L $1 ]] || return 0
  local dest="$BACKUP/${1#/}"
  mkdir -p "${dest%/*}"
  cp -a -- "$1" "$dest"
}

if (( marker )); then
  backup "$MAIN"
  replacement=$(mktemp "$HYPR/.omarchy-sounds.XXXXXX")
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
if [[ -f $MENU ]] && grep -Fxq '  // omarchy-sounds shutdown >>>' "$MENU"; then
  backup "$MENU"
  awk '
    $0 == "  // omarchy-sounds shutdown >>>" { skip=1; next }
    $0 == "  // <<< omarchy-sounds shutdown" { skip=0; next }
    !skip { print }
    END { if (skip) exit 1 }
  ' "$MENU" > "$stage/menu.jsonc" || fail 'Cannot remove the shutdown menu override.'
  replacement=$(mktemp "${MENU%/*}/.omarchy-sounds.XXXXXX")
  cat "$stage/menu.jsonc" > "$replacement"
  mv -f -- "$replacement" "$MENU"
fi
if command -v omarchy >/dev/null; then
  omarchy plugin disable tomg.sounds || warn 'Widget disabling failed; remove its bar entry manually.'
fi
# Stop watchers first; removing the player before the shutdown unit prevents an uninstall chime.
systemctl --user stop omarchy-sounds.service || warn 'Event watcher stop failed.'
backup "$BIN/omarchy-sounds-play"
rm -f -- "$BIN/omarchy-sounds-play"
systemctl --user disable --now "${UNITS[@]}" || warn 'Service disabling failed; inspect the user journal.'
for file in "${FILES[@]}"; do backup "$file"; rm -f -- "$file"; done
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
