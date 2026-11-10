# PostgreSQL leg client env (AMD r8a.metal-48xl server + r7i.24xlarge client).
# SRV_CPUS is the 64-core node-1 training cell: node 1 is CPU 96-191 with no SMT, so 96-159 is
# 64 real cores. The published Intel cell was 32-63,128-159 (32 cores + SMT siblings on node 1
# of a 3-node box) -- same vCPU count, not the same silicon. Do not compare pinned NOPM across
# the two legs without saying so.
SRV_HOST=172.31.90.77
SRV_USER=ec2-user
SRV_KEY=/home/ec2-user/.ssh/id_g15amd
SRV_DIR=/home/ec2-user/pgscripts
SRV_CPUS=96-159
SRV_MEMNODE=1
PGPORT=5432
PGDATA_REMOTE=/mnt/ramdisk/pgdata

HAMMERDB=/home/ec2-user/HammerDB-4.7
RESULTS=/home/ec2-user/g15pg/results
WORK=/home/ec2-user/g15pg/work
# libpq taken from the server's own 18.3 build, so client and server are the same version by
# construction; hdblib still needed for the MySQL driver's libmysqlclient.
export LD_LIBRARY_PATH=/home/ec2-user/pglib:/home/ec2-user/hdblib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

WAREHOUSES=1536
BUILD_VU=64
RAMPUP=2
DURATION=3
PGUSER_=ec2-user
PGPASS_=postgres
PGDB=tpcc

mkdir -p $RESULTS $WORK
ssh_srv() { ssh -n -i "$SRV_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
                -o ServerAliveInterval=15 -o ServerAliveCountMax=80 \
                "$SRV_USER@$SRV_HOST" "$@"; }
psql_srv() { ssh_srv "/opt/g15-pg18-base/bin/psql -h /tmp -U $PGUSER_ -d ${1:-postgres} -Atc \"$2\""; }
