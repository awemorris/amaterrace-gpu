# atg_rop_wb

RTL: `rtl/gpu/rop/atg_rop_wb.v`.  Parent: atg_rop.  Child: `atg_rop_wpix`.  Implemented in: p007.

## 1. Purpose and place

ROP write-back: a small write-combining buffer of render-target lines; reads the destination line when its old pixels are needed, sends the pixels of each beat (one colour attachment of a quad, CAPS[30]) through a blend path (atg_rop_blend, atg_rop_fblend in atg_rop_wpix, or the packing alone), writes lines back; drains when idle.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |

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
| **From atg_rop_ds** | | | |
| `d_valid` | in | 1 | A quad after depth/stencil. |
| `d_ready` | out | 1 | Taken. |
| `d_xy` | in | 32 | Position. |
| `d_smask` | in | 16 | Samples that passed (bit 4 l + s). |
| `d_color` | in | 512 | Colour (DEBUG_COLOR expanded for q_dbg). |
| `d_rt` | in | 2 | (CAPS[30]) The beat's attachment. |
| `d_nocol` | in | 1 | (CAPS[30]) A beat without colour: taken and dropped. |
| **atg_rop_blend** | | | |
| `b_valid` | out | 1 | Blend. |
| `b_src` | out | 512 | Source. |
| `b_dst` | out | 128 | Destination. |
| `b_mask` | out | 4 | Slots (atg_rop_wpix's o_mask). |
| `b_rt` | out | 2 | The attachment (atg_rop_blend chooses its BLEND, write mask and format). |
| `b_rvalid` | in | 1 | Result. |
| `b_pix` | in | 128 | Pixels. |
| `busy` | out | 1 | Lines not yet written or responses outstanding. |
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

32 ports; 21 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

- Two line entries, entry r for row r of the quad (quads have even y, so a line never sits in both).  A miss writes the old line back (its dirty bytes only) and reads the new one when atg_rop_wpix's o_read says the old pixels are needed (blend on, or a write mask without every channel of the format); a line kept without reading serves only beats that need no read.  After 16 idle cycles the dirty lines are written and both entries emptied (the next draw must not blend with lines another block may have changed); busy stays up until then, so FENCE sees the pixels.
- A beat with d_nocol, or one atg_rop_wpix drops (no format with the colour-attachment feature, or no channel of the format in the attachment's write mask), is taken and nothing is read or written.
- One line per row (2 S ps ≤ LINE_BYTES): both rows' lines are found first, then one pass per sample (S passes) through the path, each on the lanes whose sample survived; a pass without lanes is skipped.
- Several lines per row (4 samples with 2 S ps > LINE_BYTES: 8- and 16-byte pixels at 32-byte lines, 16-byte pixels at 64): row by row, line by line (lines without a surviving sample skipped), one pass per line.
- The pass's result (atg_rop_blend's b_pix 3 cycles after b_valid; atg_rop_fblend's when done; the packing at once) merges ps bytes per slot into the slot's entry and marks them dirty.
- Simulation only: a row of one line that crosses it, or a row of several lines whose address is not a line's, prints `FAIL atg_rop_wb` (the alignment of docs/ghci.md §8.5: bases multiples of 64, strides of 2 S ps).

## 5. State machine

IDLE →(beat)→ ROW (the row's or line's address from atg_rop_wpix; drop) → LOOK (hit, or EVW: write the old line) → FILL (read when needed) → back to ROW (one line per row, row 0) or BLEND → BWAIT (the path's result, merge) → BLEND (next sample) / ROW (next line) / IDLE.  IDLE →(16 idle cycles)→ FLUSH ⇄ FLW → IDLE.

## 6. Latency and throughput

One beat at a time.  One sample of a 4-byte format on hits: ROW, LOOK, ROW, LOOK, BLEND, BWAIT (3 cycles of atg_rop_blend): about 9 cycles a beat.  The fp32 path takes atg_rop_fblend's cycles (up to about 640 per pass).  A quad of several attachments evicts the other attachments' lines (two entries); faster write-back is p025's.

## 7. Corner cases and errors

- Attachments are not expected to alias; a hit is by address only.
- `-DMUT_WPIX_LINE` (atg_rop_wpix: the line index left out) and `-DMUT_WPIX_KEEP` (the packing's kept bits not merged) fail `atg_rop_mrt`.

## 8. What the TB checks

`sim/tb/atg_rop_wb_tb.v` prints, in this order:

- `PASS atg_rop_wb.write` — pixels reach memory
- `PASS atg_rop_wb.blend` — read-blend-write
- `PASS atg_rop_wb.drain` — busy falls only after the writes are answered
- `PASS atg_rop_wb` at the end.

`sim/tb/atg_rop_mrt_tb.v` (CAPS[30]; atg_rop_wb, atg_rop_wpix and atg_rop_blend against amb_mem and `sim/vec/rop_mrt.txt` from `tools/rop-vectors.py`: 72 runs of four attachments of every colour-attachment format, absent ones and attachment 0 by RT_FORMAT's code, random blends, write masks and both kinds of constants, 24 quads each as beats (some without colour), at 32- and 64-byte lines; the four targets' region word for word) prints:

- `PASS atg_rop_mrt.one` — the runs with one sample
- `PASS atg_rop_mrt.four` — the runs with four samples (rows of one line and of several)
- `PASS atg_rop_mrt` at the end.

## 9. References

design §2.3 (RT_*), §3.8 (ROP is never blocked by the SU).

## 10. Status

2026-10-24 Q1 (P3's p007 decisions, ACKed; ghci.md to follow): stencil ops are not implemented in v1 (the ROP gets no facing bit; a port change belongs to p009). STATE bits: SCISSOR_MIN/MAX `{y, x}` (MAX 0 = none), RT_SIZE `{h, w}`, CULL [1:0] 1 front/2 back/3 both and [2] front = CCW, DEBUG_COLOR and BLEND_CONST RGBA8 (R in [7:0]), BLEND [0] enable, [4:1] src colour, [8:5] dst colour, [11:9] colour op, [15:12] src alpha, [19:16] dst alpha, [22:20] alpha op (VkBlendFactor/VkBlendOp numbers), WRITE_MASK [3:0] RGBA (0 writes nothing), DEPTH func = VkCompareOp and no test without a depth format bit; DS_BASE/RT_BASE/stride aligned to 8 bytes (4 for RGB565). The CP sequencer holds a SET_REG into the RX range (0x050–0x06F) while RX or ROP is busy and into the ROP range (0x070–0x08F) while the ROP is busy.

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.

Multisampling (the MSAA work): MS_CTRL[3:0] = 2: the pixel of sample s of x at (4 x + s) ps of the row (a quad's row is one line still), and the quad goes through `atg_rop_blend` once per sample (b_mask: the lanes whose sample passed); one sample: one pass as before.  `d_mask` became `d_smask`.  The 4-sample cases are in `sim/tb/atg_rop_ms_tb.v`.

2026-10-25 (CAPS[30], colour attachments): rewritten with the new child `atg_rop_wpix` (the attachments' state, the pixels' places, the paths); ports d_rt, d_nocol, b_rt (32).  Pixels of 1, 2, 4, 8 and 16 bytes, rows of one line or several, the three paths (§4).  The earlier TB is unchanged and passes.

2026-10-25 (area): the merge of a pass's pixels into the entries assumes the offsets that docs/ghci.md section 8.5 requires (bases multiples of 64, strides of 2 x S x ps, so a pixel's offset is a multiple of ps): a slot writes the whole ps-byte unit that holds its offset, the pixel repeated over 16 bytes (a byte of the line chooses among the four slots only).  With an offset that is not a multiple of ps (a base or stride outside section 8.5) the low bits are ignored: the pixel goes to the unit below it, where before it went to the unaligned bytes.  Aligned rows are unchanged; the TBs pass as before.
