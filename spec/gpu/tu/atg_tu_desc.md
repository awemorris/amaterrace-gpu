# atg_tu_desc

RTL: `rtl/gpu/tu/atg_tu_desc.v`.  Parent: atg_tu_addr.  Implemented in: p009 (part F).

## 1. Purpose and place

The TU's descriptors (STATE 0x090-0x18F: 16 slots of 16 words, docs/ghci.md §8.4) and the byte offsets of their mip levels, which the hardware computes from the image's size, level count, layout and view type.  No children.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `st_we` | in | 1 | One-cycle write of STATE[st_idx]. |
| `st_idx` | in | 10 | STATE index. |
| `st_wdata` | in | 32 | STATE value. |
| `busy` | out | 1 | A slot is marked or its offsets are being computed. |
| `rd_slot` | in | 5 | Read port: the slot (combinational); 16-31 the vertex stage's. |
| `rd_level` | in | 4 | Read port: the level. |
| `rd_base` | out | 32 | TEX_BASE of rd_slot. |
| `rd_size` | out | 32 | TEX_SIZE. |
| `rd_image` | out | 32 | TEX_IMAGE. |
| `rd_stride` | out | 32 | TEX_LAYER_STRIDE. |
| `rd_samp` | out | 32 | TEX_SAMPLER. |
| `rd_lod` | out | 32 | TEX_LOD. |
| `rd_fmt` | out | 21 | TEX_FORMAT[20:0] (0 after reset). |
| `rd_loff` | out | 32 | O_level: the offset of level rd_level from the layer's base (0 for level 0). |
| `rd_plane` | out | 32 | P_level: the bytes of one plane of level rd_level. |

17 ports.

## 4. Behaviour

- Keeps words 0-5 of each slot and TEX_FORMAT's bits 20:0 (word 6, CAPS[30], docs/ghci.md §8.5; reset to 0, the earlier formats); words 7-15 are reserved and not kept.
- A write of TEX_SIZE, TEX_IMAGE or TEX_FORMAT marks the slot.  One slot at a time, the lowest marked first, its offsets of levels 1-12 are computed again, one level a cycle: O_0 = 0, O_{l+1} = O_l + P_l × D_l (32-bit wrap), P_l = the plane of level l rounded up to a multiple of 64 (linear w_l × h_l × ps, ps the texel's bytes of the format (`include/atg_tu_fmt.vh`: 1-16 for TEX_FORMAT's formats; 4, or 2 for the earlier RGB565 code), tiled (only 4-byte texels and the earlier RGB565) ceil(w_l / 4) × ceil(h_l / 4) × 16 ps, compressed blocks (ETC2, EAC) ceil(w_l / 4) × ceil(h_l / 4) × the block's bytes, w_l = max(1, w >> l), h_l likewise), D_l = max(1, count >> l) for the view type 3D as written (TEX_IMAGE[11:9] = 2), 1 otherwise.  The offsets are kept as bits 31:6.
- A write to a slot while it is computed marks it again (it is computed once more).
- The read port is combinational; atg_tu_addr reads its quad's slot (tx_slot in IDLE).
- The reference is `tools/tumodel.py` (`plane`, `level_offset`).

## 5. State machine

IDLE →(a marked slot)→ RUN (levels 0-11, the slot's mark cleared) → IDLE.

## 6. Latency and throughput

12 cycles per marked slot after the write; busy covers them (atg_tu_addr takes no quad, STATUS.TU_BUSY is set).

## 7. Corner cases and errors

- Offsets beyond the level count are computed too (never used).
- After reset no slot is marked and the words are undefined until written (as STATE).

## 8. What the TB checks

No unit testbench of its own: `sim/tb/atg_tu_addr_tb.v` (`PASS atg_tu_addr.layout` and every address of the other groups) checks it through atg_tu_addr, with the slot's words written just before a quad.

## 9. References

docs/ghci.md §8.4 (the memory of an image), design §2.3.

## 10. Status

New in WS288 p009 part F (P3, branch p3-p009f): the TU computes the level offsets that were the descriptor's MIP_OFFSET words (part C); the freed words hold the view type, the depth or layer count and the layer stride.  Reading: the hardware computes (not the CP's firmware), so that a driver writes the same words whatever writes the descriptor; the cost is a 32 × 16 multiplier and 16 × 12 offsets of 26 bits.

RGB565 (the MSAA work): the plane of format 4 is w × h × 2 bytes (linear) or the tiles × 32 bytes, rounded up to 64.

TEX_FORMAT (2026-10-25): word 6 kept (21 bits, reset to 0: the TB scenes and firmware that never write it keep the earlier formats), rd_fmt, the plane by the format's texel size; TEX_IMAGE[8] reads as linear for texels other than 4 bytes.

2026-10-25 (CAPS[30]): 32 slots: 0-15 at STATE 0x090-0x18F (fragment and compute programs), 16-31 at 0x200-0x2FF (vertex programs, docs/ghci.md §8.5); a marked slot of either is computed as before (32 × 12 offsets).
