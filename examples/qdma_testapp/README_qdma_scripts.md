# qdma_testapp automation scripts

Scripts to run functional ST/MM checks and performance sweeps via `qdma_testapp --filename=...`.

Linux path (same files via Q: drive):

`/group/cdc_ir/members_noer/tjezeque/projects/samsung_2620/demo_2/dpdk_test_area/dpdk-stable/examples/qdma_testapp`

## Files

| Script | Purpose |
|--------|---------|
| `qdma_test_common.sh` | Shared functions (sourced, not run directly) |
| `qdma_st_mm_verify.sh` | 10 KiB ST then MM, H2C + C2H, `cmp` |
| `qdma_perf.sh` | Queue sweep, high iterations, Gbps summary CSV |
| `qdma_run_tests.sh` | `--verify`, `--perf`, or `--all` |
| `qdma_compare_pf_vf.sh` | **PF ST 10 KiB** — mirrors `test_pf_vf.sh` BW lines for qdma-pf vs DPDK |

## Compare DPDK vs qdma-pf (`test_pf_vf.sh`)

Replicates the **PF** section of `linux-kernel/test_pf_vf.sh`:

1. ST queue 0, ring depth **2048**, mbuf **4096**
2. H2C **10240** B → prints `size=10240 Average BW = … MB/sec`
3. **`delay 2`** (loopback settle, same as kernel `sleep 2`)
4. C2H **10240** B → same BW line
5. **`cmp`** on received file

**Rebuild testapp** after BW timing was added to `commands.c`:

```bash
make clean && make
```

Run (script **unbinds `qdma-pf`** before DPDK; **unbinds `vfio-pci`** before kernel):

```bash
export EAL_OPTS="-l 0-7 -n 4 -a 0000:c4:00.0"
sudo -E ./qdma_compare_pf_vf.sh c4:00.0
```

Optional back-to-back kernel run (unbinds vfio, then `test_pf_vf.sh` reloads `qdma-pf`):

```bash
export RUN_KERNEL_COMPARE=1
export LINUX_QDMA_DIR=/group/cdc_ir/.../dma_ip_drivers/QDMA/linux-kernel
sudo -E ./qdma_compare_pf_vf.sh
```

Results: `compare_summary.csv` under `/tmp/qdma_test.*` (set `KEEP_WORK_DIR=1`).

## Build (recommended)

```bash
# In Makefile add:
CFLAGS += -DPERF_BENCHMARK
make clean && make

# Optional PMD throughput tuning in drivers/net/qdma/meson.build:
# cflags += ['-DTHROUGHPUT_MEASUREMENT']
# then ninja + rebuild testapp
```

## Quick start (on Linux host)

```bash
cd /group/cdc_ir/members_noer/tjezeque/projects/samsung_2620/demo_2/dpdk_test_area/dpdk-stable/examples/qdma_testapp

chmod +x qdma_*.sh

# EAL options only — do NOT include "--" or --filename here
export EAL_OPTS="-l 0-7 -n 4 -a 0000:xx:00.0"
# Mbuf size for port_init (must match HW C2H buffer table, usually 4096)
export PKT_BUFF_SIZE=4096
# Total bytes per dma_to/from (can be 10240 = 3x4096 + remainder)
export SIZE=10240
# Minimal user block (no ST loopback): H2C-only ST verify
export ST_H2C_ONLY=1

sudo -E ./qdma_run_tests.sh --verify
./qdma_run_tests.sh --perf
./qdma_run_tests.sh --all
```

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `QDMA_TESTAPP` | `./build/qdma_testapp` | Binary path |
| `EAL_OPTS` | `-l 0-3 -n 4` | DPDK EAL arguments |
| `PORT_ID` | `0` | Logical port |
| `SIZE` | `10240` | Total DMA bytes per queue (H2C/C2H `size` argument) |
| `PKT_BUFF_SIZE` | `4096` | `port_init` mbuf size (must match QDMA buffer table) |
| `RING_DEPTH` | `1024` | Descriptor ring depth |
| `CARD_ADDR` | `0` | MM destination/source offset |
| `ITERATIONS` | `0` | Verify mode DMA loops |
| `PERF_ITERATIONS` | `10000` | Perf mode DMA loops |
| `PERF_QUEUES` | `1 4 8 16` | Queue counts to sweep |
| `KEEP_WORK_DIR` | `0` | Set `1` to keep `/tmp/qdma_test.*` |
| `ST_H2C_ONLY` | `0` | Set `1` to skip ST `dma_from_device`/`cmp` (no user BAR/loopback) |
| `LOOPBACK_DELAY` | `2` | Seconds between H2C and C2H in `qdma_compare_pf_vf.sh` |
| `RING_DEPTH` | `1024` (`2048` in compare script) | Descriptor ring depth for `port_init` |
| `RUN_KERNEL_COMPARE` | `0` | `1` = also run `test_pf_vf.sh` after DPDK |

## Perf output

- `${WORK_DIR}/perf_summary.csv`
- **wall_gbps**: total H2C+C2H bytes / wall time
- **peak_log_gbps**: max from log (requires `-DPERF_BENCHMARK`)

## Troubleshooting

| Symptom | Cause | Fix |
|---------|--------|-----|
| `invalid option -- 'l'` | EAL opts after `--`, or broken `EAL_OPTS` | `export EAL_OPTS="-l 0-7 -n 4 -a BDF"`; `sudo -E ./qdma_run_tests.sh ...` |
| `Expected buffer size 10240 not found` | mbuf size not in HW table | `export PKT_BUFF_SIZE=4096` (keep `SIZE=10240`) |
| MM `write-back monitor timeout` | No target memory on card | Check BRAM/DDR map; `CARD_ADDR=0` |
| `Floating point exception` | Crash after failed setup / PERF divide-by-zero | Fix EAL + buffer size; verify without `-DPERF_BENCHMARK` |
| ST `cmp` FAIL / `set_immediate_data_state` failed | No user BAR / dead BAR reads `0xffffffff` | `ST_H2C_ONLY=1` or fix user logic; use MM for round-trip |

## Hardware notes

- **ST**: needs loopback or user logic for `cmp` to pass.
- **MM**: needs valid on-card memory at `CARD_ADDR`.
