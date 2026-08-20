#!/usr/bin/env bash
# dns component verify driver — runs each sub-verify (auth, dnsdist, collector);
# exit 1 if any fails. Sub-checks live in verify.d/.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
overall=0
for sub in auth dnsdist collector; do
    bash "${SELF_DIR}/verify.d/${sub}.sh" || overall=1
done
exit "$overall"
