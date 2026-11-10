#!/bin/bash
# Record an LBR profile from the pinned postgres. RUNS ON THE SERVER (<DUT_PRIVATE_IP>).
#
#   pg-record.sh afdo <out.data> [secs]     -> feeds create_gcov  (AutoFDO arms AF/AFL/AFLB)
#   pg-record.sh bolt <out.data> [secs]     -> feeds perf2bolt    (BOLT arms B/PB/LB/AFLB)
#
# The recipes are the prior campaign's (al-metal-hwpgo-c/collect-profile-c.sh), kept verbatim in
# spirit so this campaign's BOLT/AutoFDO numbers stay comparable to its published +6.44% / +3.52%.
#
# WHY THE TWO MODES DIFFER. AutoFDO wants a CYCLES-driven sample with a branch stack, because
# create_gcov turns LBR entries into edge counts and needs the sample weighted by where time
# actually goes. BOLT wants BRANCH-driven sampling (`-e branches:u -b`): perf2bolt only cares about
# taken-branch pairs, and sampling branches directly gets far more usable pairs per byte of
# perf.data. Feeding one tool the other's profile "works" and silently produces a bad layout.
#
# WHY -C AND NOT -p. The cell is exclusive to this campaign's postgres, so recording the CPU set
# catches every backend -- including the ones forked AFTER the record starts, which -p would miss
# entirely. TPROC-C at 64 VU forks continuously, so -p would sample a shrinking subset.
#
# WHY THE PRIME PERIODS (400009 / 100003). A round period like 400000 aliases against loop trip
# counts and PostgreSQL's own batch sizes, biasing which instruction gets the sample. Primes are
# Intel's standard advice for exactly this.
#
# NMI WATCHDOG. It permanently occupies one of the four general-purpose PMU counters. Turning it
# off for the record window is what the prior campaign did; leaving it on costs a counter and can
# make the LBR record come back with far fewer usable samples.
set -uo pipefail
MODE=${1:?usage: pg-record.sh afdo|bolt <out.data> [secs]}
OUT=${2:?usage: pg-record.sh afdo|bolt <out.data> [secs]}
SECS=${3:-180}
CPUS=${CPUS:-32-63,128-159}
PGDATA=${PGDATA:-/mnt/pgramdisk/pg18data}

log() { echo "[$(date -u +%T)] $*"; }

# A profile of an idle server is the single most expensive failure here: it costs a full load run
# and the resulting .afdo/.fdata looks valid to every downstream tool. So prove the postmaster is
# up on OUR datadir before spending SECS seconds recording.
PID=$(pgrep -f "postgres -D $PGDATA" | head -1)
[ -n "$PID" ] || { log "FAIL: no postgres running on $PGDATA -- start it before recording"; exit 1; }
log "mode=$MODE pid=$PID cpus=$CPUS secs=$SECS -> $OUT"

WD=$(cat /proc/sys/kernel/nmi_watchdog)
[ "$WD" = 0 ] || { echo 0 | sudo tee /proc/sys/kernel/nmi_watchdog > /dev/null; log "nmi_watchdog 1 -> 0 for the record window"; }

case "$MODE" in
afdo)
  # cycles + branch stack. -j any,u: user-space taken branches of every kind, which is what
  # create_gcov's edge inference expects.
  sudo perf record -e cycles:u -j any,u -c 400009 \
       -C "$CPUS" -m 128M --proc-map-timeout 5000 -o "$OUT" -- sleep "$SECS"
  ;;
bolt)
  # -b keeps the full branch stack; -z1 compresses (a 180 s branch record on 64 vCPU is tens of GB
  # uncompressed); --aio=4 keeps the writer off the profiled CPUs.
  sudo perf record -b -z1 --aio=4 -c 100003 -e branches:u \
       -C "$CPUS" -m 128M --proc-map-timeout 5000 -o "$OUT" -- sleep "$SECS"
  ;;
*) log "FAIL: mode must be afdo|bolt"; exit 2 ;;
esac
RC=$?
[ "$WD" = 0 ] || echo "$WD" | sudo tee /proc/sys/kernel/nmi_watchdog > /dev/null
sudo chown "$(id -u):$(id -g)" "$OUT" 2>/dev/null

# ---- gates -------------------------------------------------------------------------------------
# All four of these have to hold or the profile is not usable, and NONE of them is visible to
# create_gcov/perf2bolt -- both accept a useless profile and emit a plausible-looking output.
#
# NO sudo AND --force HERE, both load-bearing (learned 2026-09-17 on the afdo/prep record).
# perf refuses any perf.data that is "not owned by current user or root": the chown above hands the
# file to ec2-user, so re-reading it as ROOT is exactly the case perf rejects. Under sudo all three
# gates printed nothing and the script reported "no LBR data / profile useless" for a profile that
# was in fact perfect (24.5M samples, 0 lost, 92% postgres). --force covers the reverse order too,
# if the chown ever fails and the file stays root-owned. Never put sudo back on these three lines.
log "gates"
echo -n "    samples/lost      : "
perf report -i "$OUT" --force --stats 2>/dev/null | grep -E "SAMPLE events|LOST" | tr '\n' ' ' | sed 's/  */ /g'; echo
echo -n "    brstack present   : "
N=$(perf script -i "$OUT" --force -F brstack 2>/dev/null | head -200 | grep -c '/' || true)
[ "${N:-0}" -gt 0 ] && echo "OK ($N of first 200 samples carry a branch stack)" \
                    || echo "FAIL (no LBR data -- -j/-b did not take effect)"
echo -n "    postgres share    : "
perf report -i "$OUT" --force --sort dso --stdio 2>/dev/null | grep -m1 -i postgres \
  || echo "NONE -- THE PROFILE IS USELESS (recorded an idle or wrongly-pinned cell)"
ls -l "$OUT" | sed 's/^/    /'
exit $RC
