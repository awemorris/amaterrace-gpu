#!/usr/bin/env python3
# rxmodel.py: the reference model of the RX and the ROP (WS288 p007) for
# the testbenches and the board test.  It is written from the formulas of
# spec/gpu/rx/*.md and spec/gpu/rop/*.md, not from the RTL: fp32 is IEEE
# single with round to nearest even on an unbounded exponent, then
# denormals flushed to zero (inputs and outputs) and NaN results the
# canonical 0x7FC00000 (the SU's rules, design §3.1); the edges are exact
# integers in 15.8 fixed point; the ROP blends in 8-bit unorm.
#
# Library use (tools/rx-vectors.py, plan/tools/zybo/ghci-raster-board.py):
#   import rxmodel as M
#   st = M.State(); st.set(index, value) ...
#   M.draw_raw(st, mem, [x0, y0, z0, x1, y1, z1, x2, y2, z2])   (fp32 bits)
# mem is a bytearray-like object indexed by GPU byte address (M.Mem).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
from fractions import Fraction
import struct

M32 = 0xFFFFFFFF
QNAN = 0x7FC00000
ONE = 0x3F800000

# ---------------------------------------------------------------- fp32


def f2b(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def b2f(b):
    return struct.unpack('<f', struct.pack('<I', b & M32))[0]


def _isnan(b):
    return (b >> 23) & 0xFF == 0xFF and b & 0x7FFFFF != 0


def _isinf(b):
    return (b >> 23) & 0xFF == 0xFF and b & 0x7FFFFF == 0


def _ftz(b):
    """Input denormals are zeros (sign kept)."""
    return b & 0x80000000 if (b >> 23) & 0xFF == 0 else b & M32


def _val(b):
    """The exact value of a finite, flushed fp32."""
    e = (b >> 23) & 0xFF
    if e == 0:
        return Fraction(0)
    m = (b & 0x7FFFFF) | 0x800000
    v = Fraction(m) * (Fraction(2) ** (e - 150))
    return -v if b >> 31 else v


def round_f32(v, zsign=0):
    """v (exact, nonzero or zero with zsign) to fp32: RNE, unbounded
    exponent, then overflow to infinity and underflow to zero."""
    if v == 0:
        return zsign << 31
    s = 1 if v < 0 else 0
    a = -v if s else v
    # e = floor(log2(a))
    e = a.numerator.bit_length() - a.denominator.bit_length()
    if Fraction(2) ** e > a:
        e -= 1
    elif Fraction(2) ** (e + 1) <= a:
        e += 1
    m = a / (Fraction(2) ** (e - 23))	# in [2^23, 2^24)
    q = m.numerator // m.denominator
    r = m - q
    if r > Fraction(1, 2) or (r == Fraction(1, 2) and q & 1):
        q += 1
    if q == 1 << 24:
        q = 1 << 23
        e += 1
    E = e + 127
    if E >= 255:
        return (s << 31) | 0x7F800000
    if E <= 0:
        return s << 31
    return (s << 31) | (E << 23) | (q & 0x7FFFFF)


def fadd(a, b):
    a, b = _ftz(a), _ftz(b)
    if _isnan(a) or _isnan(b):
        return QNAN
    if _isinf(a) and _isinf(b):
        return a if a == b else QNAN
    if _isinf(a):
        return a
    if _isinf(b):
        return b
    v = _val(a) + _val(b)
    if v == 0:
        return 0x80000000 if (a >> 31) and (b >> 31) else 0
    return round_f32(v)


def fsub(a, b):
    return fadd(a, b ^ 0x80000000)


def fmul(a, b):
    a, b = _ftz(a), _ftz(b)
    s = (a ^ b) >> 31
    if _isnan(a) or _isnan(b):
        return QNAN
    za, zb = a & 0x7FFFFFFF == 0, b & 0x7FFFFFFF == 0
    if _isinf(a) or _isinf(b):
        return QNAN if za or zb else (s << 31) | 0x7F800000
    if za or zb:
        return s << 31
    return round_f32(_val(a) * _val(b))


def fdiv(a, b):
    a, b = _ftz(a), _ftz(b)
    s = (a ^ b) >> 31
    if _isnan(a) or _isnan(b):
        return QNAN
    za, zb = a & 0x7FFFFFFF == 0, b & 0x7FFFFFFF == 0
    if _isinf(a):
        return QNAN if _isinf(b) else (s << 31) | 0x7F800000
    if _isinf(b):
        return s << 31
    if zb:
        return QNAN if za else (s << 31) | 0x7F800000
    if za:
        return s << 31
    return round_f32(_val(a) / _val(b))


def _rne_int(v):
    q = v.numerator // v.denominator
    r = v - q
    if r > Fraction(1, 2) or (r == Fraction(1, 2) and q & 1):
        q += 1
    return q


def f2fix(b, frac=8, lim=(1 << 22) - 1):
    """fp32 to signed fixed point with frac fraction bits, RNE, saturated
    to +-lim; NaN is 0."""
    b = _ftz(b)
    if _isnan(b):
        return 0
    if _isinf(b):
        return -lim if b >> 31 else lim
    q = _rne_int(_val(b) * (1 << frac))
    return max(-lim, min(lim, q))


def int2f(v, shift=0):
    """A signed integer times 2^-shift to fp32 (RNE)."""
    return round_f32(Fraction(v, 1 << shift))


def fclamp01(b):
    """Depth clamp: NaN and negative (sign set) to +0, above 1.0 to 1.0."""
    if _isnan(b) or b >> 31:
        return 0
    if b > ONE:
        return ONE
    return b

# ---------------------------------------------------------------- STATE

S_VIEWPORT = 0x050
S_SCISSOR_MIN = 0x056
S_SCISSOR_MAX = 0x057
S_CULL = 0x058
S_DEBUG_COLOR = 0x05C
S_RT_BASE = 0x070
S_RT_STRIDE = 0x071
S_RT_FORMAT = 0x072
S_RT_SIZE = 0x073
S_DS_BASE = 0x074
S_DS_STRIDE = 0x075
S_DEPTH = 0x076
S_BLEND = 0x07A
S_BLEND_CONST = 0x07B
S_WRITE_MASK = 0x07C
S_RAW = 0x1E0


class State:
    def __init__(self):
        self.s = [0] * 512

    def set(self, idx, value):
        self.s[idx] = value & M32

    def __getitem__(self, idx):
        return self.s[idx]

# ---------------------------------------------------------------- setup


def _s24(v):
    v &= (1 << 24) - 1
    return v - (1 << 24) if v >> 23 else v


def plane(f, dx1, dy1, dx2, dy2, rd, ox, oy):
    """Plane of the values f[0..2] (fp32 bits): (A, B, C), C at the bbox
    origin's sample; the operation order of spec atg_rx_setup §4."""
    t0 = fsub(f[1], f[0])
    t1 = fsub(f[2], f[0])
    a = fmul(fsub(fmul(t0, dy2), fmul(t1, dy1)), rd)
    b = fmul(fsub(fmul(t1, dx1), fmul(t0, dx2)), rd)
    c = fadd(f[0], fadd(fmul(a, ox), fmul(b, oy)))
    return (a, b, c)


def setup(st, tri):
    """tri: dict pos[3][4] (clip xyzw, bits), wt[3][3], pt[3], free, raw.
    Returns the sp_tri fields as a dict (spec atg_rx_setup §4)."""
    raw = tri['raw']
    one = ONE
    X, Y, Z, RW, B0, B1 = [], [], [], [], [], []
    vp = [st[S_VIEWPORT + k] for k in range(6)]
    for i in range(3):
        x, y, z, w = tri['pos'][i]
        if raw:
            X.append(x)
            Y.append(y)
            Z.append(z)
        else:
            rw = fdiv(one, w)
            RW.append(rw)
            X.append(fadd(fmul(fmul(x, rw), vp[0]), vp[2]))
            Y.append(fadd(fmul(fmul(y, rw), vp[1]), vp[3]))
            Z.append(fadd(fmul(fmul(z, rw), vp[4]), vp[5]))
            B0.append(fmul(tri['wt'][i][0], rw))
            B1.append(fmul(tri['wt'][i][1], rw))
    px = [f2fix(v) for v in X]
    py = [f2fix(v) for v in Y]
    dx1, dy1 = px[1] - px[0], py[1] - py[0]
    dx2, dy2 = px[2] - px[0], py[2] - py[0]
    D = dx1 * dy2 - dx2 * dy1
    ccw = D < 0	# area2 = -D > 0
    cull = st[S_CULL]
    front = ccw if cull & 4 else not ccw
    culled = (cull & 1 and front) or (cull & 2 and not front)
    # bbox in pixels, max exclusive, clipped to the scissor and the RT
    bx0 = min(px) >> 8
    by0 = min(py) >> 8
    bx1 = (max(px) >> 8) + 1
    by1 = (max(py) >> 8) + 1
    smin, smax, rts = st[S_SCISSOR_MIN], st[S_SCISSOR_MAX], st[S_RT_SIZE]
    if smax != 0:
        bx0 = max(bx0, smin & 0xFFFF)
        by0 = max(by0, smin >> 16)
        bx1 = min(bx1, smax & 0xFFFF)
        by1 = min(by1, smax >> 16)
    bx0, by0 = max(bx0, 0), max(by0, 0)
    bx1, by1 = min(bx1, rts & 0xFFFF), min(by1, rts >> 16)
    empty = D == 0 or culled or bx1 <= bx0 or by1 <= by0
    r = {'pt': tri['pt'], 'free': tri['free'], 'front': int(front), 'raw': raw,
         'edges': [(0, 0, 0)] * 3, 'bbox': (0, 0, 0, 0),
         'z': (0, 0, 0), 'w': (0, 0, 0), 'b0': (0, 0, 0), 'b1': (0, 0, 0)}
    if empty:
        return r
    order = [0, 1, 2] if ccw else [0, 2, 1]
    sx, sy = bx0 * 256 + 128, by0 * 256 + 128
    edges = []
    for k in range(3):
        a, b = order[k], order[(k + 1) % 3]
        A = py[b] - py[a]
        B = px[a] - px[b]
        tl = A > 0 or (A == 0 and B > 0)
        E = A * (sx - px[a]) + B * (sy - py[a]) - (0 if tl else 1)
        edges.append((A, B, E))
    r['edges'] = edges
    r['bbox'] = (bx0, by0, bx1, by1)
    fdx1, fdy1 = int2f(dx1, 8), int2f(dy1, 8)
    fdx2, fdy2 = int2f(dx2, 8), int2f(dy2, 8)
    rd = fdiv(one, int2f(D, 16))
    ox, oy = int2f(sx - px[0], 8), int2f(sy - py[0], 8)
    P = (fdx1, fdy1, fdx2, fdy2, rd, ox, oy)
    r['z'] = plane(Z, *P)
    if not raw:
        r['w'] = plane(RW, *P)
        r['b0'] = plane(B0, *P)
        r['b1'] = plane(B1, *P)
    return r


def pack_sp(r):
    """sp_tri as an integer (768 bits)."""
    v = 0
    for k, (A, B, E) in enumerate(r['edges']):
        v |= ((A & 0xFFFFFF) | ((B & 0xFFFFFF) << 24) | ((E & (1 << 48) - 1) << 48)) << (96 * k)
    bx0, by0, bx1, by1 = r['bbox']
    v |= (bx0 | (by0 << 16) | (bx1 << 32) | (by1 << 48)) << 288
    for n, key in enumerate(('z', 'w', 'b0', 'b1')):
        for j in range(3):
            v |= r[key][j] << (352 + 96 * n + 32 * j)
    for i in range(3):
        v |= r['pt'][i] << (736 + 8 * i)
    v |= r['free'] << 760
    v |= r['front'] << 763
    v |= r['raw'] << 764
    return v


def unpack_sp(v):
    def f(lo, n):
        return (v >> lo) & ((1 << n) - 1)

    def s(x, n):
        return x - (1 << n) if x >> (n - 1) else x
    r = {'edges': [(s(f(96 * k, 24), 24), s(f(96 * k + 24, 24), 24), s(f(96 * k + 48, 48), 48))
                   for k in range(3)],
         'bbox': (f(288, 16), f(304, 16), f(320, 16), f(336, 16)),
         'pt': [f(736 + 8 * i, 8) for i in range(3)], 'free': f(760, 3),
         'front': f(763, 1), 'raw': f(764, 1)}
    for n, key in enumerate(('z', 'w', 'b0', 'b1')):
        r[key] = tuple(f(352 + 96 * n + 32 * j, 32) for j in range(3))
    return r


def pack_cl(tri):
    v = 0
    for i in range(3):
        for c in range(4):
            v |= tri['pos'][i][c] << (32 * (4 * i + c))
        for j in range(3):
            v |= tri['wt'][i][j] << (384 + 32 * (3 * i + j))
        v |= tri['pt'][i] << (672 + 8 * i)
    v |= tri['free'] << 696
    v |= tri['raw'] << 699
    return v


IDW = [[ONE, 0, 0], [0, ONE, 0], [0, 0, ONE]]


def raw_tri(words):
    """DRAW_RAW's 9 words to a cl_tri (spec atg_rx_clip §4)."""
    return {'pos': [[words[3 * i], words[3 * i + 1], words[3 * i + 2], ONE] for i in range(3)],
            'wt': [row[:] for row in IDW], 'pt': [0, 0, 0], 'free': 0, 'raw': 1}

# ---------------------------------------------------------------- clip


def _lerp(p, q, t):
    """p + t (q - p), component-wise, for the 7 words {x, y, z, w, w0, w1, w2}."""
    return [fadd(p[c], fmul(fsub(q[c], p[c]), t)) for c in range(7)]


def clip(pos, pt, free):
    """Near-plane clip (z >= 0 inside) of a triangle: pos[3][4] bits.
    Returns the list of cl_tri dicts (spec atg_rx_clip §4)."""
    v = [pos[i] + IDW[i] for i in range(3)]

    def inside(b):
        return not _isnan(_ftz(b)) and not (_ftz(b) >> 31 and _ftz(b) & 0x7FFFFFFF)

    ins = [inside(v[i][2]) for i in range(3)]

    def tri(a, b, c, fl):
        return {'pos': [a[:4], b[:4], c[:4]], 'wt': [a[4:], b[4:], c[4:]],
                'pt': list(pt), 'free': fl, 'raw': 0}

    def isect(p, q):
        t = fdiv(p[2], fsub(p[2], q[2]))
        return _lerp(p, q, t)
    n = sum(ins)
    if n == 3:
        return [tri(v[0], v[1], v[2], free)]
    if n == 0:
        z = [0, 0, 0, ONE, 0, 0, 0]
        return [tri(z, z, z, free)]
    # rotate so that the run of inside vertices starts at a
    for r in range(3):
        a, b, c = v[r], v[(r + 1) % 3], v[(r + 2) % 3]
        ia, ib, ic = ins[r], ins[(r + 1) % 3], ins[(r + 2) % 3]
        if n == 1 and ia:
            return [tri(a, isect(a, b), isect(a, c), free)]
        if n == 2 and ia and ib:
            ibc = isect(b, c)
            ica = isect(a, c)
            return [tri(a, b, ibc, 0), tri(a, ibc, ica, free)]
    raise AssertionError('clip')

# ---------------------------------------------------------------- scan


def scan(r):
    """The direct quads of a set-up triangle: list of (x, y, mask, z[4]),
    the last flagged; [] for an empty bbox (spec atg_rx_scan §4)."""
    bx0, by0, bx1, by1 = r['bbox']
    if bx1 <= bx0 or by1 <= by0:
        return []
    az, bz, cz = r['z']
    out = []
    for qy in range(by0 & ~1, by1, 2):
        for qx in range(bx0 & ~1, bx1, 2):
            mask = 0
            zs = [0, 0, 0, 0]
            for ln in range(4):
                x, y = qx + (ln & 1), qy + (ln >> 1)
                if not (bx0 <= x < bx1 and by0 <= y < by1):
                    continue
                ok = True
                for (A, B, E) in r['edges']:
                    if E + 256 * (A * (x - bx0) + B * (y - by0)) < 0:
                        ok = False
                if not ok:
                    continue
                mask |= 1 << ln
                zi = fadd(fadd(fmul(az, int2f(x - bx0)), fmul(bz, int2f(y - by0))), cz)
                zs[ln] = fclamp01(zi)
            if mask:
                out.append((qx, qy, mask, zs))
    if not out:
        out.append((bx0 & ~1, by0 & ~1, 0, [0, 0, 0, 0]))
    return out

# ---------------------------------------------------------------- ROP


class Mem:
    """Sparse little-endian GPU memory."""

    def __init__(self):
        self.b = {}

    def rd8(self, a):
        return self.b.get(a, 0)

    def wr8(self, a, v):
        self.b[a] = v & 0xFF

    def rd32(self, a):
        return sum(self.rd8(a + i) << (8 * i) for i in range(4))

    def wr32(self, a, v):
        for i in range(4):
            self.wr8(a + i, v >> (8 * i))

    def rd16(self, a):
        return self.rd8(a) | (self.rd8(a + 1) << 8)

    def wr16(self, a, v):
        self.wr8(a, v)
        self.wr8(a + 1, v >> 8)


UNORM8 = [round_f32(Fraction(c, 255)) for c in range(256)]


def f2u8(b):
    """fp32 to unorm8: NaN and <= 0 to 0, >= 1 to 255, else RNE(f x 255)."""
    b = _ftz(b)
    if _isnan(b) or b >> 31 or b & 0x7FFFFFFF == 0:
        return 0
    if b >= ONE:
        return 255
    return _rne_int(_val(b) * 255)


def f2u24(b):
    b = _ftz(b)
    if _isnan(b) or b >> 31 or b & 0x7FFFFFFF == 0:
        return 0
    if b >= ONE:
        return (1 << 24) - 1
    return _rne_int(_val(b) * ((1 << 24) - 1))


def div255(x):
    """round(x / 255) for 0 <= x (x / 255 is never a half)."""
    return (x + 127) // 255


def _fkey(b):
    """Order key of a non-NaN fp32 (flushed), -0 == +0."""
    b = _ftz(b)
    if b & 0x7FFFFFFF == 0:
        return 0
    return -(b & 0x7FFFFFFF) if b >> 31 else b


def depth_pass(func, frag, stored, f32):
    if func == 0:
        return False
    if func == 7:
        return True
    if f32:
        if _isnan(_ftz(frag)) or _isnan(_ftz(stored)):
            return func == 5
        a, b = _fkey(frag), _fkey(stored)
    else:
        a, b = frag, stored
    return {1: a < b, 2: a == b, 3: a <= b, 4: a > b, 5: a != b, 6: a >= b}[func]


def unpack_px(fmt, p):
    if fmt == 0:
        return [(p >> 16) & 255, (p >> 8) & 255, p & 255, p >> 24]
    if fmt == 1:
        return [p & 255, (p >> 8) & 255, (p >> 16) & 255, p >> 24]
    r, g, b = (p >> 11) & 31, (p >> 5) & 63, p & 31
    return [(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2), 255]


def pack_px(fmt, c):
    r, g, b, a = c
    if fmt == 0:
        return b | (g << 8) | (r << 16) | (a << 24)
    if fmt == 1:
        return r | (g << 8) | (b << 16) | (a << 24)
    return ((r * 31 + 127) // 255 << 11) | ((g * 63 + 127) // 255 << 5) | ((b * 31 + 127) // 255)


def _factor(f, ch, s, d, k):
    sa, da, ka = s[3], d[3], k[3]
    if f == 1:
        return 255
    if f == 2:
        return s[ch]
    if f == 3:
        return 255 - s[ch]
    if f == 4:
        return d[ch]
    if f == 5:
        return 255 - d[ch]
    if f == 6:
        return sa
    if f == 7:
        return 255 - sa
    if f == 8:
        return da
    if f == 9:
        return 255 - da
    if f == 10:
        return k[ch]
    if f == 11:
        return 255 - k[ch]
    if f == 12:
        return ka
    if f == 13:
        return 255 - ka
    if f == 14:
        return 255 if ch == 3 else min(sa, 255 - da)
    return 0


def blend(bl, kc, s, d):
    """BLEND (spec atg_rop_blend §4) of RGBA8 s over d."""
    if not bl & 1:
        return s[:]
    k = [kc & 255, (kc >> 8) & 255, (kc >> 16) & 255, kc >> 24]
    out = []
    for ch in range(4):
        if ch < 3:
            fs, fd, op = (bl >> 1) & 15, (bl >> 5) & 15, (bl >> 9) & 7
        else:
            fs, fd, op = (bl >> 12) & 15, (bl >> 16) & 15, (bl >> 20) & 7
        p = s[ch] * _factor(fs, ch, s, d, k)
        q = d[ch] * _factor(fd, ch, s, d, k)
        if op == 0:
            v = div255(p + q)
        elif op == 1:
            v = div255(max(p - q, 0))
        elif op == 2:
            v = div255(max(q - p, 0))
        elif op == 3:
            v = min(s[ch], d[ch])
        elif op == 4:
            v = max(s[ch], d[ch])
        else:
            v = div255(p + q)
        out.append(min(v, 255))
    return out


def debug_rgba(st):
    c = st[S_DEBUG_COLOR]
    return [UNORM8[(c >> (8 * i)) & 255] for i in range(4)]


def ds_quad(st, mem, x, y, mask, z):
    """atg_rop_ds: the depth test and write of a quad; returns the passing lanes."""
    dep = st[S_DEPTH]
    test = dep & 1 and dep & 0x60
    f32 = bool(dep & 0x40)
    func = (dep >> 2) & 7
    if not test:
        return mask
    out = 0
    for ln in range(4):
        if not mask >> ln & 1:
            continue
        px, py = x + (ln & 1), y + (ln >> 1)
        da = st[S_DS_BASE] + py * st[S_DS_STRIDE] + px * 4
        stored = mem.rd32(da)
        if f32:
            ok = depth_pass(func, z[ln], stored, True)
            nv = z[ln]
        else:
            ok = depth_pass(func, f2u24(z[ln]), stored & 0xFFFFFF, False)
            nv = (stored & 0xFF000000) | f2u24(z[ln])
        if ok:
            out |= 1 << ln
            if dep & 2:
                mem.wr32(da, nv)
    return out


def rop_quad(st, mem, x, y, mask, z, colors):
    """One quad in primitive order: depth test/write, blend, write
    (spec atg_rop_ds, atg_rop_wb).  colors: 4 lanes x RGBA fp32 bits."""
    mask = ds_quad(st, mem, x, y, mask, z)
    for ln in range(4):
        if not mask >> ln & 1:
            continue
        px, py = x + (ln & 1), y + (ln >> 1)
        fmt = st[S_RT_FORMAT] & 3
        ps = 2 if fmt == 2 else 4
        ca = st[S_RT_BASE] + py * st[S_RT_STRIDE] + px * ps
        dpx = mem.rd16(ca) if ps == 2 else mem.rd32(ca)
        p = blend_pixel(st, colors[ln], dpx)
        if ps == 2:
            mem.wr16(ca, p)
        else:
            mem.wr32(ca, p)


def blend_pixel(st, color, dpx):
    """One pixel through atg_rop_blend: fp32 RGBA color over the pixel dpx
    (RT_FORMAT bits), BLEND, WRITE_MASK; returns the new pixel bits."""
    fmt = st[S_RT_FORMAT] & 3
    d = unpack_px(fmt, dpx)
    s = [f2u8(color[c]) for c in range(4)]
    o = blend(st[S_BLEND], st[S_BLEND_CONST], s, d)
    wm = st[S_WRITE_MASK]
    o = [o[c] if wm >> c & 1 else d[c] for c in range(4)]
    if fmt == 2:
        # channels kept by WRITE_MASK keep their original bits
        p = pack_px(2, o)
        keep = (0 if wm & 1 else 0xF800) | (0 if wm & 2 else 0x07E0) | (0 if wm & 4 else 0x001F)
        return (p & ~keep) | (dpx & keep)
    return pack_px(fmt, o)


def draw_tri(st, mem, tri):
    """One cl_tri through setup, scan and the ROP with DEBUG_COLOR."""
    r = setup(st, tri)
    col = debug_rgba(st)
    quads = scan(r)
    for (x, y, mask, z) in quads:
        rop_quad(st, mem, x, y, mask, z, [col] * 4)
    return r, quads


def draw_raw(st, mem, words):
    return draw_tri(st, mem, raw_tri(words))


if __name__ == '__main__':
    # Self-checks of the model's arithmetic.
    import random
    rnd = random.Random(1)
    for c in range(256):
        assert f2u8(UNORM8[c]) == c
    for x in range(0, 2 * 65025 + 1):
        assert div255(x) == (2 * x + 255) // 510
    for _ in range(20000):
        a = f2b(rnd.uniform(-1e4, 1e4))
        b = f2b(rnd.uniform(-1e4, 1e4))
        for op, ref in ((fadd, lambda p, q: p + q), (fmul, lambda p, q: p * q)):
            got = op(a, b)
            exp = f2b(float(__import__('numpy').float32(ref(__import__('numpy').float32(b2f(a)),
                                                            __import__('numpy').float32(b2f(b))))))
            assert got == exp, (op.__name__, hex(a), hex(b), hex(got), hex(exp))
        if b & 0x7FFFFFFF:
            import numpy as np
            assert fdiv(a, b) == f2b(float(np.float32(b2f(a)) / np.float32(b2f(b))))
    print('rxmodel: self-check PASS')
