# atg_cp_fmt

RTL: `rtl/gpu/cp/atg_cp_fmt.v` (new).  Parent: atg_cp (beside atg_cp_regs, on the HCR snoop port).

## 1. Purpose and place

The FMT extended capability (GHCI capability id 10): the register window through which a driver reads, format by format, the VkFormatFeatureFlags that the GPU's fixed-function units support, from the same table the units use (`atg_fmt_feat`).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `BASE` | `10'h058` | The window's first HCR dword index (byte 0x160; atg_cp_regs lists FMT at 0x160 in the extended capability list). |
| `HAS_ETC` | `0` | The TU has the ETC2/EAC decoder: the ten ETC2/EAC formats report their features. |
| `NRT` | `4` | Colour attachments (FMT_LIMITS[3:0]). |

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **HCR snoop port (atg_cp_regs)** | | | |
| `hcr_we` | in | 1 | A host write to the register file. |
| `hcr_widx` | in | 10 | Its dword index. |
| `hcr_wdata` | in | 32 | Data. |
| `hcr_wmask` | in | 32 | Bits written (byte enables expanded). |
| `hcr_ridx` | in | 10 | The registered read index. |
| `hcr_rdata` | out | 32 | This module's word for hcr_ridx, 0 outside its window (atg_cp_regs ORs it). |

8 ports; 3 counting the HCR snoop port as one group.

## 4. Behaviour

Registers (byte offsets from 0x160): +0x0 FMT_INDEX (RW, [7:0] a VkFormat value; [31:8] read 0), +0x4 FMT_OPTIMAL (R: `atg_fmt_feat(FMT_INDEX, HAS_ETC)`'s optimal features), +0x8 FMT_LINEAR (R: the same), +0xC FMT_BUFFER (R: the buffer features), +0x10 FMT_LIMITS (R: [3:0] NRT, [31:4] 0), +0x14-+0x1C read 0.  A write to FMT_INDEX is taken in every CP state (it changes nothing else); reads have no side effects.

## 5. State machine

None (one register and a combinational read).

## 6. Latency and throughput

The read data is ready in the cycle atg_cp_regs needs it (combinational from hcr_ridx and the register).  The table is `atg_fmt_feat`'s case, ≈0.2k LUT (estimated).

## 7. Corner cases and errors

- A value without an entry reads 0 in all three feature registers.
- A partial write (wmask) changes only the masked bits of FMT_INDEX[7:0].

## 8. What the TB checks

`sim/tb/atg_cp_regs_tb.v` (with this module beside atg_cp_regs) prints:

- `PASS atg_cp_regs.fmt` — the FMT entry in the extended capability list, FMT_INDEX write and read back, the three feature words for all 256 values against `sim/vec/fmt_info.txt`, FMT_LIMITS.

## 9. References

docs/ghci.md §4 (FMT), `spec/gpu/fmt/atg_fmt.md`, `spec/gpu/cp/atg_cp_regs.md`.  design §16.15.

## 10. Status

Implemented 2026-10-25: `PASS atg_cp_regs.fmt`.  atg_cp_regs lists FMT (id 10, XCAP_MASK 10 bits, 0x160); atg_cp instantiates this module when HAS_FMT (atg_top sets it with CAPS[30] in the integration step) and ORs its data into atg_cp_regs's x_rdata.
