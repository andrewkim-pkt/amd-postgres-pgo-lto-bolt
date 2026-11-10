#!/bin/bash
# BOLT stage for the PG AMD leg. Runs ON THE SERVER (llvm-bolt 18.1.3 lives there).
#   pg-bolt-amd.sh pgoltoq  pgoltob
#   pg-bolt-amd.sh afdoltoq afdoltob
# Takes the arm's own perf recording, converts with perf2bolt, rewrites with llvm-bolt, and
# installs into a COPY of the input's prefix so the libraries come from the same compile.
set -uo pipefail
export PATH=/opt/llvm-bolt-18.1.3/bin:$PATH

IN_ARM=${1:?input arm}
OUT_ARM=${2:?output arm}
SRCPFX=/opt/g15-pg18-$IN_ARM
OUTPFX=/opt/g15-pg18-$OUT_ARM
PDATA=/home/ec2-user/g15/prof/perf-bolt-$IN_ARM.data
W=/home/ec2-user/g15/bolt-$OUT_ARM
FDATA=$W/$OUT_ARM.fdata

echo "=== BOLT $IN_ARM -> $OUT_ARM $(date -u +%FT%TZ)"
[ -x "$SRCPFX/bin/postgres" ] || { echo "!!! no input at $SRCPFX"; exit 1; }
[ -s "$PDATA" ] || { echo "!!! no perf data at $PDATA"; exit 1; }

rm -rf "$W"; mkdir -p "$W"; cd "$W"
# perf2bolt insists the input ELF be named exactly "postgres"
cp "$SRCPFX/bin/postgres" ./postgres
sync
SSZ=$(stat -c%s "$SRCPFX/bin/postgres"); DSZ=$(stat -c%s ./postgres 2>/dev/null || echo 0)
[ "$SSZ" = "$DSZ" ] || { echo "!!! copy incomplete: $DSZ of $SSZ bytes"; exit 1; }
echo "    input copied: $DSZ bytes (matches source)"

echo "--- input gates"
# NB: capture readelf's output instead of piping into `grep -q`. `grep -q` exits on the first
# match, readelf then takes SIGPIPE and returns 141, and with `set -o pipefail` the pipeline
# reports failure even though the section WAS found. That raced and produced a bogus
# "no .rela.text" on a binary that has it.
SEC=$(readelf -S ./postgres 2>/dev/null || true)
case "$SEC" in
  *rela.text*) ;;
  *) echo "!!! no .rela.text -- llvm-bolt will reject this (was -Wl,-q dropped?)"; exit 1 ;;
esac
case "$SEC" in
  *bolt_info*) echo "!!! input already carries .note.bolt_info -- refusing to BOLT a BOLTed binary"; exit 1 ;;
esac
echo "    .rela.text present, not already BOLTed"

echo "--- perf2bolt"
time perf2bolt -p "$PDATA" -o "$FDATA" ./postgres 2>&1 | tail -10
FSZ=$(stat -c%s "$FDATA" 2>/dev/null || echo 0)
echo "    fdata: $FSZ bytes"
[ "$FSZ" -gt 512000 ] || { echo "!!! fdata under 500 KB -- the ELF/profile match FAILED"; exit 1; }
NFUNC=$(grep -c . "$FDATA" 2>/dev/null || echo 0)
echo "    fdata lines: $NFUNC"

echo "--- llvm-bolt"
time llvm-bolt ./postgres -o ./postgres.bolt -data="$FDATA" \
  -reorder-blocks=ext-tsp -reorder-functions=cdsort \
  -split-functions -split-all-cold -split-eh \
  -dyno-stats --update-debug-sections > bolt.log 2>&1
rc=$?
[ $rc -eq 0 ] || { echo "!!! llvm-bolt FAILED rc=$rc"; tail -30 bolt.log; exit 1; }
grep -aE 'functions in the binary|taken branches' bolt.log | head -4 | sed 's/^/    /'

echo "--- output gates"
OSEC=$(readelf -S ./postgres.bolt 2>/dev/null || true)
case "$OSEC" in
  *bolt_info*) ;;
  *) echo "!!! output has no .note.bolt_info -- rewrite did not happen"; exit 1 ;;
esac
echo "    .note.bolt_info present"

echo "--- install into a copy of $SRCPFX"
sudo rm -rf "$OUTPFX"
sudo cp -a "$SRCPFX" "$OUTPFX"
sudo cp ./postgres.bolt "$OUTPFX/bin/postgres"
sudo chmod 755 "$OUTPFX/bin/postgres"
echo "    $OUT_ARM md5=$(md5sum $OUTPFX/bin/postgres | cut -c1-12)"
"$OUTPFX/bin/postgres" --version
echo "=== PG-BOLT-DONE $OUT_ARM $(date -u +%FT%TZ)"
