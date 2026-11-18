# atg_pcie_msi

RTL: `rtl/bsp/pcie/atg_pcie_msi.v`.  Parent: `atg_kc705_top` (and other FPGA board tops).

## 1. Purpose and place

The MSI rule of GHCI's PCIe binding (docs/ghci.md §15.2) for FPGA board tops, one vector: GHCI's interrupt line (OR(IRQ_STATUS & IRQ_ENABLE)).  The display controller's events are bits of IRQ_STATUS (DISP2, [12:9]), so it has no vector of its own (ws288 p035).

Located in `rtl/bsp/pcie/` as a common board support package module for PCIe-enabled FPGA targets.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `IRQ_STATUS_ADDR` | 17'h00038 | Byte offset of GHCI_IRQ_STATUS in host register port | 17-bit address |
| `IRQ_ENABLE_ADDR` | 17'h0003C | Byte offset of GHCI_IRQ_ENABLE in host register port | 17-bit address |

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | gclk and its reset. |
| `irq` | in | 1 | GHCI's interrupt line (gclk). |
| `aw_take` | in | 1 | A write address taken at atg_top's register port (gclk). |
| `aw_addr` | in | 17 | Its address. |
| `b_take` | in | 1 | A write response taken there (in order). |
| `uclk`, `urst_n` | in | 1 | The PCIe user clock and its reset. |
| `msi_req` | out | 1 | A message requested (uclk), held until msi_ack. |
| `msi_ack` | in | 1 | The message was sent (one cycle). |

10 ports.

## 4. Behaviour

A message when irq goes from 0 to 1, and again 2 cycles after the response of a write through the register port to IRQ_STATUS or IRQ_ENABLE if irq is then 1.  The events are gathered in gclk and handed to uclk by a 4-phase handshake (am_sync both ways); events during a handshake are gathered for the next round, so none is lost and close ones give one message.  msi_req rises for a message, falls after msi_ack; one requested meanwhile follows.  Writes are matched to their responses through an 8-deep FIFO.

## 5. State machine

None beyond the handshake bits.

## 6. Latency and throughput

About 2 gclk + 4 uclk cycles from the event to msi_req.

## 7. Corner cases and errors

More than 8 writes outstanding at the register port would lose the matching (atg_top takes one at a time).

## 8. What the TB checks

`sim/tb/atg_kc705_pcie_tb.v` (msi): IRQ_SET of the soft interrupt gives one message; an IRQ_ENABLE write that leaves the line 1 another; the IRQ_STATUS write that clears it none; the DC's VBLANK (IRQ_STATUS [9]) one, and no more while it stays set.  Without the re-arm (only the rising edge) the TB fails.

## 9. References

docs/ghci.md §9.2, §15.2.

## 10. Status

Implemented in `rtl/bsp/pcie/atg_pcie_msi.v` (parameterized in Phase 034).
