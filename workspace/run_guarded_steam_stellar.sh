#!/bin/bash
# Outer sandbox starts before Wine/server creation. Inner bash sets DYLD after
# sandbox-exec (a platform binary) has applied its normal environment handling.
set -euo pipefail
research_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
test -f "$research_dir/stellar-original-write-guard.sb"
export STELLAR_ORIGINAL_WRITE_GUARD=1
exec /usr/bin/sandbox-exec -f "$research_dir/stellar-original-write-guard.sb" \
    /bin/bash "$research_dir/run_stock10_stellar_trial.sh" "$@"
