#!/usr/bin/env bash
# Remove owned integration files; settings and sounds remain unless --purge is explicit.
# Also cleans up legacy omarchy-sounds integration so an old install cannot keep firing.
set -euo pipefail
[[ $# = 0 || ( $# = 1 && $1 = --purge ) ]] || { echo 'Usage: uninstall.sh [--purge]' >&2; exit 1; }

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}"
CONF="$CONFIG_ROOT/beepboop"
HYPR="$CONFIG_ROOT/hypr"
MAIN="$HYPR/hyprland.lua"
BIN="$HOME/.local/bin"
SHARE="$DATA_ROOT/beepboop"
UNIT_DIR="$CONFIG_ROOT/systemd/user"
PLUGIN_DIR="$CONFIG_ROOT/omarchy/plugins/beepboop.sounds"
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

marker=0
[[ ! -L $MAIN && ( ! -e $MAIN || -f $MAIN ) ]] || fail "Refusing non-regular Lua config: $MAIN"
if [[ -f $MAIN ]]; then
  marker=$(awk -v b="$BEGIN" -v e="$END" -v ob="$OLD_BEGIN" -v oe="$OLD_END" '
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
    index($0,ob) || index($0,oe) || index($0,b) || index($0,e) {
      tag = (index($0,ob) || index($0,oe)) ? "old" : "new"
      n[tag]++; lines[tag,n[tag]]=$0
    }
    END {
      if (check("old") || check("new")) exit 1
      print (n["new"]/2) + (n["old"]/2)
    }
  ' "$MAIN") || fail 'Malformed beepboop or legacy omarchy-sounds markers; repair the paired block first.'
fi
for tool in bash timeout systemctl cp mv mktemp awk mkdir date rm rmdir; do
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
FILES=("$HYPR/beepboop.lua" "$PLUGIN_DIR/manifest.json" "$PLUGIN_DIR/Panel.qml" "$PLUGIN_DIR/beepboop.svg")
for name in beepboop beepboop-play beepboop-daemon; do FILES+=("$BIN/$name"); done
for name in common.sh config.default events.tsv; do FILES+=("$SHARE/$name"); done
for name in "${UNITS[@]}"; do FILES+=("$UNIT_DIR/$name"); done
for name in battery-low theme-set post-update; do FILES+=("$CONFIG_ROOT/omarchy/hooks/$name.d/beepboop"); done
for file in "${FILES[@]}" "$CONFIG_ROOT/omarchy/shell.json" "$MENU"; do
  [[ ! -L $file && ( ! -e $file || -f $file ) ]] || fail "Refusing non-regular target: $file"
done
[[ ! -L $CONF ]] || fail "Refusing a symlinked settings directory: $CONF"
stage=$(mktemp -d /tmp/beepboop-uninstall.XXXXXX)
trap 'rm -rf -- "$stage"' EXIT

BACKUP="$STATE_ROOT/beepboop/backups/$(date +%Y%m%d-%H%M%S-%N)"
backup() {
  [[ -e $1 || -L $1 ]] || return 0
  local dest="$BACKUP/${1#/}"
  mkdir -p "${dest%/*}"
  cp -a -- "$1" "$dest"
}

if (( marker )); then
  for tool in luac Hyprland; do command -v "$tool" >/dev/null || fail "Missing required command: $tool"; done
  [[ -n ${XDG_RUNTIME_DIR:-} && -d $XDG_RUNTIME_DIR && -w $XDG_RUNTIME_DIR ]] || fail 'Run from the desktop session with a writable XDG_RUNTIME_DIR.'
  awk -v b="$BEGIN" -v e="$END" -v ob="$OLD_BEGIN" -v oe="$OLD_END" '
    $0 == b || $0 == ob { skip=1; next }
    $0 == e || $0 == oe { skip=0; next }
    !skip { print }
  ' "$MAIN" > "$stage/main.lua"
  luac -p "$stage/main.lua"
  timeout 15 Hyprland --verify-config --config "$stage/main.lua" || fail 'Hyprland rejected the staged removal; installation was not changed.'
fi
timeout 5 systemctl --user show-environment >/dev/null || fail 'Cannot reach the user service manager; run from your desktop terminal.'

if (( marker )); then
  backup "$MAIN"
  replacement=$(mktemp "$HYPR/.beepboop.XXXXXX")
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
if [[ -f $MENU ]] && (grep -Fxq "$OLD_MENU_BEGIN" "$MENU" || grep -Fxq "$MENU_BEGIN" "$MENU"); then
  backup "$MENU"
  awk -v b="$MENU_BEGIN" -v e="$MENU_END" -v ob="$OLD_MENU_BEGIN" -v oe="$OLD_MENU_END" '
    $0 == b || $0 == ob { skip=1; next }
    $0 == e || $0 == oe { skip=0; next }
    !skip { print }
    END { if (skip) exit 1 }
  ' "$MENU" > "$stage/menu.jsonc" || fail 'Cannot remove the shutdown menu override.'
  replacement=$(mktemp "${MENU%/*}/.beepboop.XXXXXX")
  cat "$stage/menu.jsonc" > "$replacement"
  mv -f -- "$replacement" "$MENU"
fi
if command -v omarchy >/dev/null; then
  omarchy plugin disable beepboop.sounds || warn 'Widget disabling failed; remove its bar entry manually.'
  omarchy plugin disable "$OLD_PLUGIN_ID" 2>/dev/null || true
fi
# Stop watchers first; removing the player before the shutdown unit prevents an uninstall chime.
systemctl --user stop beepboop.service || warn 'Event watcher stop failed.'
backup "$BIN/beepboop-play"
rm -f -- "$BIN/beepboop-play"
systemctl --user disable --now "${UNITS[@]}" || warn 'Service disabling failed; inspect the user journal.'
# Remove legacy units as well so an old install cannot keep running.
for unit in "${OLD_UNITS[@]}"; do
  systemctl --user stop "$unit" 2>/dev/null || true
  systemctl --user disable "$unit" 2>/dev/null || true
  [[ -f $UNIT_DIR/$unit ]] && { backup "$UNIT_DIR/$unit"; rm -f -- "$UNIT_DIR/$unit"; }
done
for file in "${FILES[@]}"; do backup "$file"; rm -f -- "$file"; done
# Legacy cleanup.
for name in "${OLD_BINARIES[@]}"; do [[ -f $BIN/$name ]] && { backup "$BIN/$name"; rm -f -- "$BIN/$name"; }; done
for hook in battery-low theme-set post-update; do
  [[ -f $CONFIG_ROOT/omarchy/hooks/$hook.d/$OLD_HOOK_NAME ]] && { backup "$CONFIG_ROOT/omarchy/hooks/$hook.d/$OLD_HOOK_NAME"; rm -f -- "$CONFIG_ROOT/omarchy/hooks/$hook.d/$OLD_HOOK_NAME"; }
done
[[ -d $CONFIG_ROOT/omarchy/plugins/$OLD_PLUGIN_ID ]] && { backup "$CONFIG_ROOT/omarchy/plugins/$OLD_PLUGIN_ID"; rm -rf -- "$CONFIG_ROOT/omarchy/plugins/$OLD_PLUGIN_ID"; }
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
