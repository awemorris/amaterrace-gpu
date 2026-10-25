# atg_blt_blend

RTL: `rtl/gpu/blt/atg_blt_blend.v`.  Parent: `atg_blt_2d`.  Children: none.

## 1. Purpose and place

The 2D engine's blend-over of a line of 32-bit pixels (docs/ghci.md §8.2): out = src + round(dst × (255 − src.a) / 255) per byte, saturated.

## 2. Parameters

`LINE_BYTES` (32), `LINE_SHIFT` (5).

## 3. Ports

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock, synchronous active-low reset |
| `go` | in | 1 | Start a line (src and dst held by the caller until done) |
| `src`, `dst` | in | `LINE_BYTES*8` each | The source line (the copied line or the FILL line) and the destination line |
| `done` | out | 1 | Pulse: out holds the blended line (until the next go) |
| `out` | out | `LINE_BYTES*8` | The blended line |

7 ports.

## 4. Behaviour

Three stages a word: take the words, the four 8 × 8 products with 255 − src.a, the sums with round(t / 255) = (t + 128 + ((t + 128) >> 8)) >> 8, saturated at 255.

## 5. State machine

Idle / running (one bit), the stage valid bits.

## 6. Latency and throughput

LINE_BYTES / 4 + 3 cycles from go to done.

## 7. Corner cases and errors

None.

## 8. What the TB checks

Through `sim/tb/atg_top_tb.v` (blend FILL and COPY with saturation) and `sim/tb/atg_blt_tb.v` (`tile` group).

## 9. References

docs/ghci.md §8.2.

## 10. Status

New (2026-10-25): split off `atg_blt_2d` (the same arithmetic; one cycle more per blended segment).

WS288 p037 (2026-10-25): the arithmetic is am_ modules (docs/style.md), function unchanged (equal to the former module on 200,000 random cycles).
