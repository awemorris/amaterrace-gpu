# atg_sa

RTL: `rtl/gpu/sa/atg_sa.v`.  Parent: atg_top (HAS_SA, 0 everywhere in v1).  Implemented in: Future Work (fw-sa-core).

## 1. Purpose and place

The systolic array, reserved (design §3.9, Appendix A, deferred until the SU implements GSI1): only the top ports exist so atg_top and atg_su keep the place for it; every output is 0 and CAPS[25] stays 0.

Only this top is part of the p023 tree; the inner modules of design §7.6 (`atg_sa_in`, `atg_sa_pe_*`, `atg_sa_array`, `atg_sa_drain`, `atg_sa_red`, `atg_sa_norm`, `atg_sa_buf`, `atg_sa_wfetch`, `atg_sa_fifo`, `atg_sa_ctl`) are specified with the SA design (Future Work fw-sa-core).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `NPHYS` | `8` | The SU's lane-group width (rq entry beat = NPHYS × 32 bits). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **STATE broadcast (from atg_cp_state)** | | | |
| `st_we` | in | 1 | One-cycle write of STATE[st_idx]. |
| `st_idx` | in | 9 | STATE index (design §2.3). |
| `st_wdata` | in | 32 | STATE value; the block keeps the words of its range. |
| **HCR register snoop (from atg_cp_regs)** | | | |
| `hcr_we` | in | 1 | One-cycle write strobe to an HCR word (0x000-0xFFC). |
| `hcr_widx` | in | 10 | Word index of the write (byte offset >> 2). |
| `hcr_wdata` | in | 32 | Write data. |
| `hcr_wmask` | in | 32 | Bit mask from WSTRB (1 = written). |
| `hcr_ridx` | in | 10 | Word index being read; the read data is due in the same cycle (combinational from this registered index). |
| `hcr_rdata` | out | 32 | Read data of this module's registers at `hcr_ridx`, 0 for other indices (the parent ORs them). |
| **To the SU's rq port (atg_su sa_*)** | | | |
| `push_valid` | in | 1 | Entry from the SU. |
| `push_ready` | out | 1 | Taken. |
| `push_data` | in | NPHYS*32 | Data. |
| `pop_valid` | out | 1 | Entry to the SU. |
| `pop_ready` | in | 1 | Taken. |
| `pop_data` | out | NPHYS*32 | Data. |
| `ctl_valid` | in | 1 | sactl. |
| `ctl_data` | in | 32 | Control word. |
| `qstat` | out | 32 | Operand 120. |
| `sastat` | out | 32 | Operand 121. |
| `qtag` | out | 32 | Operand 122. |
| `busy` | out | 1 | STATUS[7] SA_BUSY. |
| **AMB client port (design §4.1)** | | | |
| `req_valid` | out | 1 | Request valid; payload held until `req_ready`. |
| `req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `req_write` | out | 1 | 1 write, 0 read. |
| `req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `req_tag` | out | 8 | The client's tag, returned with the response. |
| `rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `rsp_tag` | in | 8 | Tag of the request answered. |
| `rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |

35 ports; 19 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Reserved.  The SA registers live at 0x140-0x14F (hcr snoop), STATE 0x1B0-0x1BF, the weights stream through the AMB port (design §3.9 point 3).

## 5. State machine

-

## 6. Latency and throughput

-

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §3.9, Appendix A.

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
