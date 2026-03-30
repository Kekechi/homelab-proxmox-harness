#!/usr/bin/env bash
# terraform-guard.sh — PreToolUse hook for Bash tool
# Enforces the terraform safety rules from sandbox-isolation.md as hard blocks.
# Input: JSON object on stdin with tool_input.command

set -euo pipefail

cmd=$(python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")

# --- terraform apply ---

if [[ "$cmd" == *"terraform apply"* ]] && [[ "$cmd" != *".tfplan"* ]]; then
    echo "BLOCKED: bare 'terraform apply' detected."
    echo "Required workflow: terraform plan -out=<file>.tfplan && terraform apply <file>.tfplan"
    exit 2
fi

if [[ "$cmd" == *"terraform apply production.tfplan"* ]]; then
    echo "BLOCKED: production apply is not permitted from the dev container."
    echo "Hand production.tfplan to the operator for manual apply."
    exit 2
fi

# --- terraform destroy ---

if [[ "$cmd" == *"terraform destroy"* ]]; then
    echo "BLOCKED: terraform destroy is not permitted from the dev container."
    echo "To remove sandbox resources, use a targeted destroy plan:"
    echo "  terraform plan -destroy -var-file=sandbox.tfvars -out=destroy.tfplan"
    echo "  terraform apply destroy.tfplan"
    echo "For production resources, coordinate with the operator."
    exit 2
fi

# --- state manipulation ---

if [[ "$cmd" == *"terraform state rm"* ]]; then
    echo "BLOCKED: terraform state rm requires explicit operator approval."
    echo "State manipulation can cause resource orphaning and is prohibited from the dev container."
    exit 2
fi

if [[ "$cmd" == *"terraform state mv"* ]]; then
    echo "BLOCKED: terraform state mv requires explicit operator approval."
    exit 2
fi

if [[ "$cmd" == *"terraform force-unlock"* ]]; then
    echo "BLOCKED: terraform force-unlock requires explicit operator approval."
    echo "If a lock is stuck, verify no concurrent apply is running before unlocking."
    exit 2
fi

if [[ "$cmd" == *"terraform import"* ]]; then
    echo "BLOCKED: terraform import requires explicit operator instruction."
    echo "Importing resources can cause state drift if not carefully validated."
    exit 2
fi

exit 0
