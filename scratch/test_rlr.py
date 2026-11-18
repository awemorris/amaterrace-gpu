# Verify equivalence of new rem_line_row_next vs old formula across all parameters

def old_formula(cur_da_row, cur_b_dst_delta_lo, pslw_ctl, m_rev, US=5):
    LINE_BYTES = 1 << US
    cur_da_row_next = (cur_da_row + cur_b_dst_delta_lo) & ((1 << US) - 1)
    da_px_row_next = cur_da_row_next >> pslw_ctl
    line_pixels_b = LINE_BYTES >> pslw_ctl
    rem_line_row_f = line_pixels_b - da_px_row_next
    rem_line_row_r = da_px_row_next + 1
    return rem_line_row_r if m_rev else rem_line_row_f

def new_formula(cur_da_row, cur_b_dst_delta_lo, pslw_ctl, m_rev, US=5):
    LINE_BYTES = 1 << US
    line_pixels_b = LINE_BYTES >> pslw_ctl
    mask_k = line_pixels_b - 1
    
    # current row remaining pixels
    da_px_cur = cur_da_row >> pslw_ctl
    rlr_curr = (da_px_cur + 1) if m_rev else (line_pixels_b - da_px_cur)
    
    delta_px = cur_b_dst_delta_lo >> pslw_ctl
    
    if m_rev:
        cand = (rlr_curr + delta_px)
    else:
        cand = (rlr_curr - delta_px) & ((1 << (US + 1)) - 1)
        
    masked = cand & mask_k
    return masked if masked != 0 else line_pixels_b

errors = 0
total = 0
for US in [5, 6]:
    for pslw_ctl in range(min(5, US)):
        bpp = 1 << pslw_ctl
        LINE_BYTES = 1 << US
        # Pixel-aligned byte offsets
        for cur_da_row in range(0, LINE_BYTES, bpp):
            for delta_bytes in range(0, LINE_BYTES, bpp):
                for m_rev in [0, 1]:
                    total += 1
                    old_v = old_formula(cur_da_row, delta_bytes, pslw_ctl, m_rev, US)
                    new_v = new_formula(cur_da_row, delta_bytes, pslw_ctl, m_rev, US)
                    if old_v != new_v:
                        print(f"Mismatch: US={US} psl={pslw_ctl} m_rev={m_rev} cur_da={cur_da_row} delta={delta_bytes}: old={old_v} new={new_v}")
                        errors += 1
                        if errors > 10:
                            break
            if errors > 10: break
        if errors > 10: break

print(f"Total tests: {total}, Errors: {errors}")
