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
    printf '%s' "$object" | plutil -insert "$key" -json "$value" -o - - 2>/dev/null || return 2
  else
    return 1
  fi
}
