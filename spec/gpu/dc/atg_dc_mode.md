# atg_dc_mode

RTL: `rtl/gpu/dc/atg_dc_mode.v`.  Parent: atg_dc.  Implemented in: p035 D3.

## 1. Purpose and place

The DC's registers of the DISP2 window that are not the scan-out's (docs/ghci.md §13.2): MODE_INDEX and the mode table, CONNECTED and its HOTPLUG event, CURSOR_POS, CURSOR_CTRL and CURSOR_BASE.  Split from `atg_dc_regs` to keep both under 40 ports (design §18.5).  No children.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | gclk; the board reset. |
| `dc_reset` | in | 1 | The DC's CTRL.RESET (a level): CONNECTED back to 1. |
| `d_we`, `d_idx`, `d_wdata`, `d_wmask`, `d_ridx` | in | 1, 6, 32, 32, 6 | The DC's internal bus (as atg_dc_regs'). |
| `d_rdata` | out | 32 | This module's word at `d_ridx`, combinational; 0 for the others. |
| `connected` | out | 1 | CONNECTED[0]. |
| `ev_hotplug` | out | 1 | One-cycle pulse the cycle after a write that changed CONNECTED. |
| `cur_pos`, `cur_show` | out | 32, 1 | CURSOR_POS, CURSOR_CTRL[0] (to atg_dc_cursor, which takes them at a frame start). |
| `cursor_base` | in | 32 | CURSOR_BASE, from atg_dc_cursor. |

14 ports.

## 4. Behaviour

- MODE_INDEX (3 bits) selects the mode that MODE_H0, H1, V0, V1, CLOCK and FLAGS show: 0 = 640 x 480 at 60 Hz (H 640/16/96/48, V 480/10/2/33, 25,200 kHz, FLAGS 0: negative syncs, PCLK_SEL 0), 1 = 1280 x 720 at 60 Hz (H 1280/110/40/220, V 720/5/5/20, 74,250 kHz, FLAGS 0x13: positive syncs, PCLK_SEL 1); the other indices read 0.  DC_CAPS[11:9] (atg_dc_regs) says 2.
- CONNECTED: 1 after the board reset and while `dc_reset`; a write of bit 0 sets it, and `ev_hotplug` pulses when the value changed.
- CURSOR_POS (strobes apply) and CURSOR_CTRL[0] are stored; CURSOR_BASE reads `cursor_base`.

## 5. State machine

None.

## 6. Latency and throughput

Reads combinational; writes take effect in their cycle.

## 7. Corner cases and errors

- A write of CONNECTED in a cycle of `dc_reset` is lost (the reset wins).

## 8. What the TB checks

`sim/tb/atg_dc_mode_tb.v`: `PASS atg_dc_mode.modes` (both modes, their totals against the clock at 60 Hz, an index without a mode), `PASS atg_dc_mode.connected` (reset value, HOTPLUG only on a change, the DC's reset), `PASS atg_dc_mode.cursor` (the registers, strobes, the outputs, words of other modules read 0), then `PASS atg_dc_mode`.

## 9. References

docs/ghci.md §13.2; design §18.5.  Values referenced: CTA-861 video formats 1 and 4 (the porches, sync widths and polarities), the same as zedBSD's display driver's table.

## 10. Status

Implemented in p035 D3.  About 140 lines.
