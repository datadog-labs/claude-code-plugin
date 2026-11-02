# Hosts whose CLAUDE_CODE_ENTRYPOINT may show the ddviz panel. Shared by
# forward.sh (bails on anything else) and the /ddviz status skill (warns),
# so the two never drift.
readonly DDVIZ_ALLOWED_ENTRYPOINTS='cli|claude-vscode'

# Returns 0 if $CLAUDE_CODE_ENTRYPOINT is an allowlisted interactive host.
ddviz_entrypoint_allowed() {
  [[ "${CLAUDE_CODE_ENTRYPOINT:-}" == cli || "${CLAUDE_CODE_ENTRYPOINT:-}" == claude-vscode ]]
}
