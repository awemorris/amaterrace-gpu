# atg_rx_order

RTL: `rtl/gpu/rx/atg_rx_order.v`.  Parent: atg_rx.  Implemented in: p007.

## 1. Purpose and place

Hands out the fragment sequence numbers in primitive order (design §3.8) and tells the ROP which numbers exist.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `sq_req` | in | 1 | Request. |
| `sq_seq` | out | 16 | Number (combinational, the current counter). |
| `ord_valid` | out | 1 | A number was issued (one-cycle). |
| `ord_seq` | out | 16 | It. |

6 ports.

## 4. Behaviour

A 16-bit counter reset by the core reset; sq_seq = counter, incremented on sq_req; ord_* echo each issue for the ROP's scoreboard.  Several RX bands (p015) get one counter each.

## 5. State machine

None.

## 6. Latency and throughput

1 cycle.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_rx_order_tb.v` prints, in this order:

- `PASS atg_rx_order.seq` — consecutive numbers and wrap
- `PASS atg_rx_order` at the end.

## 9. References

design §3.8 (ROP order).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
