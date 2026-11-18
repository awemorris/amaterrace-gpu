# atg_cp_seq_dec

RTL: `rtl/gpu/cp/atg_cp_seq_dec.v`.  Parent: atg_cp_seq.  Implemented in: (empty).

## 1. Purpose and place

`atg_cp_seq`'s decoders, combinational: for the header in hand, whether the op is known and
present and how many payload dwords it needs; for the payload dword in hand, whether it is a bad
index (SET_REG) or a bad offset (DISP_SET).  Moved out of `atg_cp_seq` to keep it under 400 lines
when DISP_SET and FLIP came (design §18.4).  No children.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `UNITS` | `8'h03` | Present blocks, STATUS busy-bit order. |
| `HAS_VSYNC` | `0` | WAIT_VSYNC is present. |
| `HAS_DISP` | `0` | A DISP2 controller: DISP_SET and FLIP are present. |

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `hdr` | in | 32 | The header dword. |
| `hdr_fw` | in | 1 | The header comes from the firmware's FIFO. |
| `h_known` | out | 1 | Class 0 or 1 and a known op. |
| `h_absent` | out | 1 | The op's unit is absent, or a DISP op from the firmware (fault 2). |
| `h_need` | out | 8 | Payload dwords the op needs (SET_REG and DISP_SET: n rounded up to even). |
| `vendor` | in | 1 | The current µop's class is 1. |
| `op` | in | 6 | The current µop. |
| `p` | in | 8 | The payload dwords taken. |
| `in_data` | in | 32 | The payload dword in hand. |
| `pay_bad` | out | 1 | The dword is an index (even p) of SET_REG outside 0x000-0x2FF, or an offset of DISP_SET that is not a DISP_SET register (docs/ghci.md §7.3): fault 3, `fault_addr` = the dword. |

10 ports.

## 4. Behaviour

The header rules of `atg_cp_seq` (unchanged), plus op 15 DISP_SET (need: n rounded up to even)
and 16 FLIP (need 4), absent without `HAS_DISP` or with `hdr_fw`.  DISP_SET's offsets: 0x10,
0x28, 0x2C, 0x30-0x50, 0x58, 0xA4 and 0xA8 (4-byte aligned, below 0x100).

## 5. State machine

None.

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

- FB_NEXT (0x24) is not a DISP_SET register (FLIP writes it).

## 8. What the TB checks

Through `sim/tb/atg_cp_seq_tb.v` (groups `disp` and the existing header groups).

## 9. References

docs/ghci.md §7.3; design §18.4.

## 10. Status

Implemented (WS288 p035 D4, 2026-10-25, P3): about 140 lines, `n` rounded up to even with one `am_add`.  Checked through `atg_cp_seq_tb` (`disp`, `badop`).
