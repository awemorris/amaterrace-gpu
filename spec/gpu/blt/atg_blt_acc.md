# atg_blt_acc

RTL: `rtl/gpu/blt/atg_blt_acc.v`.  Parents: `atg_blt_2d` (two), `atg_blt_rsv` (two).  Children: none.

## 1. Purpose and place

A row address of the blitter's engines: base + y × stride by shift and add, then + a step per row.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `W` | 32 | Address width |

## 3. Ports

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock, synchronous active-low reset |
| `go`, `y`, `s`, `b` | in | 1, 17, W, W | Load r = b and start r += y × s |
| `add`, `d` | in | 1, W | When idle: r += d |
| `r` | out | W | The address |
| `idle` | out | 1 | The product is done |

9 ports.

## 4. Behaviour

One bit of y a cycle, LSB first (s doubles); 32-bit wrap.

## 5. State machine

None (the remaining bits of y).

## 6. Latency and throughput

At most 17 cycles after go (the engines' former S_MUL).

## 7. Corner cases and errors

- `add` is ignored while not idle (the engines add only after the product).

## 8. What the TB checks

Through `sim/tb/atg_blt_tb.v`, `atg_blt_rsv_tb.v` and `atg_top_tb.v`.

## 9. References

`atg_blt_2d.md`, `atg_blt_rsv.md`.

## 10. Status

New (2026-10-25): the multipliers of the two engines in one module.
