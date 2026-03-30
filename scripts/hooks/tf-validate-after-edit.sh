#!/usr/bin/env bash
# tf-validate-after-edit.sh — PostToolUse hook for Write|Edit tools
# Runs terraform fmt -check and terraform validate after any .tf file is modified.
# Non-blocking (always exits 0) — output is injected so Claude sees errors immediately.
# Input: JSON object on stdin with tool_input.file_path

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

file_path=$(python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null || echo "")

# Only act on .tf files under terraform/
case "$file_path" in
    */terraform/*.tf|*/terraform/**/*.tf) ;;
    *) exit 0 ;;
esac

# Skip if terraform directory doesn't exist or terraform isn't available
[[ -d "$TF_DIR" ]] || exit 0
command -v terraform &>/dev/null || exit 0

echo "--- terraform fmt check ---"
if ! terraform -chdir="$TF_DIR" fmt -check -diff 2>&1; then
    echo ""
    echo "Fix: run 'terraform -chdir=terraform fmt' or 'make fmt'"
fi

echo ""
echo "--- terraform validate ---"
# validate requires init; skip gracefully if not initialized
if [[ -d "${TF_DIR}/.terraform" ]]; then
    terraform -chdir="$TF_DIR" validate 2>&1 || true
else
    echo "(skipped — terraform init has not been run yet)"
fi

exit 0
