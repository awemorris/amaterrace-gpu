Old targets
===========

Sources of targets that are no longer synthesised, kept for reference.
Nothing here is built, linted or simulated.

- `zybo/`: the Digilent ZYBO (XC7Z010) target, dropped on 2026-10-25: its
  board tops and constraints, their specifications, the VGA output of the
  DC (`atg_dc_vga`) with its testbench, the firmware images for 32-byte
  lines and the testbenches' shape choice (`tb_shape.vh`), each at the
  path it had under the repository's root; and the lint stand-ins for the
  PS7 and the HDMI serialisers, split out of `sim/lint/xilinx_stubs.v`
  into `sim/lint/xilinx_stubs_zybo.v`.
