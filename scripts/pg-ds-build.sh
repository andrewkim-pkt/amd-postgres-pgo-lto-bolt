#!/bin/bash
# Build the 1536 WH TPROC-C dataset for PostgreSQL and save it as a golden copy. CLIENT side.
# Equivalent of the MySQL leg's ds-build.sh; written for this campaign because the published
# postgres-pgo-lto-bolt repo ships no HammerDB dataset builder.
set -uo pipefail
source /home/ec2-user/g15pg/pg-env.sh
LOG=$RESULTS/pg-dsbuild-$(date -u +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
ARM=base

echo "=== PG $WAREHOUSES WH dataset build $(date -u +%FT%TZ)"
ssh_srv "bash $SRV_DIR/pg-srv-amd.sh hugepages"            2>&1 | tail -2
ssh_srv "bash $SRV_DIR/pg-srv-amd.sh stop"                 2>&1 | tail -1
ssh_srv "bash $SRV_DIR/pg-srv-amd.sh init  $ARM"           2>&1 | tail -2
# whole box for the load: the build is throughput work, not the pinned training cell
ssh_srv "bash $SRV_DIR/pg-srv-amd.sh start $ARM"           2>&1 | tail -4

TCL=$WORK/pg-schema-$WAREHOUSES.tcl
sed -e "s/@HOST@/$SRV_HOST/" -e "s/@WH@/$WAREHOUSES/" -e "s/@BUILDVU@/$BUILD_VU/" \
    /home/ec2-user/g15pg/pg-schema.tcl.in > "$TCL"

echo "--- schema build start $(date -u +%T)"
time ( cd "$HAMMERDB" && ./hammerdbcli auto "$TCL" < /dev/null ) 2>&1 \
  | grep -viE "^Vuser[0-9]+:(Loading|Elapsed|\.\.\.)" | tail -12

echo "--- row counts $(date -u +%T)"
ssh_srv "/opt/g15-pg18-$ARM/bin/psql -h /tmp -U $PGUSER_ -d $PGDB -Atc \
  \"select (select count(*) from warehouse) w, (select count(*) from district) d, \
           (select count(*) from customer) c, (select count(*) from order_line) ol\"" 2>&1 | tail -2

echo "--- size $(date -u +%T)"
ssh_srv "/opt/g15-pg18-$ARM/bin/psql -h /tmp -U $PGUSER_ -d $PGDB -Atc \
  \"select pg_size_pretty(pg_database_size('$PGDB'))\"" 2>&1 | tail -1
ssh_srv "du -sh $PGDATA_REMOTE" 2>&1 | tail -1

ssh_srv "bash $SRV_DIR/pg-srv-amd.sh stop"   2>&1 | tail -1
echo "--- saving golden $(date -u +%T)"
ssh_srv "bash $SRV_DIR/pg-srv-amd.sh golden" 2>&1 | grep -E 'real|golden|G$|G\s' | tail -6
echo "=== PG-DSBUILD-DONE $(date -u +%FT%TZ)"
