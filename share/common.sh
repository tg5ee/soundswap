# shellcheck shell=bash disable=SC2034
# Shared data parsing for the CLI, player and watchers. Never source user config.
conf="${XDG_CONFIG_HOME:-$HOME/.config}/soundswap"
cfg="$conf/config"
share="${BASH_SOURCE[0]%/*}"
defaults=$share/config.default
[[ -f $defaults ]] || defaults=$share/../config.default
declare -a EVENTS=()
declare -A LABEL HINT GROUP ICON KNOWN
while IFS=$'\t' read -r id label hint group icon; do
  [[ -z $id || $id == \#* ]] && continue
  EVENTS+=("$id"); LABEL[$id]=$label; HINT[$id]=$hint; GROUP[$id]=$group; ICON[$id]=$icon
  key=${id^^}; KNOWN[${key//-/_}]=1
done < "$share/events.tsv"

valid_event() {
  [[ ${1:-} =~ ^[a-z][a-z0-9-]*$ && -n ${LABEL[$1]+x} ]] && return 0
  printf 'Unknown sound event: %s\n' "${1:-<missing>}" >&2
  return 1
}

read_config() {
  local key value line event
  ENABLED=1 VOLUME=0.6 LOG=0 CRITICAL_BATTERY_LEVEL=5
  for event in "${EVENTS[@]}"; do
    key=${event^^}; key=${key//-/_}; printf -v "$key" '%s' 1
    printf -v "${key}_VOLUME" '%s' 1
  done
  [[ -f $cfg && -r $cfg ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*([^#[:space:]]+)[[:space:]]*(#.*)?$ ]] || continue
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    case $key in
      VOLUME|*_VOLUME)
        [[ $key == VOLUME || -n ${KNOWN[${key%_VOLUME}]+x} ]] || continue
        [[ $value == .* ]] && value=0$value
        [[ $value =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || continue ;;
      CRITICAL_BATTERY_LEVEL)
        [[ $value =~ ^([0-9]|[1-9][0-9]|100)$ ]] || continue ;;
      ENABLED|LOG) [[ $value == 0 || $value == 1 ]] || continue ;;
      *) [[ -n ${KNOWN[$key]+x} && ( $value == 0 || $value == 1 ) ]] || continue ;;
    esac
    printf -v "$key" '%s' "$value"
  done < "$cfg"
}

sound_file() {
  local ext
  file=
  for ext in wav ogg oga flac mp3; do
    [[ -f $conf/sounds/$1.$ext && -r $conf/sounds/$1.$ext ]] || continue
    file=$conf/sounds/$1.$ext; break
  done
}

runtime_dir() {
  local base=${XDG_RUNTIME_DIR:-/tmp/soundswap-$UID}
  if [[ -z ${XDG_RUNTIME_DIR:-} ]]; then
    (umask 077; mkdir -p -- "$base") || return 1
    [[ -O $base && ! -L $base ]] || return 1
    chmod 700 -- "$base" || return 1
  fi
  [[ -d $base && -O $base && ! -L $base ]] || return 1
  state=$base/soundswap
  [[ ! -L $state ]] || return 1
  (umask 077; mkdir -p -- "$state") || return 1
  [[ -O $state ]] || return 1
  chmod 700 -- "$state"
}

json_str() {
  local s=$1 char escaped i
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  if [[ $s == *[$'\001'-$'\037']* ]]; then
    for ((i=1; i<32; i++)); do
      printf -v char '\\x%02x' "$i"
      printf -v char '%b' "$char"
      printf -v escaped '\\u%04x' "$i"
      s=${s//"$char"/"$escaped"}
    done
  fi
  printf '"%s"' "$s"
}

# Keep a stable lock inode: the config itself is atomically replaced.
setvar() (
  local key=$1 value=$2 tmp input=$cfg
  umask 077
  mkdir -p -- "$conf" || return 1
  exec 9>"$conf/config.lock" || return 1
  flock -w 5 9 || return 1
  [[ ! -e $cfg || ( -f $cfg && -w $cfg ) ]] || { echo 'Settings file is not writable' >&2; return 1; }
  if [[ $value == toggle ]]; then
    read_config
    value=1; [[ $ENABLED == 1 ]] && value=0
  fi
  if [[ -f $cfg ]]; then
    mkdir -p -- "$conf/backups" || return 1
    cp -p -- "$cfg" "$conf/backups/config.$EPOCHREALTIME" || return 1
  fi
  tmp=$(mktemp "$conf/.config.XXXXXX") || return 1
  trap 'rm -f -- "$tmp"' EXIT
  [[ -f $input ]] || input=$defaults
  awk -v key="$key" -v value="$value" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {if (!found++) print key "=" value; next}
    {print}
    END {if (!found) print key "=" value}
  ' "$input" > "$tmp" || return 1
  mv -- "$tmp" "$cfg"
)
