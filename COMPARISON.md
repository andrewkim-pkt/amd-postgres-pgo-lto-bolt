# PostgreSQL 18.3 + gcc 15.2.0: FDO across Intel, AMD and Graviton

This file is identical in all three PostgreSQL legs of this campaign, so they cannot disagree about
the comparison:

| leg | repository |
|---|---|
| Intel | [`postgres-pgo-lto-bolt`](https://github.com/andrewkim-pkt/postgres-pgo-lto-bolt) (its gcc 15.2.0 section; the gcc 14.2.1 data there is a different campaign and is not used here) |
| AMD | [`amd-postgres-pgo-lto-bolt`](https://github.com/andrewkim-pkt/amd-postgres-pgo-lto-bolt) |
| Graviton | [`graviton-postgres-pgo-lto-bolt`](https://github.com/andrewkim-pkt/graviton-postgres-pgo-lto-bolt) |

**Every number below is copied from those repositories, not recomputed.** Nothing here is new
measurement; this is the cross-reading.

## What is held constant

HammerDB 4.7 TPROC-C, **1,536 warehouses**, whole box unpinned, mirrored passes, one server
lifetime per pass, datadir on **tmpfs** (so no storage I/O), `shared_buffers` on **1 GiB huge
pages**, `jit = off`. PostgreSQL **18.3** at commit `62d6c7d3df6` / tree `eacca3d098ca` — stock
upstream, same tree hash on all three. gcc **15.2.0** built from source on each host.
`llvm-bolt`/`perf2bolt` **18.1.3** and autofdo `create_gcov` at `f95d1a1` where those stages exist.
The **same r7i.24xlarge client** drove all three, so the load generator is not a variable.

Each leg's `postgresql.conf` body is byte-identical to the others' (diff-verified), so these are
compiler comparisons rather than configuration comparisons.

---

## 1. Platform and result

| | **Intel r8i.metal-48xl** | **AMD r8a.metal-48xl** | **Graviton r8g.metal-48xl** |
|---|---:|---:|---:|
| CPU | Xeon 6975P-C | EPYC 9R45 (Zen 5) | Graviton 4 (Neoverse V2) |
| physical cores / threads | **96 / 192 (SMT)** | 192 / 192 | 192 / 192 |
| NUMA nodes | 3 | 2 | 2 |
| L3 per socket | 480 MiB | 384 MiB | **36 MiB** |
| arms / mirrored passes | 4 / 8 | 4 / 8 | 3 / 6 |
| | | | |
| **best available arm** | **`pgoltob` +11.95%** | **`afdoltob` +3.76%** | **`pgolto` +2.28%** |
| `pgoltob` (PGO + LTO + BOLT) | **+11.95%** | +2.59% | **impossible** |
| `pgolto` (PGO + LTO) | +8.88% | +2.49% | +2.28% |
| `afdoltob` (AutoFDO + LTO + BOLT) | +8.50% | +3.76% | **impossible** |
| `pgo` (PGO only, no LTO) | not run | not run | +1.40% |
| | | | |
| AutoFDO possible? | yes — LBR, 32-deep | yes — `amd_lbr_v2`, 16-deep | **no** |
| BOLT possible? | yes | yes | **no** |
| | | | |
| base peak NOPM | 2,388,763 @ 512 VU | 2,241,874 @ 256 VU | 2,034,025 @ 256 VU |
| as % of Intel peak | 100% | 93.9% | 85.2% |
| **peak NOPM per physical core** | **24,883** | 11,676 | 10,594 |

All percentages are means over the six VU counts, each arm versus its own box's `base`.

## 2. `pgolto` per rung — the only arm present on all three

| VU | Intel | AMD | Graviton |
|---|---:|---:|---:|
| 32 | +7.99% | +1.53% | +1.75% |
| 64 | +2.62% | +3.46% | +0.10% |
| 128 | +6.83% | +5.39% | +2.49% |
| 256 | **+19.15%** | +1.04% | +1.91% |
| 512 | +8.46% | +3.14% | *+3.91%* |
| 1024 | +8.21% | +0.40% | +3.49% |
| **mean** | **+8.88%** | **+2.49%** | **+2.28%** |

## 3. Best arm per rung

| VU | Intel `pgoltob` | AMD `afdoltob` | Graviton `pgolto` |
|---|---:|---:|---:|
| 32 | +8.73% | +3.36% | +1.75% |
| 64 | +7.97% | +4.77% | +0.10% |
| 128 | +11.98% | +5.96% | +2.49% |
| 256 | **+25.11%** | +2.08% | +1.91% |
| 512 | +8.74% | +3.40% | *+3.91%* |
| 1024 | +9.17% | +3.02% | +3.49% |
| **mean** | **+11.95%** | **+3.76%** | **+2.28%** |

## 4. base NOPM per rung — machine capability with no FDO

| VU | Intel | AMD | AMD % of Intel | Graviton | Graviton % of Intel |
|---|---:|---:|---:|---:|---:|
| 32 | 1,408,256 | 644,798 | 45.8% | 596,863 | 42.4% |
| 64 | 2,040,296 | 1,167,124 | 57.2% | 1,063,077 | 52.1% |
| 128 | 1,950,717 | 2,059,883 | 105.6% | 1,848,701 | 94.8% |
| 256 | 2,001,653 | 2,241,874 | 112.0% | 2,034,025 | **101.6%** |
| 512 | **2,388,763** | 2,202,199 | 92.2% | 1,936,343 | 81.1% |
| 1024 | 2,364,134 | 2,055,715 | 87.0% | 1,647,868 | 69.7% |

Both non-Intel boxes show the same shape — well behind Intel at light load, level or ahead in the
mid-range, behind again at high VU. **Neither is simply a slower machine. They are machines that
respond far less to FDO.**

---

## 5. Reading the result

### 5.1 The winning arm flips twice

Instrumented PGO + LTO + BOLT wins on Intel; **AutoFDO** + LTO + BOLT wins on AMD; and on Graviton
LTO adds so little over plain PGO (+2.28% vs +1.40%) that the difference sits inside the pass
spreads. A pipeline tuned on one vendor should not be assumed to rank the same on another.

### 5.2 Graviton's ceiling is structural, not a measurement gap

AutoFDO (`create_gcov`) and BOLT (`perf2bolt`) both need LBR-style **from→to branch records**.
Graviton 4 exposes none — the kernel refuses `PERF_SAMPLE_BRANCH_STACK` for this PMU, and ARM SPE
produces single-address operation samples whose `perf script -F brstack` output is empty. So two of
the four arms cannot be built there at all. Intel's extra ~3 points from BOLT and AMD's winning
AutoFDO arm are **unavailable on Graviton, not merely unmeasured**.

```
$ perf record -e cycles:u -j any,u -- sleep 1 && echo supported
```

Ten-second capability check for any machine.

### 5.3 The leading explanation is saturation, and core count drives it

Each non-Intel leg reached the same conclusion independently, and in both cases the profile is
demonstrably doing its job — the machine just has no CPU shortage to relieve:

| | evidence published in that leg |
|---|---|
| **AMD** | CPU per transaction falls **10.5–12.9%**, comparable to Intel, yet the box peaks at **54% busy**. |
| **Graviton** | At 256 VU `pgolto` executes **23.7% fewer instructions and 27.0% fewer branches per new order** — a *larger* work reduction than FDO achieved for MySQL on the same box — for **+0.09%** throughput. `cpu-clock` sampling puts **56–60% of wall clock in the kernel idle loop**, and the box never passes 58% busy. |

Core count is the likely driver. **Intel reaches the highest absolute throughput from half the
physical cores** — 2.1× per core — so the same workload actually loads it, while AMD and Graviton
have 192 real cores to fill and never become CPU-bound anywhere on the ladder.

**This is inference, not measurement, on the Intel side.** The Intel HammerDB leg published neither
box-busy % nor CPU per transaction, so the two cells that would confirm the mechanism on the
reference machine are missing. Closing that would take a short Intel 48xl re-run with CPU sampling
enabled.

### 5.4 The sharpest single data point

The Graviton leg ran **MySQL and PostgreSQL on the same box, same compiler, same dataset size, same
client, same day**. MySQL saturates it (80.7% → 91% busy) and gains **+12.59%**; PostgreSQL peaks at
48% busy and gains **+1.95%**. With architecture held constant and only the database changing, that
is the cleanest statement in this campaign that **FDO gain tracks how CPU-bound the server is, not
the CPU vendor.**

---

## 6. Caveats — read before quoting

1. **Run shape differs between legs.** Intel used a fixed **2 min rampup + 5 min measured**; AMD and
   Graviton used **adaptive rampup (2/2/3/4/6/10 min) + 3 min measured**. The adaptive rule exists
   because HammerDB logs vusers in at roughly 2/second, so a fixed 2 min leaves the 256+ VU rungs
   still connecting while the measurement is running. It applies equally to every arm within a box,
   so each box's percentages are internally sound — but it makes Intel's high-VU rungs not directly
   comparable to the other two. **Intel's +19.15% / +25.11% at 256 VU is the most suspicious cell in
   these tables, for exactly this reason.**
2. **Intel's per-VU figures are hand placement-matched pairs**, not straight mirrored means; that
   leg found its naive means confounded by tmpfs page placement. AMD's and Graviton's are straight
   means from data where the mirror balanced placement by construction.
3. **Each non-Intel leg has one unreliable rung, and they are handled differently.** AMD's 128 VU
   rung had 14–18% pass spreads from a root-caused placement confound and was **kept** in its mean.
   Graviton's 512 VU rung (italicised above) has 12–14% spreads in all three arms including `base`,
   is bimodal, and remains unexplained. The **+2.28%** used here is Graviton's 6-rung mean, chosen to
   match the other two legs' methodology; **excluding the 512 rung gives +1.95%, which is that leg's
   preferred headline.**
4. **Arm and pass counts differ**: 4 arms over 8 mirrored passes on Intel and AMD, 3 arms over 6 on
   Graviton.
5. **Absolute NOPM is comparable here only because all three ran 1,536 warehouses.** Elsewhere in
   these repositories the warehouse count scales with machine size, and absolute NOPM must not be
   compared across those.
6. **`cli%` in any leg's results is contaminated** (~20%) by a CPU-activity guard that prevents
   idle auto-shutdown. Do not quote it. On the Graviton PostgreSQL leg that guard also ran on the
   **server** during the ladder, which inflates its absolute box-busy figures by roughly 2.6 points;
   it was present identically in all six passes, so the arm-to-arm comparison is unaffected, and the
   perf capture was re-run with it stopped and verified clean.

## 7. One cross-leg reading trap

On both the MySQL and PostgreSQL Graviton legs, **LTO inlines the lock-acquisition function into its
callers**, so a naive symbol-by-symbol profile diff reports a collapse that is not a win:

| leg | base | `pgolto` | what actually happened |
|---|---|---|---|
| PostgreSQL | `LWLockAcquire` 10.09% | 0.23% | `__aarch64_cas4_acq_rel` rises 7.32% → 18.24%; the **pair is conserved** (17.41% → 18.47%) |
| MySQL | `ut_delay` 19.87% | absent | inlined into `rw_lock_sx_lock_func`, which rises 1.74% → 24.28% |

**Sum the pair before comparing arms.** The same applies to the Intel MySQL leg, where `ut_delay`
folds into `rw_lock_sx_lock_func` identically.
