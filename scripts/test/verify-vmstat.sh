#!/bin/bash
# verify-vmstat.sh — cross-check the app's memory reading against vm_stat
# (free + speculative parity, ±5% tolerance). M1 gate per the plan.
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN=.build/debug/RamGuard
[ -x "$BIN" ] || { echo "FAIL: $BIN not built (run: swift build)"; exit 1; }

# Live memory drifts between samples; bracket the app reading with two
# vm_stat samples and use the closer one.
VM_BEFORE=$(vm_stat)
APP_OUT=$("$BIN" once)
VM_AFTER=$(vm_stat)
APP_MIB=$(echo "$APP_OUT" | sed -nE 's/available=([0-9.]+) MiB.*/\1/p')
[ -n "$APP_MIB" ] || { echo "FAIL: could not parse app output: $APP_OUT"; exit 1; }

pages() { echo "$1" | awk '/^Pages free/ {gsub(/\./,"");print $3}'; }
spec() { echo "$1" | awk '/speculative/ {gsub(/\./,"");print $3}'; }
VM_PAGES=$(( ( $(pages "$VM_BEFORE") + $(pages "$VM_AFTER") ) / 2 ))
SPEC_PAGES=$(( ( $(spec "$VM_BEFORE") + $(spec "$VM_AFTER") ) / 2 ))
PAGE_SIZE=$(vm_stat | awk '/page size of/ {print $8}' | tr -d 'bytes.')
[ -n "$PAGE_SIZE" ] || PAGE_SIZE=$(pagesize 2>/dev/null || echo 16384)
VM_MIB=$(python3 -c "print(($VM_PAGES + $SPEC_PAGES) * $PAGE_SIZE / 1048576)")

echo "app=$APP_MIB MiB  vm_stat=$VM_MIB MiB (pages free=$VM_PAGES spec=$SPEC_PAGES page=$PAGE_SIZE)"

python3 - "$APP_MIB" "$VM_MIB" <<'EOF'
import sys
app, vm = float(sys.argv[1]), float(sys.argv[2])
if vm <= 0:
    print("FAIL: vm_stat reading non-positive"); sys.exit(1)
delta = abs(app - vm) / vm
if delta <= 0.05:
    print(f"PASS: parity within 5% (delta={delta:.4f})")
else:
    print(f"FAIL: parity off by {delta:.2%}"); sys.exit(1)
EOF
