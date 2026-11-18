# am_jtag_bscan (Xilinx 7 Series)

RTL: `rtl/bsp/xilinx7/am_jtag_bscan.v`.

## 1. Purpose and place

Wrapper for Xilinx 7-series JTAG primitive (`BSCANE2` and `BUFG`) when `SYNTH_KINTEX7` is defined.

## 2. Parameters

- `JTAG_CHAIN` (2): JTAG chain index (USER2 corresponds to chain 2).

## 3. Ports

- `tck`: output clock (buffered via BUFG)
- `sel`: output USER register select
- `capture`: output capture state
- `shift`: output shift state
- `update`: output update state
- `tdi`: output TDI (data into JTAG register)
- `tdo`: input TDO (data from JTAG register)
