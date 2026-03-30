#!/usr/bin/env bash
# protected-path-guard.sh — PreToolUse hook for Write|Edit tools
# Blocks modifications to safety-critical files that Claude should never edit.
# Input: JSON object on stdin with tool_input.file_path

set -euo pipefail

file_path=$(python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null || echo "")

[[ -z "$file_path" ]] && exit 0

# Normalize to repo-relative path for matching
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
rel_path="${file_path#"$REPO_ROOT"/}"

# --- Protected paths ---

# .devcontainer/ — Squid config baked into image, changes have no effect until operator rebuilds
case "$rel_path" in
    .devcontainer/*)
        echo "BLOCKED: .devcontainer/ files are baked into the Docker image."
        echo "Changes have no effect until the operator runs 'make build' and reopens the container."
        echo "Exception: 'make configure' may regenerate allowed-cidrs.conf as a downstream output."
        exit 2
        ;;
esac

# Hook scripts — prevent Claude from disabling its own safety gates
case "$rel_path" in
    scripts/hooks/*.sh)
        echo "BLOCKED: Hook scripts enforce safety constraints and must not be modified by Claude."
        echo "To change hook behavior, ask the operator to edit the script directly."
        exit 2
        ;;
esac

# Settings — prevent Claude from disabling hooks or changing permissions
case "$rel_path" in
    .claude/settings.json)
        echo "BLOCKED: .claude/settings.json contains hook configuration and permissions."
        echo "Modifying it could disable safety gates. Ask the operator to make changes."
        exit 2
        ;;
esac

# Core isolation rule — the foundational safety document
case "$rel_path" in
    .claude/rules/sandbox-isolation.md)
        echo "BLOCKED: sandbox-isolation.md defines the core safety boundary."
        echo "Changes to this rule file require operator review."
        exit 2
        ;;
esac

exit 0
