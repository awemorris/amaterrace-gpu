#!/usr/bin/env python3
# gsi1fp.py: the bit-exact reference of the SU's arithmetic (design §3.1
# precision) for tools/gsi1model.py and the unit testbenches:
#   - fp32 (atg_su_fpu, include/atg_su_fp.vh): exact rational arithmetic,
#     one rounding (rm 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, 7 = RNE),
#     denormals flushed on input and output (a result whose exponent after
#     rounding is below the normal range is a zero of its sign), NaN results
#     are the canonical 0x7FC00000;
#   - fp16 halves (atg_su_pk) under the same rules;
#   - the integer divider (atg_su_div, RISC-V semantics);
#   - the transcendental unit (atg_su_xu): the same integer algorithms as
#     the RTL, step for step, so that the results are identical.
#
#   gsi1fp.py --fpu-vec OUT [--seed N]   vectors for sim/tb/atg_su_fpu_tb.v
#   gsi1fp.py --pk-vec OUT [--seed N]    vectors for sim/tb/atg_su_pk_tb.v
#   gsi1fp.py --xu-vec OUT [--seed N]    vectors for sim/tb/atg_su_xu_tb.v
#   gsi1fp.py --xu-tab OUT               include/atg_su_xu_tab.vh (the XU's constants)
#
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import math
import random
import struct
from fractions import Fraction

M32 = 0xFFFFFFFF
QNAN = 0x7FC00000
QNAN16 = 0x7E00
RNE, RTZ, RDN, RUP, RMM = 0, 1, 2, 3, 4


def rmode(rm):
    return RNE if rm in (5, 6, 7) else rm


class Fmt:
    def __init__(self, ew, mw):
        self.ew, self.mw = ew, mw
        self.bias = (1 << (ew - 1)) - 1
        self.emax = (1 << ew) - 1
        self.w = 1 + ew + mw
        self.qnan = (self.emax << mw) | (1 << (mw - 1))

    def fields(self, x):
        return x >> (self.w - 1) & 1, x >> self.mw & self.emax, x & ((1 << self.mw) - 1)

    def flush(self, x):
        s, e, m = self.fields(x)
        return s << (self.w - 1) if e == 0 else x

    def isnan(self, x):
        s, e, m = self.fields(x)
        return e == self.emax and m != 0

    def isinf(self, x):
        s, e, m = self.fields(x)
        return e == self.emax and m == 0

    def iszero(self, x):
        return self.fields(x)[1] == 0

    def value(self, x):
        """The exact value of a finite (flushed) number."""
        s, e, m = self.fields(x)
        if e == 0:
            return Fraction(0)
        v = Fraction((1 << self.mw) | m) * Fraction(2) ** (e - self.bias - self.mw)
        return -v if s else v

    def inf(self, s):
        return s << (self.w - 1) | self.emax << self.mw

    def maxf(self, s):
        return s << (self.w - 1) | (self.emax - 1) << self.mw | ((1 << self.mw) - 1)

    def zero(self, s):
        return s << (self.w - 1)

    def round(self, v, rm, zsign=0):
        """Round the exact value v; zsign is the sign of an exact zero."""
        rm = rmode(rm)
        if v == 0:
            return self.zero(zsign)
        s = 1 if v < 0 else 0
        a = -v if s else v
        e = math.floor(math.log2(a.numerator) - math.log2(a.denominator))
        # Fix e exactly: 2^e <= a < 2^(e+1).
        while Fraction(2) ** e > a:
            e -= 1
        while Fraction(2) ** (e + 1) <= a:
            e += 1
        q = a / Fraction(2) ** (e - self.mw)      # in [2^mw, 2^(mw+1))
        n = q.numerator // q.denominator
        rem = q - n
        up = False
        if rem != 0:
            if rm == RNE:
                up = rem > Fraction(1, 2) or (rem == Fraction(1, 2) and n & 1)
            elif rm == RMM:
                up = rem >= Fraction(1, 2)
            elif rm == RDN:
                up = s == 1
            elif rm == RUP:
                up = s == 0
        if up:
            n += 1
            if n == 1 << (self.mw + 1):
                n >>= 1
                e += 1
        be = e + self.bias
        if be >= self.emax:
            if rm == RTZ or (rm == RDN and not s) or (rm == RUP and s):
                return self.maxf(s)
            return self.inf(s)
        if be <= 0:
            return self.zero(s)
        return s << (self.w - 1) | be << self.mw | (n & ((1 << self.mw) - 1))


F32 = Fmt(8, 23)
F16 = Fmt(5, 10)


def fma(f, a, b, c, rm, noc=False):
    """round(a*b + c); noc: c is absent (fmul)."""
    a, b, c = f.flush(a), f.flush(b), f.flush(c)
    if f.isnan(a) or f.isnan(b) or (not noc and f.isnan(c)):
        return f.qnan
    sp = f.fields(a)[0] ^ f.fields(b)[0]
    ia, ib = f.isinf(a), f.isinf(b)
    if (ia and f.iszero(b)) or (ib and f.iszero(a)):
        return f.qnan
    if ia or ib:
        if not noc and f.isinf(c) and f.fields(c)[0] != sp:
            return f.qnan
        return f.inf(sp)
    if not noc and f.isinf(c):
        return c
    p = f.value(a) * f.value(b)
    if noc:
        return f.round(p, rm, sp)
    v = p + f.value(c)
    sc = f.fields(c)[0]
    if v == 0:
        if p == 0 and f.iszero(c):
            zs = sp & sc if rmode(rm) != RDN else sp | sc
        else:
            zs = 1 if rmode(rm) == RDN else 0
        return f.zero(zs)
    return f.round(v, rm)


def fround(x, rm):
    """Round to an integral value (fround.s, Zfa); keeps the sign of zeros."""
    x = F32.flush(x)
    if F32.isnan(x):
        return QNAN
    if F32.isinf(x) or F32.iszero(x):
        return x
    s, e, m = F32.fields(x)
    if e >= 150:
        return x
    v = F32.value(x)
    n = rint(v, rm)
    if n == 0:
        return F32.zero(s)
    return F32.round(Fraction(n), RNE)


def rint(v, rm):
    """The integer nearest to v under rm."""
    rm = rmode(rm)
    fl = v.numerator // v.denominator
    rem = v - fl
    if rem == 0:
        return fl
    if rm == RTZ:
        return fl if v > 0 else fl + 1
    if rm == RDN:
        return fl
    if rm == RUP:
        return fl + 1
    if rm == RMM:
        if rem == Fraction(1, 2):
            return fl + 1 if v > 0 else fl
        return fl + 1 if rem > Fraction(1, 2) else fl
    if rem == Fraction(1, 2):
        return fl + (fl & 1)
    return fl + 1 if rem > Fraction(1, 2) else fl


def fcvt_ws(x, rm, unsigned):
    x = F32.flush(x)
    lo, hi = (0, M32) if unsigned else (-(1 << 31), (1 << 31) - 1)
    if F32.isnan(x):
        return hi & M32
    if F32.isinf(x):
        return (lo if F32.fields(x)[0] else hi) & M32
    n = rint(F32.value(x), rm)
    return max(lo, min(hi, n)) & M32


def fcvt_sw(i, rm, unsigned):
    v = i & M32 if unsigned else (i & M32) - ((i & 0x80000000) << 1)
    return F32.round(Fraction(v), rm, 0)


def fminmax(f, a, b, is_max):
    a, b = f.flush(a), f.flush(b)
    na, nb = f.isnan(a), f.isnan(b)
    if na and nb:
        return f.qnan
    if na:
        return b
    if nb:
        return a

    def key(x):
        s = f.fields(x)[0]
        return (f.value(x), -s)     # -0 < +0
    if is_max:
        return a if key(a) >= key(b) else b
    return a if key(a) <= key(b) else b


def fcmp(f, a, b, op):
    """op 0 eq, 1 lt, 2 le, 3 ne; True/False."""
    a, b = f.flush(a), f.flush(b)
    if f.isnan(a) or f.isnan(b):
        return op == 3
    va, vb = f.value(a), f.value(b)
    return [va == vb, va < vb, va <= vb, va != vb][op]


def sat(f, x):
    """Clamp to [0, 1]; NaN, negatives and -0 give +0."""
    if f.isnan(x) or f.fields(x)[0]:
        return 0
    one = f.bias << f.mw
    return one if x > one else x


def fract(x):
    fl = fround(x, RDN)
    if F32.isnan(fl):
        return QNAN
    return fma(F32, x, 0x3F800000, fl ^ 0x80000000, RNE)


# FPU op codes (include/atg_su_uop.vh).
FADD, FSUB, FMUL, FMADD, FMSUB, FNMSUB, FNMADD, FSGNJ, FMIN, FMAX, FCVTWS, FCVTWUS, \
    FCVTSW, FCVTSWU, FEQ, FLT, FLE, FNE, FROUND, FRACT, MUL, MULH, MULHSU, MULHU = range(24)
FLOAT_RESULT = {FADD, FSUB, FMUL, FMADD, FMSUB, FNMSUB, FNMADD, FSGNJ, FMIN, FMAX, FCVTSW,
                FCVTSWU, FROUND, FRACT}
ONE = 0x3F800000


def s32(v):
    v &= M32
    return v - (1 << 32) if v >> 31 else v


def fpu(op, a, b, c, rm, sat_bit=0):
    """One lane of atg_su_fpu (operands after the n/a modifiers)."""
    if op == FADD:
        r = fma(F32, a, ONE, b, rm)
    elif op == FSUB:
        r = fma(F32, a, ONE, b ^ 0x80000000, rm)
    elif op == FMUL:
        r = fma(F32, a, b, 0, rm, noc=True)
    elif op == FMADD:
        r = fma(F32, a, b, c, rm)
    elif op == FMSUB:
        r = fma(F32, a, b, c ^ 0x80000000, rm)
    elif op == FNMSUB:
        r = fma(F32, a ^ 0x80000000, b, c, rm)
    elif op == FNMADD:
        r = fma(F32, a ^ 0x80000000, b, c ^ 0x80000000, rm)
    elif op == FSGNJ:
        r = (b & 0x80000000) | (a & 0x7FFFFFFF)
    elif op == FMIN:
        r = fminmax(F32, a, b, False)
    elif op == FMAX:
        r = fminmax(F32, a, b, True)
    elif op == FCVTWS:
        r = fcvt_ws(a, rm, False)
    elif op == FCVTWUS:
        r = fcvt_ws(a, rm, True)
    elif op == FCVTSW:
        r = fcvt_sw(a, rm, False)
    elif op == FCVTSWU:
        r = fcvt_sw(a, rm, True)
    elif op in (FEQ, FLT, FLE, FNE):
        r = M32 if fcmp(F32, a, b, [FEQ, FLT, FLE, FNE].index(op)) else 0
    elif op == FROUND:
        r = fround(a, rm)
    elif op == FRACT:
        r = fract(a)
    elif op == MUL:
        r = (a * b) & M32
    elif op == MULH:
        r = (s32(a) * s32(b)) >> 32 & M32
    elif op == MULHSU:
        r = (s32(a) * (b & M32)) >> 32 & M32
    elif op == MULHU:
        r = ((a & M32) * (b & M32)) >> 32 & M32
    else:
        raise ValueError("fpu op %d" % op)
    if sat_bit and op in FLOAT_RESULT:
        r = sat(F32, r)
    return r & M32


# ---------------------------------------------------------------------------
# fp16 packed (atg_su_pk).

PK_FADD2, PK_FSUB2, PK_FMUL2, PK_FFMA2, PK_FMIN2, PK_FMAX2, PK_IADD2, PK_ISUB2, PK_IMUL2, \
    PK_FCMPLT2, PK_FCMPGE2, PK_FCMPEQ2, PK_FCMPNE2, PK_PACKH, PK_UNPACKH, PK_SWAPH = range(16)
ONE16 = 0x3C00


def f32_to_f16(x):
    """RNE conversion of an fp32 to fp16 (flushing); NaN -> 0x7E00."""
    x = F32.flush(x)
    if F32.isnan(x):
        return QNAN16
    s = F32.fields(x)[0]
    if F32.isinf(x):
        return F16.inf(s)
    if F32.iszero(x):
        return F16.zero(s)
    return F16.round(F32.value(x), RNE)


def f16_to_f32(h):
    h = F16.flush(h)
    if F16.isnan(h):
        return QNAN
    s = F16.fields(h)[0]
    if F16.isinf(h):
        return F32.inf(s)
    if F16.iszero(h):
        return F32.zero(s)
    return F32.round(F16.value(h), RNE)


def pk_half(op, a, b, c, rm):
    if op == PK_FADD2:
        return fma(F16, a, ONE16, b, rm)
    if op == PK_FSUB2:
        return fma(F16, a, ONE16, b ^ 0x8000, rm)
    if op == PK_FMUL2:
        return fma(F16, a, b, 0, rm, noc=True)
    if op == PK_FFMA2:
        return fma(F16, a, b, c, rm)
    if op == PK_FMIN2:
        return fminmax(F16, a, b, False)
    if op == PK_FMAX2:
        return fminmax(F16, a, b, True)
    if op == PK_IADD2:
        return (a + b) & 0xFFFF
    if op == PK_ISUB2:
        return (a - b) & 0xFFFF
    if op == PK_IMUL2:
        return (a * b) & 0xFFFF
    if op == PK_FCMPLT2:
        return 0xFFFF if fcmp(F16, a, b, 1) else 0
    if op == PK_FCMPGE2:
        return 0xFFFF if fcmp(F16, b, a, 2) else 0
    if op == PK_FCMPEQ2:
        return 0xFFFF if fcmp(F16, a, b, 0) else 0
    if op == PK_FCMPNE2:
        return 0xFFFF if fcmp(F16, a, b, 3) else 0
    raise ValueError("pk op %d" % op)


def pk(op, a, b, c, rm, hsel, sub, sat_bit=0):
    """One lane of atg_su_pk.  hsel: 0 both halves, 1 low only (high from
    a), 2 high only (low from a), 3 swap b's halves, both."""
    if op == PK_PACKH:
        return f32_to_f16(b) << 16 | f32_to_f16(a)
    if op == PK_UNPACKH:
        return f16_to_f32(a >> 16 if sub else a & 0xFFFF)
    if op == PK_SWAPH:
        return (a >> 16 | a << 16) & M32
    if hsel == 3:
        b = (b >> 16 | b << 16) & M32
    lo = pk_half(op, a & 0xFFFF, b & 0xFFFF, c & 0xFFFF, rm)
    hi = pk_half(op, a >> 16, b >> 16, c >> 16, rm)
    if sat_bit and op in (PK_FADD2, PK_FSUB2, PK_FMUL2, PK_FFMA2, PK_FMIN2, PK_FMAX2):
        lo, hi = sat(F16, lo), sat(F16, hi)
    if hsel == 1:
        hi = a >> 16
    elif hsel == 2:
        lo = a & 0xFFFF
    return hi << 16 | lo


# ---------------------------------------------------------------------------
# Integer division (atg_su_div): RISC-V semantics.

def div(op, a, b):
    a, b = a & M32, b & M32
    if op in (0, 2):        # div, rem
        sa, sb = s32(a), s32(b)
        if sb == 0:
            return M32 if op == 0 else a
        if sa == -(1 << 31) and sb == -1:
            return a if op == 0 else 0
        q = abs(sa) // abs(sb)
        if (sa < 0) != (sb < 0):
            q = -q
        r = sa - q * sb
        return (q if op == 0 else r) & M32
    if b == 0:
        return M32 if op == 1 else a
    return (a // b) if op == 1 else (a % b)


# ---------------------------------------------------------------------------
# The transcendental unit (atg_su_xu).  Integer algorithms, the same as the
# RTL's sequential engine, step for step.

XU_RCP, XU_RSQ, XU_EXP2, XU_LOG2, XU_SIN, XU_COS, XU_FSQRT = range(7)


def norm_round(s, n, e, sticky=0):
    """The fp32 of (-1)^s * n * 2^e (n > 0 an integer, sticky: more nonzero
    bits below n's LSB), RNE, flushed."""
    k = n.bit_length()
    # Keep 24 bits plus guard; the rest goes into the sticky bit.
    if k > 25:
        sh = k - 25
        sticky |= (n & ((1 << sh) - 1)) != 0
        n >>= sh
        e += sh
    elif k < 25:
        n <<= 25 - k
        e -= 25 - k
    g = n & 1
    m = n >> 1
    e += 1
    if g and (sticky or m & 1):
        m += 1
        if m == 1 << 24:
            m >>= 1
            e += 1
    be = e + 23 + 127
    if be >= 255:
        return F32.inf(s)
    if be <= 0:
        return F32.zero(s)
    return s << 31 | be << 23 | (m & 0x7FFFFF)


def isqrt(n):
    """floor(sqrt(n)) by the bit-by-bit method (as the RTL)."""
    return math.isqrt(n)


# 2^(2^-i) in Q2.38 for i = 1..30, and atan(2^-i)/(2*pi) in Q0.40 turns.
EXP_W = 38
EXP_K = [round(2 ** (2.0 ** -i) * (1 << EXP_W)) for i in range(1, 31)]
CORDIC_N = 26
CORDIC_W = 34
ATAN_T = [round(math.atan(2.0 ** -i) / (2 * math.pi) * (1 << 40)) for i in range(CORDIC_N)]
# The CORDIC gain 1/K in Q1.CORDIC_W.
CORDIC_G = round((1 << CORDIC_W) / math.prod(math.sqrt(1 + 4.0 ** -i)
                                              for i in range(CORDIC_N)))
INV2PI = round((1 << 61) / (2 * math.pi))   # 1/(2 pi) in Q0.61 (59 significant bits)


def xu(op, x):
    """One lane of atg_su_xu."""
    x &= M32
    x = F32.flush(x)
    s, e, mf = F32.fields(x)
    m = (1 << 23) | mf
    nan, inf, zero = F32.isnan(x), F32.isinf(x), F32.iszero(x)
    if op == XU_RCP:
        if nan:
            return QNAN
        if zero:
            return F32.inf(s)
        if inf:
            return F32.zero(s)
        # 1/m: 2^50 / m in (2^26, 2^27], restoring division.
        q, r = divmod(1 << 50, m)
        return norm_round(s, q, -50 - (e - 150), r != 0)
    if op in (XU_RSQ, XU_FSQRT):
        if nan or (s and not zero):
            return QNAN
        if zero:
            return F32.inf(s) if op == XU_RSQ else x
        if inf:
            return 0 if op == XU_RSQ else x
        # x = m * 2^(e-150); make the exponent even.
        ee = e - 150
        mm = m
        if ee & 1:
            mm <<= 1
            ee -= 1
        if op == XU_FSQRT:
            n = mm << 26                # sqrt has 25+ bits
            r = isqrt(n)
            return norm_round(0, r, (ee - 26) // 2, r * r != n)
        # rsq: t = isqrt(mm << 34) ~ sqrt(mm) * 2^17 (30 bits), then
        # q = 2^57 / t ~ 2^40 / sqrt(mm) (28 bits); 1/sqrt(x) = q * 2^(-40 - ee/2).
        n = mm << 34
        t = isqrt(n)
        q, r = divmod(1 << 57, t)
        return norm_round(0, q, -40 - ee // 2, r != 0 or t * t != n)
    if op == XU_EXP2:
        if nan:
            return QNAN
        if inf:
            return 0 if s else x
        if zero:
            return ONE
        # x as fixed point Q8.30 (saturating): |x| >= 256 overflows anyway.
        sh = e - 150 + 30
        if e >= 135:                    # |x| >= 256
            return 0 if s else F32.inf(0)
        v = m << sh if sh >= 0 else m >> -sh
        if s:
            v = -v
        n = v >> 30                     # floor
        f = v & ((1 << 30) - 1)
        y = 1 << EXP_W
        for i in range(30):
            if f >> (29 - i) & 1:
                y = (y * EXP_K[i]) >> EXP_W
        return norm_round(0, y, n - EXP_W)
    if op == XU_LOG2:
        if nan or (s and not zero):
            return QNAN
        if zero:
            return F32.inf(1)
        if inf:
            return x
        # log2(m) bit by bit: y in [1, 2) as Q1.LW, square, compare with 2.
        lw = 40
        y = m << (lw - 23)
        frac = 0
        for _ in range(30):
            y = (y * y) >> lw
            frac <<= 1
            if y >> (lw + 1):
                frac |= 1
                y >>= 1
        v = ((e - 127) << 30) + frac      # Q.30
        if v == 0:
            return 0
        sg = 1 if v < 0 else 0
        return norm_round(sg, -v if sg else v, -30)
    if op in (XU_SIN, XU_COS):
        if nan or inf:
            return QNAN
        if e < 115:                     # |x| < 2^-12: sin x = x, cos x = 1
            return x if op == XU_SIN else ONE
        # turns t = x / (2 pi) as Q.40 fraction (mod 1).
        p = m * INV2PI                  # x / 2pi = p * 2^(e-150-61)
        sh = e - 150 - 61 + 40
        t = p << sh if sh >= 0 else p >> -sh
        t &= (1 << 40) - 1
        if s:
            t = (-t) & ((1 << 40) - 1)
        if op == XU_COS:
            t = (t + (1 << 38)) & ((1 << 40) - 1)    # cos(x) = sin(x + pi/2)
        # Quadrant, then CORDIC on the residual in [0, 1/4) turn.
        quad = t >> 38
        a = t & ((1 << 38) - 1)
        if quad & 1:
            a = (1 << 38) - a
        cx, cy, z = CORDIC_G, 0, a
        for i in range(CORDIC_N):
            if z >= 0:
                cx, cy, z = cx - (cy >> i), cy + (cx >> i), z - ATAN_T[i]
            else:
                cx, cy, z = cx + (cy >> i), cy - (cx >> i), z + ATAN_T[i]
        v = cy                          # sin of the residual, Q1.CORDIC_W
        if v <= 0:
            return 0
        sg = 1 if quad >> 1 else 0
        return norm_round(sg, v, -CORDIC_W)
    raise ValueError("xu op %d" % op)


# ---------------------------------------------------------------------------
# Vector files.

SPECIALS32 = [0x00000000, 0x80000000, 0x3F800000, 0xBF800000, 0x7F800000, 0xFF800000,
              0x7FC00000, 0x7F800001, 0xFFC00000, 0x00000001, 0x807FFFFF, 0x00800000,
              0x80800000, 0x7F7FFFFF, 0xFF7FFFFF, 0x3F000000, 0x3FC00000, 0x40000000,
              0x4B000000, 0x4AFFFFFF, 0x4B7FFFFF, 0x4F000000, 0xCF000000, 0x4F800000,
              0x3EFFFFFF, 0x3F000001, 0xBF000000, 0x34000000, 0x00FFFFFF]


def rnd32(r):
    k = r.random()
    if k < 0.15:
        return r.choice(SPECIALS32)
    if k < 0.6:
        # Moderate exponents: interesting sums.
        e = r.randrange(110, 145)
        return r.getrandbits(1) << 31 | e << 23 | r.getrandbits(23)
    if k < 0.7:
        e = r.randrange(0, 256)
        return r.getrandbits(1) << 31 | e << 23 | r.getrandbits(23)
    return r.getrandbits(32)


def fpu_vec(path, seed):
    r = random.Random(seed)
    vec = []
    for i in range(6000):
        op = r.randrange(24)
        a, b, c = rnd32(r), rnd32(r), rnd32(r)
        if op in (FADD, FSUB, FMADD, FMSUB, FNMSUB, FNMADD) and r.random() < 0.3:
            # Near cancellation.
            b = (a ^ 0x80000000) + r.randrange(-3, 4) & M32 if op != FSUB else \
                (a + r.randrange(-3, 4)) & M32
            if op >= FMADD:
                c = (fpu(FMUL, a, b, 0, RNE) ^ 0x80000000) & M32
        if op in (FCVTSW, FCVTSWU, MUL, MULH, MULHSU, MULHU) and r.random() < 0.5:
            a, b = r.getrandbits(32), r.getrandbits(32)
        rm = r.choice([0, 1, 2, 3, 4, 7]) if op != FROUND else r.randrange(4)
        st = 1 if r.random() < 0.1 else 0
        y = fpu(op, a, b, c, rm, st)
        vec.append((op, rm, st, a, b, c, y))
    with open(path, "w") as f:
        for op, rm, st, a, b, c, y in vec:
            f.write("%02x%x%x%08x%08x%08x%08x\n" % (op, rm, st, a, b, c, y))
    return len(vec)


def rnd16(r):
    k = r.random()
    sp = [0x0000, 0x8000, 0x3C00, 0xBC00, 0x7C00, 0xFC00, 0x7E00, 0x7C01, 0x0001, 0x0400,
          0x7BFF, 0xFBFF, 0x3800, 0x0200]
    if k < 0.2:
        return r.choice(sp)
    if k < 0.7:
        return r.getrandbits(1) << 15 | r.randrange(8, 24) << 10 | r.getrandbits(10)
    return r.getrandbits(16)


def pk_vec(path, seed):
    r = random.Random(seed)
    vec = []
    for i in range(4000):
        op = r.randrange(16)
        a = rnd16(r) << 16 | rnd16(r)
        b = rnd16(r) << 16 | rnd16(r)
        c = rnd16(r) << 16 | rnd16(r)
        if op in (PK_PACKH, PK_UNPACKH) and r.random() < 0.7:
            a, b = rnd32(r), rnd32(r)
            if r.random() < 0.5:
                e = r.randrange(100, 150)
                a = r.getrandbits(1) << 31 | e << 23 | r.getrandbits(23)
        rm = r.choice([0, 1, 2, 3, 4, 7])
        hsel = r.randrange(4)
        sub = r.randrange(2) if op == PK_UNPACKH else 0
        st = 1 if r.random() < 0.1 else 0
        y = pk(op, a, b, c, rm, hsel, sub, st)
        vec.append((op, rm, hsel, sub, st, a, b, c, y))
    with open(path, "w") as f:
        for op, rm, hsel, sub, st, a, b, c, y in vec:
            f.write("%x%x%x%x%x%08x%08x%08x%08x\n" % (op, rm, hsel, sub, st, a, b, c, y))
    return len(vec)


def bits_f(v):
    return struct.unpack("<I", struct.pack("<f", v))[0]


def xu_vec(path, seed):
    """Inputs and the model's outputs; the TB checks the outputs bit for bit
    and, separately, against $sin/$exp/... with error bounds."""
    r = random.Random(seed)
    vec = []
    for i in range(3000):
        if i % 8 == 0:
            op = r.randrange(7)     # one op per block of 8 (a lane group)
        k = r.random()
        if k < 0.1:
            x = r.choice(SPECIALS32)
        elif op in (XU_SIN, XU_COS):
            x = bits_f(r.uniform(-8, 8)) if k < 0.8 else rnd32(r)
        elif op == XU_EXP2:
            x = bits_f(r.uniform(-140, 130)) if k < 0.5 else bits_f(r.uniform(-2, 2))
        elif op == XU_LOG2 and k < 0.4:
            x = bits_f(r.uniform(0.5, 2))
        else:
            e = r.randrange(1, 255)
            x = (r.getrandbits(1) if op in (XU_RCP, XU_SIN, XU_COS, XU_EXP2) else 0) << 31 | \
                e << 23 | r.getrandbits(23)
        vec.append((op, x, xu(op, x)))
    with open(path, "w") as f:
        for op, x, y in vec:
            f.write("%x%08x%08x\n" % (op, x, y))
    return len(vec)


def xu_tab(path):
    with open(path, "w") as f:
        f.write("/*\n * Amaterrace GPU\n * Copyright (C) 2026 Awe Morris\n *\n"
                " * SPDX-License-Identifier: Zlib\n */\n\n"
                "/*\n * atg_su_xu_tab.vh: the constants of atg_su_xu, generated by\n"
                " * tools/gsi1fp.py --xu-tab (do not edit).  Included inside the module.\n"
                " */\n\n")
        f.write("/* 1/(2 pi) in Q0.61. */\nlocalparam [58:0] XU_INV2PI = 59'd%d;\n" % INV2PI)
        f.write("/* The CORDIC start value 1/K in Q1.%d. */\n" % CORDIC_W)
        f.write("localparam [35:0] XU_CG = 36'd%d;\n\n" % CORDIC_G)
        f.write("/* 2^(2^-(i+1)) in Q2.%d. */\nfunction [39:0] xu_expk;\n"
                "\tinput [4:0] i;\n\tcase (i)\n" % EXP_W)
        for i, v in enumerate(EXP_K):
            f.write("\t5'd%d: xu_expk = 40'd%d;\n" % (i, v))
        f.write("\tdefault: xu_expk = 40'd%d;\n\tendcase\nendfunction\n\n" % (1 << EXP_W))
        f.write("/* atan(2^-i) / (2 pi) in turns, Q0.40. */\nfunction [39:0] xu_atan;\n"
                "\tinput [4:0] i;\n\tcase (i)\n")
        for i, v in enumerate(ATAN_T):
            f.write("\t5'd%d: xu_atan = 40'd%d;\n" % (i, v))
        f.write("\tdefault: xu_atan = 40'd0;\n\tendcase\nendfunction\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fpu-vec")
    ap.add_argument("--pk-vec")
    ap.add_argument("--xu-vec")
    ap.add_argument("--xu-tab")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    if a.fpu_vec:
        print("gsi1fp: %d fpu vectors in %s" % (fpu_vec(a.fpu_vec, a.seed), a.fpu_vec))
    if a.pk_vec:
        print("gsi1fp: %d pk vectors in %s" % (pk_vec(a.pk_vec, a.seed), a.pk_vec))
    if a.xu_tab:
        xu_tab(a.xu_tab)
    if a.xu_vec:
        print("gsi1fp: %d xu vectors in %s" % (xu_vec(a.xu_vec, a.seed), a.xu_vec))


if __name__ == "__main__":
    main()
