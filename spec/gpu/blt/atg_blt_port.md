# atg_blt_port

RTL: `rtl/gpu/blt/atg_blt_port.v`.  Parent: `atg_blt_2d`.  Children: none.

## 1. Purpose and place

The 2D engine's AMB port: the request register, the counts of outstanding reads and writes, the three line buffers the read responses fill, and the error flag.

## 2. Parameters

`ADDR_W` (32), `LINE_BYTES` (32), `LINE_SHIFT` (5).

## 3. Ports

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst_n`, `clr` | in | 1 each | Clock, reset, clear `fail` (the kick) |
| `issue`, `i_write`, `i_line`, `i_slot`, `i_be`, `i_wdata` | in | 1, 1, `ADDR_W-LINE_SHIFT`, 2, `LINE_BYTES`, `LINE_BYTES*8` | A request, taken when `free` |
| `free`, `rd_idle`, `wr_idle`, `fail` | out | 1 each | No request held; no read, no write outstanding; an error response was seen |
| `buf0`, `buf1`, `bufd` | out | `LINE_BYTES*8` each | The read lines of slots 0, 1 (source) and 2 (destination) |
| `req_*`, `rsp_*` | | | The AMB client port (`atg_blt_2d.md` §3); tag {5'd0, write, slot} |

24 ports (counting the AMB ports one by one).

## 4. Behaviour

As the ports say; the outstanding counts change by the request taken and the response seen in the same cycle.

## 5. State machine

None (registers).

## 6. Latency and throughput

The request is a register (as before the split).

## 7. Corner cases and errors

- `clr` wins over an error response in the same cycle (as before).

## 8. What the TB checks

Through `sim/tb/atg_blt_tb.v` and `sim/tb/atg_top_tb.v`.

## 9. References

`atg_blt_2d.md`, `spec/gpu/mc/atg_mc.md`.

## 10. Status

New (2026-10-25): split off `atg_blt_2d`.

WS288 p037 (2026-10-25): the arithmetic is am_ modules (docs/style.md), function unchanged (equal to the former module on 200,000 random cycles).
