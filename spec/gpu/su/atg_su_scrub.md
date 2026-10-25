# atg_su_scrub

RTL: `rtl/gpu/su/atg_su_scrub.v`.  Parents: `atg_su_rf`, `atg_su_lds`, `atg_su_lda`, `atg_su_pt`,
`atg_su_cbank`, `atg_su_exp` (instance `sc` in each).  Written for session protection
(docs/ghci.md §11.6, 2026-10-25).

## 1. Purpose and place

The address counter of a memory's scrub: when the CP switches the units to another protected
session (atg_cp_prot), the shader unit writes 0 to every word that a warp could read without
having written it (registers, shared memory, varyings, constants, colour outputs).  Each memory
writes the zeros through its own write port (a mux in front of it; no added port, the RAMs'
declarations and reads unchanged).

## 2. Parameters

`DEPTH` (16), `AW` (clog2(DEPTH), at least 1).

## 3. Ports

Domain `clk`.  5 ports: `clk`, `rst_n`, `start` (one cycle), `on` (the memory writes 0 at `a`),
`a`.

## 4. Behaviour

`start` sets `on` for DEPTH cycles with a = 0 … DEPTH − 1; a start while on begins again.  The
memory's write has priority while `on` (the unit is idle: atg_cp_prot drains it first).  Each
memory's `scrub_busy` is its `on`; `atg_su`'s is the OR.

## 5. State machine

idle → (start) on → (a = DEPTH − 1) idle.

## 6. Latency and throughput

DEPTH cycles.  The SU: the longest memory (default NPHYS 8: the primitive table, 1536 words; the
KC705: the primitive table, 6144 words ≈ 61 µs at 100 MHz, estimate).  The memories run at once.

## 7. Corner cases and errors

rst_n stops it.  A memory with several copies or banks writes them all at once.

## 8. What the TB checks

`sim/tb/atg_su_scrub_tb.v`: atg_su (NPHYS 8) with every scrubbed memory filled with non-zero
words; after the scrub every word is 0 and `scrub_busy` lasted the longest memory's depth.

## 9. References

`spec/gpu/cp/atg_cp_prot.md`; the parents' specs.

## 10. Status

Implemented (session protection, R4).  Not done: the written-memory marks (atg_cp_prot counts
the µops that use the shader units instead), a wider write for the primitive table.
