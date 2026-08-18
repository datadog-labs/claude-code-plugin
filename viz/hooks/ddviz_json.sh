# Build a JSON object from KEY VALUE pairs. jq/plutil encode safely.
#   0: ok           1: no JSON engine
json_build_object() {
  if command -v jq &>/dev/null; then
    # `--arg` per pair (not one `--args`) keeps a leading `-` in a value from
    # being mis-lexed as an option.
    local -a args=()
    while (( $# )); do args+=(--arg "$1" "$2"); shift 2; done
    jq -nc "${args[@]}" '$ARGS.named'
  elif command -v plutil &>/dev/null; then
    local doc='<plist version="1.0"><dict/></plist>'
    while (( $# )); do
      doc=$(printf '%s' "$doc" | plutil -insert "$1" -string "$2" -o - - 2>/dev/null) || return 1
      shift 2
    done
    printf '%s' "$doc" | plutil -convert json -o - - 2>/dev/null
  else
    return 1
  fi
}

# Set KEY to a raw JSON VALUE on a JSON object.
#   0: ok           1: no JSON engine           2: malformed JSON
json_set() {
  local object="$1" key="$2" value="$3"
  if command -v jq &>/dev/null; then
    jq -c --arg k "$key" --argjson v "$value" '.[$k] = $v' <<< "$object" 2>/dev/null || return 2
  elif command -v plutil &>/dev/null; then
    # -replace, not -insert: -insert fails outright when the key already exists.
    printf '%s' "$object" | plutil -replace "$key" -json "$value" -o - - 2>/dev/null || return 2
  else
    return 1
  fi
}

# Like json_set, but VALUE may be large (a recovered spill file, up to
# forward.sh's size cap) rather than a small string. On jq, it's passed via a
# temp file with --slurpfile instead of --argjson, so it never has to fit
# inside this process's argv/ARG_MAX budget — unlike json_set's two other call
# sites (both small, fixed-shape values), this one carries arbitrary-sized
# recovered JSON. plutil has no file-based equivalent for -json, so that
# branch is unchanged and keeps the same argv-size exposure as before.
#   0: ok           1: no JSON engine           2: malformed JSON
json_set_large() {
  local object="$1" key="$2" value="$3"
  if command -v jq &>/dev/null; then
    local tmp status
    # mktemp, not a PID-based name: it creates the file atomically with a
    # random suffix and mode 0600, so another local account sharing $TMPDIR
    # can't guess the path to plant a symlink there or read the recovered
    # payload before it's removed below.
    tmp=$(mktemp "${TMPDIR:-/tmp}/ddviz-json_set_large.XXXXXX") || return 2
    printf '%s' "$value" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 2; }
    jq -c --arg k "$key" --slurpfile v "$tmp" '.[$k] = $v[0]' <<< "$object" 2>/dev/null
    status=$?
    rm -f "$tmp"
    [[ $status -eq 0 ]] || return 2
  elif command -v plutil &>/dev/null; then
    printf '%s' "$object" | plutil -replace "$key" -json "$value" -o - - 2>/dev/null || return 2
  else
    return 1
  fi
}
