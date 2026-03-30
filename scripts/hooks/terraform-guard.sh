#!/usr/bin/env bash
# terraform-guard.sh — PreToolUse hook for Bash tool
# Blocks bare 'terraform apply' and production applies from the dev container.
# Input: JSON object on stdin with tool_input.command

set -euo pipefail

cmd=$(python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")

if [[ "$cmd" == *"terraform apply"* ]] && [[ "$cmd" != *".tfplan"* ]]; then
    echo "BLOCKED: bare 'terraform apply' detected."
    echo "Required workflow: terraform plan -out=<file> && terraform apply <file>"
    exit 2
fi

if [[ "$cmd" == *"terraform apply production.tfplan"* ]]; then
    echo "BLOCKED: production apply is not permitted from the dev container."
    echo "Hand production.tfplan to the operator for manual apply."
    exit 2
fi

exit 0
