# am_arb3

RTL: `rtl/library/bus/am_arb3.v`.  Parent: `am_axi_split` (instances `barb` for B, `rarb` for R).  Written in WS288 p039 (2026-10-25).

## 1. Purpose and place

Picks one of three valid sources in turn and keeps it for a whole unit: a B response, or an R burst up to its RLAST, so a source's payload stays shown while it waits for ready and R bursts do not interleave.

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | Clock, synchronous reset |
| `v` | in | 3 | The sources' valid |
| `fire` | in | 1 | A transfer of the selected source went through this cycle |
| `last` | in | 1 | It ended the unit (1 for B; RLAST for R) |
| `sel` | out | 2 | The source shown (0..2), combinational |

## 4. Behaviour

While a unit is under way (a transfer went through without `last`, or the selected source was valid without `fire`) `sel` stays; otherwise it is the next valid source after the one that finished the last unit (round robin; when none is valid, one whose valid is 0).

## 5. State machine

Free → (selected source valid and no fire, or fire without last) → held → (fire with last) → free.

## 6. Latency and throughput

One transfer per cycle; a new unit can start in the cycle after the last one ended.

## 7. Corner cases and errors

A source that drops valid while held (against AXI) keeps the selection.

## 8. What the TB checks

Through `sim/tb/am_axi_split_tb.v` (`MUT_SPLIT_NOHOLD` lets bursts interleave and fails).

## 9. References

`spec/library/bus/am_axi_split.md`.

## 10. Status

Implemented (2026-10-25, p039).
