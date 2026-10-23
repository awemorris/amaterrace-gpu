# atg_cpu_mem

RTL: `rtl/gpu/cp/atg_cpu_mem.v`.  Parent: atg_cpu.  Implemented in: p017.

## 1. Purpose and place

IMEM and DMEM of the CP's CPU (block RAMs with initial images from $readmemh), with a fetch port, a data port and a DMA port for the firmware load and the CPU's line DMA.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `IMEM_WORDS` | `8192` | IMEM size in 32-bit words (32 KiB). |
| `DMEM_WORDS` | `4096` | DMEM size in words (16 KiB). |
| `IMEM_INIT` | `""` | $readmemh file of the IMEM image ("" = none). |
| `DMEM_INIT` | `""` | $readmemh file of the DMEM image. |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| **Fetch (atg_cpu_core)** | | | |
| `i_en` | in | 1 | Read. |
| `i_addr` | in | 32 | Byte address in IMEM. |
| `i_rdata` | out | 32 | Word, next cycle. |
| **Data (from atg_cpu_win)** | | | |
| `d_en` | in | 1 | Access. |
| `d_we` | in | 4 | Byte write enables (0 = read). |
| `d_addr` | in | 32 | Byte offset in DMEM. |
| `d_wdata` | in | 32 | Data. |
| `d_rdata` | out | 32 | Word, next cycle. |
| **DMA (from atg_cpu_dma)** | | | |
| `x_en` | in | 1 | Access. |
| `x_we` | in | 1 | Write a whole word. |
| `x_imem` | in | 1 | 1 IMEM, 0 DMEM. |
| `x_addr` | in | 32 | Byte offset. |
| `x_wdata` | in | 32 | Data. |
| `x_rdata` | out | 32 | Word, next cycle (DMEM only; IMEM reads 0). |

15 ports.

## 4. Behaviour

- IMEM: port A fetch, port B DMA writes (firmware load).  DMEM: port A data, port B DMA.
- No reset of the contents (BRAM): the firmware's boot.S copies .data from the image's initial-value
  area at each start (design §2.4.7, the restart rule).

## 5. State machine

None.

## 6. Latency and throughput

One access per port per cycle, read latency 1.  BRAM36: IMEM 8 + DMEM 4 at the defaults.

## 7. Corner cases and errors

- Addresses beyond the size wrap (the core faults fetches outside IMEM before they get here).
- Reads are read-first (a write returns the old word); each read output holds until the next
  enabled read of its port (atg_cpu_core relies on this for i_rdata).
- The two ports of one RAM writing (or one writing, one reading) the same word in the same cycle
  is undefined; the users never do it (the DMA writes IMEM only with the core in reset, and the
  firmware does not touch a DMEM buffer while its DMA runs).

## 8. What the TB checks

`sim/tb/atg_cpu_mem_tb.v` prints, in this order:

- `PASS atg_cpu_mem.init` — the init files appear in IMEM and DMEM (checked first, before writes)
- `PASS atg_cpu_mem.ports` — the three ports read and write independently; byte enables work
- `PASS atg_cpu_mem` at the end.

## 9. References

design §2.4.7 (IMEM 32 KiB, DMEM 16 KiB, $readmemh, CPFW reload).

## 10. Status

Implemented in WS288 p017 (P2, branch p2-cpu); `sim/tb/atg_cpu_mem_tb.v` passes (IMEM 64 /
DMEM 32 words with `sim/tb/cpu/mem_init_*.hex`).  p017 spec changes: §7 (read-first, held output,
same-word collisions), §8 order.
