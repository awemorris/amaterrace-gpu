# atg_mc_atom

RTL: `rtl/gpu/mc/atg_mc_atom.v`.  Parent: atg_top (when NSU > 0).  Implemented in: p008.

## 1. Purpose and place

The MC's atomic unit: one read-modify-write at a time for the SUs' atomics (design §4.1): reads the line, applies the operation to one word, writes the line back, returns the old value.  An MC client of its own (placed next to atg_mc in atg_top).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 (ZYBO) or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `NATOM` | `1` | Requesters (one per SU). |
| `AW` | `1` | clog2(NATOM), at least 1. |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Atomic requests (packed, SU 0 in the low bits)** | | | |
| `at_valid` | in | NATOM | Request. |
| `at_ready` | out | NATOM | Taken. |
| `at_op` | in | NATOM*4 | Operation (atg_su_lsu's at_op). |
| `at_addr` | in | NATOM*30 | Word address. |
| `at_a` | in | NATOM*32 | Operand. |
| `at_b` | in | NATOM*32 | cmpxchg compare value. |
| `at_rsp_valid` | out | NATOM | Response to requester k. |
| `at_old` | out | 32 | Old value (shared). |
| `at_error` | out | 1 | Aperture error (shared). |
| `busy` | out | 1 | An operation is in progress. |
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

24 ports; 13 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Serial: read line → modify word → write line (byte enables of that word only) → respond.  Requesters round-robin: in IDLE the first valid requester after the one taken last gets `at_ready` (combinational, in that cycle); the payload is held by the requester until then.  The operation is the `atom` sub of docs/ghci.md §12.5: 0 and, 1 or, 2 xor, 3 xchg, 4 add, 5 sub, 6 smax, 7 smin, 8 umax, 9 umin, 10 cmpxchg (`at_a` is stored when the old word equals `at_b`); 11-15, which the SU never sends (atg_su_dec faults on sub above 10), store the old word back.  The written line carries the new word in every word position, with the byte enables of the addressed word only.  The response is a one-cycle pulse on the requester's `at_rsp_valid`, with `at_old` and `at_error` (shared, valid with the pulse), after the write's response, so the SU's cm counter covers the BRESP.  One AMB request is outstanding at a time, tag 0; the read's response is the one with `rsp_write` 0, the write's the one with `rsp_write` 1.  Atomicity: other clients' plain writes to the same word between the read and the write are not excluded in v1 (the D$ is write-through and invalidated by atom; the compiler's memory model is per design §3.4.1).

## 5. State machine

IDLE → READ_REQ → READ_WAIT → WRITE_REQ → WRITE_WAIT → IDLE.

## 6. Latency and throughput

Two AMB round trips per atomic, plus the cycle in IDLE that takes the request (about 5 cycles and the two latencies).

## 7. Corner cases and errors

- rsp_error on the read: no write; the response has at_error 1 and at_old 0 (the MC has raised the fault).
- rsp_error on the write: the response has at_error 1 and the old value (atg_su_lsu gives the lane 0 for either).

## 8. What the TB checks

`sim/tb/atg_mc_atom_tb.v` prints, in this order:

Two instances (NATOM 2; 32-byte and 64-byte lines) in front of sim/models/amb_mem.v (random ready and latency, an error region from 0x1000), against a shadow copy of memory updated in the order the unit takes the requests:

- `PASS atg_mc_atom.ops` — requester 0 alone: all 11 operations (and 11-15) with edge and random operands, cmpxchg equal and not equal, words anywhere in a line; requests in the error region give at_error, at_old 0 and no write; memory equals the shadow (only the word was written) and the number of writes equals the number of successful atomics
- `PASS atg_mc_atom.multi` — both requesters on 8 shared words in two lines, mostly offering the next request as soon as one is taken: each response goes to its requester with the old value of the order of taking, and when both are valid the other one than last time is taken (round-robin)
- `PASS atg_mc_atom` at the end.

The SU's atomics through this unit (behind am_amb_mux, sharing the D$'s memory) are checked by `sim/tb/atg_su_tb.v` (programs mem.s and reduce.s against tools/gsi1model.py).

## 9. References

design §4.1 (atomic port), §3.4.1 (atom).

## 10. Status

Implemented in WS288 p008 (branch p1-atom; TB `sim/tb/atg_mc_atom_tb.v`).  Ports and parameters unchanged.  Decided here (the spec was silent): round-robin from the requester after the last one taken; ops 11-15 store the old word back; rsp_error on the write gives at_error with the old value; at_old and at_error are shared registers valid with the pulse.  States as §5 (IDLE takes the request; an error on the read goes back to IDLE).  ADDR_W must be 32 (the word address is 30 bits).
