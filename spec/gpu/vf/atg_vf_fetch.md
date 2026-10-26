# atg_vf_fetch

RTL: `rtl/gpu/vf/atg_vf_fetch.v`.  Parent: atg_vf.  Implemented in: p009.

## 1. Purpose and place

VF attribute fetch: for each vertex of a warp and each enabled attribute k (ATTR[k]_BASE/DESC), computes the address (per-vertex or per-instance with divisor) and reads the attribute's bytes through the AMB.

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
| **Vertices of a warp (atg_vf_asm → atg_vf_fetch)** | | | |
| `vb_valid` | in | 1 | A vertex for lane vb_lane. |
| `vb_ready` | out | 1 | Taken. |
| `vb_index` | in | 32 | Index (+ VERTEX_OFFSET applied). |
| `vb_inst` | in | 32 | Instance. |
| `vb_lane` | in | 5 | Lane. |
| `vb_last` | in | 1 | Last vertex of the warp. |
| **Attribute data (atg_vf_fetch → atg_vf_conv)** | | | |
| `af_valid` | out | 1 | One attribute of one vertex. |
| `af_ready` | in | 1 | Taken. |
| `af_attr` | out | 4 | Attribute k. |
| `af_lane` | out | 5 | Lane. |
| `af_raw` | out | 128 | Raw bytes (up to 16), byte 0 in [7:0]. |
| `af_oob` | out | 1 | (CAPS[30]) The attribute is outside its ATTR_LIMIT; af_raw is unspecified. |
| `af_last` | out | 1 | Last attribute of the last lane of the warp. |
| `busy` | out | 1 | Work outstanding. |
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

30 ports; 19 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

- Attribute k is **enabled when its whole ATTR_DST[k] word is not 0** (ATTR_DST[7:6] holds count − 1, so "0 components" cannot be encoded; a word of 0 means "not used", and a 1-component attribute cannot go to r0).  For each vertex from vb, the enabled attributes in ascending k, one at a time.
- element = index for a per-vertex attribute; for a per-instance one (DESC[20]) Vulkan's rule: FIRST_INSTANCE + (inst − FIRST_INSTANCE) / divisor, and FIRST_INSTANCE for divisor 0 (DESC[31:24]; divisor 1 needs no division; others use a sequential divider, 32 cycles, with a one-entry memo).  addr = ATTR_BASE + stride × element (mod 2^32).  The size comes from the format (4, 8, 12 or 16 bytes; the reserved formats read 4); with CAPS[30] and ATTR_DST[k][31:24] ≠ 0 it is the VkFormat's bytes (`atg_fmt_info`: 1, 2, 4, 8, 12 or 16; a value without an entry, and a compressed block, reads 4); any byte alignment.
- An attribute is enabled when its whole ATTR_DST word (with [31:24]) is not 0, so a VkFormat attribute may go to r0 with one component.
- **ATTR_LIMIT[k]** (0x1D0 + k, CAPS[30]): with [31] = 1, an attribute whose bytes pass the limit (offset + size > [30:0], where offset = stride × element, with offset + size computed in 49 bits so it cannot wrap; checked in PLAN, which then goes straight to EMIT) is not read: its af comes with `af_oob` = 1 and atg_vf_conv writes (0, 0, 0, 1).  [31] = 0: no limit (as before).  The robust buffer access of Vulkan's (0, 0, 0, 1) form.
- **Line buffer architecture**: 4 independent attribute streams (Position, Normal, Color, TexCoord, etc. mapped as $s = k[1:0]$), each equipped with an 8-entry line buffer (256 bytes per stream, 32 entries / 1 KiB total). Each stream independently caches its fetched lines so that fetching one attribute never evicts another attribute's cached lines (eliminating cache thrashing across multiple vertex buffers). An attribute crossing line boundaries uses two entries within its stream buffer without evicting either.
- Requests to the AMB use tags `{3'b0, s[1:0], entry[2:0]}` allowing responses to be demultiplexed directly to the targeted stream and entry. The entries are cleared on warp completion. An error response reads as 0 (the MC raises the fault).
- af_raw byte 0 is the byte at addr; bytes beyond the format's size are unspecified.  Order out: lane-major (all attributes of lane 0, then lane 1) so conv can write as data comes; af_last on the last attribute of the vertex with vb_last.  A warp whose vertices have no enabled attribute still sends one af (attr 0, which is then disabled, af_last) so that atg_vf_conv pulses conv_done.

## 5. State machine

IDLE →(vb)→ ELEM (element; DIV for a divisor above 1 not in the memo) → MUL (address) → PLAN (hit/miss, entries) → REQ (the misses) → DATA (responses) → EMIT →(next enabled attribute: ELEM | none: IDLE).  A vertex without enabled attribute: IDLE, or NONE (the dummy af) when it is the warp's last.

## 6. Latency and throughput

- On a line buffer hit, `ST_PLAN` transitions directly to `ST_EMIT`, completing the attribute in ~4 cycles (0 DRAM latency).
- With 4 streams retaining up to 8 lines each (1 KiB total), subsequent vertices within the warp achieve near 100% cache hit rates, boosting vertex delivery rate by 4x over the single 2-line buffer design.
- A miss initiates pipelined AMB burst requests; line responses arrive tagged per stream/entry.

## 7. Corner cases and errors

- Divisor 0 means every instance uses instance FIRST_INSTANCE's data (Vulkan's divisor 0 rule).
- No enabled attribute: see §4 (the dummy af).
- rsp_error: the bytes read as 0; the warp still ends.

## 8. What the TB checks

`sim/tb/atg_vf_fetch_tb.v` prints, in this order:

- `PASS atg_vf_fetch.addr` — strides, offsets, per-instance with divisors (0, 1, 2, 3, 7, 255, FIRST_INSTANCE above 0), every format, disabled attributes and a warp without any
- `PASS atg_vf_fetch.cross` — attributes that cross a line (any byte alignment)
- `PASS atg_vf_fetch.limit` — ATTR_LIMIT: attributes just inside and just outside, per vertex and per instance (CAPS[30])
- `PASS atg_vf_fetch.limit0` — [31] = 1 with 0 bytes: nothing is read
- `PASS atg_vf_fetch.size12` — R32G32B32 (12 bytes) by VkFormat
- `PASS atg_vf_fetch` at the end.

## 9. References

design §2.3 (ATTR_*), §3.4.3.

## 10. Status

Implemented.
Phase 032 (2026-10-27): Multi-stream line buffer expansion (4 streams x 8 entries = 32 entries / 1 KiB total) and direct hit emit pipeline. All arithmetic operations linted clean (0 bare operators). PASS atg_vf_fetch verified.

Implemented in WS288 p009 part A (branch p1-vf).  Readings of the text above (Q1 to confirm): the enable rule is "ATTR_DST[k] ≠ 0" (§4); the per-instance element follows Vulkan (relative to FIRST_INSTANCE), where the earlier text said inst / divisor; the dummy af for a warp without attributes.  Difference from §6's target: two reads in flight, not four.  Ports and parameters unchanged.  2026-10-25 (CAPS[30], spec first, the RTL follows): the size from the VkFormat and ATTR_LIMIT (§4); one new port `af_oob` (out, 1: the attribute is outside its limit, af_raw unspecified), 31 ports, 20 counting each AMB and HCR port as one group.  MUT_ATTR_LIMIT_GE (the limit compare as ≥) must make the TB fail.  Implemented 2026-10-25: every PASS of §8; `iverilog -DMUT_ATTR_LIMIT_GE` fails `atg_vf_fetch.limit` (the limits there sit on stride × element + size − 1, + 0 and + 1 with elements 0-7).
