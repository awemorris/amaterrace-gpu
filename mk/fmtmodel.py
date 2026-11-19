#!/usr/bin/env python3
# fmtmodel.py: the reference model of the format table of
# include/atg_fmt_info.vh, the conversions of rtl/gpu/fmt (atg_fmt_comp,
# atg_fmt_pack and their converters), the sRGB tables of include/atg_srgb.vh
# and the sRGB encoder atg_fmt_srgbenc.  It is
# written from Vulkan's conversion rules (docs/ghci.md section 8.5), not
# from the RTL: every conversion to fp32 is exact and then rounded to
# nearest even, with exact integer arithmetic.
#
#   python3 -I tools/fmtmodel.py --selftest   checks the model against
#       independent references (exact fractions, Python's struct 'e' for
#       fp16, high-precision decimals for sRGB) and the D24 round trip for
#       every code; prints "PASS fmtmodel.selftest" (about a minute).
#   python3 -I tools/fmtmodel.py --vectors    writes sim/vec/fmt_unpack.txt,
#       fmt_pack.txt, fmt_info.txt, fmt_required.txt and fmt_srgbenc.txt
#       for sim/tb/atg_fmt_tb.v and atg_fmt_srgbenc_tb.v (in git; check
#       `git diff sim/vec` after a change).
#
# Library use: import fmtmodel as F; F.unpack(raw, fmt, stencil),
# F.pack(comps, fmt, wm), F.info(fmt), F.features(fmt, etc).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
from decimal import Decimal, getcontext
from fractions import Fraction
import os
import random
import struct
import sys
import time

M32 = 0xFFFFFFFF
ONE = 0x3F800000
QNAN = 0x7FC00000
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

# ---------------------------------------------------------------- types

UNORM, SNORM, UINT, SINT, SFLOAT, SRGB, UFLOAT, E5 = range(8)

# VkFormatFeatureFlagBits of Vulkan 1.0 (values are the specification's).
F_SAMPLED = 0x1
F_STORAGE = 0x2
F_STORAGE_ATOMIC = 0x4
F_UTB = 0x8
F_STB = 0x10
F_STB_ATOMIC = 0x20
F_VERTEX = 0x40
F_COLOR = 0x80
F_BLEND = 0x100
F_DS = 0x200
F_BLIT_SRC = 0x400
F_BLIT_DST = 0x800
F_LINEAR = 0x1000


class Fmt:
    """One format: bytes of a texel (or of a block), components, type,
    the (position, width) of R, G, B, A, flags, and the fixed-function
    features the GPU supports (letters: S sampled and blit source, F
    linear filter, C colour attachment and blit destination, B blend, D
    depth/stencil attachment; V vertex buffer)."""

    def __init__(self, value, name, nbytes, ty, chans, feat, depth=False, stencil=False,
                 block=False):
        self.value = value
        self.name = name
        self.nbytes = nbytes
        self.ty = ty
        self.chans = chans
        self.feat = feat
        self.depth = depth
        self.stencil = stencil
        self.block = block


def _rgba(w, n):
    return [(w * i, w) for i in range(n)]


FORMATS = {}


def _add(*a, **k):
    f = Fmt(*a, **k)
    FORMATS[f.value] = f


_add(3, 'B4G4R4A4_UNORM_PACK16', 2, UNORM, [(4, 4), (8, 4), (12, 4), (0, 4)], 'SF')
_add(4, 'R5G6B5_UNORM_PACK16', 2, UNORM, [(11, 5), (5, 6), (0, 5)], 'SFCB')
_add(8, 'A1R5G5B5_UNORM_PACK16', 2, UNORM, [(10, 5), (5, 5), (0, 5), (15, 1)], 'SFCB')
for _v, _n, _t, _f in ((9, 'UNORM', UNORM, 'SFCB|V'), (10, 'SNORM', SNORM, 'SF|V'),
                       (13, 'UINT', UINT, 'SC|V'), (14, 'SINT', SINT, 'SC|V')):
    _add(_v, 'R8_' + _n, 1, _t, _rgba(8, 1), _f)
    _add(_v + 7, 'R8G8_' + _n, 2, _t, _rgba(8, 2), _f)
for _v, _n, _t, _f in ((37, 'UNORM', UNORM, 'SFCB|V'), (38, 'SNORM', SNORM, 'SF|V'),
                       (41, 'UINT', UINT, 'SC|V'), (42, 'SINT', SINT, 'SC|V'),
                       (43, 'SRGB', SRGB, 'SFCB')):
    _add(_v, 'R8G8B8A8_' + _n, 4, _t, _rgba(8, 4), _f)
    _add(_v + 14, 'A8B8G8R8_' + _n + '_PACK32', 4, _t, _rgba(8, 4), _f)
_add(44, 'B8G8R8A8_UNORM', 4, UNORM, [(16, 8), (8, 8), (0, 8), (24, 8)], 'SFCB|V')
_add(50, 'B8G8R8A8_SRGB', 4, SRGB, [(16, 8), (8, 8), (0, 8), (24, 8)], 'SFCB')
_add(64, 'A2B10G10R10_UNORM_PACK32', 4, UNORM, [(0, 10), (10, 10), (20, 10), (30, 2)],
     'SFCB|V')
_add(68, 'A2B10G10R10_UINT_PACK32', 4, UINT, [(0, 10), (10, 10), (20, 10), (30, 2)], 'SC')
for _v, _n, _t, _f in ((70, 'UNORM', UNORM, '|V'), (71, 'SNORM', SNORM, '|V'),
                       (74, 'UINT', UINT, 'SC|V'), (75, 'SINT', SINT, 'SC|V'),
                       (76, 'SFLOAT', SFLOAT, 'SFCB|V')):
    _add(_v, 'R16_' + _n, 2, _t, _rgba(16, 1), _f)
    _add(_v + 7, 'R16G16_' + _n, 4, _t, _rgba(16, 2), _f)
    _add(_v + 21, 'R16G16B16A16_' + _n, 8, _t, _rgba(16, 4), _f)
for _v, _n, _t in ((98, 'UINT', UINT), (99, 'SINT', SINT), (100, 'SFLOAT', SFLOAT)):
    _add(_v, 'R32_' + _n, 4, _t, _rgba(32, 1), 'SC|V')
    _add(_v + 3, 'R32G32_' + _n, 8, _t, _rgba(32, 2), 'SC|V')
    _add(_v + 6, 'R32G32B32_' + _n, 12, _t, _rgba(32, 3), '|V')
    _add(_v + 9, 'R32G32B32A32_' + _n, 16, _t, _rgba(32, 4), 'SC|V')
_add(122, 'B10G11R11_UFLOAT_PACK32', 4, UFLOAT, [(0, 11), (11, 11), (22, 10)], 'SF')
_add(123, 'E5B9G9R9_UFLOAT_PACK32', 4, E5, [(0, 9), (9, 9), (18, 9)], 'SF')
_add(124, 'D16_UNORM', 2, UNORM, [(0, 16)], 'SFD', depth=True)
_add(125, 'X8_D24_UNORM_PACK32', 4, UNORM, [(0, 24)], 'SFD', depth=True)
_add(126, 'D32_SFLOAT', 4, SFLOAT, [(0, 32)], 'SFD', depth=True)
_add(129, 'D24_UNORM_S8_UINT', 4, UNORM, [(0, 24)], 'SFD', depth=True, stencil=True)
for _v, _n, _b, _t, _c in ((147, 'ETC2_R8G8B8_UNORM_BLOCK', 8, UNORM, 3),
                           (148, 'ETC2_R8G8B8_SRGB_BLOCK', 8, SRGB, 3),
                           (149, 'ETC2_R8G8B8A1_UNORM_BLOCK', 8, UNORM, 4),
                           (150, 'ETC2_R8G8B8A1_SRGB_BLOCK', 8, SRGB, 4),
                           (151, 'ETC2_R8G8B8A8_UNORM_BLOCK', 16, UNORM, 4),
                           (152, 'ETC2_R8G8B8A8_SRGB_BLOCK', 16, SRGB, 4),
                           (153, 'EAC_R11_UNORM_BLOCK', 8, UNORM, 1),
                           (154, 'EAC_R11_SNORM_BLOCK', 8, SNORM, 1),
                           (155, 'EAC_R11G11_UNORM_BLOCK', 16, UNORM, 2),
                           (156, 'EAC_R11G11_SNORM_BLOCK', 16, SNORM, 2)):
    _add(_v, _n, _b, _t, [(0, 0)] * _c, 'SF', block=True)

ETC_FIRST, ETC_LAST = 147, 156


def info(fmt):
    return FORMATS.get(fmt)


def features(fmt, etc=True):
    """(optimal, buffer) VkFormatFeatureFlags of the fixed-function units;
    linear tiling has the optimal ones.  etc: the ETC2/EAC decoder."""
    f = FORMATS.get(fmt)
    if f is None or (f.block and not etc):
        return 0, 0
    img, _, buf = f.feat.partition('|')
    o = 0
    if 'S' in img:
        o |= F_SAMPLED | F_BLIT_SRC
    if 'F' in img:
        o |= F_LINEAR
    if 'C' in img:
        o |= F_COLOR | F_BLIT_DST
    if 'B' in img:
        o |= F_BLEND
    if 'D' in img:
        o |= F_DS
    b = F_VERTEX if 'V' in buf else 0
    return o, b


def info_word(fmt):
    """The bits of atg_fmt_info (include/atg_fmt_info.vh): [0] valid,
    [5:1] bytes, [8:6] components, [11:9] type, [12] depth, [13] stencil,
    [14] block, [15] 0, then per component c (R, G, B, A) 13 bits at
    16 + 13c: [6:0] position, [12:7] width."""
    f = FORMATS.get(fmt)
    if f is None:
        return 0
    v = 1 | f.nbytes << 1 | len(f.chans) << 6 | f.ty << 9
    v |= f.depth << 12 | f.stencil << 13 | f.block << 14
    for c, (p, w) in enumerate(f.chans):
        v |= (p | w << 7) << (16 + 13 * c)
    return v


# ---------------------------------------------------------------- exact fp32


def rat_f32(num, den, neg=False):
    """num / den (num >= 0, den > 0) to fp32, round to nearest even,
    denormals kept, overflow to infinity."""
    s = 0x80000000 if neg else 0
    if num == 0:
        return s
    e = num.bit_length() - den.bit_length()
    if (num << max(0, -e)) < (den << max(0, e)):
        e -= 1
    # 2^e <= num/den < 2^(e+1)
    if e + 127 >= 255:
        return s | 0x7F800000
    sh = 23 - e if e >= -126 else 149
    q = rne_div(num << max(0, sh), den << max(0, -sh))
    if e < -126:
        return s | q  # q <= 2^23 (2^23 is the smallest normal)
    if q == 1 << 24:
        q >>= 1
        e += 1
        if e + 127 >= 255:
            return s | 0x7F800000
    return s | (e + 127) << 23 | (q - (1 << 23))


def f32_val(b):
    """(num, den, neg) of a finite fp32, exactly."""
    e = (b >> 23) & 0xFF
    m = b & 0x7FFFFF
    if e == 0:
        num, ex = m, -149
    else:
        num, ex = m | 0x800000, e - 150
    if ex >= 0:
        return num << ex, 1, bool(b >> 31)
    return num, 1 << -ex, bool(b >> 31)


def is_nan(b):
    return (b >> 23) & 0xFF == 0xFF and b & 0x7FFFFF


def rne_div(num, den):
    q, r = divmod(num, den)
    if 2 * r > den or (2 * r == den and q & 1):
        q += 1
    return q


# ---------------------------------------------------------------- unpack


def unorm_f32(c, b):
    return rat_f32(c, (1 << b) - 1)


def snorm_f32(c, b):
    if c >> (b - 1):
        c -= 1 << b
    if c == -(1 << (b - 1)):
        return 0xBF800000
    return rat_f32(abs(c), (1 << (b - 1)) - 1, c < 0)


def half_f32(h):
    s = 0x80000000 if h >> 15 else 0
    e = (h >> 10) & 0x1F
    m = h & 0x3FF
    if e == 31:
        return QNAN if m else s | 0x7F800000
    return _ufl(e, m, 10, bool(s))


def _ufl(e, m, mb, neg=False):
    """An unsigned float field with a 5-bit exponent (bias 15) and mb
    mantissa bits, exactly (e < 31)."""
    if e == 0:
        return rat_f32(m, 1 << (14 + mb), neg)
    num = m | (1 << mb)
    sh = e - 15 - mb
    if sh >= 0:
        return rat_f32(num << sh, 1, neg)
    return rat_f32(num, 1 << -sh, neg)


def ufloat_f32(v, mb):
    e = (v >> mb) & 0x1F
    m = v & ((1 << mb) - 1)
    if e == 31:
        return QNAN if m else 0x7F800000
    return _ufl(e, m, mb)


def e5_f32(m, e):
    sh = e - 15 - 9
    if sh >= 0:
        return rat_f32(m << sh, 1)
    return rat_f32(m, 1 << -sh)


SRGB_DEC = None
SRGB_THR = None


def _srgb_tables():
    global SRGB_DEC, SRGB_THR
    if SRGB_DEC is None:
        SRGB_DEC, SRGB_THR = srgb_tables()
    return SRGB_DEC, SRGB_THR


def comp_unpack(fld, w, ty, ch):
    if ty == UNORM:
        return unorm_f32(fld, w)
    if ty == SNORM:
        return snorm_f32(fld, w)
    if ty == UINT:
        return fld
    if ty == SINT:
        return (fld - (1 << w) if fld >> (w - 1) else fld) & M32
    if ty == SFLOAT:
        return fld if w == 32 else half_f32(fld)
    if ty == SRGB:
        return _srgb_tables()[0][fld] if ch < 3 else unorm_f32(fld, 8)
    if ty == UFLOAT:
        return ufloat_f32(fld, w - 5)
    raise ValueError(ty)


def unpack(raw, fmt, stencil=False):
    """raw (an int of the texel's bytes, little endian) to (c0..c3, is_int)."""
    f = FORMATS.get(fmt)
    if f is None or f.block:
        return [0, 0, 0, ONE], False
    if stencil:
        if not f.stencil:
            return [0, 0, 0, ONE], False
        return [(raw >> 24) & 0xFF, 0, 0, 1], True
    is_int = f.ty in (UINT, SINT)
    out = [0, 0, 0, 1 if is_int else ONE]
    for c, (p, w) in enumerate(f.chans):
        fld = (raw >> p) & ((1 << w) - 1)
        if f.ty == E5:
            out[c] = e5_f32(fld, (raw >> 27) & 0x1F)
        else:
            out[c] = comp_unpack(fld, w, f.ty, c)
    return out, is_int


# ---------------------------------------------------------------- pack


def f32_unorm(b, w):
    """RNE(clamp01(f) x (2^w - 1)); NaN and negative values to 0."""
    if is_nan(b) or b >> 31:
        return 0
    if b >= ONE:
        return (1 << w) - 1
    num, den, _ = f32_val(b)
    return rne_div(num * ((1 << w) - 1), den)


def f32_half(b):
    s = (b >> 31) << 15
    e = (b >> 23) & 0xFF
    if e == 0xFF:
        return 0x7E00 if b & 0x7FFFFF else s | 0x7C00
    num, den, _ = f32_val(b)
    if num == 0:
        return s
    # grid of the half result: 2^-24 below 2^-14, else 2^(E-10)
    E = num.bit_length() - den.bit_length()
    if (num << max(0, -E)) < (den << max(0, E)):
        E -= 1
    g = -24 if E < -14 else E - 10
    q = rne_div(num << max(0, -g), den << max(0, g))
    if E < -14:
        return s | q  # q <= 0x400 (0x400 is the smallest normal)
    if q == 1 << 11:
        q >>= 1
        E += 1
    if E > 15:
        return s | 0x7C00
    return s | (E + 15) << 10 | (q - 0x400)


def comp_pack(v, w, ty, ch):
    if ty == UNORM:
        return f32_unorm(v, w)
    if ty == SRGB:
        return v & 0xFF if ch < 3 else f32_unorm(v, 8)
    if ty in (UINT, SINT):
        return v & ((1 << w) - 1)
    if ty == SFLOAT:
        return v & M32 if w == 32 else f32_half(v)
    raise ValueError(ty)


def pack(comps, fmt, wm):
    """comps (four 32-bit words; for sRGB formats R, G, B are the 8-bit
    codes of atg_fmt_srgbenc), write mask wm[3:0] -> (raw, keep), 128
    bits each: keep has a 1 for every bit not written."""
    f = FORMATS.get(fmt)
    allk = (1 << 128) - 1
    if f is None or 'C' not in f.feat:
        return 0, allk
    raw = 0
    wr = 0
    for c, (p, w) in enumerate(f.chans):
        if not (wm >> c) & 1:
            continue
        raw |= comp_pack(comps[c], w, f.ty, c) << p
        wr |= ((1 << w) - 1) << p
    return raw, allk & ~wr


# ---------------------------------------------------------------- sRGB


def _eotf(u):
    if u <= Decimal('0.04045'):
        return u / Decimal('12.92')
    return ((u + Decimal('0.055')) / Decimal('1.055')) ** Decimal('2.4')


def _dec_f32(d, up=False):
    """A positive Decimal to fp32: nearest (even), or with up the smallest
    fp32 above it; checks that d is not within 10^-40 (relative) of a
    rounding boundary, so the 60-digit value decides as the exact one."""
    fr = Fraction(d)
    b = rat_f32(fr.numerator, fr.denominator)
    lo = Fraction(*f32_val(b)[:2])
    if up:
        if lo <= fr:
            b += 1
        nb = Fraction(*f32_val(b)[:2])
        assert abs(fr - lo) > fr * Fraction(1, 10 ** 40) and abs(nb - fr) > fr * Fraction(1, 10 ** 40)
        return b
    for nb in (b - 1, b + 1):
        mid = (lo + Fraction(*f32_val(nb)[:2])) / 2
        assert abs(fr - mid) > fr * Fraction(1, 10 ** 40), d
    return b


def srgb_tables():
    """(decode, thresholds): decode[c] = EOTF(c / 255) as fp32 (nearest);
    thr[c] (c = 0..254) = the smallest fp32 above EOTF((c + 0.5) / 255),
    so the nearest code of a linear x in [0, 1] is the count of
    thresholds <= x."""
    getcontext().prec = 60
    dec = [0] + [_dec_f32(_eotf(Decimal(c) / 255)) for c in range(1, 256)]
    thr = [_dec_f32(_eotf((Decimal(c) + Decimal('0.5')) / 255), up=True) for c in range(255)]
    return dec, thr


def srgb_encode(b):
    """atg_fmt_srgbenc: NaN and negative values (and -0) to 0, else the
    count of thresholds <= x by an 8-step binary search."""
    _, thr = _srgb_tables()
    if is_nan(b) or b >> 31:
        return 0
    lo = 0
    for bit in range(7, -1, -1):
        if b >= thr[lo + (1 << bit) - 1]:
            lo += 1 << bit
    return lo


# ---------------------------------------------------------------- self-test


def f32_of_float(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def selftest():
    t0 = time.time()
    rnd = random.Random(1)
    bad = 0

    def check(name, ok):
        nonlocal bad
        if not ok:
            bad += 1
            if bad < 20:
                print('FAIL fmtmodel.%s' % name)

    # rat_f32 against Python's float (exact for these small cases: the
    # double rounding of num/den to double then to float is avoided by
    # comparing with Fraction neighbours).
    for _ in range(20000):
        num = rnd.getrandbits(rnd.randint(1, 60))
        den = rnd.getrandbits(rnd.randint(1, 60)) | 1
        b = rat_f32(num, den)
        if num == 0 or b >= 0x7F800000:
            continue
        v = Fraction(num, den)
        x = Fraction(*f32_val(b)[:2])
        for nb in (b - 1, b + 1):
            if 0 <= nb < 0x7F800000:
                y = Fraction(*f32_val(nb)[:2])
                check('rat %d/%d' % (num, den), abs(v - x) < abs(v - y) or
                      (abs(v - x) == abs(v - y) and b & 1 == 0))
    # UNORM: every code of every width against Fraction's nearest.
    for w in (1, 2, 4, 5, 6, 8, 10, 11, 16):
        for c in range(1 << w):
            b = unorm_f32(c, w)
            v = Fraction(c, (1 << w) - 1)
            x = Fraction(*f32_val(b)[:2])
            ulp = Fraction(1, 1 << 150) if b == 0 else Fraction(*f32_val(b + 1)[:2]) - x
            check('unorm%d %d' % (w, c), abs(v - x) * 2 <= ulp)
            check('unorm%d rt %d' % (w, c), f32_unorm(b, w) == c)
    for c in range(-128, 128):
        b = snorm_f32(c & 0xFF, 8)
        check('snorm8 %d' % c, b == f32_of_float(max(c / 127.0, -1.0)) or
              Fraction(*f32_val(b)[:2]) == abs(max(Fraction(c, 127), Fraction(-1))))
    # fp16 against struct 'e' (both ways, every half; the round trip
    # through fp32 of every finite half, and random fp32 to half).
    for h in range(1 << 16):
        b = half_f32(h)
        x = struct.unpack('<e', struct.pack('<H', h))[0]
        if x != x:
            check('half nan %x' % h, b == QNAN)
        else:
            check('half %x' % h, b == f32_of_float(x))
            check('half rt %x' % h, f32_half(b) == h)
    for _ in range(200000):
        b = rnd.getrandbits(32)
        if is_nan(b):
            check('f2h nan', f32_half(b) == 0x7E00)
            continue
        x = struct.unpack('<f', struct.pack('<I', b))[0]
        try:
            want = struct.unpack('<H', struct.pack('<e', x))[0]
        except OverflowError:
            want = (b >> 31) << 15 | 0x7C00
        check('f2h %08x' % b, f32_half(b) == want)
    # 11- and 10-bit unsigned floats, E5B9G9R9 against Fraction.
    for mb in (6, 5):
        for v in range(1 << (mb + 5)):
            b = ufloat_f32(v, mb)
            e, m = v >> mb, v & ((1 << mb) - 1)
            if e == 31:
                check('ufl', b == (QNAN if m else 0x7F800000))
                continue
            ex = Fraction(m, 1 << mb) * Fraction(2) ** (-14) if e == 0 else \
                (1 + Fraction(m, 1 << mb)) * Fraction(2) ** (e - 15)
            check('ufl%d %x' % (mb, v), Fraction(*f32_val(b)[:2]) == ex)
    for _ in range(5000):
        m, e = rnd.getrandbits(9), rnd.getrandbits(5)
        check('e5', Fraction(*f32_val(e5_f32(m, e))[:2]) == Fraction(m) * Fraction(2) ** (e - 24))
    # D24: c / (2^24 - 1) and back, every code (the repeated-bits form of
    # the RTL: c / (2^24 - 1) = 0.cc... in binary).
    D = (1 << 24) - 1
    for c in range(1, D):
        lz = 24 - c.bit_length()
        r = ((c << 24 | c) << 24 | c) << lz  # 72 bits, leading one at bit 71
        m = (r >> 48) & 0x7FFFFF
        e = 126 - lz
        if (r >> 47) & 1:
            m += 1
            if m == 1 << 23:
                m = 0
                e += 1
        b = e << 23 | m
        num = (m | 0x800000) * D
        sh = 150 - e
        q, rr = num >> sh, num & ((1 << sh) - 1)
        half = 1 << (sh - 1)
        if rr > half or (rr == half and q & 1):
            q += 1
        if q != c:
            check('d24 rt %d' % c, False)
        if c % 4099 == 1:
            check('d24 exact %d' % c, b == unorm_f32(c, 24))
    # sRGB: the decode table against an independent float computation,
    # the encoder at and around every threshold against the Decimal
    # definition (the code whose interval of EOTF contains x).
    dec, thr = _srgb_tables()
    getcontext().prec = 60
    for c in range(256):
        u = c / 255.0
        x = u / 12.92 if u <= 0.04045 else ((u + 0.055) / 1.055) ** 2.4
        check('srgb dec %d' % c, abs(struct.unpack('<f', struct.pack('<I', dec[c]))[0] - x) <=
              max(x, 1e-30) * 2 ** -23)
    bounds = [_eotf((Decimal(c) + Decimal('0.5')) / 255) for c in range(255)]
    for c in range(255):
        for b in (thr[c] - 1, thr[c], thr[c] + 1):
            fr = Fraction(*f32_val(b)[:2])
            want = sum(1 for d in bounds if Fraction(d) < fr)
            check('srgb enc %08x' % b, srgb_encode(b) == want)
        check('srgb thr order %d' % c, c == 0 or thr[c] > thr[c - 1])
    check('srgb enc 0', srgb_encode(0) == 0 and srgb_encode(0x80000000) == 0)
    check('srgb enc 1', srgb_encode(ONE) == 255 and srgb_encode(0x7F800000) == 255)
    check('srgb enc nan', srgb_encode(QNAN) == 0 and srgb_encode(0xBF800000) == 0)
    # decode then encode returns the code
    for c in range(256):
        check('srgb rt %d' % c, srgb_encode(dec[c]) == c)
    # The fixed-function features are a superset of Vulkan's required ones.
    req, oneof = read_required()
    for fmt, (o, b) in req.items():
        fo, fb = features(fmt)
        check('required %d' % fmt, fo & o == o and fb & b == b)
    for groups, bits in oneof:
        check('oneof %s' % groups, any(all(features(f)[0] & bits == bits for f in g)
                                       for g in groups))
    if bad == 0:
        print('PASS fmtmodel.selftest (%.0f s)' % (time.time() - t0))
    return bad == 0


# ---------------------------------------------------------------- required


FIXED = F_SAMPLED | F_BLIT_SRC | F_LINEAR | F_COLOR | F_BLIT_DST | F_BLEND | F_DS
LETTERS = {'S': F_SAMPLED | F_BLIT_SRC, 'F': F_LINEAR, 'C': F_COLOR | F_BLIT_DST,
           'B': F_BLEND, 'D': F_DS, 'V': F_VERTEX}


def read_required():
    """tools/vk-required-formats.txt: {format: (optimal, buffer)} of the
    fixed-function columns, and the "one of" groups."""
    req = {}
    oneof = []
    with open(os.path.join(ROOT, 'tools', 'vk-required-formats.txt')) as fd:
        for line in fd:
            line = line.split('#')[0].split()
            if not line:
                continue
            if line[0] in ('oneof', 'family'):
                bits = 0
                for ch in line[1]:
                    bits |= LETTERS.get(ch, 0)
                if line[0] == 'oneof':
                    groups = [[int(v)] for v in line[2:]]
                else:
                    groups = []
                    for rng in ' '.join(line[2:]).split('/'):
                        lo, hi = rng.split('-')
                        groups.append(list(range(int(lo), int(hi) + 1)))
                oneof.append((groups, bits & FIXED))
                continue
            fmt = int(line[0])
            img, _, buf = line[2].partition('|')
            o = 0
            for ch in img:
                o |= LETTERS.get(ch, 0)
            b = F_VERTEX if 'V' in buf else 0
            req[fmt] = (o & FIXED, b)
    return req, oneof


# ---------------------------------------------------------------- vectors


def rand_f32(rnd):
    k = rnd.randrange(8)
    if k == 0:
        return rnd.choice([0, 0x80000000, ONE, 0xBF800000, 0x7F800000, 0xFF800000, QNAN,
                           0x3F000000, 0x3F7FFFFF, 0x00000001, 0x477FE000, 0x477FF000,
                           0x38800000, 0x387FC000, 0x33800000, 0x33000001])
    if k < 4:
        return rnd.getrandbits(23) | rnd.randrange(100, 128) << 23
    return rnd.getrandbits(32)


def vectors():
    rnd = random.Random(7)
    vec = os.path.join(ROOT, 'sim', 'vec')
    fmts = sorted(FORMATS)
    with open(os.path.join(vec, 'fmt_info.txt'), 'w') as fd:
        # fmt info(68 bits) optimal buffer (with the ETC2 decoder) optimal buffer (without)
        for fmt in range(256):
            o, b = features(fmt, True)
            o0, b0 = features(fmt, False)
            fd.write('%02x %017x %04x %04x %04x %04x\n' % (fmt, info_word(fmt), o, b, o0, b0))
    with open(os.path.join(vec, 'fmt_unpack.txt'), 'w') as fd:
        # fmt stencil raw(128) c0 c1 c2 c3 is_int
        for fmt in fmts + [0, 1, 200]:
            f = FORMATS.get(fmt)
            nb = f.nbytes if f else 4
            cases = [0, (1 << (8 * nb)) - 1]
            if f and not f.block and len(f.chans) == 1 and f.chans[0][1] <= 11:
                cases += list(range(1 << f.chans[0][1]))
            cases += [rnd.getrandbits(8 * nb) for _ in range(48)]
            if f and f.ty in (SFLOAT, UFLOAT, E5):
                for _ in range(16):
                    v = 0
                    for p, w in f.chans:
                        v |= rnd.choice([0, (1 << w) - 1, 0x7C00, 0x7C01, 0x3C00, 0x0001, 0x8001,
                                         0x7F800000, 0x7FC00000, 0x7C0, 0x7BF, 0x3E0, 0x3DF]
                                        ) & ((1 << w) - 1) << p
                    cases.append(v | rnd.getrandbits(5) << 27)
            for raw in cases:
                for st in ((False, True) if f and f.stencil else (False,)):
                    c, ii = unpack(raw, fmt, st)
                    fd.write('%02x %d %032x %08x %08x %08x %08x %d\n' %
                             (fmt, st, raw, c[0], c[1], c[2], c[3], ii))
    with open(os.path.join(vec, 'fmt_pack.txt'), 'w') as fd:
        # fmt wm c0 c1 c2 c3 raw(128) keep(128)
        for fmt in fmts + [0, 200]:
            f = FORMATS.get(fmt)
            n = 64 if f and 'C' in f.feat else 4
            for i in range(n):
                comps = [rand_f32(rnd) for _ in range(4)]
                if f and f.ty in (UINT, SINT, SRGB):
                    comps = [rnd.getrandbits(32) for _ in range(4)]
                    if f.ty == SRGB:
                        comps[3] = rand_f32(rnd)
                wm = 15 if i < n // 2 else rnd.getrandbits(4)
                raw, keep = pack(comps, fmt, wm)
                fd.write('%02x %x %08x %08x %08x %08x %032x %032x\n' %
                         (fmt, wm, comps[0], comps[1], comps[2], comps[3], raw, keep))
        # every unorm code of the widths 1-10 back from its exact value and the
        # thresholds between codes
        for fmt, w in ((8, 5), (4, 6), (64, 10), (9, 8)):
            for c in range(1 << w):
                b = unorm_f32(c, w)
                for x in (b, b + 1, b - 1 if b else 0):
                    comps = [x, x, x, x]
                    raw, keep = pack(comps, fmt, 15)
                    fd.write('%02x %x %08x %08x %08x %08x %032x %032x\n' %
                             (fmt, 15, x, x, x, x, raw, keep))
    dec, thr = _srgb_tables()
    with open(os.path.join(vec, 'fmt_srgbenc.txt'), 'w') as fd:
        # x code
        xs = [0, 0x80000000, ONE, 0x7F800000, QNAN, 0xBF800000, 0x3F7FFFFF, 0x40000000, 1]
        for c in range(255):
            xs += [thr[c] - 1, thr[c], thr[c] + 1]
        for c in range(256):
            xs.append(dec[c])
        xs += [rnd.getrandbits(23) | rnd.randrange(90, 127) << 23 for _ in range(500)]
        for x in xs:
            fd.write('%08x %02x\n' % (x, srgb_encode(x)))
    req, oneof = read_required()
    with open(os.path.join(vec, 'fmt_required.txt'), 'w') as fd:
        # fmt optimal buffer: the bits Vulkan requires (fixed-function columns)
        for fmt in sorted(req):
            fd.write('%02x %04x %04x\n' % (fmt, req[fmt][0], req[fmt][1]))
        # one-of groups: "ff bits n" then n groups, each "count format..."
        for groups, bits in oneof:
            fd.write('ff %04x %x\n' % (bits, len(groups)))
            for g in groups:
                fd.write('%02x %s\n' % (len(g), ' '.join('%02x' % v for v in g)))
    print('fmtmodel: wrote sim/vec/fmt_{info,unpack,pack,srgbenc,required}.txt')


if __name__ == '__main__':
    if '--selftest' in sys.argv:
        sys.exit(0 if selftest() else 1)
    if '--vectors' in sys.argv:
        vectors()
        sys.exit(0)
    print(__doc__ or 'usage: fmtmodel.py --selftest | --vectors')
    sys.exit(2)
