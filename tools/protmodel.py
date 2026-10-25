#!/usr/bin/env python3
# protmodel.py: the reference model of session protection (docs/ghci.md
# section 11.6, spec/gpu/mc/atg_mc_prot.md): whether the MC's root lets a
# request through, refuses it as outside the aperture, or refuses it for
# protection.  It is written from the rules of the specification, not from
# the RTL.
#
# The rules, for a request of one line at byte address `addr`:
#   - outside [aperture base, limit) (both line aligned): refused, aperture;
#   - a write into [PROT_TABLE, + PROT_TABLE_BYTES) without the tbl bit,
#     while PROT_TABLE != 0: refused, protection (whatever chk says);
#   - chk = 0: allowed;
#   - chk = 1: g = addr >> 12; refused (protection) when PROT_TABLE = 0 or
#     g is outside [G0, G1) (G0 = floor(base / 4096), G1 = ceil(limit /
#     4096)); else with b = table[g - G0], slot s and write w:
#       own   = s != 0 and b[5:0] == s and not (w and b[6])
#       pub   = b[7] and not w
#       grant = some valid grant e with e.slot == s, e.base <= g < e.limit
#               and (e.write if w else e.read)
#     allowed when own or pub or grant, else refused (protection).
#   An atomic (a read of a client in the RMW mask) is judged as a write.
#
# Library use:
#   import protmodel as P
#   m = P.Prot(base, limit, line_shift)
#   m.tbase = 0xE0000; m.table[g - m.g0()] = owner | P.RO | P.PUB
#   m.grants.append(P.Grant(slot, read, write, gbase, glimit))
#   m.check(addr, write, chk, tbl, slot)  ->  OK, APER or PROT
# Vectors for sim/tb/atg_mc_prot_tb.v:
#   python3 -I tools/protmodel.py --vectors sim/vec/prot.txt [--seed N]
# Self-check: python3 -I tools/protmodel.py --selftest  ->  PASS protmodel.selftest
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import random
import sys

GRANULE_SHIFT = 12
GRANULE = 1 << GRANULE_SHIFT
RO = 0x40
PUB = 0x80
OWNER = 0x3F

OK = 0
APER = 1
PROT = 2


class Grant:
    """One entry of the grant CAM: granules [base, limit)."""

    def __init__(self, slot, read, write, base, limit, valid=True):
        self.slot = slot
        self.read = read
        self.write = write
        self.base = base
        self.limit = limit
        self.valid = valid


class Prot:
    """The protection state the MC's root sees."""

    def __init__(self, base, limit, line_shift=5):
        self.base = base
        self.limit = limit
        self.line_shift = line_shift
        self.tbase = 0
        self.table = bytearray(self.table_bytes())
        self.grants = []

    def g0(self):
        return self.base >> GRANULE_SHIFT

    def g1(self):
        return (self.limit + GRANULE - 1) >> GRANULE_SHIFT

    def table_bytes(self):
        n = max(self.g1() - self.g0(), 0)
        return (n + GRANULE - 1) & ~(GRANULE - 1)

    def byte(self, g):
        return self.table[g - self.g0()]

    def in_table(self, addr):
        return self.tbase != 0 and self.tbase <= addr < self.tbase + self.table_bytes()

    def check(self, addr, write, chk, tbl=False, slot=0):
        line = addr >> self.line_shift << self.line_shift
        if not (self.base <= line < self.limit):
            return APER
        if write and not tbl and self.in_table(line):
            return PROT
        if not chk:
            return OK
        g = line >> GRANULE_SHIFT
        if self.tbase == 0 or not (self.g0() <= g < self.g1()):
            return PROT
        b = self.byte(g)
        own = slot != 0 and (b & OWNER) == slot and not (write and b & RO)
        pub = bool(b & PUB) and not write
        grant = any(e.valid and e.slot == slot and e.base <= g < e.limit and
                    (e.write if write else e.read) for e in self.grants)
        return OK if own or pub or grant else PROT


def selftest():
    errors = 0

    def expect(what, got, want):
        nonlocal errors
        if got != want:
            errors += 1
            print('FAIL protmodel.selftest: %s: %d, expected %d' % (what, got, want))

    # An aperture that is not 4 KiB aligned: G0 is rounded down, G1 up.
    m = Prot(0x00800, 0xF8020, 5)
    expect('g0', m.g0(), 0)
    expect('g1', m.g1(), 0xF9)
    expect('table bytes', m.table_bytes(), 4096)
    expect('no table, chk', m.check(0x5000, False, True, slot=1), PROT)
    expect('no table, chk 0', m.check(0x5000, True, False), OK)
    expect('aperture low', m.check(0x007E0, False, False), APER)
    expect('aperture high', m.check(0xF8020, False, True, slot=1), APER)
    m.tbase = 0xE0000
    m.table[0x05] = 1
    m.table[0x06] = 1 | RO
    m.table[0x07] = PUB
    m.table[0x08] = 2
    expect('own read', m.check(0x5000, False, True, slot=1), OK)
    expect('own write', m.check(0x5FE0, True, True, slot=1), OK)
    expect('other read', m.check(0x5000, False, True, slot=2), PROT)
    expect('ro read', m.check(0x6000, False, True, slot=1), OK)
    expect('ro write', m.check(0x6000, True, True, slot=1), PROT)
    expect('pub read', m.check(0x7000, False, True, slot=3), OK)
    expect('pub write', m.check(0x7000, True, True, slot=3), PROT)
    expect('nobody', m.check(0x9000, False, True, slot=1), PROT)
    expect('slot 0 on free', m.check(0x9000, False, True, slot=0), PROT)
    expect('slot 0 on pub', m.check(0x7000, False, True, slot=0), OK)
    expect('chk 0 other', m.check(0x8000, True, False), OK)
    # Grants: [8, 0x0A) to slot 1 read only; the limit is exclusive.
    m.grants.append(Grant(1, True, False, 0x08, 0x0A))
    expect('grant read', m.check(0x8000, False, True, slot=1), OK)
    expect('grant read end', m.check(0x9FE0, False, True, slot=1), OK)
    expect('grant past limit', m.check(0xA000, False, True, slot=1), PROT)
    expect('grant write', m.check(0x8000, True, True, slot=1), PROT)
    expect('grant other slot', m.check(0x8000, False, True, slot=3), PROT)
    m.grants.append(Grant(1, True, True, 0x08, 0x09))
    expect('second grant write', m.check(0x8000, True, True, slot=1), OK)
    m.grants[1].valid = False
    expect('revoked write', m.check(0x8000, True, True, slot=1), PROT)
    expect('kept read', m.check(0x8000, False, True, slot=1), OK)
    # The table: writes need tbl, chk or not; reads are as any memory.
    expect('table write', m.check(0xE0000, True, False), PROT)
    expect('table write chk', m.check(0xE0FE0, True, True, slot=1), PROT)
    expect('table write tbl', m.check(0xE0000, True, False, tbl=True), OK)
    expect('table end', m.check(0xE1000, True, False), OK)
    expect('table read', m.check(0xE0000, False, False), OK)
    if errors == 0:
        print('PASS protmodel.selftest')
    return errors


# ------------------------------------------------------------- vectors
#
# One scenario for atg_mc_prot_tb (32-byte lines, 1 MiB memory):
#   A base limit                 the aperture (hex)
#   T tbase                      PROT_TABLE (hex); PROT_TABLE_BYTES follows
#   B index value                a table byte that is not 0 (hex)
#   G index slot read write base limit   a grant entry (hex)
#   R client write chk tbl slot addr expect   a request (hex; expect 0 OK,
#                                1 aperture, 2 protection)
#   E                            the end
# The requests of one client keep their order; the TB checks each response
# (an error for a refusal with read data 0, the memory's data else).

NCLIENT = 4


def vectors(path, seed):
    rnd = random.Random(seed)
    m = Prot(0x00800, 0xF8020, 5)
    m.tbase = 0xE0000
    # Granules 0x10..0x4F: owners 1..3, some read-only, some public, some free.
    for g in range(0x10, 0x50):
        k = rnd.randrange(8)
        if k < 5:
            m.table[g - m.g0()] = rnd.randrange(1, 4) | (RO if k == 4 else 0)
        elif k == 5:
            m.table[g - m.g0()] = PUB
    grants = [Grant(1, True, False, 0x20, 0x24), Grant(2, True, True, 0x30, 0x31),
              Grant(2, True, True, 0x30, 0x31), Grant(3, False, True, 0x40, 0x48)]
    m.grants = grants
    out = ['A %x %x' % (m.base, m.limit), 'T %x' % m.tbase]
    for i, b in enumerate(m.table):
        if b:
            out.append('B %x %x' % (i, b))
    for i, e in enumerate(grants):
        out.append('G %x %x %d %d %x %x' % (i, e.slot, e.read, e.write, e.base, e.limit))
    counts = [0, 0, 0]
    for c in range(NCLIENT):
        for _ in range(300):
            k = rnd.randrange(16)
            if k == 0:
                addr = rnd.choice([0x00400, 0xF8020, 0xFC000])
            elif k == 1:
                addr = m.tbase + rnd.randrange(0, 4096, 32)
            else:
                addr = rnd.randrange(0x10000, 0x50000, 32)
            write = rnd.randrange(2) == 1
            chk = c != 0 and rnd.randrange(8) != 0
            tbl = k == 1 and rnd.randrange(4) == 0
            slot = c if chk else 0
            e = m.check(addr, write, chk, tbl, slot)
            counts[e] += 1
            out.append('R %x %d %d %d %x %x %d' % (c, write, chk, tbl, slot, addr, e))
    out.append('E')
    with open(path, 'w') as f:
        f.write('\n'.join(out) + '\n')
    print('protmodel: %s: %d ok, %d aperture, %d protection' % (path, *counts))


def main():
    if '--selftest' in sys.argv:
        sys.exit(1 if selftest() else 0)
    if '--vectors' in sys.argv:
        i = sys.argv.index('--vectors')
        seed = 1
        if '--seed' in sys.argv:
            seed = int(sys.argv[sys.argv.index('--seed') + 1])
        vectors(sys.argv[i + 1], seed)
        return
    print('usage: protmodel.py --selftest | --vectors FILE [--seed N]')


if __name__ == '__main__':
    main()
