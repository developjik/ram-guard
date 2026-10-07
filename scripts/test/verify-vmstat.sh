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
VM_VALUES=""
APP_BEST=""
for i in 1 2 3 4 5; do
  read -r APP_MIB VM_MIB <<< "$(pair)"
  DELTA=$(python3 -c "print(abs($APP_MIB - $VM_MIB) / $VM_MIB)")
  echo "pair $i: app=$APP_MIB MiB  vm_stat=$VM_MIB MiB  delta=$(python3 -c "print(f'{$DELTA:.4f}')")"
  VM_VALUES="$VM_VALUES $VM_MIB"
  if python3 -c "raise SystemExit(0 if $DELTA < $BEST_DELTA else 1)"; then
    BEST_DELTA=$DELTA
    APP_BEST=$APP_MIB
  fi
done

# PASS when the best pair is within 5% (calm host), OR when the app reading
# falls inside the window the system itself traversed during sampling ±5%
# (churning host: absolute 5% between sequential samples is unphysical).
python3 - $APP_BEST $BEST_DELTA $VM_VALUES <<'PYEOF'
import sys
app, best_delta, vms = float(sys.argv[1]), float(sys.argv[2]), [float(v) for v in sys.argv[3:]]
lo, hi = min(vms), max(vms)
spread_pct = (hi - lo) / lo * 100
if best_delta <= 0.05:
    print(f"PASS: parity within 5% (best pair delta={best_delta:.4f})")
elif lo * 0.95 <= app <= hi * 1.05:
    print(f"PASS under churn: app={app:.1f} MiB inside system-sampled window [{lo:.1f}, {hi:.1f}] MiB "
          f"(spread {spread_pct:.1f}%, best pair delta={best_delta:.4f})")
else:
    print(f"FAIL: app={app:.1f} MiB outside sampled window [{lo:.1f}, {hi:.1f}] MiB, best delta={best_delta:.2%}")
    raise SystemExit(1)
PYEOF
