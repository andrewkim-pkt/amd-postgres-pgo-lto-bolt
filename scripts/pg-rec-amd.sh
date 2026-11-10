#!/bin/bash
# Record an LBR profile from a PINNED PostgreSQL under TPROC-C load. CLIENT side; the perf
# recording itself runs on the server. Serves both profile stages, which differ only in the event:
#
#   pg-rec-amd.sh prep     afdo    -> perf-afdo.data     -> create_gcov -> pg18-g15-hammerdb.afdo
#   pg-rec-amd.sh pgoltoq  bolt    -> perf-bolt-pgoltoq.data -> perf2bolt (later)
#   pg-rec-amd.sh afdoltoq bolt    -> perf-bolt-afdoltoq.data
#
# PG forks a backend per connection, so the capture MUST be per-CPU (-C) not per-process.
# On this EPYC part `-a` (whole-system) LBR is unsupported but `-C <cpulist>` works -- verified.
set -uo pipefail
source /home/ec2-user/g15pg/pg-env.sh

ARM=${1:?arm: prep|pgoltoq|afdoltoq}
MODE=${2:?mode: afdo|bolt}
VU=${PROF_VU:-64}
RU=${PROF_RAMPUP:-3}
DU=${PROF_DURATION:-6}
TOUT=$(( (RU + DU + 6) * 60 ))
STAMP=$(date -u +%Y%m%d-%H%M%S)
LOG=$RESULTS/pg-rec-$ARM-$MODE-$STAMP.log
OUTF=$RESULTS/pg-rec-$ARM-$MODE-$STAMP.txt
exec > >(tee -a "$LOG") 2>&1

case "$MODE" in
  afdo) PD=/home/ec2-user/g15/prof/perf-afdo.data
        EV='-e cycles:u -j any,u -c 400009' ;;
  bolt) PD=/home/ec2-user/g15/prof/perf-bolt-$ARM.data
        EV='-b -z1 --aio=4 -c 100003 -e branches:u' ;;
  *) echo "bad mode"; exit 2 ;;
esac

echo "=== PG profile recording: arm=$ARM mode=$MODE $(date -u +%FT%TZ)"
echo "    cell   : cpus=$SRV_CPUS --preferred=$SRV_MEMNODE (64 cores on node 1)"
echo "    load   : $VU VU, rampup ${RU}m, duration ${DU}m, $WAREHOUSES WH"
echo "    perf   : $EV -C $SRV_CPUS -m 128M --proc-map-timeout 5000, 180 s, starting 30 s after rampup"
echo "    output : $PD"

ssh_srv "bash $SRV_DIR/pg-srv-amd.sh stop" 2>&1 | tail -1
ssh_srv "bash $SRV_DIR/pg-srv-amd.sh restore-il" 2>&1 | grep -E 'real|restoring' | tr '\n' ' '; echo
ssh_srv "bash $SRV_DIR/pg-srv-amd.sh start $ARM $SRV_CPUS" 2>&1 | tail -4

# free a PMU counter, as the published recipe does; restored afterwards
NMI_WAS=$(ssh_srv "cat /proc/sys/kernel/nmi_watchdog" | tr -d '\r ')
ssh_srv "sudo sh -c 'echo 0 > /proc/sys/kernel/nmi_watchdog'" >/dev/null 2>&1
echo "    nmi_watchdog: $NMI_WAS -> $(ssh_srv 'cat /proc/sys/kernel/nmi_watchdog' | tr -d '\r ')"

TCL=$WORK/pg-rec-$ARM-$VU.tcl
sed -e "s/@HOST@/$SRV_HOST/" -e "s/@RAMPUP@/$RU/" -e "s/@DURATION@/$DU/" \
    -e "s/@TIMEOUT@/$TOUT/" -e "s/@VU@/$VU/" /home/ec2-user/g15pg/pg-point.tcl.in > "$TCL"
[ -s "$TCL" ] || { echo "!!! empty $TCL"; exit 1; }

echo "--- load start $(date -u +%T)"
( cd "$HAMMERDB" && ./hammerdbcli auto "$TCL" < /dev/null ) > "$OUTF" 2>&1 &
HDB=$!

# anchor on rampup completion, then wait 30 s as the recipe specifies
for i in $(seq 1 240); do grep -qa 'Rampup complete' "$OUTF" && break; sleep 5; done
grep -qa 'Rampup complete' "$OUTF" || { echo "!!! rampup marker never appeared"; kill $HDB 2>/dev/null; exit 1; }
echo "--- rampup complete $(date -u +%T); +30 s then recording 180 s"
sleep 30
ssh_srv "sudo rm -f $PD; sudo perf record $EV -C $SRV_CPUS -m 128M --proc-map-timeout 5000 -o $PD -- sleep 180 2>&1 | tail -3; sudo chown ec2-user: $PD 2>/dev/null; ls -lh $PD | awk '{print \"    raw: \"\$5}'"

wait $HDB 2>/dev/null
grep -aE "TEST RESULT|System achieved" "$OUTF" | tail -2 | sed "s/^/    /"
if grep -aqE "achieved 0 NOPM|FINISHED FAILED" "$OUTF"; then echo "!!! ZERO-NOPM or FAILED vusers -- the workload did no work, this profile is WORTHLESS"; exit 9; fi
ssh_srv "sudo sh -c 'echo ${NMI_WAS:-1} > /proc/sys/kernel/nmi_watchdog'" >/dev/null 2>&1
ssh_srv "bash $SRV_DIR/pg-srv-amd.sh stop" 2>&1 | tail -1

echo "--- LBR sanity (brstack must be non-empty or the profile is useless)"
ssh_srv "sudo perf script -f -i $PD -F brstack 2>/dev/null | head -2 | wc -l | sed 's/^/    brstack lines: /'"

if [ "$MODE" = afdo ]; then
  echo "--- perf inject --build-ids"
  ssh_srv "cd /home/ec2-user/g15/prof && sudo perf inject -f --build-ids -i perf-afdo.data -o perf-afdo.inj.data 2>&1 | tail -2; sudo chown ec2-user: perf-afdo.inj.data; ls -lh perf-afdo.inj.data | awk '{print \"    injected: \"\$5}'"
  echo "--- create_gcov --gcov_version=2"
  ssh_srv "cd /home/ec2-user/g15/prof && /home/ec2-user/g15m/src/autofdo/build-gcov/create_gcov \
      --binary=/opt/g15-pg18-prep/bin/postgres --profile=perf-afdo.inj.data \
      --gcov=pg18-g15-hammerdb.afdo --gcov_version=2 2>&1 | tail -4; ls -l pg18-g15-hammerdb.afdo | awk '{print \"    afdo: \"\$5\" bytes\"}'"
  echo "--- afdo function count"
  ssh_srv "/home/ec2-user/g15m/src/autofdo/build-gcov/dump_gcov /home/ec2-user/g15/prof/pg18-g15-hammerdb.afdo 2>/dev/null | grep -cE '^[A-Za-z_].*total:[0-9]+ head:' | sed 's/^/    functions: /'"
fi
echo "=== PG-REC-DONE arm=$ARM mode=$MODE $(date -u +%FT%TZ)"
