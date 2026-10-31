import struct, random

def to_f32(val_int):
    return struct.unpack('>f', struct.pack('>I', val_int))[0]

def to_u32(val_float):
    return struct.unpack('>I', struct.pack('>f', val_float))[0]

def sim_orig(a_u, b_u, sub):
    # exact recreation of current atg_rx_fadd
    b_in = b_u ^ (0x80000000 if sub else 0)
    ea = (a_u >> 23) & 0xFF
    eb = (b_in >> 23) & 0xFF
    za = (ea == 0)
    zb = (eb == 0)
    ma = 0 if za else (0x800000 | (a_u & 0x7FFFFF))
    mb = 0 if zb else (0x800000 | (b_in & 0x7FFFFF))
    
    nan_a = (ea == 0xFF) and (a_u & 0x7FFFFF) != 0
    nan_b = (eb == 0xFF) and (b_in & 0x7FFFFF) != 0
    inf_a = (ea == 0xFF) and (a_u & 0x7FFFFF) == 0
    inf_b = (eb == 0xFF) and (b_in & 0x7FFFFF) == 0
    
    sa = (a_u >> 31) & 1
    sb = (b_in >> 31) & 1
    
    dab = (ea - eb) & 0xFF
    dba = (eb - ea) & 0xFF
    ea_lt_eb = (ea < eb)
    exp_diff = dba if ea_lt_eb else dab
    a_big = not ea_lt_eb if (ea != eb) else ((ea << 24) | ma) >= ((eb << 24) | mb)
    
    sp1 = nan_a or nan_b or (inf_a and inf_b and sa != sb) or inf_a or inf_b or (ma == 0 and mb == 0)
    if nan_a or nan_b or (inf_a and inf_b and sa != sb): spv1 = 0x7FC00000
    elif inf_a: spv1 = (sa << 31) | 0x7F800000
    elif inf_b: spv1 = (sb << 31) | 0x7F800000
    elif (ma == 0 and mb == 0): spv1 = ((sa and sb) << 31)
    else: spv1 = 0
    
    sx1 = sa if a_big else sb
    sub1 = (sa != sb)
    ex1 = ea if a_big else eb
    mx1 = ma if a_big else mb
    my1 = mb if a_big else ma
    d1 = 255 if (za or zb) else exp_diff
    
    # Stage 2
    shi = my1 << 3
    shr = (shi >> (d1 & 0x1F)) & 0x7FFFFFF
    if d1 >= 27:
        stk = 1 if my1 != 0 else 0
        sh = 0
    else:
        stk = 0
        for k in range(27):
            if k < d1 and ((shi >> k) & 1):
                stk = 1
        sh = shr
    
    px2 = mx1 << 3
    py2 = ((sh >> 1) << 1) | ((sh & 1) | stk)
    
    # Stage 3
    if sub1:
        sum_val = px2 - py2
    else:
        sum_val = px2 + py2
    
    lz = 27
    for k in range(27):
        if (sum_val >> k) & 1:
            lz = 26 - k
            
    nl = (sum_val << lz) & 0x7FFFFFF
    sum27 = (sum_val >> 27) & 1
    if sum27:
        n_comb = ((sum_val >> 2) << 1) | (((sum_val >> 1) & 1) | (sum_val & 1))
    else:
        n_comb = nl
        
    sz = (sum_val == 0)
    
    # Stage 4
    ex2_p1 = ex1 + 1
    e0_sub = ex1 - lz
    e0_4 = ex2_p1 if sum27 else e0_sub
    
    inc = ((n_comb >> 2) & 1) and (((n_comb >> 1) & 1) or (n_comb & 1) or ((n_comb >> 3) & 1))
    m0 = (n_comb >> 3) + (1 if inc else 0)
    m = (m0 >> 1) if (m0 >> 24) & 1 else m0
    e = e0_4 + (1 if (m0 >> 24) & 1 else 0)
    
    if sp1: return spv1
    if sz: return 0
    if e >= 255: return (sx1 << 31) | 0x7F800000
    if e <= 0: return (sx1 << 31)
    return (sx1 << 31) | ((e & 0xFF) << 23) | (m & 0x7FFFFF)

print("sim_orig ready")

def sim_dual_path(a_u, b_u, sub):
    b_in = b_u ^ (0x80000000 if sub else 0)
    ea = (a_u >> 23) & 0xFF
    eb = (b_in >> 23) & 0xFF
    za = (ea == 0)
    zb = (eb == 0)
    ma = 0 if za else (0x800000 | (a_u & 0x7FFFFF))
    mb = 0 if zb else (0x800000 | (b_in & 0x7FFFFF))
    
    nan_a = (ea == 0xFF) and (a_u & 0x7FFFFF) != 0
    nan_b = (eb == 0xFF) and (b_in & 0x7FFFFF) != 0
    inf_a = (ea == 0xFF) and (a_u & 0x7FFFFF) == 0
    inf_b = (eb == 0xFF) and (b_in & 0x7FFFFF) == 0
    
    sa = (a_u >> 31) & 1
    sb = (b_in >> 31) & 1
    
    dab = (ea - eb) & 0xFF
    dba = (eb - ea) & 0xFF
    ea_lt_eb = (ea < eb)
    exp_diff = dba if ea_lt_eb else dab
    
    # mant_cmp on raw bits
    mant_ge = (a_u & 0x7FFFFF) >= (b_u & 0x7FFFFF)
    a_big = not ea_lt_eb if (ea != eb) else mant_ge
    
    sp1 = nan_a or nan_b or (inf_a and inf_b and sa != sb) or inf_a or inf_b or (ma == 0 and mb == 0)
    if nan_a or nan_b or (inf_a and inf_b and sa != sb): spv1 = 0x7FC00000
    elif inf_a: spv1 = (sa << 31) | 0x7F800000
    elif inf_b: spv1 = (sb << 31) | 0x7F800000
    elif (ma == 0 and mb == 0): spv1 = ((sa and sb) << 31)
    else: spv1 = 0
    
    sx1 = sa if a_big else sb
    sub1 = (sa != sb)
    ex1 = ea if a_big else eb
    mx1 = ma if a_big else mb
    my1 = mb if a_big else ma
    d1 = 255 if (za or zb) else exp_diff
    
    # Stage 2
    shi = my1 << 3
    shr = (shi >> (d1 & 0x1F)) & 0x7FFFFFF
    if d1 >= 27:
        stk = 1 if my1 != 0 else 0
        sh = 0
    else:
        stk = 0
        for k in range(27):
            if k < d1 and ((shi >> k) & 1):
                stk = 1
        sh = shr
    
    px2 = mx1 << 3
    py2 = ((sh >> 1) << 1) | ((sh & 1) | stk)
    ex2 = ex1
    ex2_p1 = ex1 + 1
    ex2_sub1 = ex1 - 1
    
    # Stage 3
    if sub1:
        sum_val = px2 - py2
    else:
        sum_val = px2 + py2
        
    lz = 27
    for k in range(27):
        if (sum_val >> k) & 1:
            lz = 26 - k
            
    sz = (sum_val == 0)
    sum27 = (sum_val >> 27) & 1
    
    # Stage 4
    # Close path: sub1 and lz >= 2
    is_close = sub1 and (lz >= 2)
    nl = (sum_val << lz) & 0x7FFFFFF
    close_m = (nl >> 3) & 0x7FFFFF
    close_e = ex2 - lz
    
    # Far path: lz <= 1 or addition
    far_c = sum27
    far_norm = (sum_val >> 26) & 1
    if far_c:
        far_m_unr = (sum_val >> 4) & 0xFFFFFF
        far_g = (sum_val >> 3) & 1
        far_r = (sum_val >> 2) & 1
        far_s = (sum_val & 3) != 0
        far_e_base = ex2_p1
    elif far_norm:
        far_m_unr = (sum_val >> 3) & 0xFFFFFF
        far_g = (sum_val >> 2) & 1
        far_r = (sum_val >> 1) & 1
        far_s = (sum_val & 1) != 0
        far_e_base = ex2
    else: # lz == 1
        far_m_unr = (sum_val >> 2) & 0xFFFFFF
        far_g = (sum_val >> 1) & 1
        far_r = sum_val & 1
        far_s = 0
        far_e_base = ex2_sub1
        
    far_lsb = far_m_unr & 1
    far_inc = far_g and (far_r or far_s or far_lsb)
    far_m0 = far_m_unr + (1 if far_inc else 0)
    if (far_m0 >> 24) & 1:
        far_m = (far_m0 >> 1) & 0x7FFFFF
        far_e = far_e_base + 1
    else:
        far_m = far_m0 & 0x7FFFFF
        far_e = far_e_base
        
    m = close_m if is_close else far_m
    e = close_e if is_close else far_e
    
    if sp1: return spv1
    if sz: return 0
    if e >= 255: return (sx1 << 31) | 0x7F800000
    if e <= 0: return (sx1 << 31)
    return (sx1 << 31) | ((e & 0xFF) << 23) | (m & 0x7FFFFF)

# Run test
mismatches = 0
trials = 50000
for i in range(trials):
    a = random.randint(0, 0xFFFFFFFF)
    b = random.randint(0, 0xFFFFFFFF)
    sub = random.randint(0, 1)
    
    # also test close numbers
    if i % 3 == 0:
        b = a ^ (random.randint(0, 0x1F))
    elif i % 3 == 1:
        ea = (a >> 23) & 0xFF
        b = (b & 0x807FFFFF) | (ea << 23)
        
    r_orig = sim_orig(a, b, sub)
    r_dual = sim_dual_path(a, b, sub)
    if r_orig != r_dual:
        print(f"MISMATCH: a=0x{a:08x}, b=0x{b:08x}, sub={sub}")
        print(f"  orig=0x{r_orig:08x}")
        print(f"  dual=0x{r_dual:08x}")
        mismatches += 1
        if mismatches >= 10: break

if mismatches == 0:
    print(f"ALL {trials} TRIALS PASSED PERFECTLY!")
