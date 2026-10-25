KC705 (XC7K325T-2FFG900)
========================

`atg_kc705_raster`: CP with its CPU, the shader units (`NSU`),
VF, RX, TU, ROP, BLT, MC on the MIG DDR3 (512-bit AXI through an AXI clock
converter, 64-byte lines), the display controller inside the GPU
(atg_top's `HAS_DISP`, the DISP2 window at 0x200, HDMI through the
ADV7511's 16-bit YCbCr 4:2:2 input, its I2C registers for the ADV7511), and the JTAG register bridge (`am_jtag_regs`
on BSCANE2 USER2), with `atg_kc705_raster.xdc`.

The PCIe endpoint (`lib/atg_kc705_pcie.v`, ws288 p013): the AXI Memory
Mapped To PCI Express bridge, Gen2 x4: BAR0 the GHCI register window
(through `am_axi_cdc` into atg_top), BAR2 the 64 MiB local window (into
the MIG wrapper's second port, not through the MC), one MSI vector for
GHCI's interrupt line, the DC's events included (`atg_pcie_msi`), and the
GPU's host accesses (ws288 p039): the MC's port is split by address
(`am_axi_split`) into local memory (the MIG wrapper's GPU port) and the
host window [0, 2 GiB) (the bridge's AXI -> PCIe port, through a 512 ->
128 bit downsizer and a clock converter); simulated by
`sim/tb/atg_kc705_pcie_tb.v` with `sim/models/kc705/atg_kc705_pcie.v`
(which has a host memory).

The IP cores of the PCIe endpoint, the memory's AXI path and the MIG
(`atg_kc705_ddr3`, from `atg_kc705_ddr3.prj`: the board file's DDR3
preset with the AXI interface) are generated and synthesised out of
context by `ip.tcl` (`vivado -mode batch -source boards/kc705/ip.tcl
-tclargs OUT [NAME...]`; not committed; Vivado 2026.1, 2026-10-25).
Built with `VIVADO_IP=OUT tools/vivado-build.sh kc705 TOP` (part
xc7k325tffg900-2).  gclk is 20 MHz for the board's bring-up (ws288
p024).  Linted by
`tools/lint.sh` and simulated by `sim/tb/atg_kc705_raster_tb.v`, where `lib/atg_kc705_clk.v` and
`lib/atg_kc705_mig.v` are replaced by `sim/models/kc705/` (same names and
ports) and the primitives by `sim/models/xilinx/`.  Not yet built or tried
on the board.
