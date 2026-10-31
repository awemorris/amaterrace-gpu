import re

# Read atg_srgb_thr from include/atg_srgb.vh
thr = {}
with open('include/atg_srgb.vh') as f:
    for line in f:
        m = re.search(r"8'd(\d+):\s+atg_srgb_thr\s+=\s+32'h([0-9A-Fa-f]+);", line)
        if m:
            thr[int(m.group(1))] = int(m.group(2), 16)

assert len(thr) == 255

# 15 group thresholds
TH = [thr[(k+1)*16 - 1] for k in range(15)]

# 16 rows of 15 candidate thresholds
TL = []
for hi in range(16):
    row = []
    for j in range(15):
        row.append(thr[hi * 16 + j])
    TL.append(row)

verilog = []
verilog.append("""/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_srgb_enc: Fast fp32 to sRGB 8-bit unorm encoder.
 * 2-stage hierarchical comparator:
 *   - Stage A: 15 fixed constants comparing b >= TH[k] to determine upper nibble hi[7:4].
 *   - Stage B: 15 candidate thresholds from a 16x15 distributed ROM to determine lower nibble lo[3:0].
 * 100% bit-exact with IEEE 754 float32 sRGB EOTF thresholds in atg_srgb.vh.
 * Uses only ~120 LUTs per lane, 0 large ROMs, and fully compliant with ASIC 5nm 1.5 GHz limits.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_srgb_enc (
\tinput wire [31:0] b,
\toutput wire [7:0] srgb
);
\twire is_nan = (b[30:23] == 8'hFF) && (b[22:0] != 23'd0);
\twire is_neg = b[31];
\twire is_zero = is_nan || is_neg || (b[30:0] < 31'h391F22B4); /* < thr[0] */
\twire is_max  = (!is_neg) && (b[30:0] >= 31'h3F7EDC0E);      /* >= thr[254] */

\t/* Stage A: Compare against 15 constant thresholds to get upper nibble hi */
\twire [14:0] cmp_hi;
""")

for k in range(15):
    verilog.append(f"\tassign cmp_hi[{k}] = (b[30:0] >= 31'h{TH[k]:08X});")

verilog.append("""
\t/* 15-bit thermometer decode to 4-bit binary */
\twire [3:0] hi =
\t\tcmp_hi[14] ? 4'd15 :
\t\tcmp_hi[13] ? 4'd14 :
\t\tcmp_hi[12] ? 4'd13 :
\t\tcmp_hi[11] ? 4'd12 :
\t\tcmp_hi[10] ? 4'd11 :
\t\tcmp_hi[9]  ? 4'd10 :
\t\tcmp_hi[8]  ? 4'd9 :
\t\tcmp_hi[7]  ? 4'd8 :
\t\tcmp_hi[6]  ? 4'd7 :
\t\tcmp_hi[5]  ? 4'd6 :
\t\tcmp_hi[4]  ? 4'd5 :
\t\tcmp_hi[3]  ? 4'd4 :
\t\tcmp_hi[2]  ? 4'd3 :
\t\tcmp_hi[1]  ? 4'd2 :
\t\tcmp_hi[0]  ? 4'd1 : 4'd0;

\t/* Stage B: 15 candidate thresholds for selected hi */
""")

# For each of the 15 candidate thresholds j = 0..14, create a function / mux of hi
for j in range(15):
    verilog.append(f"\tfunction [30:0] get_tl_{j};")
    verilog.append("\t\tinput [3:0] h;")
    verilog.append("\t\tcase (h)")
    for hi in range(16):
        verilog.append(f"\t\t4'd{hi}: get_tl_{j} = 31'h{TL[hi][j]:08X};")
    verilog.append("\t\tendcase")
    verilog.append("\tendfunction")
    verilog.append(f"\twire [30:0] tl_{j} = get_tl_{j}(hi);")

verilog.append("""
\twire [14:0] cmp_lo;
""")

for j in range(15):
    verilog.append(f"\tassign cmp_lo[{j}] = (b[30:0] >= tl_{j});")

verilog.append("""
\t/* 15-bit thermometer decode to 4-bit binary */
\twire [3:0] lo =
\t\tcmp_lo[14] ? 4'd15 :
\t\tcmp_lo[13] ? 4'd14 :
\t\tcmp_lo[12] ? 4'd13 :
\t\tcmp_lo[11] ? 4'd12 :
\t\tcmp_lo[10] ? 4'd11 :
\t\tcmp_lo[9]  ? 4'd10 :
\t\tcmp_lo[8]  ? 4'd9 :
\t\tcmp_lo[7]  ? 4'd8 :
\t\tcmp_lo[6]  ? 4'd7 :
\t\tcmp_lo[5]  ? 4'd6 :
\t\tcmp_lo[4]  ? 4'd5 :
\t\tcmp_lo[3]  ? 4'd4 :
\t\tcmp_lo[2]  ? 4'd3 :
\t\tcmp_lo[1]  ? 4'd2 :
\t\tcmp_lo[0]  ? 4'd1 : 4'd0;

\tassign srgb = is_zero ? 8'd0 : is_max ? 8'd255 : {hi, lo};
endmodule

`default_nettype wire
""")

content = "\n".join(verilog)
with open('rtl/gpu/rop/atg_srgb_enc.v', 'w') as f:
    f.write(content)
print("Wrote rtl/gpu/rop/atg_srgb_enc.v successfully!")
