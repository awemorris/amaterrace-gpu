#!/usr/bin/env python3
# Generates the self-checking atg_cpu test programs rv32i.S and rv32m.S:
# every expected value is computed here by a reference model of RV32IM.
# A program writes 1 to TOHOST (0xF000_0000) when every check passed, or
# 2*n+1 for the first failing check n.
#   python3 -I gen.py OUTDIR   (run by tools/cpu-tests.sh)
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import random
import sys

M = 0xFFFFFFFF
CORNER = [0, 1, 2, 0xFFFFFFFF, 0xFFFFFFFE, 0x80000000, 0x7FFFFFFF,
          0x80000001, 0x1F, 0x20, 0x12345678, 0xFFFF8000, 0x00007FFF]


def s32(x):
    x &= M
    return x - (1 << 32) if x & 0x80000000 else x


def sext(x, bits):
    x &= (1 << bits) - 1
    return x - (1 << bits) if x >> (bits - 1) else x


def alu(op, a, b):
    sh = b & 31
    if op == 'add':
        return (a + b) & M
    if op == 'sub':
        return (a - b) & M
    if op == 'sll':
        return (a << sh) & M
    if op == 'slt':
        return int(s32(a) < s32(b))
    if op == 'sltu':
        return int(a < b)
    if op == 'xor':
        return a ^ b
    if op == 'srl':
        return a >> sh
    if op == 'sra':
        return (s32(a) >> sh) & M
    if op == 'or':
        return a | b
    if op == 'and':
        return a & b
    if op == 'mul':
        return (a * b) & M
    if op == 'mulh':
        return ((s32(a) * s32(b)) >> 32) & M
    if op == 'mulhsu':
        return ((s32(a) * b) >> 32) & M
    if op == 'mulhu':
        return ((a * b) >> 32) & M
    if op in ('div', 'rem'):
        x, y = s32(a), s32(b)
        if y == 0:
            return M if op == 'div' else a
        if x == -0x80000000 and y == -1:
            return 0x80000000 if op == 'div' else 0
        q = abs(x) // abs(y)
        if (x < 0) != (y < 0):
            q = -q
        return (q if op == 'div' else x - q * y) & M
    if op == 'divu':
        return M if b == 0 else a // b
    if op == 'remu':
        return a if b == 0 else a % b
    raise ValueError(op)


class Prog:
    def __init__(self, seed):
        self.rnd = random.Random(seed)
        self.lines = ['\t.section .text.start', '\t.globl _start', '_start:']
        self.n = 0

    def emit(self, s):
        self.lines.append('\t' + s)

    def reg(self):
        return 'x%d' % self.rnd.randint(1, 28)

    def regs(self, k):
        return ['x%d' % r for r in self.rnd.sample(range(1, 29), k)]

    def check(self, r, want):
        """Compare register r with want; x31 holds the expected value."""
        self.n += 1
        self.emit('li x30, %d' % self.n)
        self.emit('li x31, 0x%x' % (want & M))
        self.emit('bne %s, x31, fail' % r)

    def value(self):
        if self.rnd.random() < 0.4:
            return self.rnd.choice(CORNER)
        return self.rnd.getrandbits(32)

    def finish(self):
        self.emit('lui x29, 0xF0000')
        self.emit('li x31, 1')
        self.emit('sw x31, 0(x29)')
        self.lines.append('1:\tj 1b')
        self.lines.append('fail:')
        self.emit('lui x29, 0xF0000')
        self.emit('slli x30, x30, 1')
        self.emit('ori x30, x30, 1')
        self.emit('sw x30, 0(x29)')
        self.lines.append('2:\tj 2b')
        return '\n'.join(self.lines) + '\n'


def rr(p, ops, count):
    for _ in range(count):
        op = p.rnd.choice(ops)
        a, b = p.value(), p.value()
        ra, rb, rd = p.regs(3)
        # Sometimes alias the destination with a source.
        c = p.rnd.random()
        if c < 0.15:
            rd = ra
        elif c < 0.25:
            rd = rb
        elif c < 0.3:
            rb = ra
            b = a
        p.emit('li %s, 0x%x' % (ra, a))
        if rb != ra:
            p.emit('li %s, 0x%x' % (rb, b))
        p.emit('%s %s, %s, %s' % (op, rd, ra, rb))
        p.check(rd, alu(op, a, b))


def gen_rv32i(p):
    # Register-register ALU.
    rr(p, ['add', 'sub', 'sll', 'slt', 'sltu', 'xor', 'srl', 'sra', 'or', 'and'], 200)
    # Register-immediate ALU.
    for _ in range(200):
        op = p.rnd.choice(['addi', 'slti', 'sltiu', 'xori', 'ori', 'andi',
                           'slli', 'srli', 'srai'])
        a = p.value()
        if op in ('slli', 'srli', 'srai'):
            imm = p.rnd.randint(0, 31)
            b = imm
        else:
            imm = p.rnd.choice([0, 1, -1, 2047, -2048, p.rnd.randint(-2048, 2047)])
            b = imm & M
        ra, rd = p.regs(2)
        if p.rnd.random() < 0.2:
            rd = ra
        p.emit('li %s, 0x%x' % (ra, a))
        p.emit('%s %s, %s, %d' % (op, rd, ra, imm))
        p.check(rd, alu(op[:-1] if op != 'sltiu' else 'sltu', a, b))
    # x0 stays 0.
    p.emit('addi x0, x0, 5')
    p.emit('li x1, -1')
    p.emit('add x0, x1, x1')
    p.emit('mv x2, x0')
    p.check('x2', 0)
    p.check('x0', 0)
    # LUI and AUIPC.
    for i in range(20):
        imm = p.rnd.getrandbits(20) if i > 2 else [0, 0xFFFFF, 0x80000][i]
        rd = p.reg()
        p.emit('lui %s, 0x%x' % (rd, imm))
        p.check(rd, imm << 12)
        p.emit('.La%d: auipc %s, 0x%x' % (i, rd, imm))
        p.emit('la x29, .La%d' % i)
        p.emit('li x31, 0x%x' % ((imm << 12) & M))
        p.emit('add x29, x29, x31')
        p.n += 1
        p.emit('li x30, %d' % p.n)
        p.emit('bne %s, x29, fail' % rd)
    # Branches, forward: rd = 2 if taken, 3 if not.
    conds = {'beq': lambda a, b: a == b, 'bne': lambda a, b: a != b,
             'blt': lambda a, b: s32(a) < s32(b), 'bge': lambda a, b: s32(a) >= s32(b),
             'bltu': lambda a, b: a < b, 'bgeu': lambda a, b: a >= b}
    for i in range(150):
        op = p.rnd.choice(sorted(conds))
        a = p.value()
        b = a if p.rnd.random() < 0.25 else p.value()
        ra, rb, rd = p.regs(3)
        p.emit('li %s, 0x%x' % (ra, a))
        p.emit('li %s, 0x%x' % (rb, b))
        p.emit('li %s, 0' % rd)
        p.emit('%s %s, %s, .Lb%d' % (op, ra, rb, i))
        p.emit('addi %s, %s, 1' % (rd, rd))
        p.lines.append('.Lb%d:' % i)
        p.emit('addi %s, %s, 2' % (rd, rd))
        p.check(rd, 2 if conds[op](a, b) else 3)
    # Branches, backward: count loops.
    for i in range(8):
        k = p.rnd.randint(1, 20)
        rc, rs = p.regs(2)
        p.emit('li %s, %d' % (rc, k))
        p.emit('li %s, 0' % rs)
        p.lines.append('.Ll%d:' % i)
        p.emit('addi %s, %s, 3' % (rs, rs))
        p.emit('addi %s, %s, -1' % (rc, rc))
        p.emit('bnez %s, .Ll%d' % (rc, i))
        p.check(rs, 3 * k)
    # JAL and JALR: the link and the target.
    for i in range(30):
        rd, rt = p.regs(2)
        p.emit('li %s, 0' % rt)
        if i % 3 == 0:
            p.lines.append('.Lj%d:' % i)
            p.emit('jal %s, .Lk%d' % (rd, i))
        else:
            # target = (rs + off) & ~1 with rs = label - (off & ~1).
            off = p.rnd.choice([0, 4, -4, 8, 1, 3, 2047, -2045])
            rs = rd
            while p.rnd.random() > 0.3 and rs == rd or rs == rt:
                rs = p.reg()
            p.emit('la %s, .Lk%d' % (rs, i))
            if off:
                p.emit('addi %s, %s, %d' % (rs, rs, -(off & ~1)))
            p.lines.append('.Lj%d:' % i)
            p.emit('jalr %s, %d(%s)' % (rd, off, rs))
        p.emit('li %s, 1' % rt)
        p.lines.append('.Lk%d:' % i)
        p.check(rt, 0)
        p.emit('la x29, .Lj%d' % i)
        p.emit('addi x29, x29, 4')
        p.n += 1
        p.emit('li x30, %d' % p.n)
        p.emit('bne %s, x29, fail' % rd)
    # Loads and stores against a model of 64 bytes at 0x10100.
    mem = [0] * 64
    rb = 'x28'
    p.emit('li %s, 0x10120' % rb)
    for _ in range(64):
        k = p.rnd.choice([1, 2, 4])
        off = p.rnd.randrange(0, 64, k)
        v = p.value()
        rv = 'x%d' % p.rnd.randint(1, 27)
        p.emit('li %s, 0x%x' % (rv, v))
        p.emit('%s %s, %d(%s)' % ({1: 'sb', 2: 'sh', 4: 'sw'}[k], rv, off - 32, rb))
        for j in range(k):
            mem[off + j] = (v >> (8 * j)) & 0xFF
    for _ in range(200):
        op = p.rnd.choice(['lb', 'lbu', 'lh', 'lhu', 'lw'])
        k = {'lb': 1, 'lbu': 1, 'lh': 2, 'lhu': 2, 'lw': 4}[op]
        off = p.rnd.randrange(0, 64, k)
        v = 0
        for j in range(k):
            v |= mem[off + j] << (8 * j)
        if op in ('lb', 'lh'):
            v = sext(v, 8 * k) & M
        rd = 'x%d' % p.rnd.randint(1, 27)
        p.emit('%s %s, %d(%s)' % (op, rd, off - 32, rb))
        p.check(rd, v)
    # A load used as the base of the next load, and FENCE.
    p.emit('li x1, 0x10200')
    p.emit('li x2, 0x10204')
    p.emit('sw x2, 0(x1)')
    p.emit('li x3, 0x5a5a1234')
    p.emit('sw x3, 0(x2)')
    p.emit('fence')
    p.emit('lw x4, 0(x1)')
    p.emit('lw x5, 0(x4)')
    p.check('x5', 0x5a5a1234)


def gen_rv32m(p):
    ops = ['mul', 'mulh', 'mulhsu', 'mulhu', 'div', 'divu', 'rem', 'remu']
    for op in ops:
        for a in CORNER:
            for b in [0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 7, 0xFFFFFFF9]:
                ra, rb, rd = p.regs(3)
                p.emit('li %s, 0x%x' % (ra, a))
                p.emit('li %s, 0x%x' % (rb, b))
                p.emit('%s %s, %s, %s' % (op, rd, ra, rb))
                p.check(rd, alu(op, a, b))
    rr(p, ops, 200)
    # A result used at once, and back-to-back multiply/divide.
    p.emit('li x1, 1000')
    p.emit('li x2, 7')
    p.emit('div x3, x1, x2')
    p.emit('mul x4, x3, x2')
    p.emit('rem x5, x1, x2')
    p.emit('add x6, x4, x5')
    p.check('x6', 1000)


def main():
    out = sys.argv[1]
    for name, fn, seed in (('rv32i', gen_rv32i, 1), ('rv32m', gen_rv32m, 2)):
        p = Prog(seed)
        fn(p)
        with open('%s/%s.S' % (out, name), 'w') as f:
            f.write('# Generated by sim/tb/cpu/gen.py; do not edit.\n')
            f.write(p.finish())


main()
