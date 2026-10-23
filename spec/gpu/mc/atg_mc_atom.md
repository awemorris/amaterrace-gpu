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

Serial: read line → modify word → write line (byte enables of that word only) → respond.  Requesters round-robin.  Atomicity: other clients' plain writes to the same word between the read and the write are not excluded in v1 (the D$ is write-through and invalidated by atom; the compiler's memory model is per design §3.4.1).

## 5. State machine

IDLE → READ_REQ → READ_WAIT → WRITE_REQ → WRITE_WAIT → IDLE.

## 6. Latency and throughput

Two AMB round trips per atomic.

## 7. Corner cases and errors

- rsp_error on the read: no write, at_error.

## 8. What the TB checks

`sim/tb/atg_mc_atom_tb.v` prints, in this order:

- `PASS atg_mc_atom.ops` — all 11 operations
- `PASS atg_mc_atom.multi` — two requesters interleave correctly
- `PASS atg_mc_atom` at the end.

## 9. References

design §4.1 (atomic port), §3.4.1 (atom).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
