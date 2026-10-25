# atg_mc_plb

RTL: `rtl/gpu/mc/atg_mc_plb.v`.  Parent: `atg_mc_prot` (instance `plb`).  Written for session
protection (docs/ghci.md §11.6, 2026-10-25).

## 1. Purpose and place

The protection lookaside buffer: a few lines of the protection table that `atg_mc_prot` reads
from memory (the walk) and looks the requests up in.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `PLB`, `PLB_W` | 4, 2 | Lines and clog2 (KC705 16, 4) |
| `LINE_BYTES`, `LINE_SHIFT` | 32, 5 | A line: LINE_BYTES table bytes, one per granule |
| `GW`, `TAGW` | 20, 15 | Granule number bits (ADDR_W − 12); tag bits (GW − LINE_SHIFT) |

## 3. Ports

Domain `clk`.  16 ports.

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst_n`, `flush`, `en` | in | 1 | Reset, flush and !en drop every line |
| `g0` | in | `GW` | The first granule of the table (aperture base >> 12) |
| `tag` / `hit`, `data` | in / out | `TAGW` / 1, line | Combinational lookup: the table's line index (granule − g0) >> LINE_SHIFT |
| `fill`, `fill_tag`, `fill_data` | in | 1, `TAGW`, line | One cycle: write the next line (round-robin) |
| `inv_valid`, `inv_g`, `inv_n` | in | 1, `GW`, 32 | One cycle: drop the lines that overlap [inv_g, inv_g + inv_n) (inv_n 0: all) |
| `w_tag` / `w_inv` | in / out | `TAGW` / 1 | Whether that invalidation overlaps the line of w_tag (the walk's) |

## 4. Behaviour

The line of tag t covers the granules [g0 + t·LINE_BYTES, + LINE_BYTES).  A fill in the cycle of
an invalidation is kept (the caller does not fill a line the invalidation overlaps: it uses
`w_inv`).  No two lines have the same tag (the caller fills only after a miss, one walk at a
time).

## 5. State machine

None: {valid, tag, line} per line and the round-robin pointer.

## 6. Latency and throughput

Lookup combinational; a fill or an invalidation takes effect at the next clock edge.

## 7. Corner cases and errors

`MUT_PROT_STALE` (lines not dropped by an invalidation) must fail `atg_mc_prot_tb`.

## 8. What the TB checks

Through `sim/tb/atg_mc_prot_tb.v` (2 lines there, so that the random requests replace lines;
the groups inv and race).

## 9. References

`spec/gpu/mc/atg_mc_prot.md`.

## 10. Status

Implemented (session protection, R2).  About 120 lines.
