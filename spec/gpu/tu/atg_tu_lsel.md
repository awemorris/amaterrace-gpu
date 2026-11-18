# atg_tu_lsel

RTL: `rtl/gpu/tu/atg_tu_lsel.v`.  Parent: atg_tu_addr (stage A of each lane).

## 1. Purpose and place

A lane's λ and the level it reads, moved out of atg_tu_addr (whose source would otherwise pass 400 lines) when its arithmetic became am_ modules.  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`op` (2), `qlod`, `unn`, `gather`, `ms`, `filt`, `miplin`, `mag_lin`, `min_lin`, `pas1`, `cw0` (32), `cw2` (32), `lam_q` (17), `sbias` (17), `minlod` (17), `maxlod` (17), `maxl` (4) / `lvl` (4), `lin`, `fl` (8), `lamp` (17), `dq` (16): 22 ports.

## 4. Behaviour

As atg_tu_addr's header: λ' = texl rs2, texb the quad's λ + rs2 (the query: the quad's), + mipLodBias, saturated (am_add, tu_sat16); λ = clamp(λ', minLod, maxLod), 0 unnormalized; the level: texsz rs1 (≤ 15), texf rs2 clamped (0 multisampled), gather and magnification 0, mip linear λ >> 8 (+ 1 for the second level) with the weight λ & 255, else (λ + 127) >> 8 (am_add), clamped to the last level; the query's level clamp(λ, 0, LEVELS − 1); linear filtering by the sampler's MAG/MIN filter.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

sim/tb/atg_tu_addr_tb.v, sim/tb/atg_tu_tb.v; atg_tu_addr's former and new versions on 100,000 random cycles (2026-10-25).

## 9. References

`spec/gpu/tu/atg_tu_addr.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
