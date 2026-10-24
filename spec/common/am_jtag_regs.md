# am_jtag_regs

RTL: `rtl/common/am_jtag_regs.v`.  Parent: the KC705 top (between the BSCANE2 primitive in boards/kc705 and atg_top's register bus).  Implemented in: p012.

## 1. Purpose and place

KC705 JTAG register bridge: a BSCANE2 USER2 data register of 72 bits {cmd, addr, data} that becomes a second master on the GHCI register bus (DBG capability).

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk); the JTAG pins are in tck unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Register-bus clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low (gclk). |
| **From BSCANE2 (tck domain)** | | | |
| `tck` | in | 1 | (tck) JTAG TCK from BSCANE2. |
| `tdi` | in | 1 | (tck) TDI. |
| `tdo` | out | 1 | (tck) TDO. |
| `sel` | in | 1 | (tck) USER2 selected. |
| `capture` | in | 1 | (tck) CAPTURE-DR. |
| `shift` | in | 1 | (tck) SHIFT-DR. |
| `update` | in | 1 | (tck) UPDATE-DR. |
| **Register bus master (gclk)** | | | |
| `reg_wr` | out | 1 | Write strobe (one cycle), as am_axi_regs gives. |
| `reg_waddr` | out | 17 | Byte address in the 128 KiB window. |
| `reg_wdata` | out | 32 | Data. |
| `reg_wstrb` | out | 4 | Always 4'hF. |
| `reg_rd` | out | 1 | Read strobe; data due the next cycle. |
| `reg_raddr` | out | 17 | Read address. |
| `reg_rdata` | in | 32 | Read data, the cycle after reg_rd. |
| `bus_busy` | in | 1 | The AXI slave uses the bus this cycle; wait (the top's mux gives the JTAG master the bus only when idle). |

17 ports.

## 4. Behaviour

- DR (72 bits, LSB first): `[7:0] cmd`, `[39:8] addr`, `[71:40] data`.  cmd 1 = write `data` to
  `addr`; cmd 2 = read `addr` (the value is returned in the data field of the next scan); cmd 3 =
  status (bit 0 = last command done).  Other cmd values do nothing.
- UPDATE latches the DR in tck and toggles a request bit; the bit crosses to gclk through `am_sync`
  (the 72-bit word is stable while the request is pending: the host never scans faster than the
  handshake, the status command tells it).  gclk performs the access when `bus_busy` is 0, captures
  the read data, and toggles an acknowledge bit back through `am_sync`.
- CAPTURE loads {read data, addr, status} into the shift register: `[7:0]` status (bit 0 done:
  no access pending; bit 1 dropped: a write or read scanned while one was pending was ignored,
  cleared by the next accepted command), `[39:8]` the address of the last accepted command,
  `[71:40]` the data of the last read.
- The tck side has no reset (the ports give none): its registers start at 0 from the
  configuration (initial values).  The toggles cross through `am_sync` without reset; a gclk
  reset acknowledges a pending request (drops it).

## 5. State machine

gclk side: IDLE →(request toggle seen)→ WAIT_BUS →(!bus_busy)→ ACCESS (one cycle reg_wr or reg_rd)
→ READ_DATA (reads: take reg_rdata) → DONE (toggle ack) → IDLE.

## 6. Latency and throughput

One register access per scan pair; the host tool (plan/tools/kc705/jtag-reg.sh) is the bottleneck (milliseconds).

## 7. Corner cases and errors

- This module crosses two domains by design (tck and gclk), the only exception to "one clock domain"
  in rtl/common, allowed because the crossing is the module's purpose and uses `am_sync` only.
- A scan during a pending access is ignored (status bit 0 stays 0, bit 1 is set).  Reset of gclk drops the request.
- reg_wr/reg_rd are combinational: asserted in a cycle with `bus_busy` = 0 only (atg_top serves
  the JTAG master in cycles without an AXI access, `j_go`).

## 8. What the TB checks

`sim/tb/am_jtag_regs_tb.v` (the TAP is `sim/models/xilinx/BSCANE2.v`'s `scan` task) prints, in this order:

- `PASS am_jtag_regs.write` — a TAP model scans a write; reg_wr appears once with addr/data
- `PASS am_jtag_regs.read` — a read scan, then a status scan returns the register value
- `PASS am_jtag_regs.busy` — with bus_busy held, the access waits and then happens once; a scan
  meanwhile is dropped (status bit 1) and has no effect
- `PASS am_jtag_regs` at the end.

## 9. References

design §4.4, Xilinx UG470 (BSCANE2; Values referenced: USER2 = IR 0x03 on 7-series).

## 10. Status

Implemented in WS288 p012 part A (TB `am_jtag_regs_tb` PASS).  Differences from the stub's text
(p012, for Q1): status bit 1 "dropped" added (§4, §7); the tck-side registers use initial values
instead of a reset (no reset port on the tck side).
