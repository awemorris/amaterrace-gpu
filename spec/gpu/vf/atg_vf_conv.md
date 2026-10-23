# atg_vf_conv

RTL: `rtl/gpu/vf/atg_vf_conv.v`.  Parent: atg_vf.  Implemented in: p009.

## 1. Purpose and place

VF format conversion: turns raw attribute bytes (R32F … RGBA16F, RGBA8 UNORM/UINT, R32/RG32 UINT) into 32-bit words and writes them into the SU's registers at ATTR_DST[k].

## 2. Parameters

None.

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
| **Attribute data (atg_vf_fetch → atg_vf_conv)** | | | |
| `af_valid` | in | 1 | One attribute of one vertex. |
| `af_ready` | out | 1 | Taken. |
| `af_attr` | in | 4 | Attribute k. |
| `af_lane` | in | 5 | Lane. |
| `af_raw` | in | 128 | Raw bytes (up to 16), byte 0 in [7:0]. |
| `af_last` | in | 1 | Last attribute of the last lane of the warp. |
| **Register writes to the SU (atg_su vl_*)** | | | |
| `vl_we` | out | 1 | Attribute word. |
| `vl_reg` | out | 6 | Register (ATTR_DST[k] + component). |
| `vl_lane` | out | 5 | Lane. |
| `vl_data` | out | 32 | Data (converted to 32 bits). |
| `conv_done` | out | 1 | One-cycle pulse after the warp's last word. |

16 ports.

## 4. Behaviour

Formats of design §2.3 ATTR_DESC[19:16]; fp16 → fp32, UNORM8 → float (x/255), UINT → integer.  Components beyond the format's count and up to ATTR_DST's count are filled with (0, 0, 0, 1).  One word per cycle.

## 5. State machine

IDLE → WRITE (components) → IDLE.

## 6. Latency and throughput

One register word per cycle.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_vf_conv_tb.v` prints, in this order:

- `PASS atg_vf_conv.formats` — every format against a C reference
- `PASS atg_vf_conv.fill` — missing components get 0,0,0,1
- `PASS atg_vf_conv` at the end.

## 9. References

design §2.3, §3.4.3 (ATTR_DST).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
