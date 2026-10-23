# atg_cp_irq

RTL: `rtl/gpu/cp/atg_cp_irq.v`.  Parent: atg_cp.  Implemented in: p004 (done).

## 1. Purpose and place

IRQ_STATUS (W1C), IRQ_ENABLE, IRQ_SET and the level interrupt line.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low (board reset): IRQ_ENABLE. |
| `core_rst_n` | in | 1 | Core reset (CTRL.RESET's pulse): IRQ_STATUS. |
| **HCR register snoop (from atg_cp_regs)** | | | |
| `hcr_we` | in | 1 | One-cycle write strobe to an HCR word (0x000-0xFFC). |
| `hcr_widx` | in | 10 | Word index of the write (byte offset >> 2). |
| `hcr_wdata` | in | 32 | Write data. |
| `hcr_wmask` | in | 32 | Bit mask from WSTRB (1 = written). |
| `hcr_ridx` | in | 10 | Word index being read; the read data is due in the same cycle (combinational from this registered index). |
| `hcr_rdata` | out | 32 | Read data of this module's registers at `hcr_ridx`, 0 for other indices (the parent ORs them). |
| `ev` | in | 9 | Event pulses: [0] FENCE [1] FAULT [2] RING_EMPTY [3] WATCHDOG [4] DBG_DONE [5] (unused, SOFT is IRQ_SET) [6] HALTED [7] RESULT [8] RETIRE. |
| `irq` | out | 1 | Level: OR(IRQ_STATUS & IRQ_ENABLE). |

11 ports.

## 4. Behaviour

- IRQ_STATUS 0x038: a bit is set by its event pulse; ev[2] is the RING_EMPTY **level** and this
  module sets bit 2 on its rising edge (its previous value resets to 1, so a core reset does not raise
  it), cleared by writing 1; a set and a clear in the same cycle leave it set.
  IRQ_ENABLE 0x03C [8:0]; IRQ_SET 0x040 bit 5 sets SOFT.
- irq is registered (one cycle after the status changes).

## 5. State machine

None.

## 6. Latency and throughput

1 cycle.

## 7. Corner cases and errors

- `core_rst_n` clears IRQ_STATUS, `rst_n` IRQ_ENABLE (design §2.6: IRQ_ENABLE survives RESET).
- W1C and IRQ_ENABLE honour the byte strobes (`hcr_wmask`).

## 8. What the TB checks

`sim/tb/atg_cp_irq_tb.v` prints, in this order:

- `PASS atg_cp_irq.w1c` — set by events, cleared by W1C, set wins over clear
- `PASS atg_cp_irq.line` — irq follows status & enable; IRQ_SET raises SOFT
- `PASS atg_cp_irq` at the end.

## 9. References

design §2.2 (IRQ registers), §2.5.

## 10. Status

Implemented (WS288 p004 (P3, amaterrace-gpu p3-cp 4a4d2da..65cc445, merged as a094748)).  78 lines.  Spec changes in p004: the `core_rst_n` port; ev[2] is a level
(edge detected here).
