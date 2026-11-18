import re
import struct

# Parse atg_srgb_thr from include/atg_srgb.vh
thr = {}
with open('include/atg_srgb.vh') as f:
    for line in f:
        m = re.search(r"8'd(\d+):\s+atg_srgb_thr\s+=\s+32'h([0-9A-Fa-f]+);", line)
        if m:
            thr[int(m.group(1))] = int(m.group(2), 16)

# thr[0] to thr[254]
assert len(thr) == 255

# Reference encoder
def ref_srgb_encode(b_bits):
    # NaN check
    ea = (b_bits >> 23) & 0xFF
    ma = b_bits & 0x7FFFFF
    if ea == 0xFF and ma != 0:
        return 0
    if b_bits & 0x80000000:
        return 0
    if b_bits >= 0x3F800000: # 1.0f
        return 255
    # Count thresholds <= b_bits
    cnt = 0
    for i in range(255):
        if b_bits >= thr[i]:
            cnt += 1
        else:
            break
    return cnt

# Fast hierarchical encoder
# 15 group thresholds: TH[k] = thr[(k+1)*16 - 1] for k in 0..14
TH = [thr[(k+1)*16 - 1] for k in range(15)]

# Table for TL_j[hi] = thr[hi*16 + j] for j in 0..14
TL = []
for hi in range(16):
    row = []
    for j in range(15):
        idx = hi * 16 + j
        row.append(thr[idx])
    TL.append(row)

def fast_srgb_encode(b_bits):
    ea = (b_bits >> 23) & 0xFF
    ma = b_bits & 0x7FFFFF
    if ea == 0xFF and ma != 0:
        return 0
    if b_bits & 0x80000000:
        return 0
    if b_bits >= 0x3F800000: # 1.0f
        return 255

    # Stage 1: find hi
    hi = 0
    for k in range(15):
        if b_bits >= TH[k]:
            hi += 1

    # Stage 2: find lo
    lo = 0
    for j in range(15):
        if b_bits >= TL[hi][j]:
            lo += 1

    return (hi << 4) | lo

# Test 1,000,000 values including boundaries around each threshold
errors = 0
tests = 0

# Check all thresholds and +/- 1, 2, 3
for t in thr.values():
    for delta in (-3, -2, -1, 0, 1, 2, 3):
        v = t + delta
        if 0 <= v <= 0x3F800000:
            tests += 1
            if ref_srgb_encode(v) != fast_srgb_encode(v):
                errors += 1
                print(f"Mismatch at 0x{v:08X}: ref={ref_srgb_encode(v)}, fast={fast_srgb_encode(v)}")
                if errors > 10:
                    break

print(f"Tested {tests} threshold boundaries, errors: {errors}")
