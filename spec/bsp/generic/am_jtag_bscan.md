# am_jtag_bscan (Generic / Simulation)

RTL: `rtl/bsp/generic/am_jtag_bscan.v`.

## 1. Purpose and place

Wrapper for JTAG boundary scan primitive (`BSCANE2` and `BUFG`) in generic / simulation environments.
Provides pass-through simulation tasks (`scan`, `idle`) to interface directly with `sim/models/xilinx/BSCANE2.v`.

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
