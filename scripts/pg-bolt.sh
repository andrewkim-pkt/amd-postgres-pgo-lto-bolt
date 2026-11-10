#!/bin/bash
# BOLT stage: perf.data + input twin -> llvm-bolt'ed postgres -> a new /opt prefix. Runs on the CLIENT.
#
#   pg-bolt.sh /opt/pg18-prep                -> /opt/pg18-boltonly   arm B
#   pg-bolt.sh /opt/pg18-pgoq                -> /opt/pg18-pgob       arm PB
#   pg-bolt.sh /opt/pg18-pgoltoq             -> /opt/pg18-pgoltob    arm LB
#   pg-bolt.sh /opt/pg18-afdoq               -> /opt/pg18-afdob      arm AFB
#   pg-bolt.sh /opt/pg18-afdoltoq            -> /opt/pg18-afdoltob   arm AFLB
#   PDATA=<file> pg-bolt.sh <prefix>          use a specific recording
#
# It runs HERE and not on the server because AL2023 ships no BOLT; /usr/bin/{perf2bolt,llvm-bolt}
# exist only on this client. So pg-profile.sh brings the sampled binary back with its perf.data,
# BOLT runs locally, and only the rewritten postgres goes back over the wire.
#
# ONE RECORDING PER ARM, NO SHARING. perf2bolt resolves samples to functions by ADDRESS in the
# input binary. prep, pgoq, afdoq, pgoltoq and afdoltoq have five different layouts, so a profile taken
# against one produces near-zero usable data for another -- and perf2bolt does not error out, it
# just writes a thin .fdata and llvm-bolt then "optimises" with almost no profile. The .fdata size
# gate below is what catches that; the prior campaign's good runs were tens of MB.
#
# THE INPUT MUST BE NAMED `postgres`. perf2bolt matches the ELF against the perf.data mmap records
# by FILE NAME, and pg-profile.sh deliberately fetches the binary under a timestamped name so the
# pairs stay distinguishable in work/. So stage it as <dir>/postgres first -- feeding it the
# timestamped name yields "no profile for the binary" and a useless .fdata.
#
# FLAGS: the prior campaign's arm-B set, verbatim (al-metal-hwpgo-c/pg-bolt4.sh), which is what its
# published +6.44% / +3.52% were measured with. The richer set (--icf --icp=all --hugify) was
# measured a wash-to-loss on this exact workload, so it stays out: this campaign is about where the
# lattice cells land relative to each other, not about re-tuning BOLT.
set -uo pipefail
cd "$(dirname "$0")"
. ./pg-env.sh

IN_PREFIX=${1:?usage: pg-bolt.sh <input-prefix>   e.g. /opt/pg18-pgoltoq}
NAME=$(basename "$IN_PREFIX" | sed 's/^pg18-//')

# Whitelist, and it is load-bearing: install below does `sudo rm -rf /opt/pg18-$TAG`. A typo'd or
# unmapped input must not be able to point that at a source prefix (base, pgo, pgolto, ...).
case "$NAME" in
  prep)     TAG=boltonly; ARM=B    ;;
  pgoq)     TAG=pgob;     ARM=PB   ;;
  pgoltoq)  TAG=pgoltob;  ARM=LB   ;;
  afdoq)    TAG=afdob;    ARM=AFB  ;;
  afdoltoq) TAG=afdoltob; ARM=AFLB ;;
  *) echo "!!! $IN_PREFIX is not a BOLT input twin. Use prep, pgoq, afdoq, pgoltoq or afdoltoq." >&2
     exit 1 ;;
esac

TS=$(date -u +%Y%m%dT%H%M%SZ)
OUTDIR=$WORK/bolt-$TAG
FDATA=$WORK/$TAG.fdata
LOG=$RESULTS/pg-bolt-$TAG-$TS.log
BOLTLOG=$RESULTS/pg-bolt-$TAG-$TS.bolt.log
mkdir -p "$RESULTS" "$OUTDIR"
exec > >(tee -a "$LOG") 2>&1

say() { echo "=== [$(date -u +%T)] $*"; }
die() { echo "!!! $*" >&2; exit 1; }

FLAGS="-reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions -split-all-cold -split-eh -dyno-stats --update-debug-sections"

say "arm $ARM  input=$IN_PREFIX  tag=$TAG"

# --- the profile ----------------------------------------------------------------------------------
PDATA=${PDATA:-}
if [ -z "$PDATA" ]; then
  P=$WORK/.last-profile-bolt-$NAME
  [ -s "$P" ] || die "no bolt profile for $NAME -- run: pg-profile.sh bolt $IN_PREFIX
!!! (a profile of a DIFFERENT arm cannot be substituted -- see the header)"
  PDATA=$(cat "$P")
fi
[ -s "$PDATA" ] || die "profile $PDATA is missing or empty"
# The sampled binary came back beside the profile, sharing its timestamp suffix.
BIN=$(echo "$PDATA" | sed 's|.*/perf-bolt-|'"$WORK"'/postgres-|; s|\.data$||')
[ -s "$BIN" ] || die "sampled binary $BIN is missing -- perf2bolt needs the EXACT binary sampled"

say "profile: $PDATA ($(stat -c%s "$PDATA") bytes)"
say "binary : $BIN"

# --- input gates, before spending anything --------------------------------------------------------
IN=$OUTDIR/postgres
cp -f "$BIN" "$IN"          # name must be exactly `postgres` -- see the header
NREL=$(readelf -SW "$IN" | grep -cE '\.rela\.text' || true)
NDBG=$(readelf -SW "$IN" | grep -cw '\.debug_line' || true)
echo "    rela.text sections : $NREL"
echo "    debug_line sections: $NDBG"
[ "${NREL:-0}" -ge 1 ] || die "no .rela.text -- this build was linked without -Wl,-q and llvm-bolt
!!! will reject it. Use the arm's *q twin, not the benchmarked arm itself."
[ "${NDBG:-0}" -ge 1 ] || die "no .debug_line -- build the input with -g"
readelf -SW "$IN" | grep -qw '\.note\.bolt_info' \
  && die "$BIN is ALREADY BOLTed -- double-BOLTing a binary is not an arm of this lattice"

# --- perf2bolt ------------------------------------------------------------------------------------
say "perf2bolt (the slow step)"
time perf2bolt -p "$PDATA" -o "$FDATA" "$IN" 2>&1 | tail -12
[ -s "$FDATA" ] || die "perf2bolt produced no .fdata"
FSZ=$(stat -c%s "$FDATA")
echo "    .fdata size        : $FSZ bytes"
[ "$FSZ" -gt 500000 ] || die ".fdata is only $FSZ bytes. A few hundred KB means the profile did not
!!! match this ELF -- i.e. the recording was taken against a different binary. Re-record with
!!! pg-profile.sh bolt $IN_PREFIX and do not reuse another arm's profile."

# --- llvm-bolt ------------------------------------------------------------------------------------
# Whole log to a file: the coverage and dyno-stats lines print in the MIDDLE of the output, and
# truncating them has already cost the prior campaign a re-run.
say "llvm-bolt   flags: $FLAGS"
time llvm-bolt "$IN" -o "$OUTDIR/postgres.bolt" -data="$FDATA" $FLAGS > "$BOLTLOG" 2>&1
RC=$?
[ $RC -eq 0 ] && [ -s "$OUTDIR/postgres.bolt" ] \
  || { tail -30 "$BOLTLOG"; die "llvm-bolt failed (rc=$RC) -- full log $BOLTLOG"; }

say "coverage / dyno-stats"
grep -E 'functions out of|were relaid out|non-empty execution profile|taken branches|taken conditional|executed instructions|of the input binary|BOLT-WARNING: [0-9]' \
  "$BOLTLOG" | sed 's/^/    /' | head -25

# A rewrite that optimised almost nothing is the silent failure mode this whole stage risks, so
# turn the coverage line into a gate rather than a printout.
NFUNC=$(grep -oE '^BOLT-INFO: ([0-9]+) out of [0-9]+ functions in the binary .* have non-empty execution profile' "$BOLTLOG" \
        | grep -oE '^BOLT-INFO: [0-9]+' | grep -oE '[0-9]+' | head -1)
[ -n "${NFUNC:-}" ] || NFUNC=$(grep -oE '[0-9]+ out of [0-9]+ functions' "$BOLTLOG" | grep -oE '^[0-9]+' | head -1)
echo "    functions with a profile: ${NFUNC:-unknown}"
[ "${NFUNC:-0}" -gt 200 ] || die "only ${NFUNC:-0} functions got a profile -- the layout was rewritten
!!! essentially blind. Treat this as a failed profile, not a finished arm."

ls -l "$IN" "$OUTDIR/postgres.bolt" | sed 's/^/    /'

# --- install --------------------------------------------------------------------------------------
# Cloned from the INPUT TWIN's prefix, not from base: everything outside bin/postgres then belongs
# to the same compilation as the binary being BOLTed (same lib/*.so, same share/). The prior
# campaign cloned base because its only BOLT input was a plain -O3 twin; here the inputs are PGO,
# PGO+LTO and AutoFDO+LTO builds, and pairing a PGO+LTO postmaster with base's libraries would
# quietly mix two arms.
say "installing -> /opt/pg18-$TAG (clone of $IN_PREFIX + BOLTed postgres)"
scp -q -i "$SRV_KEY" -o StrictHostKeyChecking=no "$OUTDIR/postgres.bolt" \
    "$SRV_USER@$SRV_HOST:/tmp/postgres-$TAG" || die "scp of the BOLTed binary failed"
ssh_srv "set -e
  sudo rm -rf /opt/pg18-$TAG
  sudo cp -a $IN_PREFIX /opt/pg18-$TAG
  sudo cp /tmp/postgres-$TAG /opt/pg18-$TAG/bin/postgres
  sudo chmod 755 /opt/pg18-$TAG/bin/postgres
  rm -f /tmp/postgres-$TAG
  ls -l /opt/pg18-$TAG/bin/postgres
  /opt/pg18-$TAG/bin/postgres --version
  echo -n 'bolt_info : '; readelf -p .note.bolt_info /opt/pg18-$TAG/bin/postgres | grep -oE 'llvm-bolt.*' | head -1 | cut -c1-120
  echo -n 'text size : '; readelf -SW /opt/pg18-$TAG/bin/postgres | awk '\$2==\".text\"{print strtonum(\"0x\"\$6)}'
  echo -n 'gcov syms : '; nm -a /opt/pg18-$TAG/bin/postgres 2>/dev/null | grep -c '__gcov\|gcov_' || true
" 2>&1 | sed 's/^/    /' || die "install of /opt/pg18-$TAG failed"

say "DONE arm $ARM -> /opt/pg18-$TAG   (.fdata $FDATA, bolt log $BOLTLOG)"
