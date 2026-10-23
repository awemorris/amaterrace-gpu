# atg_cp_irq

RTL: `rtl/gpu/cp/atg_cp_irq.v`.  Parent: atg_cp.  Implemented in: p004.

## 1. Purpose and place

IRQ_STATUS (W1C), IRQ_ENABLE, IRQ_SET and the level interrupt line.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **HCR register snoop (from atg_cp_regs)** | | | |
| `hcr_we` | in | 1 | One-cycle write strobe to an HCR word (0x000-0xFFC). |
| `hcr_widx` | in | 10 | Word index of the write (byte offset >> 2). |
| `hcr_wdata` | in | 32 | Write data. |
| `hcr_wmask` | in | 32 | Bit mask from WSTRB (1 = written). |
| `hcr_ridx` | in | 10 | Word index being read; the read data is due in the same cycle (combinational from this registered index). |
| `hcr_rdata` | out | 32 | Read data of this module's registers at `hcr_ridx`, 0 for other indices (the parent ORs them). |
| `ev` | in | 9 | Event pulses: [0] FENCE [1] FAULT [2] RING_EMPTY [3] WATCHDOG [4] DBG_DONE [5] (unused, SOFT is IRQ_SET) [6] HALTED [7] RESULT [8] RETIRE. |
| `irq` | out | 1 | Level: OR(IRQ_STATUS & IRQ_ENABLE). |

10 ports.

## 4. Behaviour

- IRQ_STATUS 0x038: a bit is set by its event pulse (RING_EMPTY by the rising edge of empty, given as
  a pulse by the parent), cleared by writing 1; a set and a clear in the same cycle leave it set.
  IRQ_ENABLE 0x03C [8:0]; IRQ_SET 0x040 bit 5 sets SOFT.
- irq is registered (one cycle after the status changes).

## 5. State machine

None.

## 6. Latency and throughput

1 cycle.

## 7. Corner cases and errors

- Reset clears IRQ_STATUS and IRQ_ENABLE (design §2.6 lists IRQ_ENABLE as kept over RESET: this module is on rst_n, not core_rst_n).

## 8. What the TB checks

`sim/tb/atg_cp_irq_tb.v` prints, in this order:

- `PASS atg_cp_irq.w1c` — set by events, cleared by W1C, set wins over clear
- `PASS atg_cp_irq.line` — irq follows status & enable; IRQ_SET raises SOFT
- `PASS atg_cp_irq` at the end.

## 9. References

design §2.2 (IRQ registers), §2.5.

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
