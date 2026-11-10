#!/bin/bash
# PostgreSQL WHOLE-BOX ladder driver (CLIENT) for the AMD r8a.metal-48xl.
# 8 mirrored passes: base afdoltob pgolto pgoltob | pgoltob pgolto afdoltob base.
# Per pass = ONE server lifetime: stop -> restore-il (numactl --interleave=all, tmpfs pages
# spread over BOTH nodes) -> start UNPINNED on all 192 cores -> VU 32..1024 ascending, one
# hammerdbcli per rung, then drain between rungs.
# Deliberately emits the SAME artifact layout as the MySQL leg ($tag-$vu.txt, $tag.cpu,
# $tag.clicpu, $tag.numa-*) so the 2-node report-wb.sh works on it unchanged.
# RESUMABLE: a pass with $B/<tag>.done is skipped.
#   setsid nohup bash ~/g15pg/pg-bench-wb.sh > ~/g15pg/wb/bench.out 2>&1 < /dev/null &
set -uo pipefail
source /home/ec2-user/g15pg/pg-env.sh
G=/home/ec2-user/g15pg; B=$G/wb; mkdir -p $B
ARMS=${ARMS:-"base afdoltob pgolto pgoltob pgoltob pgolto afdoltob base"}
VUS=${VUS:-"32 64 128 256 512 1024"}; DU=$DURATION

# Same adaptive rampup rule as the MySQL leg: HammerDB logs vusers in at ~2/s, so a fixed 2 min
# left 256+ VU still connecting while measuring. ceil((VU/rate + settle)/60), floored at RAMPUP.
CONNECT_RATE=${CONNECT_RATE:-2.0}; SETTLE=${SETTLE:-60}
rampup_for() { awk -v v="$1" -v r="$CONNECT_RATE" -v s="$SETTLE" -v m="$RAMPUP" 'BEGIN{ n=int((v/r+s+59)/60); print (n<m?m:n) }'; }

PSQL_B=/opt/g15-pg18-base/bin/psql
ulimit -n 65536 2>/dev/null
echo "client ulimit -n = $(ulimit -n)  rampup(adaptive)=$(for v in $VUS; do echo -n "$v:$(rampup_for $v) "; done)duration=${DU}m"
exec 9>$B/.lock; flock -n 9 || { echo "another pg-bench-wb is running"; exit 1; }

drain() { local i n; for i in $(seq 1 60); do
    n=$(ssh_srv "$PSQL_B -h /tmp -U $PGUSER_ -d postgres -Atc \"select count(*) from pg_stat_activity where backend_type='client backend'\" 2>/dev/null" | tr -d '\r')
    [ -z "$n" ] && return 0; [ "$n" -le 5 ] && return 0; sleep 5; done; echo "  !!! still $n conns"; }

i=0
for arm in $ARMS; do
  i=$((i+1)); tag=$(printf %02d $i)-$arm
  [ -f $B/$tag.done ] && continue
  until ssh_srv true 2>/dev/null; do echo "[$(date -u +%T)] server unreachable, waiting"; sleep 120; done
  echo "=== $tag /opt/g15-pg18-$arm $(date -u +%FT%TZ)"
  ssh_srv "bash $SRV_DIR/pg-srv-amd.sh stop" >/dev/null 2>&1
  ssh_srv "bash $SRV_DIR/pg-srv-amd.sh restore-il" 2>&1 | grep -E 'real|FAIL|restoring' | tr '\n' ' '; echo
  ssh_srv "numastat -m" > $B/$tag.numa-restore
  ssh_srv "bash $SRV_DIR/pg-srv-amd.sh start $arm" 2>&1 | tail -5 > $B/$tag.start
  cat $B/$tag.start
  grep -q 'md5=' $B/$tag.start || { echo "!!! START FAILED $tag"; sleep 60; continue; }

  ssh_srv "/opt/g15-pg18-$arm/bin/psql -h /tmp -U $PGUSER_ -d postgres -Atc \"select current_setting('shared_buffers'),current_setting('huge_pages'),current_setting('max_wal_size'),current_setting('max_connections'),current_setting('synchronous_commit'),current_setting('jit')\" 2>/dev/null" \
    | sed 's/^/  shared_buffers,huge_pages,max_wal,maxconn,sync_commit,jit: /' | tee $B/$tag.vars
  ssh_srv "pid=\$(pgrep -f 'bin/postgres -D $PGDATA_REMOTE' | head -1); md5sum /opt/g15-pg18-$arm/bin/postgres; grep -E 'Cpus_allowed_list' /proc/\$pid/status" > $B/$tag.ident
  cat $B/$tag.ident | sed 's/^/  /'

  ssh_srv "pkill -f 'cpusample-al[l]' ; true"
  ssh_srv "mkdir -p /home/ec2-user/hwpgo/wb; setsid nohup bash /home/ec2-user/hwpgo/cpusample-all.sh /home/ec2-user/hwpgo/wb/$tag.cpu >/dev/null 2>&1 < /dev/null &"
  pkill -f 'cpusample-loo[p]' ; setsid nohup bash /home/ec2-user/g15m/cpusample-loop.sh $B/$tag.clicpu >/dev/null 2>&1 < /dev/null &

  ok=1
  for vu in $VUS; do
    RU=$(rampup_for $vu); TOUT=$(( (RU + DU + 3) * 60 ))
    TCL=/tmp/g15pg-wb-$tag-$vu.tcl
    sed -e "s/@HOST@/$SRV_HOST/" -e "s/@RAMPUP@/$RU/" -e "s/@DURATION@/$DU/" \
        -e "s/@TIMEOUT@/$TOUT/" -e "s/@VU@/$vu/" $G/pg-point.tcl.in > $TCL
    ( cd $HAMMERDB && timeout $((TOUT + 300)) ./hammerdbcli auto $TCL 2>&1 < /dev/null ) \
      | awk '{print strftime("%Y-%m-%dT%H:%M:%SZ", systime(), 1), $0; fflush()}' > $B/$tag-$vu.txt
    r=$(grep -a 'System achieved' $B/$tag-$vu.txt | tr -d '\r' | sed 's/.*System achieved/System achieved/')
    e=$(grep -acE 'Error|FINISHED FAILED|error connecting|does not exist' $B/$tag-$vu.txt)
    nl=$(grep -ac "Processing 10000000" $B/$tag-$vu.txt)
    echo "  $tag $vu VU rampup=${RU}m logged_in=$nl: ${r:-NO RESULT}  (error lines: $e)"
    [ -n "$r" ] || ok=0
    # a rung that transacted nothing is not a result, it is a broken run
    case "$r" in *"achieved 0 NOPM"*) echo "  !!! $tag $vu VU achieved 0 NOPM"; ok=0 ;; esac
    drain
  done

  ssh_srv "numastat -m" > $B/$tag.numa-end
  ssh_srv "numastat -p \$(pgrep -f 'bin/postgres -D $PGDATA_REMOTE' | head -1)" > $B/$tag.numa-proc
  ssh_srv "pkill -f 'cpusample-al[l]' ; true"; pkill -f 'cpusample-loo[p]'
  scp -q -i "$SRV_KEY" -o StrictHostKeyChecking=no "$SRV_USER@$SRV_HOST:/home/ec2-user/hwpgo/wb/$tag.cpu" "$B/$tag.cpu" 2>/dev/null
  ssh_srv "bash $SRV_DIR/pg-srv-amd.sh stop" 2>&1 | tail -1
  [ $ok = 1 ] && touch $B/$tag.done || echo "!!! $tag incomplete, will retry"
done
echo "PG-WB-ALL-DONE $(date -u +%FT%TZ)"
