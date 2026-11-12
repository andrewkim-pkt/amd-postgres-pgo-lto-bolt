# PostgreSQL 18.3 on AMD EPYC — PGO, AutoFDO, LTO and BOLT, end to end

Instrumented PGO, hardware-sampled AutoFDO, LTO and BOLT applied to PostgreSQL 18.3 on an
**AWS r8a.metal-48xl (AMD EPYC 9R45, Zen 5)**, measured with HammerDB TPROC-C.

**Headline: `afdoltob` (AutoFDO + LTO + BOLT) is the best arm at +3.76% NOPM** over a plain
`-O3 -march=native` build, against **+11.95%** for `pgoltob` on the equivalent Intel
r8i.metal-48xl — about **3.2× smaller, and the winning arm flips** from instrumented PGO to
AutoFDO.

The cause is not a weak profile. CPU per transaction falls **10.5–12.9%**, comparable to Intel.
**The box simply never saturates — it peaks at 54% busy** — so there is no throughput headroom to
convert the saving into. Section 4 has the detail.

Intel counterpart for comparison:
[`andrewkim-pkt/postgres-pgo-lto-bolt`](https://github.com/andrewkim-pkt/postgres-pgo-lto-bolt)
(its gcc 15.2.0 leg; the gcc 14.2.1 data there is a different campaign and is not compared here).
The MySQL leg on this same AMD machine is in [`andrewkim-pkt/amd-mysql-pgo-lto-bolt`](https://github.com/andrewkim-pkt/amd-mysql-pgo-lto-bolt).

---

## 1. System and workload

### 1.1 Server (database under test)

| | |
|---|---|
| Instance | AWS **r8a.metal-48xl** |
| CPU | **AMD EPYC 9R45**, 96 cores per socket |
| Topology | **192 cores / 2 sockets / 1 thread per core — no SMT** |
| NUMA | **2 nodes**: node 0 = CPU 0–95, node 1 = CPU 96–191. **Distances 10 local / 32 remote** |
| L3 / L2 | 768 MiB (24 × 32 MiB CCX) / 192 MiB (1 MiB per core) |
| Clock | 4.51 GHz max, ~3.5 GHz under full load |
| RAM | 1,505 GB |
| OS / kernel | Amazon Linux 2023, 6.18.56-125.164.amzn2023.x86_64 |
| Governor / THP / numa_balancing | `performance` / `madvise` / 1 |

### 1.2 Client (load generator)

AWS **r7i.24xlarge** — Xeon Platinum 8488C, 96 vCPU, 1 NUMA node, 743 GB, HammerDB 4.7 with
`libpq` taken from the server's own 18.3 build so client and server match by construction.

> `cli%` in `results/` is contaminated (~20%) by a CPU-activity guard left running to stop the
> instance being auto-stopped for idleness. **Do not quote `cli%` for this leg.** The server-side
> `box%`, `n0%` and `n1%` columns are clean.

### 1.3 Workload

| | |
|---|---|
| Benchmark | HammerDB 4.7 **TPROC-C**, `allwarehouse true`, `keyandthink false`, stored procedures on |
| Warehouses | **1,536** |
| Dataset | PGDATA **243 G**, database 146 GB, built in 12 min at 64 build-VU |
| Location | **tmpfs** `/mnt/ramdisk/pgdata` — zero storage I/O in the measurement |
| Handling | built once, kept as a RAM golden plus an EBS snapshot, and **restored before every pass** with `numactl --interleave=all cp` so tmpfs pages spread over both nodes |
| Row counts | warehouse 1,536 · district 15,360 · customer 46,080,000 · order_line 460,821,018 |

### 1.4 Server configuration

[`scripts/pg-amd.conf`](scripts/pg-amd.conf). Everything that shapes the workload is held
identical to the published PG campaign so the AMD-vs-Intel comparison is not a configuration
comparison.

```ini
max_connections = 1500
shared_buffers = 192GB            # on 1 GiB huge pages
huge_pages = on
huge_page_size = 1GB
effective_cache_size = 1100GB
work_mem = 8MB
maintenance_work_mem = 4GB
synchronous_commit = off
full_page_writes = off
wal_level = minimal
max_wal_senders = 0
wal_buffers = 1GB
max_wal_size = 96GB
min_wal_size = 12GB
checkpoint_timeout = 30min
random_page_cost = 1.0
seq_page_cost = 1.0
effective_io_concurrency = 200
jit = off
autovacuum_max_workers = 8
bgwriter_delay = 10ms
max_locks_per_transaction = 256
```

`shared_buffers` lives on **201 × 1 GiB huge pages**, reserved before each boot:

```bash
echo 201 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
```

PostgreSQL refuses to start if those pages are unavailable, so a successful start is itself proof
the setting took effect. **See §5 for why reserving them globally introduces a NUMA confound.**

### 1.5 Toolchain

Identical versions to the Intel leg, so cross-vendor differences are not toolchain-version
artifacts.

| tool | version |
|---|---|
| gcc / g++ | **15.2.0** → `/opt/gcc15` |
| llvm-bolt / perf2bolt / merge-fdata | **18.1.3** → `/opt/llvm-bolt-18.1.3` |
| autofdo `create_gcov` | commit **`f95d1a1`**, `-DENABLE_TOOL=GCOV`, run with `--gcov_version=2` |
| PostgreSQL source | **18.3**, tag `REL_18_3` = **`62d6c7d3df6`** |

`-march=native` resolves to **`znver5`** here (`graniterapids` on the Intel leg).

Prerequisites that are easy to miss on AL2023:
* **`perl-File-Compare`** — `Catalog.pm:19` needs it. Without it PostgreSQL will not build at all,
  and the failure surfaces as `fmgr-stamp` / `node-support-stamp` / `bki-stamp` errors that look
  like a toolchain problem.
* `readline-devel`, `libicu-devel`, `openssl-devel`, `zlib-devel`, `flex`, `bison`.
* `protobuf-devel` for `create_gcov`.
* `ninja install-perf2bolt` is **not a target** in LLVM 18.1.3 — install `install-llvm-bolt` and
  `install-merge-fdata`, then copy `perf2bolt` from `build/bin` by hand.

---

## 2. Build steps

Nine binaries. Four are measurable arms; the rest exist only to carry a profile between stages.
All produced by [`scripts/pg-build.sh <arm>`](scripts/pg-build.sh) (the gcc 15.2.0 variant).

| arm | role | `postgres` md5 | `.text` |
|---|---|---|---|
| `base` | `-O3 -march=native -mtune=native` — **the reference** | `8a6f660c783d` | 7,185,250 |
| `prep` | `base` + `-g -Wl,-q`, AutoFDO recording input | `3c53080c6538` | **7,185,250** |
| `pgogen` | instrumented, training only | `aef7412c51d0` | — |
| `pgolto` | **PGO + LTO** | `4b0fa228ba8d` | 9,262,274 |
| `pgoltoq` | `pgolto` + `-g -Wl,-q`, BOLT input twin | `fb1797fdbeea` | 9,437,522 |
| **`pgoltob`** | **PGO + LTO + BOLT** | **`ce4deabc25a0`** | **885,308** |
| `afdoltoq` | AutoFDO + LTO + `-g -Wl,-q -fno-reorder-blocks-and-partition`, BOLT input twin | — | — |
| **`afdoltob`** | **AutoFDO + LTO + BOLT** | **`5d576b3db66e`** | **1,030,665** |

`prep` has **exactly the same `.text` size as `base`**, which is the gate proving `-g` and
`-Wl,-q` do not change code generation — so `prep` is a legitimate stand-in for `base` when
recording. `pgoltoq` is within 64 bytes of `pgolto` for the same reason.

`pgogen` carries **59,300 gcov symbols — the identical count the Intel leg published**, which is
the strongest single piece of evidence that the two legs instrument the same source in the same way.

### 2.1 Flags

```
COMMON  = -O3 -march=native -mtune=native
LTO     = -flto=96 -ffat-lto-objects
PGOUSE  = -fprofile-use -fprofile-correction -fprofile-partial-training -Wno-missing-profile
AFDO    = -fauto-profile=pg18-g15-hammerdb.afdo
```

| arm | CFLAGS | LDFLAGS |
|---|---|---|
| `base` | `COMMON` | — |
| `prep` | `COMMON -g` | `-Wl,-q` |
| `pgogen` | `COMMON -fprofile-generate -fprofile-update=prefer-atomic` | `-fprofile-generate` (+ `make enable_coverage=yes`) |
| `pgolto` | `COMMON PGOUSE LTO` | `LTO` |
| `pgoltoq` | `COMMON PGOUSE LTO -g` | `LTO -Wl,-q` |
| `afdoltoq` | `COMMON LTO -g -fno-reorder-blocks-and-partition AFDO` | `LTO -Wl,-q AFDO -fno-reorder-blocks-and-partition` |

configure: `--prefix=/opt/g15-pg18-<arm> --with-openssl --with-readline` (ICU on, JIT off),
`AR/RANLIB/NM = /opt/gcc15/bin/gcc-{ar,ranlib,nm}`, `make -j192`.

**Three LTO details that matter.**

* **`-ffat-lto-objects` is required, not optional.** PostgreSQL's build runs objects through
  `ar`/`ranlib` *and executes generated tools*. Fat objects keep both the IR and real machine code
  in every `.o`, so neither path breaks. It costs build time and is the configuration the
  published numbers were produced with.
* **`-flto=96` is kept at 96 even though this box has 192 cores.** `-flto=N` controls LTRANS
  partitioning, so changing it would make the comparison a flag study rather than a hardware one.
* **The gcc-15 archivers must be forced.** Otherwise the system gcc 11 `ar` loads the wrong LTO
  plugin for IR produced by gcc 15.

**AutoFDO on the LTO arms puts the profile on the compile line as well as the link line.** This is
what the gcc 15 recipe changed relative to gcc 14, and it is what actually applies the profile;
link-line-only is a no-op. The build gate checks `-fauto-profile` appears in the compile commands.

**`afdoltoq` disables hot/cold splitting (`-fno-reorder-blocks-and-partition`) and `pgoltoq` does
not.** `-fauto-profile` turns splitting on, and BOLT does not want pre-split functions. This
asymmetry is deliberate and is carried over from the published recipe so the arms stay comparable
with the earlier campaign — it is also why the two BOLT inputs report different function counts
(20,924 vs 15,009).

### 2.2 PGO training → `.gcda`

| | |
|---|---|
| Binary | `pgogen` (instrumented) |
| Cell | **64 cores on node 1**: `numactl --physcpubind=96-159 --preferred=1` |
| Load | **64 VU**, 3 min rampup + 10 min, 1,536 WH |
| Result | **941 `.gcda`** |

`--preferred` not `--membind`: `--membind` OOM-killed the node on the Intel box, and the setting is
kept for method parity.

Two things that silently destroy the profile:
1. **The build's own tool runs leave `.gcda` in the tree.** Those describe the build, not TPROC-C.
   Delete them before training.
2. **Stop with `pg_ctl -m fast`.** `-m immediate` sends SIGQUIT, skips the exit handlers, and gcov
   never dumps — the whole training run is lost with no error anywhere.

### 2.3 AutoFDO recording → `.afdo`

Against `prep`, under the same load.

```bash
echo 0 > /proc/sys/kernel/nmi_watchdog      # frees a PMU counter; restored afterwards
perf record -e cycles:u -j any,u -c 400009 \
    -C 96-159 -m 128M --proc-map-timeout 5000 -o perf-afdo.data -- sleep 180
perf inject -f --build-ids -i perf-afdo.data -o perf-afdo.inj.data
create_gcov --binary=/opt/g15-pg18-prep/bin/postgres --profile=perf-afdo.inj.data \
    --gcov=pg18-g15-hammerdb.afdo --gcov_version=2
```

Result: **`pg18-g15-hammerdb.afdo`, 2,278,802 bytes, 2,357 functions**, recorded while the server
was doing **1,224,601 NOPM**.

**The capture must be per-CPU (`-C`), not per-process (`-p`)** — PostgreSQL forks a backend per
connection, so `-p` on the postmaster sees none of the work. On this EPYC part whole-system `-a`
LBR is **unsupported** (`PMU Hardware or event type doesn't support branch stack sampling`) but
**per-CPU `-C <cpulist>` works**. Both forms were verified before starting.

`perf inject` and `perf script` need **`-f`**: perf refuses files it does not own even under sudo,
and without it the `.afdo` comes out 0 bytes.

### 2.4 BOLT recording and rewrite

One recording per BOLT input, never shared — `perf2bolt` matches samples by address.

```bash
perf record -b -z1 --aio=4 -c 100003 -e branches:u \
    -C 96-159 -m 128M --proc-map-timeout 5000 -o perf-bolt-<arm>.data -- sleep 180
```

| | `pgoltoq` | `afdoltoq` |
|---|---|---|
| NOPM during recording | 1,261,935 | 1,259,938 |
| `.fdata` | 2,869,265 B | 2,567,324 B |
| **Functions with a profile** | **2,106 / 20,924 = 10.1%** | **1,882 / 15,009 = 12.5%** |
| **Taken branches after rewrite** | **−20.3%** | **−39.0%** |

```bash
perf2bolt -p perf-bolt-<arm>.data -o <arm>.fdata ./postgres   # input must be named "postgres"

llvm-bolt ./postgres -o postgres.bolt -data=<arm>.fdata \
  -reorder-blocks=ext-tsp \
  -reorder-functions=cdsort \
  -split-functions -split-all-cold -split-eh \
  -dyno-stats --update-debug-sections
```

Gates enforced: input must carry `.rela.text` and must **not** already carry `.note.bolt_info`;
`.fdata` > 500 KB; output must carry `.note.bolt_info`. Each BOLTed binary is installed into a
copy of its input's prefix so the libraries come from the same compile.

> **Trap worth knowing:** `readelf -S x | grep -q PATTERN` under `set -o pipefail` is a race.
> `grep -q` exits on the first match, `readelf` takes SIGPIPE and returns 141, and the pipeline
> reports failure even though the section exists. This produced a bogus "no `.rela.text`" that
> blocked both rewrites. Capture the output to a variable and match on that instead.

---

## 3. Test results

4 arms × 6 load points × **8 mirrored passes** (`base afdoltob pgolto pgoltob | pgoltob pgolto
afdoltob base`), one server lifetime per pass, dataset restored interleaved before each. Rampup
scales with VU (2/2/3/4/6/10 min) because HammerDB logs vusers in at ~2/second, then 3 min
measured. Raw output in [`results/wholebox-48xl/`](results/wholebox-48xl/).

**Mean NOPM (mean of the two mirrored passes)**

| VU | box busy | base | afdoltob | pgolto | pgoltob |
|---|---:|---:|---:|---:|---:|
| 32 | 3.3% | 644,798 | **666,438** | 654,690 | 652,635 |
| 64 | 8.7% | 1,167,124 | **1,222,830** | 1,207,512 | 1,208,143 |
| 128 | 21% | 2,059,883 | **2,182,569** | 2,170,809 | 2,172,186 |
| 256 | 32% | 2,241,874 | **2,288,409** | 2,265,252 | 2,275,369 |
| 512 | 51% | 2,202,199 | **2,277,025** | 2,271,298 | 2,260,751 |
| 1024 | 54% | 2,055,715 | **2,117,700** | 2,063,968 | 2,080,068 |

**Percent versus base**

| VU | afdoltob | pgolto | pgoltob |
|---|---:|---:|---:|
| 32 | +3.36% | +1.53% | +1.22% |
| 64 | +4.77% | +3.46% | +3.51% |
| 128 | +5.96% | +5.39% | +5.45% |
| 256 | +2.08% | +1.04% | +1.49% |
| 512 | +3.40% | +3.14% | +2.66% |
| 1024 | +3.02% | +0.40% | +1.18% |
| **mean of 6 rungs** | **+3.76%** | +2.49% | +2.59% |
| CPU per transaction | −10.5% | −12.9% | −11.3% |

**`afdoltob` leads at every single rung.** That is a cleaner result than the Intel leg, where the
ordering changed with load.

Data quality: pass spreads **0.4–6%** at most rungs; 14–18% at 128 VU, which is a fully explained
placement effect rather than noise — see §5. Zero error lines on every rung, and every rung logged
its full VU count.

### 3.1 Against Intel

| | Intel r8i | AMD r8a |
|---|---:|---:|
| best arm | **pgoltob +11.95%** | **afdoltob +3.76%** |
| second | pgolto +8.88% | pgoltob +2.59% |
| third | afdoltob +8.50% | pgolto +2.49% |
| base peak NOPM | 2,388,763 @ 512 VU | 2,241,874 @ 256 VU = **93.9%** |

base NOPM, AMD as a share of Intel per rung: 45.8% / 57.2% / **105.6%** / **112.0%** / 92.2% /
87.0% at 32…1024 VU. **AMD trails badly at light load and is ahead of Intel in the mid-range**,
finishing within 6% at peak. So this is not a slower machine; it is a machine that responds far
less to FDO.

Note the Intel per-VU figures in that repo are **hand placement-matched pairs**, not straight
mirrored means (its naive means were confounded). The AMD figures above are straight means from
data where the mirror balanced placement by construction — see §5.

---

## 4. Why the gain is small: saturation, not the profile

| | |
|---|---|
| CPU per transaction | **−10.5 to −12.9%** — comparable to Intel |
| Box busy, by rung | 3.3% · 8.7% · 21% · 32% · 51% · **54% max** |

FDO is doing its job: it removes 11–13% of the CPU cost of every transaction. There is simply no
throughput headroom to convert that into, because nothing on this machine is CPU-bound at any
point on the ladder. This matches the pattern seen across this campaign family — the gain only
materialises once the server is actually CPU-bound.

It is also the **opposite** mechanism from the MySQL leg on this same box, which is worth keeping
straight:

| | MySQL on AMD | PostgreSQL on AMD |
|---|---|---|
| Did FDO reduce work? | barely — CPU/txn −2.8% | **yes — −11.3%** |
| Was the box saturated? | **yes — 86–92%** | no — 32% at peak |
| Limiting factor | no front-end stall left to reclaim (3.9% of cycles vs Intel's 16.5% of slots) | no throughput headroom |
| Result | +2.11% | +3.76% |

**If this is revisited, drive the box harder before drawing conclusions about magnitude** — more
VU, or pin to a single node so the cell becomes CPU-bound.

---

## 5. The 128 VU placement confound — root-caused

Pass spreads are 0.4–6% at most rungs but **14–18% at 128 VU for every arm**. That is not noise.

Reserving huge pages globally **splits them evenly across both sockets**:

```
echo 201 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
  → node0: 101    node1: 100
```

So `shared_buffers=192GB` straddles both nodes (~96 GB each), while at the low rungs the CPU load
sits almost entirely on node 1 (at 128 VU `n0 = 0.4%` vs `n1 = 38.5%`). Roughly half of
`shared_buffers` is therefore remote at **distance 32 vs 10 — a 3.2× penalty** — and how much is
remote varies between passes.

The correlation across all eight passes is perfect (`numastat -p`, postgres MB n0/n1):

| regime | passes | 128 VU NOPM |
|---|---|---|
| `n0=3` — memory on node 1, co-located with the load | 01-base, 02-afdoltob, 04-pgoltob, 06-pgolto | **2.24–2.34 M** |
| `n0=19` — split toward node 0 | 03-pgolto, 05-pgoltob, 07-afdoltob, 08-base | **1.88–2.03 M** |

Cost to the base arm: **16.2%**. Variance tracks the CPU-vs-memory mismatch exactly — worst at
128 VU (0.4/38.5), smallest at 512 and 1024 VU where both nodes are busy and the load matches the
symmetric memory pool.

**The mirrored design cancelled it by construction** — every arm received exactly one pass of each
regime (base 01/08, afdoltob 02/07, pgolto 06/03, pgoltob 04/05). Placement-matched at 128 VU:

| arm | fast regime | slow regime | naive mean |
|---|---:|---:|---:|
| afdoltob | **+4.32%** | **+7.91%** | +5.96% |
| pgoltob | +4.04% | +7.13% | +5.45% |
| pgolto | +3.87% | +7.19% | +5.39% |

`afdoltob` leads in both regimes independently and the naive mean falls between them, so the
headline ordering is sound and the rung should be kept.

Secondary finding: **FDO gains roughly double under bad placement** (+7–8% vs +4%). When the
machine is paying cross-socket latency, cheaper code per transaction is worth more — the same
direction as the saturation argument.

**Fix for a rerun:** reserve per-node and pin, rather than relying on the mirror to average it out:

```bash
echo 192 > /sys/devices/system/node/node1/hugepages/hugepages-1048576kB/nr_hugepages
```

---

## 6. Binaries

All four arms ship whole (install prefixes), small enough to need no splitting. See
[`binaries/`](binaries/) for checksums.

| arm | `postgres` md5 | archive | size |
|---|---|---|---|
| `base` | `8a6f660c783d` | `pg18-amd-base.tar.xz` | 7,549,048 |
| `pgolto` | `4b0fa228ba8d` | `pg18-amd-pgolto.tar.xz` | 12,202,920 |
| **`pgoltob`** | **`ce4deabc25a0`** | `pg18-amd-pgoltob.tar.xz` | 39,158,684 |
| **`afdoltob`** | **`5d576b3db66e`** | `pg18-amd-afdoltob.tar.xz` | 38,036,904 |

These are **`znver5`** builds and will not run on an Intel host.

[`profiles/`](profiles/) carries `pg18-g15-hammerdb.afdo`, both BOLT `.fdata`, and the PGO
`.gcda` tarball, so any arm can be rebuilt without repeating the ~1 h of training and recording
runs. Note a `.fdata` is bound to the exact ELF it was recorded against, so it applies only to a
`*q` twin built by the same `pg-build.sh` invocation.

---

## 7. A note on reproducing the Intel leg

The published `postgres-pgo-lto-bolt` **cannot be reproduced end to end as shipped.** Its scripts
reference nine files that are not committed — `pg-run-sweep.tcl.in`, `pg-dataset.sh`,
`pg-schema.sh`, `pg-sweep.sh`, `pg-hugepages.sh`, `pg-afdo.sh`, `collect-profile-c.sh`,
`STAMP.tcl`, `TS.tcl` — and it ships no `postgresql.conf` for the HammerDB boxes, only for a
separate sysbench sweep. Its sysbench harness is complete; the HammerDB one that produced the
headline +10–12% is not.

[`scripts/`](scripts/) here therefore contains a complete working HammerDB harness written for
this campaign and worth back-porting: `pg-amd.conf`, `pg-env.sh`, `pg-srv-amd.sh`
(hugepages/init/start/stop/golden/restore-il), `pg-schema.tcl.in`, `pg-point.tcl.in`,
`pg-ds-build.sh`, `pg-train-amd.sh`, `pg-rec-amd.sh`, `pg-bolt-amd.sh`, `pg-bench-wb.sh`. The
Intel originals they derive from are included alongside for provenance. The ladder driver
deliberately emits the MySQL leg's artifact layout so the 2-NUMA-node `report-wb.sh` works on it
unchanged.

### The one trap that will cost you a day

**`pg_storedprocs` must be set at SCHEMA BUILD time, not just at run time.** `pgoltp.tcl:32-33`:

```tcl
proc CreateStoredProcs { lda ora_compatible citus_compatible pg_storedprocs }
    if { $pg_storedprocs eq "true" } { ... }
```

It gates whether `buildschema` creates **CALL-able PROCEDUREs (33 args)** or plain **FUNCTIONs
(10 args)**. Set it only at run time and the driver calls procedures that do not exist:

```
ERROR: procedure payment(integer, integer, ...) does not exist
```

Every transaction fails, the run reports **0 NOPM**, and the only visible symptoms are vusers
"FINISHED FAILED" plus `Procedure Error set RAISEERROR for Details` — because HammerDB defaults
`RAISEERROR` off. It silently poisoned a complete PGO training run here; the giveaway was `user
2m24s` of CPU for a 14-minute run, against `22m17s` when healthy.

Gate on `prokind='p'` / `pronargs=33` **and** on training NOPM before building anything from a
profile.

---

## Cross-architecture comparison

[`COMPARISON.md`](COMPARISON.md) sets this leg against the other two PostgreSQL legs of this
campaign (Intel / AMD / Graviton) on identical PostgreSQL 18.3 + gcc 15.2.0 builds and the same
1,536 warehouse HammerDB TPROC-C workload. The same file is in all three repositories.
