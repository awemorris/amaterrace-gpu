def orig(rlr_cand, psl_ctl, LINE_BYTES=32):
    US = 5
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

def new_calc(rlr_cand, psl_ctl, LINE_BYTES=32):
    US = 5
    res = 0
    # bit 0, 1, 2:
    res |= (rlr_cand & 0x7)
    
    # bit 3:
    if psl_ctl == 2:
        b3 = 1 if ((rlr_cand & 0x7) == 0) else 0
    elif psl_ctl < 2:
        b3 = (rlr_cand >> 3) & 1
    else:
        b3 = 0
    res |= (b3 << 3)
    
    # bit 4:
    if psl_ctl == 1:
        b4 = 1 if ((rlr_cand & 0xF) == 0) else 0
    elif psl_ctl == 0:
        b4 = (rlr_cand >> 4) & 1
    else:
        b4 = 0
    res |= (b4 << 4)
    
    # bit 5:
    if psl_ctl == 0:
        b5 = 1 if ((rlr_cand & 0x1F) == 0) else 0
    else:
        b5 = 0
    res |= (b5 << 5)
    return res

all_ok = True
for psl in [0, 1, 2]:
    for cand in range(64):
        o = orig(cand, psl)
        n = new_calc(cand, psl)
        if o != n:
            print(f"Mismatch for psl={psl}, cand={cand}: orig={o}, new={n}")
            all_ok = False
            break
if all_ok:
    print("ALL 192 CASES MATCH EXACTLY!")
