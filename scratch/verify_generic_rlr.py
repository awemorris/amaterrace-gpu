def generic_calc(rlr_cand, psl_ctl, LINE_BYTES):
    import math
    US = int(math.log2(LINE_BYTES))
    line_pixels_b = LINE_BYTES >> psl_ctl
    res = 0
    res |= (rlr_cand & 1) # bit 0 is always rlr_cand[0] because line_pixels_b >= 4
    for k in range(1, US + 1):
        is_lp_k = (line_pixels_b == (1 << k))
        lt_lp_k = (line_pixels_b > (1 << k))
        if is_lp_k:
            eq_zero = ((rlr_cand & ((1 << k) - 1)) == 0)
            bit = 1 if eq_zero else 0
        elif lt_lp_k:
            bit = (rlr_cand >> k) & 1
        else:
            bit = 0
        res |= (bit << k)
    return res

def orig_calc(rlr_cand, psl_ctl, LINE_BYTES):
    import math
    US = int(math.log2(LINE_BYTES))
    line_pixels_b = LINE_BYTES >> psl_ctl
    mask_k = [0] * (US + 1)
    for g_mk in range(US):
        mask_k[g_mk] = 1 if ((line_pixels_b >> (g_mk + 1)) > 0) else 0
    mask_k[US] = 0
    
    rlr_masked = 0
    for i in range(US + 1):
        if (rlr_cand & (1 << i)) and mask_k[i]:
            rlr_masked |= (1 << i)
    if rlr_masked != 0:
        return rlr_masked
    else:
        return line_pixels_b

all_ok = True
for lb in [32, 64]:
    for psl in [0, 1, 2]:
        for cand in range(lb * 2):
            o = orig_calc(cand, psl, lb)
            g = generic_calc(cand, psl, lb)
            if o != g:
                print(f"Mismatch for LB={lb}, psl={psl}, cand={cand}: orig={o}, gen={g}")
                all_ok = False
                break
if all_ok:
    print("GENERIC FORMULA 100% MATCHES BOTH 32B AND 64B ACROSS ALL CASES!")
