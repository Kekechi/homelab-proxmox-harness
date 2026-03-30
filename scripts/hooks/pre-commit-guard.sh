#!/usr/bin/env bash
# pre-commit-guard.sh — PreToolUse hook for Bash tool
# Blocks git commit if sensitive files are staged (belt-and-suspenders on .gitignore).
# Only fires when the Bash command contains "git commit".
# Input: JSON object on stdin with tool_input.command

set -euo pipefail

INPUT=$(cat)

cmd=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")

# Only check git commit commands
case "$cmd" in
    *"git commit"*) ;;
    *) exit 0 ;;
esac

# Check staged files against blocklist
staged=$(git diff --cached --name-only 2>/dev/null || echo "")
[[ -z "$staged" ]] && exit 0

blocked=""
while IFS= read -r file; do
    case "$file" in
        .envrc|.envrc.new)
            blocked="${blocked}\n  - ${file} (secrets: API tokens, MinIO keys)"
            ;;
        config/*.yml)
            # Allow .yml.example files
            case "$file" in
                *.yml.example) ;;
                *) blocked="${blocked}\n  - ${file} (environment config with IPs/CIDRs)" ;;
            esac
            ;;
        *.tfstate|*.tfstate.*)
            blocked="${blocked}\n  - ${file} (Terraform state — contains resource metadata)"
            ;;
        *.tfvars)
            # Allow .tfvars.example files
            case "$file" in
                *.tfvars.example) ;;
                *) blocked="${blocked}\n  - ${file} (Terraform variables — may contain IPs/secrets)" ;;
            esac
            ;;
        *.tfplan)
            blocked="${blocked}\n  - ${file} (Terraform plan file — binary, environment-specific)"
            ;;
        ansible/inventory/hosts.yml)
            blocked="${blocked}\n  - ${file} (generated inventory — contains host IPs)"
            ;;
        .env.mk)
            blocked="${blocked}\n  - ${file} (generated Makefile fragment)"
            ;;
    esac
done <<< "$staged"

if [[ -n "$blocked" ]]; then
    echo "BLOCKED: Sensitive or generated files are staged for commit."
    echo -e "Files that must be unstaged:${blocked}"
    echo ""
    echo "To unstage: git reset HEAD <file>"
    echo "These files are normally gitignored. If you used 'git add -f', remove the -f flag."
    exit 2
fi

exit 0
