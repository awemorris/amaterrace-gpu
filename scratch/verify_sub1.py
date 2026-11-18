import struct, random, math

def f2u(f):
    return struct.unpack('>I', struct.pack('>f', f))[0]

def u2f(u):
    return struct.unpack('>f', struct.pack('>I', u))[0]

def ref_sub1(u):
    ea = (u >> 23) & 0xFF
    ma = u & 0x7FFFFF
    s = (u >> 31) & 1
    # Check NaN
    if ea == 0xFF and ma != 0:
        return 0x7FC00000
    # Check Inf
    if ea == 0xFF and ma == 0:
        return 0x7F800000 if s else 0xFF800000
    # Denormal flushed to 0
    if ea == 0:
        return 0x3F800000 # 1.0 - 0 = 1.0
    
    f = u2f(u)
    # Compute in 64-bit then round to 32-bit float
    r = struct.unpack('>f', struct.pack('>f', 1.0 - f))[0]
    ur = f2u(r)
    # Canonical NaN
    if ((ur >> 23) & 0xFF) == 0xFF and (ur & 0x7FFFFF) != 0:
        return 0x7FC00000
    return ur

def rtl_sub1(u):
    ea = (u >> 23) & 0xFF
    ma = u & 0x7FFFFF
    s = (u >> 31) & 1
    
    # NaN
    if ea == 0xFF and ma != 0:
        return 0x7FC00000
    # Inf
    if ea == 0xFF and ma == 0:
        return 0x7F800000 if s else 0xFF800000
    # Zero or denormal
    if ea == 0:
        return 0x3F800000
    # Exact 1.0
    if s == 0 and ea == 127 and ma == 0:
        return 0x00000000
        
    m24 = (1 << 23) | ma
    
    # Magnitude compare: is |x| <= 1.0?
    x_le_1 = (ea < 127) or (ea == 127 and ma == 0)
    
    if x_le_1:
        # 1.0 is larger
        dab = 127 - ea
        ex = 127
        # align x: shift m24 right by dab bits with sticky
        shi = m24 << 3
        if dab >= 27:
            sh = 0
            stk = 1 if m24 != 0 else 0
        else:
            sh = shi >> dab
            stk = 1 if (shi & ((1 << dab) - 1)) != 0 else 0
        
        px = 0x800000 << 3 # 1.0
        py = (sh & ~1) | (sh & 1) | stk
        
        # If s == 0 (positive x): subtract (1.0 - x)
        # If s == 1 (negative x): add (1.0 + |x|)
        if s == 0:
            sum_val = px - py
            sub_op = 1
        else:
            sum_val = px + py
            sub_op = 0
            
        sx = 0
        
        # Count leading zeros of sum_val (in 27 bits)
        if sum_val == 0:
            return 0x00000000
            
        # check overflow if addition (bit 27)
        if (sum_val >> 27) & 1:
            n = (sum_val >> 1) | (sum_val & 1)
            e0 = ex + 1
        else:
            # find leading zero
            lz = 0
            for k in range(26, -1, -1):
                if (sum_val >> k) & 1:
                    lz = 26 - k
                    break
            n = (sum_val << lz) & 0x7FFFFFF
            e0 = ex - lz
            
    else:
        # |x| > 1.0
        dab = ea - 127
        ex = ea
        # align 1.0: 1.0 has mantissa 0x800000
        shi = 0x800000 << 3
        if dab >= 27:
            sh = 0
            stk = 1
        else:
            sh = shi >> dab
            stk = 1 if (shi & ((1 << dab) - 1)) != 0 else 0
            
        px = m24 << 3
        py = (sh & ~1) | (sh & 1) | stk
        
        if s == 0:
            # 1.0 - x = -(x - 1.0)
            sum_val = px - py
            sx = 1
        else:
            # 1.0 - (-|x|) = 1.0 + |x|
            sum_val = px + py
            sx = 0
            
        if (sum_val >> 27) & 1:
            n = (sum_val >> 1) | (sum_val & 1)
            e0 = ex + 1
        else:
            lz = 0
            for k in range(26, -1, -1):
                if (sum_val >> k) & 1:
                    lz = 26 - k
                    break
            n = (sum_val << lz) & 0x7FFFFFF
            e0 = ex - lz
            
    # Round to nearest even
    # n has 27 bits: [26:3] mantissa (24 bits), [2] guard, [1] round, [0] sticky
    inc = ((n >> 2) & 1) and (((n >> 1) & 1) or (n & 1) or ((n >> 3) & 1))
    m0 = (n >> 3) + (1 if inc else 0)
    if (m0 >> 24) & 1:
        m = m0 >> 1
        e = e0 + 1
    else:
        m = m0
        e = e0
        
    if e >= 255:
        return (sx << 31) | (0xFF << 23) # Inf
    if e <= 0:
        return (sx << 31) # flush denormal
    return (sx << 31) | ((e & 0xFF) << 23) | (m & 0x7FFFFF)

# Test 100000 random floats
mismatches = 0
for i in range(100000):
    u = random.randint(0, 0xFFFFFFFF)
    r_ref = ref_sub1(u)
    r_rtl = rtl_sub1(u)
    if r_ref != r_rtl:
        mismatches += 1
        if mismatches <= 10:
            print(f'Mismatch on 0x{u:08x} ({u2f(u)}): ref=0x{r_ref:08x} ({u2f(r_ref)}), rtl=0x{r_rtl:08x} ({u2f(r_rtl)})')

print(f'Test completed. Total mismatches: {mismatches}/100000')
