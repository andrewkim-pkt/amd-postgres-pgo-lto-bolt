#!/bin/bash
# PGO training for PostgreSQL on the AMD r8a.metal-48xl. CLIENT side.
# Drives the INSTRUMENTED /opt/g15-pg18-pgogen under TPROC-C so it writes .gcda into
# /home/ec2-user/g15/pgsrc-pgo, which pgo/pgolto/pgoltoq then reuse in place.
#
# TWO THINGS THAT SILENTLY RUIN THE PROFILE IF GOT WRONG:
#  1. The build's OWN tool runs (genbki, fmgr, ecpg...) leave .gcda in the tree. Those describe
#     the build, not TPROC-C, so they are deleted before the run.
#  2. Stop must be `pg_ctl -m fast`. -m immediate sends SIGQUIT, skips the exit handlers, and
#     gcov never dumps -- the entire training run is lost with no error anywhere.
set -uo pipefail
source /home/ec2-user/g15pg/pg-env.sh
LOG=$RESULTS/pg-train-$(date -u +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1

ARM=pgogen
PGOTREE=/home/ec2-user/g15/pgsrc-pgo
VU=${TRAIN_VU:-64}
RU=${TRAIN_RAMPUP:-3}
DU=${TRAIN_DURATION:-10}
TOUT=$(( (RU + DU + 6) * 60 ))

echo "=== PG PGO training $(date -u +%FT%TZ)"
echo "    instrumented : /opt/g15-pg18-$ARM"
echo "    gcda tree    : $PGOTREE"
echo "    cell         : 64 cores on node 1, cpus=$SRV_CPUS --preferred=$SRV_MEMNODE"
echo "    load         : $VU VU, rampup ${RU}m, duration ${DU}m, $WAREHOUSES WH"

echo "--- wiping .gcda left by the build's own tool runs"
ssh_srv "find $PGOTREE -name '*.gcda' -delete 2>/dev/null; echo \"  gcda before training: \$(find $PGOTREE -name '*.gcda' | wc -l)\""

echo "--- restoring the $WAREHOUSES WH golden and starting the instrumented server PINNED"
ssh_srv "bash $SRV_DIR/pg-srv-amd.sh stop" 2>&1 | tail -1
ssh_srv "bash $SRV_DIR/pg-srv-amd.sh restore-il" 2>&1 | grep -E 'real|restoring' | tr '\n' ' '; echo
ssh_srv "bash $SRV_DIR/pg-srv-amd.sh start $ARM $SRV_CPUS" 2>&1 | tail -5

TCL=$WORK/pg-train-$VU.tcl
sed -e "s/@HOST@/$SRV_HOST/" -e "s/@RAMPUP@/$RU/" -e "s/@DURATION@/$DU/" \
    -e "s/@TIMEOUT@/$TOUT/" -e "s/@VU@/$VU/" \
    /home/ec2-user/g15pg/pg-point.tcl.in > "$TCL"
[ -s "$TCL" ] || { echo "!!! empty $TCL -- template substitution failed"; exit 1; }

echo "--- training load start $(date -u +%T)  (instrumented: expect a few x slower than base)"
time ( cd "$HAMMERDB" && ./hammerdbcli auto "$TCL" < /dev/null ) 2>&1 \
  | grep -aiE "TEST RESULT|System achieved|Rampup complete|VU TEST|Error" | tail -8

if grep -aqE "achieved 0 NOPM|FINISHED FAILED" "$LOG" 2>/dev/null; then echo "!!! ZERO-NOPM or FAILED vusers -- training profiled error paths, NOT TPROC-C; aborting"; ssh_srv "bash $SRV_DIR/pg-srv-amd.sh stop" >/dev/null 2>&1; exit 9; fi
echo "--- stopping with pg_ctl -m fast so gcov dumps the counters"
ssh_srv "bash $SRV_DIR/pg-srv-amd.sh stop" 2>&1 | tail -1

echo "--- profile produced"
ssh_srv "echo \"  gcda files: \$(find $PGOTREE -name '*.gcda' | wc -l)\"; echo \"  gcda size : \$(du -sh --exclude=.git $PGOTREE 2>/dev/null | cut -f1) tree total\"; find $PGOTREE -name '*.gcda' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END {printf \"  gcda bytes: %.1f MB\n\", s/1048576}'"
echo "=== PG-TRAIN-DONE $(date -u +%FT%TZ)"
