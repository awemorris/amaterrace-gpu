# atg_cp_regs

RTL: `rtl/gpu/cp/atg_cp_regs.v`.  Parent: atg_cp.  Implemented in: p004 (done).

## 1. Purpose and place

The GHCI register bus decoder of the CP: identification, CAPS, EXTCAP list, VEND, SCRATCH, COUNTER and PERF registers, plus the HCR snoop bus and the STATE alias that the other CP modules (and atg_cpu) use for their own registers.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `GCLK_HZ` | `32'd100000000` | GCLK_HZ register. |
| `VENDOR_ID` | `32'h414D4154` | "AMAT". |
| `DEVICE_ID` | `32'h41544731` | "ATG1". |
| `DEVICE_VERSION` | `32'h00000002` | Implementation version. |
| `ISA_ID` | `32'h47534931` | "GSI1"; 0 when there is no SU. |
| `NATIVE_ISA_ID` | `32'h47534931` | NATIVE_ISA_ID (0x048). |
| `RESIDENT_WARPS` | `16'd0` | RESIDENT_WARPS (0x04C) [15:0]: the warps the GPU runs at once over its SUs (atg_top: NSU x SU_NWARPS). |
| `NREGS` | `8'd0` | RESIDENT_WARPS [23:16]: the general registers of a lane (atg_top: SU_NREGS with an SU, else 0). |
| `LOCAL_BASE` | `32'd0` | MEM capability LOCAL_BASE (0x1E0). |
| `LOCAL_BYTES` | `32'd0` | MEM capability LOCAL_SIZE (0x1E4). |
| `WINDOW_BYTES` | `32'd0` | MEM capability WINDOW_SIZE (0x1E8); not 0 gives WINDOW_CTRL its bit. |
| `HOST_LIMIT` | `32'd0` | MEM capability HOST_LIMIT (0x1EC): host addresses below it; 0 = all (GHCI §11.2). |
| `CAPS` | `32'h00500002` | CAPS value (design §2.2), set by atg_top from its parameters. |
| `CAPS2` | `32'h00000001` | CAPS2 value. |
| `VEND` | `256'd0` | The 8 VEND words (0x0C0-0x0DF), word 0 in bits 31:0. |
| `XCAP_MASK` | `10'h004` | Which extended capabilities are listed: bit id-1 (DISP 1, DBG 2, PERF 3, VEND 4, CPFW 6, SA 7, MEM 8 at 0x1E0, PROT 9 at 0x1D0 (atg_cp_prot), FMT 10 at 0x160, atg_cp_fmt). |
| `DISP_OFFSET` | `32'h00010000` | Where the DISP entry points (KC705 +0x10000). |
| `PERF_SRC` | `32'hFFFFFFFF` | PERF_SRC0..3 (byte n = PERF_SRCn; 0xFF unused). Amaterrace 2D: 0xFFFF0801 (BLT busy, memory). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Register bus (from am_axi_regs or am_jtag_regs)** | | | |
| `reg_wr` | in | 1 | Write strobe. |
| `reg_waddr` | in | 17 | Byte address. |
| `reg_wdata` | in | 32 | Data. |
| `reg_wstrb` | in | 4 | Byte strobes. |
| `reg_rd` | in | 1 | Read strobe. |
| `reg_raddr` | in | 17 | Read address. |
| `reg_rdata` | out | 32 | Read data, the cycle after reg_rd. |
| **HCR snoop bus (to the other CP modules and atg_cpu)** | | | |
| `hcr_we` | out | 1 | Write to 0x000-0xFFC (the cycle of reg_wr). |
| `hcr_widx` | out | 10 | reg_waddr[11:2]. |
| `hcr_wdata` | out | 32 | reg_wdata. |
| `hcr_wmask` | out | 32 | WSTRB expanded to bits. |
| `hcr_ridx` | out | 10 | Registered reg_raddr[11:2] (valid the cycle after reg_rd). |
| **STATE alias (0x1000-0x1BFC, to atg_cp_state)** | | | |
| `alias_we` | out | 1 | Whole-word write to the alias (WSTRB = 4'hF; partial writes are dropped here). |
| `alias_idx` | out | 10 | reg_waddr[11:2] (0x1000-0x1BFC); the data is hcr_wdata. |
| `alias_ridx` | out | 10 | reg_raddr[11:2], combinational (the state RAM registers it). |
| **Read data of the other modules (0 outside their registers)** | | | |
| `ctl_rdata` | in | 32 | atg_cp_ctl. |
| `irq_rdata` | in | 32 | atg_cp_irq. |
| `ring_rdata` | in | 32 | atg_cp_ring. |
| `fence_rdata` | in | 32 | atg_cp_fence. |
| `dbg_rdata` | in | 32 | atg_cp_dbg. |
| `state_rdata` | in | 32 | atg_cp_state (registered RAM output for alias_ridx). |
| `x_rdata` | in | 32 | Outside the CP: atg_cpu's CPFW registers (0x120-0x13F), atg_sa's SA registers; 0 if absent. |
| **PERF** | | | |
| `perf_busy` | in | 4 | Busy levels counted by PERF0-3 (Amaterrace: SU, RX, TU, MC). |
| `perf_reset` | in | 1 | PERF_RESET µop (one cycle) from atg_cp_seq; PERF_CTRL[0] clears too. |
| **MEM** | | | |
| `win_en` | out | 1 | WINDOW_CTRL.ENABLE: the local window is open (to the board's window path, through atg_cp and atg_top).  1 after `rst_n` with a window (MEM listed, WINDOW_BYTES not 0), else 0. |

27 ports.

## 4. Behaviour

- Writes: `hcr_we` for 0x00000-0x00FFC (also KICK at 0xF00; atg_cp_ctl snoops it), `alias_we` for
  0x01000-0x017FC with WSTRB = 4'hF.  0x10000 and above are not the CP's (the top decodes the DC).
  This module itself keeps SCRATCH (0x028) and PERF_CTRL; everything else belongs to the module that
  uses it (snoop rule: a module takes the writes of its own word indices).
- Reads: the cycle after `reg_rd`, `reg_rdata` = this module's own register at `hcr_ridx`
  (MAGIC, VERSION, VENDOR_ID, DEVICE_ID, ISA_ID, DEVICE_VERSION, EXTCAP = 0x100, GCLK_HZ, CAPS, CAPS2,
  SCRATCH, COUNTER, NATIVE_ISA_ID, VEND, PERF0-3, PERF_CTRL, PERF_SRCn, the EXTCAP list at 0x100) OR
  the `*_rdata` inputs, or `state_rdata` for the alias range, or 0 elsewhere.
- EXTCAP list at 0x100: one 2-word entry per set bit of XCAP_MASK in id order; the first two at 0x100
  and 0x108, the others from 0x180 (0x110-0x17F hold PERF, CPFW and SA registers); EXTCAP reads 0
  when XCAP_MASK is 0 (PERF keeps its
  registers at 0x110, design §2.4.10; VEND 0x0C0; CPFW 0x120; SA 0x140; after the room of a full list
  (0x100-0x1BF) PROT 0x1D0 (atg_cp_prot) and MEM 0x1E0; DISP at DISP_OFFSET; DBG 0).
- MEM (XCAP_MASK[7]): 0x1E0 LOCAL_BASE, 0x1E4 LOCAL_BYTES, 0x1E8 WINDOW_BYTES, 0x1EC HOST_LIMIT (read only),
  0x1F0 WINDOW_CTRL ([0] ENABLE, RW, `win_en`); they read 0 when MEM is not listed.  WINDOW_CTRL.ENABLE
  is 1 after `rst_n` (the board's reset: CTRL.RESET does not reach this module) and takes writes whose
  byte 0 is enabled; without a window (WINDOW_BYTES 0) it reads 0 and ignores writes (GHCI §11.1, §11.3).
- COUNTER counts every clk.  PERFn counts cycles with `perf_busy[n]`; cleared by PERF_CTRL[0] or
  `perf_reset`.

## 5. State machine

None (registers and a read mux).

## 6. Latency and throughput

Register read latency 1 cycle (the am_axi_regs contract).

## 7. Corner cases and errors

- A write with partial WSTRB to the alias is dropped (and reported by atg_cp_state only for whole
  words written while locked).
- Addresses 0x01800-0x0FFFF read 0.
- The read answer is combinational from the registered index (`hcr_ridx`) and the modules'
  `*_rdata`, valid the cycle after `reg_rd` (the am_axi_regs contract).

## 8. What the TB checks

`sim/tb/atg_cp_regs_tb.v` prints, in this order:

- `PASS atg_cp_regs.id` — identification, CAPS, CAPS2, VEND, RESIDENT_WARPS (with NREGS in [23:16]) read their parameter values
- `PASS atg_cp_regs.extcap` — the EXTCAP list walks to the end for several XCAP_MASK values; with MEM listed, its entry points at 0x1E0 and the four read-only words read the parameters (0 without MEM, 0 at the old 0x1C0)
- `PASS atg_cp_regs.window` — WINDOW_CTRL reads 1 and `win_en` is 1 after reset, written 0 both are 0, a write without byte 0 does not change it, written 1 they are 1 again, the reset opens it again; 0 without MEM
- `PASS atg_cp_regs.fmt` — (CAPS[30]) a bench with atg_cp_fmt beside it: the FMT entry (id 10, 0x160), FMT_INDEX written and read back (partial writes too), FMT_OPTIMAL, FMT_LINEAR and FMT_BUFFER for all 256 values against `sim/vec/fmt_info.txt`, FMT_LIMITS 4
- `PASS atg_cp_regs.snoop` — a write gives one hcr_we with index, data and mask; a partial alias write gives no alias_we
- `PASS atg_cp_regs.ormux` — reads OR the module inputs; COUNTER increments; PERF counts busy and clears
- `PASS atg_cp_regs` at the end.

## 9. References

design §2.2, §2.4.10 (offsets of the v3 additions), include/ghci_regs.vh, the current inline code in `rtl/gpu/cp/atg_cp.v` (identification, CAPS, PERF).

## 10. Status

Implemented (WS288 p004 (P3, amaterrace-gpu p3-cp 4a4d2da..65cc445, merged as a094748)).  216 lines.  Spec change in p004: the `PERF_SRC` parameter, the list layout
above.

2026-10-25 (CAPS[30]): XCAP_MASK has 10 bits; FMT (id 10) points at 0x160 (atg_cp_fmt's window, ORed in by atg_cp through x_rdata).

2026-10-25 (p040): the MEM capability moved to 0x1E0 (five words do not fit before PROT at 0x1D0); WINDOW_CTRL at 0x1F0 and the `win_en` output.

2026-10-25 (p039): MEM HOST_LIMIT at 0x1CC (parameter HOST_LIMIT, through atg_cp from atg_top).

2026-10-25: the MEM capability (id 8, XCAP_MASK[7], registers at 0x1C0; parameters LOCAL_BASE, LOCAL_BYTES, WINDOW_BYTES) and RESIDENT_WARPS[23:16] = NREGS.

2026-10-25 (CAPS[30]): STATE has 0x000-0x2FF (0x200-0x2FF the vertex stage's texture slots, docs/ghci.md §8.1, §8.5); STATE indices are 10 bits.  The alias covers 0x1000-0x1BFC; 0x1C00-0x1FFC read 0 and ignore writes.
