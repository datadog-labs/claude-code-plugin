#!/usr/bin/env bash
# Hooks: PreToolUse + PostToolUse

INPUT=$(cat)

DDVIZ_SOCKET="$CLAUDE_PLUGIN_DATA/ddviz.sock"

if [[ ! -S "$DDVIZ_SOCKET" ]]; then
    DDVIZ_DATA_DIR="$CLAUDE_PLUGIN_DATA" swift "${CLAUDE_PLUGIN_ROOT}/viz/ddviz.swift" &>/dev/null &
    for _ in $(seq 1 12); do
        [[ -S "$DDVIZ_SOCKET" ]] && break
        sleep 0.5
    done
fi

if [[ -S "$DDVIZ_SOCKET" && ! -L "$DDVIZ_SOCKET" ]]; then
    nc -w 1 -U "$DDVIZ_SOCKET" <<< "$INPUT" &>/dev/null &
fi
