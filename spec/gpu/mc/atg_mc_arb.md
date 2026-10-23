# atg_mc_arb

RTL: `rtl/gpu/mc/atg_mc_arb.v`.  Parent: atg_mc.  Implemented in: p015 (split of atg_mc; the scaffold is in place).

## 1. Purpose and place

The MC's arbiter: one grant per cycle among the clients with a request; the HIGH_MASK clients by fixed priority (lowest number first), the others round-robin (design §4.1).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NCLIENT` | `2` | Clients (≤ 32). |
| `CW` | `1` | Client number width (clog2(NCLIENT), at least 1). |
| `HIGH_MASK` | `2'b01` | Fixed-priority clients (NCLIENT bits). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `req` | in | NCLIENT | Clients with a request (c_req_valid). |
| `hold` | in | 1 | Grant nothing (quiesce, or an error response waiting). |
| `gnt_valid` | out | 1 | A client is selected this cycle (combinational). |
| `gnt_idx` | out | CW | Its number. |
| `take` | in | 1 | The selected request is granted this cycle (the round-robin pointer moves past it). |
| `flush` | in | 1 | Return to the reset state (MC flush). |

8 ports.

## 4. Behaviour

The selection logic now inline in atg_mc (`sel`, `rr_next`), as a module.  A request is selected even under hold, but take is then 0 (atg_mc gates it).

## 5. State machine

None (a pointer).

## 6. Latency and throughput

Combinational select, 1 grant per cycle.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_mc_arb_tb.v` prints, in this order:

- `PASS atg_mc_arb.high` — high clients win in number order
- `PASS atg_mc_arb.rr` — others take turns; starvation-free among them
- `PASS atg_mc_arb` at the end.

## 9. References

design §4.1, the inline arbiter of rtl/gpu/mc/atg_mc.v, spec/gpu/mc/atg_mc.md.

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
