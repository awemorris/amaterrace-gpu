# am_fifo_key

RTL: `rtl/library/bus/am_fifo_key.v`.  Parent: `am_axi_master` (the user queues `ids[i].wq`, `ids[i].rq`).  Written in WS288 p039 (2026-10-25).

## 1. Purpose and place

`am_fifo` whose entries also keep a key, with an output that says whether an entry with a given key is in it: am_axi_master keeps the order key (the MC's client) of each outstanding burst and holds a request of a key that is outstanding on another AXI ID.

## 2. Parameters

`W` (8: data bits), `KEY_W` (8: key bits), `DEPTH_LOG2` (2: 2^DEPTH_LOG2 entries; ≥ 1).

## 3. Ports

As `am_fifo` (`in_valid/in_ready/in_data`, `out_valid/out_ready/out_data`, `count`), plus:

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `in_key` | in | KEY_W | The pushed entry's key |
| `key` | in | KEY_W | The key asked about |
| `has` | out | 1 | Combinational: an entry now in the FIFO has this key (one popped in this cycle still counts, one pushed in this cycle not yet) |

## 4. Behaviour

First-word fall-through; a push and a pop in one cycle are allowed.  Each slot has a flag that is set by the push into it and cleared by the pop from it; `has` ORs flag and key match over the slots.

## 5. State machine

None.

## 6. Latency and throughput

One push and one pop per cycle.

## 7. Corner cases and errors

As `am_fifo`: a push when full or a pop when empty is not made (the handshakes say so).

## 8. What the TB checks

Through `sim/tb/atg_mc_tb.v` case D (`MUT_AXI_NOKEY` in am_axi_master removes the check and fails the per-client order).

## 9. References

`spec/library/bus/am_fifo.md`, `spec/library/bus/am_axi_master.md`.

## 10. Status

Implemented (2026-10-25, p039).
