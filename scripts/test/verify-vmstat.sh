#!/bin/bash
# verify-vmstat.sh — cross-check the app's memory reading against vm_stat
# (free + speculative parity). Live memory drifts between sequential samples,
# so take 5 bracketed pairs and gate on the smallest gap; report every pair.
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN=.build/debug/RamGuard
[ -x "$BIN" ] || { echo "FAIL: $BIN not built (run: swift build)"; exit 1; }

pages() { echo "$1" | awk '/^Pages free/ {gsub(/\./,"");print $3}'; }
spec() { echo "$1" | awk '/speculative/ {gsub(/\./,"");print $3}'; }

# Prints "app_mib vm_mib" for one bracketed pair.
pair() {
  local before after app_out app_mib pgs spec_pages vm_mib
  before=$(vm_stat)
  app_out=$("$BIN" once)
  after=$(vm_stat)
  app_mib=$(echo "$app_out" | sed -nE 's/available=([0-9.]+) MiB.*/\1/p')
  [ -n "$app_mib" ] || { echo "FAIL: could not parse app output: $app_out"; exit 1; }
  pgs=$(( ( $(pages "$before") + $(pages "$after") ) / 2 ))
  spec_pages=$(( ( $(spec "$before") + $(spec "$after") ) / 2 ))
  vm_mib=$(python3 -c "print((($pgs + $spec_pages) * 16384) / 1048576)")
  echo "$app_mib $vm_mib"
}

BEST_DELTA=999
for i in 1 2 3 4 5; do
  read -r APP_MIB VM_MIB <<< "$(pair)"
  DELTA=$(python3 -c "print(abs($APP_MIB - $VM_MIB) / $VM_MIB)")
  echo "pair $i: app=$APP_MIB MiB  vm_stat=$VM_MIB MiB  delta=$(python3 -c "print(f'{$DELTA:.4f}')")"
  BEST_DELTA=$(python3 -c "print(min($BEST_DELTA, $DELTA))")
done

python3 -c "
delta = float('$BEST_DELTA')
if delta <= 0.05:
    print(f'PASS: parity within 5% (best pair delta={delta:.4f})')
else:
    print(f'FAIL: parity off by {delta:.2%} even at best pair')
    raise SystemExit(1)
"
