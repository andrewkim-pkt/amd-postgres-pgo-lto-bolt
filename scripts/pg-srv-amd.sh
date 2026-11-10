#!/bin/bash
# PostgreSQL server lifecycle + dataset handling for the AMD r8a.metal-48xl HammerDB leg.
# Written for this campaign because the published postgres-pgo-lto-bolt repo ships its sysbench
# harness but not its HammerDB one (no pg-srv/pg-dataset/pg-schema/pg-sweep for the ladder).
# Modelled on that repo's sysbench pg-srv.sh plus the MySQL leg's um-dataset2.sh.
#
#   pg-srv-amd.sh hugepages              reserve 201 x 1 GiB (idempotent)
#   pg-srv-amd.sh init   <arm>           initdb a fresh PGDATA on tmpfs with this arm's binaries
#   pg-srv-amd.sh start  <arm> [cpus]    start; with cpus -> numactl --physcpubind=<cpus> --preferred=1
#   pg-srv-amd.sh stop                   pg_ctl -m fast  (NEVER -m immediate: PGO counters are
#                                        written by exit handlers, immediate loses the whole run)
#   pg-srv-amd.sh golden                 PGDATA -> RAM golden + EBS snapshot
#   pg-srv-amd.sh restore-il             golden -> PGDATA, numactl --interleave=all (ladder)
#   pg-srv-amd.sh status
set -uo pipefail

TMPFS=/mnt/ramdisk
PGDATA=$TMPFS/pgdata
GOLDEN=$TMPFS/pggolden
SNAP=/home/ec2-user/pg-snapshot-1536
CONF=/home/ec2-user/pgscripts/pg-amd.conf
HP_WANT=201
PGUSER_=ec2-user

pfx() { echo /opt/g15-pg18-${1:?arm}; }

case "${1:?usage: hugepages|init|start|stop|golden|restore-il|status}" in

hugepages)
  cur=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0)
  [ "$cur" -ge "$HP_WANT" ] || sudo sh -c "echo $HP_WANT > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages"
  echo "1GiB hugepages: $(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages) (want $HP_WANT)"
  grep -E '^Hugetlb' /proc/meminfo ;;

init)
  arm=${2:?arm}; P=$(pfx "$arm")
  mountpoint -q $TMPFS || { sudo mkdir -p $TMPFS; sudo mount -t tmpfs -o size=900G tmpfs $TMPFS; sudo chown $PGUSER_: $TMPFS; }
  rm -rf $PGDATA; mkdir -p $PGDATA; chmod 700 $PGDATA
  "$P/bin/initdb" -D $PGDATA -U $PGUSER_ --data-checksums -E UTF8 >/tmp/initdb.log 2>&1 \
    || { tail -20 /tmp/initdb.log; exit 1; }
  cp "$CONF" $PGDATA/postgresql.conf
  echo "host all all 172.31.0.0/16 trust" >> $PGDATA/pg_hba.conf
  echo "[$(date -u +%T)] initdb done with $arm ($(md5sum $P/bin/postgres | cut -c1-12))" ;;

start)
  arm=${2:?arm}; CPUS=${3:-}; P=$(pfx "$arm")
  cp "$CONF" $PGDATA/postgresql.conf
  pin=(); [ -n "$CPUS" ] && pin=(numactl --physcpubind="$CPUS" --preferred=1)
  "${pin[@]}" "$P/bin/pg_ctl" -D $PGDATA -l /tmp/pg-$arm.log -w -t 600 start \
    || { tail -30 /tmp/pg-$arm.log; exit 1; }
  echo "[$(date -u +%T)] started ${CPUS:+pinned $CPUS }$P md5=$(md5sum $P/bin/postgres | cut -c1-12)"
  "$P/bin/psql" -h /tmp -U $PGUSER_ -d postgres -Atc \
    "select current_setting('shared_buffers'),current_setting('huge_pages'),current_setting('max_connections'),version()" 2>&1 | head -1
  pgrep -f "bin/postgres -D $PGDATA" | head -1 | sed 's/^/  postmaster pid /'
  taskset -cp $(pgrep -f "bin/postgres -D $PGDATA" | head -1) 2>/dev/null | sed 's/^/  /' ;;

stop)
  for a in $(ls -d /opt/g15-pg18-* 2>/dev/null); do
    [ -x "$a/bin/pg_ctl" ] || continue
    "$a/bin/pg_ctl" -D $PGDATA -m fast -w -t 600 stop >/dev/null 2>&1 && { echo "[$(date -u +%T)] stopped (fast) via $a"; exit 0; }
  done
  echo "[$(date -u +%T)] no running server" ;;

golden)
  [ -d $GOLDEN ] && { echo "FAIL: $GOLDEN exists; refusing to overwrite a golden"; exit 1; }
  mkdir -p $GOLDEN
  echo "[$(date -u +%T)] PGDATA -> RAM golden (node 0, off the node-1 training cell)"
  time numactl --cpunodebind=0 --membind=0 cp -a $PGDATA/. $GOLDEN/
  mkdir -p $SNAP && time cp -a $PGDATA/. $SNAP/
  du -sh $PGDATA $GOLDEN $SNAP ;;

restore-il)
  SRC=""; [ -d $GOLDEN ] && SRC=$GOLDEN; [ -z "$SRC" ] && [ -d $SNAP ] && SRC=$SNAP
  [ -n "$SRC" ] || { echo "FAIL: no golden at $GOLDEN or $SNAP"; exit 1; }
  rm -rf $PGDATA; mkdir -p $PGDATA; chmod 700 $PGDATA
  echo "[$(date -u +%T)] restoring (interleave=all) from $SRC"
  time numactl --interleave=all cp -a $SRC/. $PGDATA/ ;;

status)
  echo "hugepages: $(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null)"
  df -h $TMPFS 2>/dev/null | tail -1
  du -sh $PGDATA $GOLDEN $SNAP 2>/dev/null
  pgrep -a -f "bin/postgres -D $PGDATA" | head -2 || echo "no postmaster" ;;
esac
