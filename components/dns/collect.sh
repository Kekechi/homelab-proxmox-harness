#!/usr/bin/env bash
# dns component collect driver — dumps raw state from each sub-collector.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for sub in auth dnsdist; do
    bash "${SELF_DIR}/collect.d/${sub}.sh"
done
