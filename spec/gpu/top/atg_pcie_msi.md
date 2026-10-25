# atg_pcie_msi

RTL: `rtl/gpu/top/atg_pcie_msi.v`.  Parent: atg_kc705_raster.  Written in WS288 p013 (2026-10-25).

## 1. Purpose and place

The MSI rule of GHCI's PCIe binding (docs/ghci.md §15.2) for the KC705: vector 0 is the GPU's interrupt line, vector 1 the display controller's (design §4.3).

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | gclk and its reset. |
| `irq` | in | 2 | The lines (gclk): [0] the GPU's, [1] the DC's. |
| `aw_take` | in | 1 | A write address taken at atg_top's register port (gclk). |
| `aw_addr` | in | 17 | Its address. |
| `b_take` | in | 1 | A write response taken there (in order). |
| `uclk`, `urst_n` | in | 1 | The PCIe user clock and its reset. |
| `msi_req` | out | 2 | A message requested for vector v (uclk), held until msi_ack[v]. |
| `msi_ack` | in | 2 | The message was sent (one cycle). |

10 ports.

## 4. Behaviour

A message of vector v when irq[v] goes from 0 to 1, and again 2 cycles after the response of a write through the register port to that vector's IRQ_STATUS or IRQ_ENABLE (GHCI 0x38, 0x3C; the DC's +0x10018, +0x1001C) if irq[v] is then 1.  The events of a vector are gathered in gclk and handed to uclk by a 4-phase handshake (am_sync both ways); events during a handshake are gathered for the next round, so none is lost and close ones give one message.  msi_req[v] rises for a message, falls after msi_ack[v]; one requested meanwhile follows.  Writes are matched to their responses through an 8-deep FIFO.

## 5. State machine

None beyond the handshake bits.

## 6. Latency and throughput

About 2 gclk + 4 uclk cycles from the event to msi_req.

## 7. Corner cases and errors

More than 8 writes outstanding at the register port would lose the matching (atg_top takes one at a time).

## 8. What the TB checks

`sim/tb/atg_kc705_pcie_tb.v` (msi): IRQ_SET of the soft interrupt gives one message; an IRQ_ENABLE write that leaves the line 1 another; the IRQ_STATUS write that clears it none; the DC's VSYNC a message of vector 1.  Without the re-arm (only the rising edge) the TB fails.

## 9. References

docs/ghci.md §9.2, §15.2.

## 10. Status

Implemented (2026-10-25, p013).
