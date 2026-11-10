#!/bin/bash
# Drive a TPROC-C load against ONE binary and take an LBR profile of it mid-run. Runs on the CLIENT.
#
#   pg-profile.sh afdo /opt/pg18-prep                 -> work/perf-afdo-prep-<ts>.data
#   pg-profile.sh bolt /opt/pg18-pgoltoq              -> work/perf-bolt-pgoltoq-<ts>.data
#   REC_SECS=300 pg-profile.sh bolt /opt/pg18-pgoq    longer record
#
# This is the load-driving half of both profile-guided stages; pg-record.sh (on the server) is the
# perf half, and pg-afdo.sh / pg-bolt.sh consume what this produces. One orchestrator for both
# means the profiled load is IDENTICAL for AutoFDO and BOLT, which matters: if BOLT saw a different
# warehouse mix or VU count than AutoFDO, a layout difference between arms AFL and LB could not be
# attributed to the tools.
#
# THE PROFILE MUST COME FROM THE BINARY BEING OPTIMISED. perf2bolt maps samples onto the input
# binary by address, so a profile of `prep` cannot be used to BOLT `pgoltoq` -- LTO moved every
# function. Hence one run per BOLT arm rather than one shared recording. AutoFDO is different: it
# maps back to SOURCE LINES via .debug_line, so a single `prep` recording legitimately feeds all
# three AutoFDO builds.
#
# WHY THE SAME PRE-RUN SEQUENCE AS pg-sweep.sh. A profile taken against a mutated dataset trains
# the arm for a dataset that no measured run will ever see, so the golden restore and the pinned
# start are not optional here either. The huge-page gate is kept for the same reason it exists in
# pg-sweep.sh: an arm profiled on 4 KB pages has different hot paths (page-walk stalls) than the
# arm that gets measured on 1 GB pages.
set -uo pipefail
cd "$(dirname "$0")"
. ./pg-env.sh

MODE=${1:?usage: pg-profile.sh afdo|bolt <prefix>}
PREFIX=${2:?usage: pg-profile.sh afdo|bolt <prefix>}
NAME=$(basename "$PREFIX" | sed 's/^pg18-//')
TS=$(date -u +%Y%m%dT%H%M%SZ)
VU=${PROF_VU:-$TRAIN_VU_DEFAULT}
PROF_RAMPUP=${PROF_RAMPUP:-$RAMPUP}
PROF_DURATION=${PROF_DURATION:-6}
REC_SECS=${REC_SECS:-180}
SETTLE=${SETTLE:-30}
PDATA_SRV=/home/ec2-user/perf-$MODE-$NAME-$TS.data
PDATA=$WORK/perf-$MODE-$NAME-$TS.data
LOG=$RESULTS/profile-$MODE-$NAME-$TS.log
HDBLOG=$RESULTS/profile-$MODE-$NAME-$TS.hammerdb.log
mkdir -p "$RESULTS" "$WORK"
exec > >(tee -a "$LOG") 2>&1

say() { echo "=== [$(date -u +%T)] $*"; }
die() { echo "!!! $*" >&2; exit 1; }

case "$MODE" in afdo|bolt) ;; *) die "mode must be afdo|bolt" ;; esac

# The record window has to sit INSIDE the measured window: rampup, then a settle, then the record,
# and the load must still be running when the record ends. Check the arithmetic here rather than
# discovering at minute 8 that perf recorded HammerDB's vudestroy.
REC_START=$(( PROF_RAMPUP * 60 + SETTLE ))
LOAD_END=$(( (PROF_RAMPUP + PROF_DURATION) * 60 ))
[ $(( REC_START + REC_SECS )) -lt "$LOAD_END" ] \
  || die "record window ${REC_START}s..$(( REC_START + REC_SECS ))s does not fit inside a ${LOAD_END}s load
!!! raise PROF_DURATION (now $PROF_DURATION min) or lower REC_SECS (now $REC_SECS s)"

say "profile $MODE  binary=$PREFIX  cell=$TRAIN_CPUS  ${WAREHOUSES} WH  ${VU} VU"
say "timeline: rampup ${PROF_RAMPUP}m, settle ${SETTLE}s, record ${REC_SECS}s at t+${REC_START}s, load ends t+${LOAD_END}s"

# --- pre-flight -----------------------------------------------------------------------------------
ssh_srv "test -x $PREFIX/bin/postgres" || die "no postgres at $PREFIX on $SRV_HOST"
ssh_srv "test -x $SRV_DIR/pg-record.sh || test -f $SRV_DIR/pg-record.sh" \
  || die "pg-record.sh is not on the server -- scp it to $SRV_DIR first"
[ -x "$HAMMERDB/hammerdbcli" ] || die "no hammerdbcli at $HAMMERDB"

# BOTH tools need the line table: create_gcov maps LBR samples to source lines through .debug_line,
# and perf2bolt needs the relocations that -Wl,-q retained. Only the *q / prep builds carry them, so
# a profile run against a stripped arm is wasted time -- name that now.
HASDBG=$(ssh_srv "readelf -SW $PREFIX/bin/postgres | grep -cw '\.debug_line'" | tr -d '\r ')
[ "${HASDBG:-0}" -gt 0 ] || die "$PREFIX/bin/postgres has NO .debug_line -- profile it and both
!!! create_gcov and perf2bolt will produce empty output. Use a -g / -Wl,-q build (prep, *q)."
if [ "$MODE" = bolt ]; then
  HASREL=$(ssh_srv "readelf -SW $PREFIX/bin/postgres | grep -cw '\.rela\.text'" | tr -d '\r ')
  [ "${HASREL:-0}" -gt 0 ] || die "$PREFIX/bin/postgres has no .rela.text -- it was linked without
!!! -Wl,-q and llvm-bolt will refuse it. Use the arm's *q twin."
fi

HTLB=$(ssh_srv "awk '/^Hugetlb:/{print \$2}' /proc/meminfo" | tr -d '\r ')
[ "${HTLB:-0}" -gt 0 ] || die "no huge pages reserved on $SRV_HOST -- run pg-hugepages.sh reserve"
say "huge page pool: $((HTLB/1048576)) GiB reserved"

# --- identical starting state (same sequence as pg-sweep.sh) --------------------------------------
say "restoring $PGDATA from the golden copy"
ssh_srv "cd $SRV_DIR && bash pg-srv.sh stop" 2>&1 | sed 's/^/    /'
ssh_srv "cd $SRV_DIR && bash pg-dataset.sh restore" 2>&1 | sed 's/^/    /' || die "restore failed"

say "starting $NAME pinned to the cell"
ssh_srv "cd $SRV_DIR && CPUS=$TRAIN_CPUS MEMNODE=$TRAIN_MEMNODE bash pg-srv.sh start $PREFIX" 2>&1 | sed 's/^/    /' \
  || die "server did not start"

HPS=$(PGPASSWORD=$PG_SUPERPASS psql -h "$SRV_HOST" -p "$SRV_PORT" -U "$PG_SUPER" -d postgres -tAc \
        "select current_setting('huge_pages_status')" 2>/dev/null | tr -d '\r')
say "huge_pages_status: $HPS"
case "$HPS" in
  on*) ;;
  *) ssh_srv "cd $SRV_DIR && bash pg-srv.sh stop" >/dev/null 2>&1
     die "huge_pages_status is '$HPS', expected 'on' -- profiling on 4 KB pages would train the
!!! arm for page-walk stalls that the measured runs do not have." ;;
esac

# --- the load -------------------------------------------------------------------------------------
TIMEOUT=$(( (PROF_RAMPUP + PROF_DURATION) * 60 + 600 ))
TCL=$WORK/pg-profile-$MODE-$NAME-$TS.tcl
sed -e "s|@PGHOST@|$SRV_HOST|g" -e "s|@RAMPUP@|$PROF_RAMPUP|g" -e "s|@DURATION@|$PROF_DURATION|g" \
    -e "s|@TIMEOUT@|$TIMEOUT|g" -e "s|@VULIST@|$VU|g" \
    pg-run-sweep.tcl.in > "$TCL"
grep -q '@[A-Z]*@' "$TCL" && die "unsubstituted placeholder in $TCL"

say "load starting in the background -> $HDBLOG"
( cd "$HAMMERDB" && ./hammerdbcli auto "$TCL" 2>&1 ) \
  | awk '{print strftime("%Y-%m-%dT%H:%M:%SZ"), $0; fflush()}' > "$HDBLOG" &
HDB=$!
T0=$(date +%s)

# If HammerDB dies early (bad credentials, schema missing) the sleep below would still expire and
# perf would dutifully record an idle cell. Poll instead of sleeping blind.
say "waiting ${REC_START}s for rampup + settle"
while [ $(( $(date +%s) - T0 )) -lt "$REC_START" ]; do
  kill -0 "$HDB" 2>/dev/null || { wait "$HDB"; die "HammerDB exited during rampup -- see $HDBLOG"; }
  sleep 5
done
grep -aqE "Timer: |VU TEST" "$HDBLOG" || die "no HammerDB progress in $HDBLOG after ${REC_START}s"

say "recording ${REC_SECS}s on the server"
ssh_srv "cd $SRV_DIR && CPUS=$TRAIN_CPUS PGDATA=$PGDATA bash pg-record.sh $MODE $PDATA_SRV $REC_SECS" 2>&1 | sed 's/^/    /' \
  || die "pg-record.sh failed"

say "record done at t+$(( $(date +%s) - T0 ))s; letting the load finish"
wait "$HDB"
grep -a 'System achieved' "$HDBLOG" | tr -d '\r' | sed 's/^/    /'

say "stopping"
ssh_srv "cd $SRV_DIR && bash pg-srv.sh stop" 2>&1 | sed 's/^/    /'

# --- collect --------------------------------------------------------------------------------------
# The binary comes back with the profile. create_gcov and perf2bolt both run on the CLIENT (AL2023
# has neither), and both need the EXACT binary that was sampled -- not a rebuilt one. Copying it
# next to the perf.data makes the pair self-contained and re-processable later.
say "pulling perf.data and the sampled binary to the client"
scp_from "$PDATA_SRV" "$PDATA" || die "could not fetch $PDATA_SRV"
scp_from "$PREFIX/bin/postgres" "$WORK/postgres-$NAME-$TS" || die "could not fetch the binary"
ssh_srv "rm -f $PDATA_SRV"
ls -l "$PDATA" "$WORK/postgres-$NAME-$TS" | sed 's/^/    /'

say "DONE  profile=$PDATA  binary=$WORK/postgres-$NAME-$TS"
echo "$PDATA" > "$WORK/.last-profile-$MODE-$NAME"
