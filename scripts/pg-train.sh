#!/bin/bash
# PGO training run for PostgreSQL: drive the INSTRUMENTED /opt/pg18-pgogen under TPROC-C so it
# writes the .gcda that -fprofile-use will consume. Runs on the CLIENT.
#
# Adapted from my-train.sh (the MySQL equivalent). Everything below that differs from it does so
# because of a real PostgreSQL difference, noted inline.
#
# WHY THE PROFILE DATA IS WIPED FIRST. The pgogen *build* already left .gcda in the tree: every
# build-time tool PG compiles and then runs is instrumented too (genbki.pl's C helpers, the
# ecpg/zic/gen_keywordlist tooling, and the initdb+psql smoke test the build script itself runs)
# and each dumps counters at exit. Those tools link the same src/port and src/common objects the
# backend does, at the same object paths, so their .gcda are the SAME FILES the backend will
# merge into -- build-tool execution counts would be added to the workload's. The training
# profile must describe TPROC-C, not the build, so the counters are deleted and only the server
# run fills them. TUs that exist solely for build tools then have no profile at all, which is
# exactly right and is what -Wno-missing-profile and -fprofile-partial-training handle.
#
# PG-SPECIFIC: the counters live IN THE SOURCE TREE, not in a separate -fprofile-generate=<dir>.
# The prior campaign's pg-build.sh uses bare -fprofile-generate so that -fprofile-use (also
# bare) finds each .gcda beside its own object file. So this script cleans $PGOTREE, and the
# tree must never be `make clean`ed afterwards -- enable_coverage=yes hooks clean-coverage
# (rm -f *.gcda) into make clean and would silently discard the whole training run.
#
# WHY VU = CORE COUNT, NOT THE OPTIMISED BINARY'S PEAK. The binary being profiled is
# INSTRUMENTED and therefore several times slower. Per-arm profile siting is a measured effect
# on this workload, not a detail: in the MySQL campaign a saturated profile put 45% of its
# samples in ut_delay and cost BOLT half its headroom (-2.5%). Holding VU at the optimised
# binary's peak against a binary that is several times slower would queue far past saturation
# and train the optimiser on spin loops -- for PG that means s_lock/LWLockAcquire backoff paths,
# which this patched tree has specifically reworked. VU == core count keeps the instrumented
# server near its OWN peak instead.
#
# THE COUNTERS ARE ONLY WRITTEN BY GCOV'S AT-EXIT HANDLER, so every backend must exit cleanly.
#   * pg_ctl -m fast   : backends disconnect and run their exit handlers -> counters land.
#   * pg_ctl -m immediate : SIGQUIT, no exit handlers -> THE ENTIRE TRAINING RUN IS LOST.
# PG differs from MySQL here in a way that matters: it is MULTI-PROCESS, so there are hundreds
# of separate .gcda writers rather than one, and every one of them must come down cleanly.
set -uo pipefail
DIR=/home/ubuntu/pg-lattice
source "$DIR/pg-env.sh"

PREFIX=/opt/pg18-pgogen
PGOTREE=/home/ec2-user/pgsrc-pgo

# Separate TRAIN_* names on purpose: pg-env.sh defines RAMPUP/DURATION for the matrix sweeps, so
# a plain ${RAMPUP:-3} here would silently inherit those instead of this script's own values.
VU=${TRAIN_VU:-$TRAIN_VU_DEFAULT}
RAMPUP=${TRAIN_RAMPUP:-3}
DURATION=${TRAIN_DURATION:-10}
TIMEOUT=$(( (RAMPUP + DURATION + 6) * 60 ))

STAMP=$(date -u +%Y%m%d-%H%M%S)
mkdir -p "$RESULTS"
LOG=$RESULTS/pg-train-$STAMP.log
OUTF=$RESULTS/pg-train-$STAMP.txt
exec > >(tee -a "$LOG") 2>&1

echo "=== pg-train $(date -u +%FT%TZ)"
echo "    instrumented prefix : $PREFIX"
echo "    profile lives in    : $PGOTREE (in-tree .gcda, bare -fprofile-generate)"
echo "    cell                : $TRAIN_VCPU vCPU cpus=$TRAIN_CPUS membind=$TRAIN_MEMNODE"
echo "    load                : $VU VU, rampup ${RAMPUP}m, duration ${DURATION}m"
echo "    dataset             : $WAREHOUSES WH"

ssh_srv "test -x $PREFIX/bin/postgres" || { echo "!!! no instrumented postgres at $PREFIX"; exit 1; }
ssh_srv "$PREFIX/bin/postgres --version"

# Gate the instrumentation BEFORE spending 13 minutes of load on it. A pgogen prefix that is
# somehow not instrumented would run fast, look fine, and write nothing.
NSYM=$(ssh_srv "nm $PREFIX/bin/postgres 2>/dev/null | grep -c '__gcov\|gcov_'" | tr -d '\r ')
echo "    gcov symbols        : $NSYM"
[ "${NSYM:-0}" -gt 100 ] || { echo "!!! $PREFIX/bin/postgres is NOT instrumented -- rebuild pgogen"; exit 1; }

# The FULL dataset, restored fresh -- not a reduced training set. $WAREHOUSES WH is what sizes the
# working set against shared_buffers; fewer warehouses would concentrate updates on fewer districts
# and profile a contention pattern the measurement never runs. Restored fresh because a training
# run mutates it, and the next arm must start from the same state.
echo "--- stopping any server of ours, restoring the $WAREHOUSES WH golden dataset"
ssh_srv "cd $SRV_DIR && bash pg-srv.sh stop" 2>&1 | tail -2
ssh_srv "cd $SRV_DIR && bash pg-dataset.sh restore" 2>&1 | tail -3
ssh_srv "test -d $PGDATA && du -sh $PGDATA" \
  || { echo "!!! no datadir at $PGDATA -- on the server: pg-dataset.sh mount && pg-dataset.sh restore"
       echo "!!! (if there is no golden copy either, the schema must be rebuilt: pg-schema.sh)"; exit 1; }

echo "--- emptying in-tree .gcda (see header: build-tool counters are not training data)"
ssh_srv "find $PGOTREE -name '*.gcda' -delete 2>/dev/null; \
         echo -n '    gcda now: '; find $PGOTREE -name '*.gcda' | wc -l; \
         echo -n '    gcno present (must be >0, they are the instrumentation notes): '; \
         find $PGOTREE -name '*.gcno' | wc -l"

# The tree is owned by ec2-user but the backends may run as a different user; if they cannot
# write their .gcda they fail silently at exit with "profiling: ... Cannot open" and the whole
# run produces nothing.
echo "--- making the tree writable by the server process"
ssh_srv "chmod -R a+rwX $PGOTREE/src 2>/dev/null; echo '    ok'"

echo "--- starting instrumented postgres (expect a SLOW startup: instrumented)"
ssh_srv "cd $SRV_DIR && CPUS=$TRAIN_CPUS MEMNODE=$TRAIN_MEMNODE bash pg-srv.sh start $PREFIX" 2>&1 | tail -6 \
  || { echo "!!! START FAILED"; exit 1; }

TCL=/tmp/pg-train-$STAMP.tcl
sed -e "s/@RAMPUP@/$RAMPUP/" -e "s/@DURATION@/$DURATION/" -e "s/@TIMEOUT@/$TIMEOUT/" \
    -e "s/@VULIST@/$VU/" -e "s/@PGHOST@/$SRV_HOST/" "$DIR/pg-run-sweep.tcl.in" > "$TCL"

# The 64-VU siting is the one real ASSUMPTION in this script, so make it CHECKABLE rather than
# asserted. A /proc/stat sampler runs on the server through the whole training window; the busy%
# is reported for the MEASURED window only (rampup excluded, since rampup is not what trains the
# profile). The cell is 64 of 192 vCPU, so whole-box busy ~= 33% means the cell is pinned -- i.e.
# the profile is saturated and dominated by spin/backoff paths. If it comes back at ~33%, redo the
# run at a lower VU BEFORE building any PGO arm from it.
SAMPLE=/tmp/pg-train-stat-$STAMP
ssh_srv "nohup bash -c 'for i in \$(seq 1 $(( (RAMPUP+DURATION+8) * 6 ))); do \
           awk \"/^cpu /{print systime(), \\\$2+\\\$3+\\\$4+\\\$6+\\\$7+\\\$8, \\\$2+\\\$3+\\\$4+\\\$5+\\\$6+\\\$7+\\\$8}\" /proc/stat; \
           sleep 10; done' > $SAMPLE 2>/dev/null &" >/dev/null 2>&1
T_LOAD_START=$(date -u +%s)

echo "--- training load starting $(date -u +%FT%TZ)  (expect it to be SLOW: instrumented)"
( cd "$HAMMERDB" && ./hammerdbcli auto "$TCL" 2>&1 ) \
  | awk '{print strftime("%Y-%m-%dT%H:%M:%SZ"), $0; fflush()}' > "$OUTF"
grep -a 'System achieved' "$OUTF" | tr -d '\r' | sed 's/^/    /'

# Steady state only: skip rampup, and stop one sample short of the end to exclude vudestroy.
echo "--- saturation check (whole-box busy%, MEASURED window only, rampup excluded)"
WSTART=$(( T_LOAD_START + RAMPUP * 60 ))
WEND=$(( T_LOAD_START + (RAMPUP + DURATION) * 60 ))
ssh_srv "awk -v s=$WSTART -v e=$WEND '
  \$1>=s && \$1<=e { if (pt) { db=\$2-pb; dt=\$3-pt; if (dt>0) { sum+=100*db/dt; n++ } } pb=\$2; pt=\$3; next }
  { pb=\$2; pt=\$3 }
  END { if (n) printf \"    whole-box busy: %.1f%% over %d samples\\n\", sum/n, n;
        else print \"    (no samples in the measured window -- sampler died or clocks skewed)\" }' $SAMPLE" 2>/dev/null
echo "    reference: the cell is $TRAIN_VCPU of 192 vCPU, so ~33% == cell fully pinned == SATURATED."
echo "               If it reads ~33%, redo this run at a lower TRAIN_VU before building any PGO arm."

echo "--- clean shutdown -- THIS is when the counters are written (-m fast, never -m immediate)"
ssh_srv "cd $SRV_DIR && bash pg-srv.sh stop" 2>&1 | tail -3

echo "--- profile gates"
ssh_srv "echo -n '    .gcda files : '; find $PGOTREE -name '*.gcda' | wc -l; \
         echo -n '    profile size: '; du -sh --exclude='*.o' $PGOTREE 2>/dev/null | cut -f1; \
         echo    '    largest counter files:'; \
         find $PGOTREE -name '*.gcda' -printf '%s %p\n' | sort -rn | head -5 | sed 's|/home/ec2-user/pgsrc-pgo/|      |'"

N=$(ssh_srv "find $PGOTREE -name '*.gcda' | wc -l" | tr -d '\r ')
# A real backend profile covers most of src/backend. Counters ONLY in src/port and src/common
# would mean the backends never dumped and we are looking at build-tool leftovers again.
NB=$(ssh_srv "find $PGOTREE/src/backend -name '*.gcda' 2>/dev/null | wc -l" | tr -d '\r ')
echo "    .gcda under src/backend: $NB   (total: $N)"
echo "=== pg-train done $(date -u +%FT%TZ)  gcda=$N backend=$NB"
[ "${N:-0}" -gt 100 ] || { echo "!!! only ${N:-0} .gcda -- the training data did NOT land, do not build pgouse"; exit 1; }
[ "${NB:-0}" -gt 50 ]  || { echo "!!! only ${NB:-0} .gcda under src/backend -- the BACKENDS did not dump counters."
                            echo "    Most likely: shutdown was not clean, or the tree is not writable by the server user."; exit 1; }
echo "next, ON THE SERVER:  bash pg-build.sh pgouse && bash pg-build.sh pgolto && bash pg-build.sh pgoltoq"
