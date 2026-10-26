# am_axi_idtrack

RTL: `rtl/library/bus/am_axi_idtrack.v`.  Parent: `am_axi_split` (instances `wtr`, `rtr`).  Children: one `am_addsub` per ID.  Written in WS288 p039 (2026-10-25).

## 1. Purpose and place

The AXI transactions of one direction in flight, per ID: a count and the destination of each ID's transactions, and whether a new one of a given ID may go to a given destination (AXI's same-ID order across two slaves).

## 2. Parameters

`ID_W` (1: 2^ID_W IDs), `CNT_W` (3: up to 2^CNT_W − 1 in flight per ID).

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | Clock, synchronous reset (all counts 0) |
| `take`, `take_id`, `take_dst` | in | 1, ID_W, 2 | A transaction was taken (one cycle) with its ID and destination |
| `done`, `done_id` | in | 1, ID_W | A transaction of that ID was answered (one cycle) |
| `q_id`, `q_dst` | in | ID_W, 2 | The question: a transaction of this ID to this destination |
| `ok` | out | 1 | Combinational: none of q_id in flight, or all at q_dst, and its count below 2^CNT_W − 1 |

## 4. Behaviour

The count of an ID goes up on `take` and down on `done`; both in one cycle leave it.  The destination is that of the last `take` of the ID.

## 5. State machine

None.

## 6. Latency and throughput

`ok` is combinational; one take and one done per cycle.

## 7. Corner cases and errors

A `done` with a count of 0 (a broken slave) wraps the count; the caller does not do that.

## 8. What the TB checks

Through `sim/tb/am_axi_split_tb.v` (the `MUT_SPLIT_NOWAIT` mutation removes its effect and fails).

## 9. References

`spec/library/bus/am_axi_split.md`.

## 10. Status

Implemented (2026-10-25, p039).
