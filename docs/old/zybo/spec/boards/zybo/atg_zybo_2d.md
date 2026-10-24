# atg_zybo_2d

RTL: `boards/zybo/atg_zybo_2d.v`, constraints `boards/zybo/atg_zybo_2d.xdc`. Written from the RTL at amaterrace-gpu main a217bf8 (WS288 p023 part 2); the RTL is authoritative.

## 1. Purpose and place

ZYBO bitstream 1, "2D" (design §3.6): the GPU (`atg_top`: CP, blitter, MC) on the original ZYBO (XC7Z010-1CLG400), with the PS7 primitive instantiated directly (as zedBSD's `plio`). Parent: none (the FPGA top). Children: `PS7` (`ps7`), `BUFG` (`fclk0_bufg`), `atg_top` (`gpu`). design.md §7.6 calls it `zybo_2d`; the file and module are named `atg_zybo_2d`.

## 2. Parameters

None. `atg_top` is instantiated with `GCLK_HZ` 100000000, `S_ID_W` 12, `S_LEN_W` 4, `LINE_BYTES` 32, `LINE_SHIFT` 5, `DATA_W` 64.

## 3. Ports

| Name | Dir | Width | Domain | Meaning |
| --- | --- | --- | --- | --- |
| `led` | out | 4 | `clk` (false path) | [0] heartbeat (`beat[25]`, about 1.5 Hz at 100 MHz), [1] the GPU interrupt line, [3:2] 0. Pins M14, M15, G14, D18, LVCMOS33 |

Internal connections (not ports): M_AXI_GP0 (AXI3, 12-bit IDs) → `atg_top.s_*` with the low 17 address bits (the kernel's PL window 0x43C00000 is 64 KiB, so bit 16 is never set); `atg_top.m_*` → S_AXI_HP0 (AXI3, 64-bit: AxLEN[3:0], AxSIZE[1:0], IDs and WID 0, AxLOCK 0, AxQOS 0, RD/WR ISSUECAP1 0); `irq` → IRQ_F2P[0] (GIC 61); FCLK_CLK0 → BUFG → `clk` = GP0 and HP0 ACLK; `mem_ready` = 1.

## 4. Behaviour

- Clock: FCLK_CLK0 (100 MHz from ps7_init) through a BUFG.
- Reset: FCLK_RESET0_N is taken through two `ASYNC_REG` flops initialised to 0 (FPGA init value) to make `rst_n`; it rises when devcfg's FPGA_ENABLE releases FPGA_RST_CTRL.
- A free-running 26-bit counter drives the heartbeat LED.

The PS must provide (checked on the board in p003 by JTAG while zedBSD ran, after `fpgaload`): FPGA0_CLK_CTRL 0x00100A00 (IO PLL / 10 = 100 MHz), LVL_SHFTR_EN 0xF, FPGA_RST_CTRL 0, AFI0 RDCHAN_CTRL 0 and WRCHAN_CTRL 0xF00 (bit 0 = 0: HP0 64-bit, the reset values; ps7_init does not write the AFI).

## 5. State machine

None.

## 6. Latency and throughput

Those of `atg_top`. Constraint: `create_clock -period 10.000` on net `clk` (gclk). Result (p003, Vivado 2026.1, xc7z010clg400-1, after routing): WNS +0.190 ns, WHS +0.048 ns; LUT 3,802 (21.6%), FF 3,719, BRAM 0.5, DSP 0; build `tools/vivado-build.sh zybo atg_zybo_2d` in 162 s; 130 warnings, no critical warning (PS7 unconnected ports and similar, none from RTL errors).

## 7. Corner cases and errors

- The reset synchroniser is a raw two-flop chain, not `am_sync`, because nothing resets it (it relies on the FPGA init value). This is the one CDC outside `am_sync`/`am_afifo`, at the board edge.
- HP0 widths are those of the PS7 primitive (Vivado 2026.1 unisim `PS7.v`): IDs 6, AxLEN 4, AxSIZE 2, WSTRB 8. UG585's HP FIFO depths were not read (design R4).
- GP0 bursts are handled by `am_axi_regs` (first address repeated).

## 8. What the TB checks

No simulation (the PS7 primitive is not in the lint or sim sets; `tools/lint.sh` lints `atg_top` instead). Board evidence (p003, real ZYBO booted from SD, zedBSD 1.0.0-beta2+g5a28d28, no driver): `plan/tools/zybo/ghci-blt-board.py` (zedBSD) passed 5 times on the final bitstream: identification, CAPS, EXTCAP/PERF, aperture, DBG write/read-back, fill32, copy32 unaligned, fill16, copy16, fill/copy blend, tile, untile, overlap reverse/forward, fill after reset, PERF counters, IRQ_SET → `fpgareg wait`, HALT, aperture FAULT → RESET; HP0 64-bit also checked by DBG on both halves of a beat. `plan/tools/zybo/ps-regs.sh` read the PS registers above. No QEMU (the PL is not modelled).

## 9. References

- design.md §1.3 (clocks, reset entry), §2.2 (window, IRQ), §3.6 (bitstream 1), §4.1 (HP0), §7.5 (bitstream distribution).
- zedBSD `plan/ws288/phase003/phase.md` (board evidence), `plan/ws288/tests/zybo-gpu-sd.dts` (64 MiB GPU reserved memory).
- Digilent `Zybo-Master.xdc` (MIT), commit c8644a9fe31cc803789643124545d56b3bef4600: LED pins (Values referenced).
- Related specs: `spec/gpu/top/atg_top.md`.

## 10. Status

Implemented (053c1ba, p002; PS notes 0c16474, p003; unchanged at a217bf8). 218 lines, 1 port, no FSM, one clock: within U38. No difference between RTL and this spec; the only naming difference is `atg_zybo_2d` vs design §7.6's `zybo_2d`.
