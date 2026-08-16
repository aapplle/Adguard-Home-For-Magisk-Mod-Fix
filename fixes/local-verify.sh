#!/bin/bash
# Local reproduction of the CI "Verify scripts" step.
# NOTE: the module scripts run under mksh on device (arrays / process
# substitution are legal there). Locally we use bash -n as the closest
# practical check; CI installs real mksh for a faithful syntax pass.
set -u
cd "$(dirname "$0")/.."
FAIL=0
while IFS= read -r f; do
  bash -n "$f" || { echo "SYNTAX-FAIL: $f"; FAIL=1; }
done < <(find Adguardhome -name '*.sh' | sort)
echo "--- marker greps ---"
grep -q '\[minfix v'                 Adguardhome/service.sh              || { echo 'FAIL m1'; FAIL=1; }
grep -q 'agh_running()'              Adguardhome/scripts/iptables.sh     || { echo 'FAIL m2'; FAIL=1; }
grep -q 'port_listening()'           Adguardhome/scripts/iptables.sh     || { echo 'FAIL m3'; FAIL=1; }
grep -q 'Adguard-Home-For-Magisk-Mod-Fix' Adguardhome/module.prop        || { echo 'FAIL m4'; FAIL=1; }
grep -Eq '^version=.+-minfix[0-9]+$' Adguardhome/module.prop             || { echo 'FAIL m5'; FAIL=1; }
[ "$FAIL" = 0 ] && echo ALL-VERIFY-OK || echo VERIFY-FAILED
exit $FAIL
