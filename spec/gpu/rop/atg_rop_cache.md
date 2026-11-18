# atg_rop_cache

RTL: `rtl/gpu/rop/atg_rop_cache.v`.  Parent: `atg_rop` / `atg_rop_wb`.  Implemented in: ws001-p017.

## 1. Purpose and place

A 4-way set-associative L1 tile cache for ROP rendering (Color / Depth attachments).
Replaces small write-combining buffers with an 8 KiB on-chip cache structure to eliminate external memory thrashing during triangle rasterization.
Infers 7-series RAMB36E1 block RAM for data lines with per-byte write enables, delivering sustained 1-cycle hit access and hiding DRAM latency.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `LINE_BYTES` | `64` | Cache line size in bytes (1 AMB burst beat / line). |
| `WAYS` | `4` | Associativity (4-way set-associative). |
| `SETS_LOG2` | `5` | Log2 of the number of sets (32 sets -> 32 × 4 × 64B = 8 KiB capacity). |

## 3. Ports

Clock/reset domain: `clk` (gclk), synchronous reset `rst_n` (active low).

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **ROP pipeline interface** | | | |
| `req_valid` | in | 1 | Request valid. |
| `req_ready` | out | 1 | Ready to accept request (1 on hit or idle). |
| `req_write` | in | 1 | 1 = write, 0 = read. |
| `req_addr` | in | 32 | Byte address. |
| `req_be` | in | LINE_BYTES | Byte enables for writes. |
| `req_wdata` | in | LINE_BYTES*8 | Write data (64 bytes). |
| `rsp_valid` | out | 1 | Response valid (asserted 1 cycle after hit or refill). |
| `rsp_rdata` | out | LINE_BYTES*8 | Read data (64 bytes). |
| **External AMB / L2 memory bus** | | | |
| `mem_req_valid` | out | 1 | Memory access request. |
| `mem_req_ready` | in | 1 | Memory interface ready. |
| `mem_req_write` | out | 1 | 1 = eviction writeback, 0 = refill read. |
| `mem_req_line` | out | 26 | Line address (`req_addr >> 6`). |
| `mem_req_wdata` | out | LINE_BYTES*8 | Eviction writeback data. |
| `mem_rsp_valid` | in | 1 | Memory read data valid. |
| `mem_rsp_rdata` | in | LINE_BYTES*8 | Refill read data from memory. |
| **Flush & Status** | | | |
| `flush` | in | 1 | Trigger full dirty-line writeback. |
| `busy` | out | 1 | Asserted during miss refill, eviction, or flush. |

16 ports.

## 4. Behaviour

- **Parallel Tag Match**: 4-way parallel comparator checks `addr_tag` against all ways in `set_idx`.
- **Hit Access (1 cycle)**:
  - Read hit: Data read synchronously from `data_mem`, `rsp_valid` returned next cycle.
  - Write hit: Line updated with byte enable `req_be`, dirty bit set, Tree-PLRU updated.
- **Tree-PLRU Replacement**:
  - Uses 3 tree bits per set ($b_0, b_1, b_2$) to track pseudo-least-recently-used ways.
  - On eviction, selects non-accessed sub-trees to determine victim way without arithmetic operators.
- **Write-Back & Dirty Tracking**:
  - Modified lines remain in cache until evicted or flushed.
  - On eviction of a dirty line, `mem_req_write = 1` writes the full 64-byte line to memory before reading the new line.
- **Flush**: Iterates through all sets and ways, writing back all dirty lines until cache is fully clean.

## 5. What the TB checks

`sim/tb/atg_rop_cache_tb.v` prints:
- `PASS atg_rop_cache.hit`: Read and write hits streaming continuously at 1 cycle/req.
- `PASS atg_rop_cache.plru`: Filling all 4 ways of a set, triggering Tree-PLRU eviction, and confirming dirty line writeback to memory.
- `PASS atg_rop_cache.flush`: Flushing all remaining dirty lines to memory and ensuring `busy` drops to 0.
- `PASS atg_rop_cache` at the end.
