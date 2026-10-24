# atg_cp_fence

RTL: `rtl/gpu/cp/atg_cp_fence.v`.  Parent: atg_cp.  Implemented in: p004 (done).

## 1. Purpose and place

Writes fences and results to memory, polls WAIT_FENCE words, keeps FENCE_LAST and raises the FENCE interrupt; memory through the CP's AMB port.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `POLL` | `64` | WAIT_FENCE: cycles between two reads (1..255). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **HCR register snoop (from atg_cp_regs)** | | | |
| `hcr_we` | in | 1 | One-cycle write strobe to an HCR word (0x000-0xFFC). |
| `hcr_widx` | in | 10 | Word index of the write (byte offset >> 2). |
| `hcr_wdata` | in | 32 | Write data. |
| `hcr_wmask` | in | 32 | Bit mask from WSTRB (1 = written). |
| `hcr_ridx` | in | 10 | Word index being read; the read data is due in the same cycle (combinational from this registered index). |
| `hcr_rdata` | out | 32 | Read data of this module's registers at `hcr_ridx`, 0 for other indices (the parent ORs them). |
| **Requests (from atg_cp_seq)** | | | |
| `f_valid` | in | 1 | Request. |
| `f_ready` | out | 1 | Taken. |
| `f_op` | in | 2 | 0 FENCE, 1 RESULT, 2 WAIT_FENCE. |
| `f_addr` | in | 32 | Address (4-byte aligned; RESULT 8-byte). |
| `f_value` | in | 32 | Value / status. |
| `f_aux` | in | 32 | RESULT aux. |
| `f_irq` | in | 1 | Raise IRQ FENCE when written. |
| `f_busy` | out | 1 | Writes unanswered or a WAIT_FENCE not yet satisfied. |
| **Events** | | | |
| `ev_fence` | out | 1 | One-cycle pulse: a fence with f_irq was written (BRESP seen). |
| `fence_last` | out | 32 | FENCE_LAST (also to atg_cpu's window). |
| **Fault report to atg_cp_ctl (one source of its `src_*` vectors)** | | | |
| `fault` | out | 1 | One-cycle pulse: this module found a fault. |
| `fault_kind` | out | 4 | FAULT_INFO[15:12] kind (design §2.2), valid with the pulse. |
| `fault_addr` | out | 32 | FAULT_ADDR value (address or PC), valid with the pulse. |
| `fault_tag` | out | 8 | JOB_TAG of the command at fault, valid with the pulse. |
| **AMB client port (design §4.1)** | | | |
| `req_valid` | out | 1 | Request valid; payload held until `req_ready`. |
| `req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `req_write` | out | 1 | 1 write, 0 read. |
| `req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `req_tag` | out | 8 | The client's tag, returned with the response. |
| `rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `rsp_tag` | in | 8 | Tag of the request answered. |
| `rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |

34 ports.

## 4. Behaviour

- FENCE: write one word (byte enables of that word only) and, on the write response, set FENCE_LAST =
  value and pulse ev_fence if f_irq.  RESULT: write the two words {status, aux}.  WAIT_FENCE: read the
  word every POLL cycles (a fixed 64-cycle gap) until `(int32)(mem - value) >= 0`.
- FENCE_LAST (0x070) is also host-writable (snoop; the driver writes it back after RESET, design §2.5).
- Order: the sequencer has already waited for the blocks; this module waits for its own write
  responses before reporting (f_busy).

## 5. State machine

IDLE →(f_valid)→ WRITE (request) → WAIT_B →(rsp)→ IDLE; WAIT_FENCE: READ → WAIT_R → (cmp ok → IDLE | GAP → READ).

## 6. Latency and throughput

One fence per AMB write round trip.

## 7. Corner cases and errors

- rsp_error: fault kind 1 (aperture) with f_addr; nothing else is written; the unit stops (f_ready 0)
  until the core reset.  A WAIT_FENCE never satisfied is ended by the watchdog (the sequencer's
  cmd_active stays 1).
- `fault_tag` is 0 (the sequencer's fault report carries the command's tag; a fence error does not).

## 8. What the TB checks

`sim/tb/atg_cp_fence_tb.v` prints, in this order:

- `PASS atg_cp_fence.fence` — a fence writes the word, updates FENCE_LAST, pulses ev_fence only with f_irq
- `PASS atg_cp_fence.result` — RESULT writes two words with the right byte enables
- `PASS atg_cp_fence.wait` — WAIT_FENCE polls until the memory model reaches the value, including wrap-around
- `PASS atg_cp_fence.error` — an error response faults with the address
- `PASS atg_cp_fence` at the end.

## 9. References

design §2.4.3 (FENCE, RESULT, WAIT_FENCE), §2.5.

## 10. Status

Implemented (WS288 p004 (P3, amaterrace-gpu p3-cp 4a4d2da..65cc445, merged as a094748)).  182 lines, one FSM (IDLE, REQ, RSP, GAP, DEAD).  Spec change in p004: the
`POLL` parameter.  Measured only in simulation.
