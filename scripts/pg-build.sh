#!/bin/bash
# Build one PostgreSQL 18.3 arm with gcc 15.2.0 (/opt/gcc15). Runs ON the metal box (AL2023).
#
# gcc 15.2.0 VARIANT of ../pg-build.sh. It differs only in: the compiler and its gcc-ar/ranlib/nm,
# the source tag (REL_18_3), the /opt/g15-pg18-* prefixes and ~/g15 work trees, and AutoFDO + LTO
# (afdolto/afdoltoq) passing -fauto-profile on the COMPILE line as well as the link line, with a
# build-log gate that requires it. Everything else is the published recipe, unchanged.
#
# Extends al-metal-hwpgo-c/pg-build.sh to the full 10-build lattice. Its conventions are kept
# deliberately -- in-tree (non-VPATH) builds, PGO arms reusing the pgogen tree, a `base` arm
# with no debug info and a separate `prep` twin for the profile tools -- so the new arms stay
# comparable with that campaign's published +6.44% / +3.52% BOLT numbers. The additions here
# are the arms it never had: a standalone PGO arm, the whole AutoFDO+LTO family, and the
# BOLT-input twins those need.
#
# SERVER BUILDS (10). Every one is -O3 -march=native -mtune=native plus the row's flags:
#   base       (nothing)                                    -> /opt/g15-pg18-base       arm A
#   prep       -g / -Wl,-q                                  -> /opt/g15-pg18-prep       BOLT input for B,
#                                                                                   AutoFDO profile source,
#                                                                                   NEVER benchmarked
#   pgogen     -fprofile-generate -fprofile-update=prefer-atomic
#                                                           -> /opt/g15-pg18-pgogen     intermediate, NEVER benchmarked
#   pgouse     -fprofile-use -fprofile-correction            -> /opt/g15-pg18-pgo        arm P
#   pgouseq    as pgouse + -g / -Wl,-q                       -> /opt/g15-pg18-pgoq       BOLT input for PB, NEVER benchmarked
#   pgolto     as pgouse + -flto=96 -ffat-lto-objects        -> /opt/g15-pg18-pgolto     arm L
#   pgoltoq    as pgolto + -g / -Wl,-q                       -> /opt/g15-pg18-pgoltoq    BOLT input for LB, NEVER benchmarked
#   afdo       -fauto-profile=<afdo>                         -> /opt/g15-pg18-afdo       arm AF
#   afdoq      as afdo + -g / -Wl,-q -fno-reorder-blocks-and-partition
#                                                           -> /opt/g15-pg18-afdoq      BOLT input for AFB, NEVER benchmarked
#   afdolto    -flto=96 -fauto-profile=<afdo> on the compile AND link line (see #2)
#                                                           -> /opt/g15-pg18-afdolto    arm AFL
#   afdoltoq   as afdolto + -g / -Wl,-q -fno-reorder-blocks-and-partition
#                                                           -> /opt/g15-pg18-afdoltoq   BOLT input for AFLB, NEVER benchmarked
#
# CLIENT BUILDS (5), by llvm-bolt in pg-bolt.sh -- AL2023 ships no BOLT, so the binaries and
# perf.data are shuttled to the client:
#   boltonly   llvm-bolt(prep)      arm B        pgoltob  llvm-bolt(pgoltoq)   arm LB
#   afdoltob   llvm-bolt(afdoltoq)  arm AFLB     pgob     llvm-bolt(pgouseq)   arm PB
#   afdob      llvm-bolt(afdoq)     arm AFB
#
# arm PB (PGO+BOLT, no LTO) was added 2026-09-17 on request. It is the one cell the original
# lattice skipped: it isolates BOLT's contribution on top of PGO alone, so PB-vs-P and LB-vs-L
# together say whether BOLT and LTO overlap or compose. Its input twin mirrors pgoltoq -- hot/cold
# splitting stays ON, matching the PGO side's asymmetry #1 below rather than the AutoFDO side's.
#
# => 9 benchmarked arms (A B P PB L LB AF AFL AFLB) from 14 builds. Five builds are never
#    benchmarked: prep, pgogen, pgouseq, afdoq, pgoltoq, afdoltoq.
#
# THREE DELIBERATE ASYMMETRIES, to state in the writeup:
#  1. afdoltoq disables hot/cold splitting; pgoltoq does NOT. BOLT handles pre-split functions
#     badly and -fauto-profile turns splitting on, but the PGO side keeps it on because that is
#     what the prior campaign measured and staying comparable to it is the point.
#  2. afdolto/afdoltoq pass the profile on the COMPILE and the link line. The published gcc 14.2.1
#     script put it on the link line only, to dodge a reported -flto + -fauto-profile ICE, and
#     that applies no profile (AutoFDO runs per TU before LTO streaming). Retested 2026-09-30 on
#     PG 18.3: gcc 15.2.0 (and 14.2.1) build it with zero ICEs, and .text differs from a plain
#     LTO control, so the profile is applied. The gate below requires -fauto-profile in the
#     compile commands; an ICE would fail the build and be listed by the make-failed grep.
#  3. base carries no -g and no -Wl,-q: it is the binary a normal user would build. The BOLT
#     and AutoFDO inputs live in `prep` instead of being folded into the baseline.
#
# SOURCE: branch `p183-base` of the git checkout at /home/ec2-user/postgres ON THIS SERVER =
# STOCK PostgreSQL 18.3 (62d6c7d3df6 "Stamp 18.3."), zero commits beyond REL_18_3,
# NUM_XLOGINSERT_LOCKS at its stock 8, tree eacca3d098ca. Verified identical to the client repo's
# `p183` branch (same tree hash) -- the branch NAMES differ between the two boxes, the trees do
# not. Stock is chosen so the compiler effect is measured against unmodified upstream and stays
# comparable to the prior campaign's numbers, which were also taken on stock.
#
# The client repo's other p183* branches carry performance patches (p183-z3s-spinbackoff is
# REL_18_3+5 with s_lock exponential backoff, lwlock spin rework, and NUM_XLOGINSERT_LOCKS raised
# to 64). Building an arm from one of those and comparing it against a stock arm would report a
# SOURCE change as a compiler win. Each arm's tree is exported from git by revision and the
# revision is echoed by every gate block below, so no binary here can be mistaken for another tree.
#
# `git archive` per arm, rather than a shipped tarball: it guarantees a pristine tree with no build
# products and no local edits, and it removes the shipped-tarball-drifts-from-the-repo failure mode
# entirely. GITREV overrides the revision; SRCREPO overrides the repo.
set -uo pipefail
ARM=${1:?base|prep|pgogen|pgouse|pgouseq|pgolto|pgoltoq|afdo|afdoq|afdolto|afdoltoq}
SRCREPO=${SRCREPO:-/home/ec2-user/postgres}
GITREV=${GITREV:-REL_18_3}
AFDO=${AFDO:-/home/ec2-user/g15/prof/pg18-g15-hammerdb.afdo}
CC=/opt/gcc15/bin/gcc
COMMON="-O3 -march=native -mtune=native"
LTOJOBS=${LTOJOBS:-96}
JOBS=${JOBS:-192}
PGOTREE=/home/ec2-user/g15/pgsrc-pgo
REUSE=0
MAKEVARS=""

# -ffat-lto-objects, kept from the prior campaign: PG's build runs objects through ar/ranlib
# and also *executes* generated tools, and fat objects keep both the IR and real machine code
# in each .o so neither path breaks. Slower to build, but it is the configuration that produced
# the numbers this campaign has to line up with.
LTO="-flto=$LTOJOBS -ffat-lto-objects"

case "$ARM" in
  base)   SRC=/home/ec2-user/g15/pgsrc-base;  PREFIX=/opt/g15-pg18-base
          CFLAGS="$COMMON"; LDFLAGS="" ;;
  prep)   SRC=/home/ec2-user/g15/pgsrc-prep;  PREFIX=/opt/g15-pg18-prep
          # -g for create_gcov (it needs .debug_line to map LBR samples back to source lines)
          # and -Wl,-q for llvm-bolt (it needs the retained relocations). Neither changes
          # codegen, which is what makes this a legitimate stand-in for `base`.
          CFLAGS="$COMMON -g"; LDFLAGS="-Wl,-q" ;;
  afdo)   SRC=/home/ec2-user/g15/pgsrc-afdo;  PREFIX=/opt/g15-pg18-afdo
          CFLAGS="$COMMON -fauto-profile=$AFDO"; LDFLAGS=""
          [ -s "$AFDO" ] || { echo "!!! no profile at $AFDO"; exit 1; } ;;
  afdoq)  SRC=/home/ec2-user/g15/pgsrc-afdoq; PREFIX=/opt/g15-pg18-afdoq
          # BOLT input for arm AFB (AutoFDO + BOLT, no LTO). Unlike afdolto/afdoltoq the
          # profile goes on the COMPILE line, so -fauto-profile reaches every compile command.
          # That makes AFB the only arm on the AutoFDO side where the profile shaped codegen --
          # AFL/AFLB pass it on the link line only, which applies no profile (asymmetry #2).
          # -g for llvm-bolt's debug line table, -Wl,-q to retain relocations after linking,
          # and -fno-reorder-blocks-and-partition because -fauto-profile turns hot/cold
          # splitting on and BOLT does not want pre-split functions (as afdoltoq).
          # No LTO, so the flag is needed on the compile line only, and the profile is
          # consumed at compile time -- LDFLAGS carries just what BOLT needs.
          [ -s "$AFDO" ] || { echo "!!! no profile at $AFDO"; exit 1; }
          CFLAGS="$COMMON -fauto-profile=$AFDO -g -fno-reorder-blocks-and-partition"
          LDFLAGS="-Wl,-q" ;;
  afdolto|afdoltoq)
          # Profile on the COMPILE line (where AutoFDO actually runs, per TU) and on the link line.
          # No ICE on PG 18.3 with gcc 15.2.0 -- see asymmetry #2.
          [ -s "$AFDO" ] || { echo "!!! no profile at $AFDO"; exit 1; }
          if [ "$ARM" = afdolto ]; then
            SRC=/home/ec2-user/g15/pgsrc-afdolto;  PREFIX=/opt/g15-pg18-afdolto
            CFLAGS="$COMMON $LTO -fauto-profile=$AFDO"; LDFLAGS="$LTO -fauto-profile=$AFDO"
          else
            SRC=/home/ec2-user/g15/pgsrc-afdoltoq; PREFIX=/opt/g15-pg18-afdoltoq
            # BOLT "doesn't like it when the functions are already split" (Andi Kleen) and
            # -fauto-profile turns hot/cold splitting ON, so the BOLT-input twin turns it off.
            # That is a real codegen difference from arm AFL, which is exactly why this is its
            # own build and is never benchmarked itself.
            CFLAGS="$COMMON $LTO -g -fno-reorder-blocks-and-partition -fauto-profile=$AFDO"
            LDFLAGS="$LTO -Wl,-q -fauto-profile=$AFDO -fno-reorder-blocks-and-partition"
          fi ;;
  pgogen) SRC=$PGOTREE; PREFIX=/opt/g15-pg18-pgogen
          # prefer-atomic keeps the counters sane when several hundred backends touch the same
          # .gcda -- PG forks one backend per connection and the training run has hundreds.
          CFLAGS="$COMMON -fprofile-generate -fprofile-update=prefer-atomic"
          LDFLAGS="-fprofile-generate"
          # src/interfaces/libpq/Makefile has a `libpq-refs-stamp` rule that fails the build if
          # libpq.so references anything calling exit(). -fprofile-generate links gcov's at-exit
          # .gcda dumper, so it does. PG's own comment names this case -- "Skip the test when
          # profiling, as gcc may insert exit() calls for that" -- and gates the skip on
          # enable_coverage. Setting it on the MAKE command line skips that one check and adds NO
          # compiler flags (the enable_coverage block in Makefile.global.in defines only the
          # coverage/lcov targets).
          # It does hook `clean-coverage` (rm -f *.gcda) into `make clean`, so this tree must
          # NEVER be `make clean`ed between the training run and the -fprofile-use builds. That
          # is why the reuse path below deletes objects with `find -delete` instead.
          MAKEVARS="enable_coverage=yes" ;;
  pgouse|pgouseq|pgolto|pgoltoq)
          SRC=$PGOTREE; REUSE=1
          # -fprofile-use with NO =path: gcc then looks for each .gcda beside its own object
          # file, which is the whole reason these arms must reuse the pgogen tree in place.
          # -fprofile-correction is required, not optional: multi-process counter merging leaves
          # inconsistent counts and gcc hard-errors without it.
          # -fprofile-partial-training keeps never-trained functions at -O3 instead of
          # size-optimising them, which matters because a TPROC-C run never touches most of PG.
          P="-fprofile-use -fprofile-correction -fprofile-partial-training -Wno-missing-profile"
          MAKEVARS="enable_coverage=yes"   # same libpq assertion skip; also required at install
          case "$ARM" in
            pgouse)  PREFIX=/opt/g15-pg18-pgo;      CFLAGS="$COMMON $P";           LDFLAGS="" ;;
            # BOLT input for arm PB: same codegen as pgouse plus what BOLT needs to read the
            # binary -- -g for the debug line table and -Wl,-q to keep relocations after linking.
            # No -fno-reorder-blocks-and-partition here: see asymmetry #1, the PGO side keeps
            # hot/cold splitting on so PB stays comparable to LB and to the prior campaign.
            pgouseq) PREFIX=/opt/g15-pg18-pgoq;     CFLAGS="$COMMON $P -g";        LDFLAGS="-Wl,-q" ;;
            pgolto)  PREFIX=/opt/g15-pg18-pgolto;   CFLAGS="$COMMON $P $LTO";      LDFLAGS="$LTO" ;;
            pgoltoq) PREFIX=/opt/g15-pg18-pgoltoq;  CFLAGS="$COMMON $P $LTO -g";   LDFLAGS="$LTO -Wl,-q" ;;
          esac ;;
  *) echo "!!! unknown arm $ARM"; exit 1 ;;
esac

# gcc-ar/ranlib must come from the SAME gcc as the compiler for any LTO arm, or they load the
# wrong plugin for the IR inside libpgcommon.a / libpgport.a and the link either fails or
# silently drops cross-module inlining. Exported, because PG's configure picks these up from
# the environment.
case "$ARM" in
  pgolto|pgoltoq|afdolto|afdoltoq)
    export AR=/opt/gcc15/bin/gcc-ar RANLIB=/opt/gcc15/bin/gcc-ranlib NM=/opt/gcc15/bin/gcc-nm ;;
esac

if [ -n "${TAG:-}" ]; then
  PREFIX="$PREFIX-$TAG"; SRC="$SRC-$TAG"
  [ "$REUSE" = 1 ] && { echo "!!! TAG cannot be combined with pgouse/pgolto/pgoltoq (they must reuse the pgogen tree)"; exit 1; }
fi

echo "=== pg-build $ARM $(date -u +%FT%TZ)"
echo "    prefix=$PREFIX"
echo "    src=$SRC (reuse=$REUSE)"
echo "    CFLAGS=$CFLAGS"
echo "    LDFLAGS=${LDFLAGS:-<none>}"
echo "    XLOGLOCKS=${XLOGLOCKS:-<stock 8>}"
"$CC" --version | head -1

if [ "$REUSE" = 1 ]; then
  [ -d "$SRC" ] || { echo "!!! $SRC missing -- run 'pg-build.sh pgogen' and pg-train.sh first"; exit 1; }
  N=$(find "$SRC" -name '*.gcda' | wc -l)
  echo "    .gcda files found in the tree: $N"
  [ "$N" -gt 100 ] || { echo "!!! only $N .gcda -- the training run did not write a profile"; exit 1; }
  # Drop build products, keep the training data (*.gcda) and instrumentation notes (*.gcno).
  #
  # objfiles.txt MUST go too. It is PG's per-directory build stamp (`all: objfiles.txt` in
  # src/backend/common.mk) and it defeats a plain object delete: with the stamp present a
  # backend subdir reports "Nothing to be done for 'all'" and compiles nothing, then the
  # top-level link reads the object list back out of the stamp and dies with
  #   /usr/bin/ld: cannot find access/brin/brin_minmax_multi.o
  # Measured on src/backend/access/brin: `make -n` emits 10 compile actions without the stamp
  # and 0 with it.
  find "$SRC" \( -name '*.o' -o -name '*.a' -o -name '*.so' -o -name objfiles.txt \) -delete
  # LINKED PROGRAMS MUST GO TOO, and deleting src/backend/postgres alone is not enough. Measured on
  # the pgouse pass of 2026-09-17: make re-entered src/bin/psql and recompiled psqlscan.o with
  # -fprofile-use, but never relinked psql -- build.out has no `-o psql` line -- so the pgogen-era
  # INSTRUMENTED psql survived from 18:45 and `make install` copied it into /opt/g15-pg18-pgo. 36 of the
  # tree's 39 executables were stale that way (psql 2875 gcov syms, pg_ctl 542, pg_dump 2650) while
  # bin/postgres itself was clean. That is not cosmetic: pg-srv.sh start/stop runs $PREFIX/bin/pg_ctl
  # and $PREFIX/bin/psql, an instrumented tool writes .gcda BESIDE ITS OBJECT in this tree, and this
  # tree is the training profile -- arm P's start on 2026-09-17 01:53:16 bumped src/port/strlcpy.gcda
  # and added strlcpy_shlib.gcda (941 -> 942 files), i.e. it mutated the profile after training.
  # With no target file present make has to run the link recipe, which is the only reliable way to
  # force it: make compares mtimes, and newer objects evidently did not do it.
  # Match on ELF magic rather than a name list: the stale set spans src/bin, src/interfaces/ecpg,
  # src/timezone/zic and src/test, and a name list would silently miss the next one. *.gcda are not
  # executable, so they cannot be caught by this.
  find "$SRC" -type f -executable \
    -exec sh -c 'file -b "$1" | grep -q "^ELF .*executable"' _ {} \; -print -delete \
    | sed 's|^|        relink forced: |'
  rm -f "$SRC/src/backend/postgres"
  echo -n "    .gcda still present after cleaning: "; find "$SRC" -name '*.gcda' | wc -l
else
  # Pristine tree per arm, exported straight from git: a configured tree must never be reused
  # between arms or stale objects silently mix flag sets. git archive also guarantees no build
  # products and no uncommitted local edits leak in.
  git -C "$SRCREPO" rev-parse --verify "$GITREV" >/dev/null 2>&1 \
    || { echo "!!! $GITREV is not a revision in $SRCREPO"; exit 1; }
  # A dirty working tree is a silent-divergence risk: the arm would be built from committed state
  # while someone reads the checkout and believes otherwise.
  D=$(git -C "$SRCREPO" status --short | wc -l)
  [ "$D" -eq 0 ] || echo "    WARNING: $SRCREPO has $D modified files -- building from COMMITTED $GITREV, not the working tree"
  rm -rf "$SRC"; mkdir -p "$SRC"
  git -C "$SRCREPO" archive "$GITREV" | tar -x -C "$SRC" || { echo "!!! git archive failed"; exit 1; }
  git -C "$SRCREPO" rev-parse --short "$GITREV" > "$SRC/.campaign-rev"
  git -C "$SRCREPO" rev-parse "$GITREV^{tree}" >> "$SRC/.campaign-rev"
fi

cd "$SRC" || exit 1
SRCREV=$(tr '\n' ' ' < .campaign-rev 2>/dev/null || echo unknown)

if [ -n "${XLOGLOCKS:-}" ]; then
  F=src/backend/access/transam/xlog.c
  sed -i -E "s/^#define NUM_XLOGINSERT_LOCKS[[:space:]]+[0-9]+/#define NUM_XLOGINSERT_LOCKS  $XLOGLOCKS/" "$F"
  echo -n "    patched: "; grep -n 'define NUM_XLOGINSERT_LOCKS' "$F"
  grep -q "NUM_XLOGINSERT_LOCKS  $XLOGLOCKS" "$F" || { echo "!!! xlog.c patch did not apply"; exit 1; }
fi

# Identical configure line for every arm; the ONLY difference between arms is CFLAGS/LDFLAGS.
# Anything else would mean measuring the build options instead of the profile.
# jit stays off (no --with-llvm): JIT-generated code is untouched by AutoFDO/BOLT and its
# anonymous runtime code would also pollute the LBR recordings that feed perf2bolt/create_gcov.
if [ "$REUSE" = 1 ] && [ -f config.status ] && [ "${RECONF:-1}" = 0 ]; then
  echo "--- reusing existing configure (RECONF=0)"
else
  ./configure --prefix="$PREFIX" --with-openssl --with-readline \
      CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" > configure.out 2>&1 || {
        echo "!!! configure failed"; tail -20 configure.out; exit 1; }
fi
grep -E '^CFLAGS|^LDFLAGS' src/Makefile.global | head -4
# GATE: prove configure did not substitute its own -O2. This is the most common way an arm
# turns out to be a plain -O2 build that merely has the right directory name.
grep -q -- '-O3' src/Makefile.global || { echo "!!! -O3 absent from Makefile.global"; exit 1; }

# `grep -iE error` here used to match `-Werror=vla` in every compile command line, burying the
# real failure under a wall of unrelated gcc invocations. Match real diagnostics only.
make -j"$JOBS" ${MAKEVARS:-} > build.out 2>&1 || {
  echo "!!! make failed"
  grep -nE 'Error [0-9]|error:|undefined reference|cannot find|collect2:|must not be|internal compiler' build.out | head -20
  exit 1; }
sudo rm -rf "$PREFIX"
# MAKEVARS again: install re-evaluates the `all` prerequisites, so the libpq exit check has to
# stay skipped here too or the install re-triggers the same failure.
sudo make install ${MAKEVARS:-} > install.out 2>&1 || { echo "!!! install failed"; tail -20 install.out; exit 1; }

# ---- gates -------------------------------------------------------------------
B=$PREFIX/bin/postgres
echo "--- gates for $ARM"
ls -l "$B"
"$B" --version
echo "    source rev/tree     : $SRCREV ($GITREV from $SRCREPO)"
echo -n "    md5                 : "; md5sum "$B" | cut -c1-12
# -SW and grep -cw, not '\.debug_line$': readelf prints the section name mid-line followed by
# type/address columns, so a '$' anchor never matches and the gate reads as failed on a binary
# that is fine. (BOLT-PIPELINE.md step 1 had exactly this bug.)
echo -n "    .debug_info        : "; readelf -SW "$B" | grep -cw '\.debug_info' || true
echo -n "    .debug_line        : "; readelf -SW "$B" | grep -cw '\.debug_line' || true
echo -n "    .rela.text         : "; readelf -SW "$B" | grep -cw '\.rela\.text' || true
echo -n "    .text bytes        : "; readelf -SW "$B" | awk '$2==".text"{print strtonum("0x"$6)}'
echo -n "    -g in build log    : "; grep -c -- ' -g ' build.out || true
echo -n "    auto-profile in log: "; grep -c -- '-fauto-profile' build.out || true
echo -n "    profile-use in log : "; grep -c -- '-fprofile-use' build.out || true
echo -n "    profile-gen in log : "; grep -c -- '-fprofile-generate' build.out || true
echo -n "    lto in log         : "; grep -c -- '-flto' build.out || true
echo -n "    WAL insert locks   : "; grep -oE 'NUM_XLOGINSERT_LOCKS[[:space:]]+[0-9]+' src/backend/access/transam/xlog.c | head -1
echo -n "    missing-profile warns: "; grep -c 'profile count data file not found' build.out || true

# A binary that already carries BOLT's marker was built from a BOLTed input; double-BOLTing is
# a real and confusing mistake.
readelf -SW "$B" | grep -qw '\.note\.bolt_info' && echo "    not-bolted         : FAIL (already BOLTed)" || echo "    not-bolted         : OK"

# gcov symbols must be present in pgogen and ABSENT everywhere else. This catches the nastiest
# failure mode: a use-build that accidentally kept instrumentation.
NG=$(nm "$B" 2>/dev/null | grep -c '__gcov\|gcov_' || true)
if [ "$ARM" = pgogen ]; then
  [ "$NG" -gt 100 ] && echo "    instrumented       : OK ($NG gcov syms)" || echo "    instrumented       : FAIL ($NG gcov syms)"
else
  [ "$NG" -eq 0 ] && echo "    no-instrumentation : OK" || echo "    no-instrumentation : FAIL ($NG gcov syms)"
fi

# THE WHOLE PREFIX, not just the postmaster. /opt/g15-pg18-pgo passed the gate above with a clean
# bin/postgres while shipping an instrumented psql, pg_ctl and pg_dump beside it (see the reuse-clean
# comment). The postmaster is what gets benchmarked, so the arm's numbers were fine -- but the tools
# are what pg-srv.sh runs, and theirs is the path that writes .gcda back into the training tree.
GCOVF=$(for f in "$PREFIX"/bin/* "$PREFIX"/lib/*.so*; do
          [ -f "$f" ] || continue
          nm -a "$f" 2>/dev/null | grep -qE '__gcov|gcov_' && echo "${f##*/}"
        done)
NGP=$(echo -n "$GCOVF" | grep -c . || true)
if [ "$ARM" = pgogen ]; then
  echo "    instrumented prefix: $NGP files carry gcov syms (expected for pgogen)"
elif [ "$NGP" -eq 0 ]; then
  echo "    prefix clean       : OK (no gcov syms anywhere in $PREFIX)"
else
  echo "    prefix clean       : FAIL ($NGP files under $PREFIX carry gcov syms:)"
  echo "$GCOVF" | tr '\n' ' ' | fold -s -w 100 | sed 's|^|        |'
  echo "        -> stale links from the pgogen build; they write .gcda into $PGOTREE when run"
fi

# Per-arm flag expectations, checked against the BUILD LOG (the compile lines gcc actually ran)
# rather than against what this script believes it passed.
need() { local n; n=$(grep -c -- "$1" build.out || true); [ "$n" -gt 0 ] && echo "    flag $1: OK ($n lines)" || echo "    flag $1: FAIL (absent from build.out)"; }
case "$ARM" in
  prep)             need ' -g ' ;;
  pgogen)           need '-fprofile-generate' ;;
  pgouse)           need '-fprofile-use' ;;
  pgouseq)          need '-fprofile-use'; need ' -g ' ;;
  pgolto|pgoltoq)   need '-fprofile-use'; need '-flto' ;;
  afdo)             need '-fauto-profile' ;;
  afdoq)            need '-fauto-profile'; need ' -g '
                    need '-fno-reorder-blocks-and-partition' ;;
  afdolto|afdoltoq) need '-flto'
                    # counted on compile commands (" -c "), not just the link line
                    n=$(grep -- ' -c ' build.out | grep -c -- "-fauto-profile=$AFDO" || true)
                    [ "$n" -gt 0 ] && echo "    flag -fauto-profile on compile lines: OK ($n lines)" \
                                   || echo "    flag -fauto-profile on compile lines: FAIL (absent)" ;;
esac

# Functional smoke. -flto on PostgreSQL is the real risk: the backend exports symbols that
# loadable modules resolve against, and LTO plus --export-dynamic can drop ones nothing in the
# main binary references. A binary that builds but cannot initdb and answer a query is worse
# than a build failure, because it looks like a valid arm.
# GCOV_PREFIX sends the instrumented smoke run's counters somewhere disposable -- without it,
# initdb + a trivial SELECT would write .gcda into the pgogen tree and contaminate the training
# profile with bootstrap/DDL paths before HammerDB has run a single transaction.
SMOKE=/home/ec2-user/g15/smoke-$ARM
SMOKE_GCOV=/home/ec2-user/g15/gcda-smoke-$ARM
rm -rf "$SMOKE" "$SMOKE_GCOV"; mkdir -p "$SMOKE_GCOV"
export GCOV_PREFIX="$SMOKE_GCOV" GCOV_PREFIX_STRIP=0
if "$PREFIX/bin/initdb" -D "$SMOKE" -U postgres --no-sync > smoke.out 2>&1; then
  if "$PREFIX/bin/pg_ctl" -D "$SMOKE" -o "-p 55432 -c listen_addresses=localhost -c huge_pages=off -c unix_socket_directories=$SMOKE" \
       -l "$SMOKE/pg.log" -w start >> smoke.out 2>&1; then
    OUT=$("$PREFIX/bin/psql" -h localhost -p 55432 -U postgres -tAc \
          "select 'rows='||count(*) from generate_series(1,1000)" 2>&1 | tr -d '\n ')
    echo "    smoke              : OK ($OUT)"
    "$PREFIX/bin/pg_ctl" -D "$SMOKE" -m immediate -w stop >> smoke.out 2>&1
  else
    echo "    smoke              : FAIL (server would not start) -- see $SMOKE/pg.log"; tail -5 "$SMOKE/pg.log" 2>/dev/null
  fi
else
  echo "    smoke              : FAIL (initdb) -- see $SRC/smoke.out"; tail -5 smoke.out
fi
unset GCOV_PREFIX GCOV_PREFIX_STRIP
rm -rf "$SMOKE" "$SMOKE_GCOV"

# The training profile has to be EMPTY before training starts, and the build just filled it
# with counters from every instrumented build-time tool PG compiled and ran (see pg-train.sh).
if [ "$ARM" = pgogen ]; then
  echo -n "    .gcda left in tree by the BUILD: "; find "$SRC" -name '*.gcda' | wc -l
  echo "    ^ pg-train.sh must delete these first -- build-tool counters are not training data"
fi
echo "=== pg-build $ARM done $(date -u +%FT%TZ)"
