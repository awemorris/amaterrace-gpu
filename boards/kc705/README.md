KC705 (XC7K325T-2FFG900)
========================

`atg_kc705_raster`: CP with its CPU, the shader units (`NSU`),
VF, RX, TU, ROP, BLT, MC on the MIG DDR3 (512-bit AXI through an AXI clock
converter, 64-byte lines), the display controller next to the GPU
(+0x10000, HDMI through the ADV7511's 16-bit YCbCr 4:2:2 input, its I2C
registers for the ADV7511), and the JTAG register bridge (`am_jtag_regs`
on BSCANE2 USER2), with `atg_kc705_raster.xdc`.

The PCIe endpoint (`lib/atg_kc705_pcie.v`, ws288 p013): the AXI Memory
Mapped To PCI Express bridge, Gen2 x4: BAR0 the GHCI register window
(through `am_axi_cdc` into atg_top), BAR2 the 64 MiB local window (into
the MIG wrapper's second port, not through the MC), MSI 0 the GPU, 1 the
DC (`atg_pcie_msi`); simulated by `sim/tb/atg_kc705_pcie_tb.v` with
`sim/models/kc705/atg_kc705_pcie.v`.

The IP cores of the PCIe endpoint and the memory's AXI path are generated
by `ip.tcl` (`vivado -mode batch -source boards/kc705/ip.tcl -tclargs
OUT`; not committed; checked with Vivado 2026.1 on 2026-10-25).  The MIG
core's TCL is not written yet (p024).  Built with
`tools/vivado-build.sh kc705 TOP` (part xc7k325tffg900-2).  Linted by
`tools/lint.sh` and simulated by `sim/tb/atg_kc705_raster_tb.v`, where `lib/atg_kc705_clk.v` and
`lib/atg_kc705_mig.v` are replaced by `sim/models/kc705/` (same names and
ports) and the primitives by `sim/models/xilinx/`.  Not yet built or tried
on the board.
