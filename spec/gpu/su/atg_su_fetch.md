# atg_su_fetch

RTL: `rtl/gpu/su/atg_su_fetch.v`.  Parent: atg_su.  Implemented in: p008.

## 1. Purpose and place

Instruction fetch: takes a (warp, pc, address) from the scheduler, reads the 64-bit instruction from the I$ and hands it to the decoder.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `WARP_W` | `2` | log2(NWARPS). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **From atg_su_sched** | | | |
| `f_valid` | in | 1 | Fetch request. |
| `f_ready` | out | 1 | Taken. |
| `f_warp` | in | WARP_W | Warp. |
| `f_pc` | in | 16 | pc. |
| `f_addr` | in | 32 | Byte address (8-byte aligned). |
| **I$ port (atg_su_icache)** | | | |
| `ic_req` | out | 1 | Read the instruction at ic_addr. |
| `ic_ready` | in | 1 | Taken. |
| `ic_addr` | out | 32 | Address. |
| `ic_rvalid` | in | 1 | The instruction (in request order). |
| `ic_rdata` | in | 64 | word0 in [31:0], word1 in [63:32]. |
| **To atg_su_dec** | | | |
| `d_valid` | out | 1 | Instruction. |
| `d_ready` | in | 1 | Taken. |
| `d_warp` | out | WARP_W | Warp. |
| `d_pc` | out | 16 | pc. |
| `d_instr` | out | 64 | Instruction. |

17 ports.

## 4. Behaviour

A small queue of in-flight fetches (depth 2) keeps {warp, pc} in order with the I$ responses; f_ready when there is room.

## 5. State machine

None (two-entry queue).

## 6. Latency and throughput

One instruction per cycle on I$ hits (I$ latency 1).

## 7. Corner cases and errors

- I$ misses stall the queue (all warps: the I$ is blocking in v1).

## 8. What the TB checks

`sim/tb/atg_su_fetch_tb.v` prints, in this order:

- `PASS atg_su_fetch.order` — random hit/miss latencies: instructions leave with their own warp and pc
- `PASS atg_su_fetch` at the end.

## 9. References

design §3.5 (I$), §3.3 (64-bit instructions).

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/atg_su_fetch_tb.v`).
