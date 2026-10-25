# atg_cp_prot

RTL: `rtl/gpu/cp/atg_cp_prot.v`.  Parent: `atg_top` (instance `g_prot.prot`, with `HAS_PROT` and
`HAS_CPU`, beside `atg_cpu`).  Written for session protection (docs/ghci.md §11.6, 2026-10-25).
The RTL is authoritative.

## 1. Purpose and place

The CP's side of session protection: which protected slot a µop's work belongs to, the switch
of the units from one session to another (drain, invalidate, scrub), the PROT capability's
host registers, and the firmware's window registers for the slots, the MC's PLB invalidation and
the grant CAM.  It sits in `atg_top` and not in `atg_cp` because it needs the firmware (a GPU
without `HAS_CPU` has no protected sessions) and `atg_cp` is at its line budget.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | 32 | |
| `SLOTS` | 31 | PROT_CAPS[7:0] (the firmware's session table less session 0) |
| `GRANTS`, `GIDX_W` | 8, 3 | PROT_CAPS[31:16] and clog2 (the MC's CAM) |
| `REG_OFF` | 0x1D0 | The PROT capability's registers (atg_cp_regs lists it) |

## 3. Ports

Domain `clk`; `rst_n` is the core reset (CTRL.RESET).  In groups: host registers (8: the snoop
bus and the aperture), the window (6: sub-bus and v_tag/v_slot), the µop (7), the units (5), the
MC (8), faults (3).

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `hcr_*` | in, out | | atg_cp_regs' snoop bus: PROT_CAPS (+0x0), PROT_TABLE (+0x4), PROT_TABLE_BYTES (+0x8) |
| `aperture_base`, `aperture_limit` | in | 32 | For PROT_TABLE_BYTES, PROT_G0, PROT_G1 |
| `sb_we`, `sb_idx`, `sb_wdata` / `sb_rdata` | in / out | | atg_cpu's sub-bus (0 outside 0x28-0x33) |
| `v_tag` / `v_slot` | in / out | 8 / 6 | SLOT_MAP of the class V packet's tag (atg_cpu_win latches it when the packet is taken) |
| `u_tag`, `u_fw`, `u_side`, `u_req` / `u_ok` | in / out | 8, 1, 7, 2 / 1 | The sequencer's µop: its tag, from the firmware, the FIFO entry's {SELF, slot}, {uses the SUs, starts a unit}; may it start the unit |
| `f_chk`, `f_slot` | out | 1, 6 | For the fence unit: check the µop's fence/result writes and polls for the slot |
| `drain_ok` | in | 1 | The units idle, no unit request at a leaf, `chk_idle`, `unit_idle` (atg_top) |
| `sw_inv` | out | 1 | One cycle: invalidate all caches and clear the occlusion counter (ORed into the CP's) |
| `scrub` / `scrub_busy` | out / in | 1 | One cycle: the SUs clear their memories; busy until done |
| `prot_unit` | out | 6 | The slot the units run for (their requests' chk and slot) |
| `tbase`, `inv_valid`, `inv_g`, `inv_n` / `inv_pending`, `gw_valid`, `gw_idx`, `gw_data` | out / in | | To `atg_mc_prot` |
| `fault_slot` / `fault_tag`, `unit_tag` | in / out | 6 / 8, 8 | SLOT_TAG of the MC's refused request's slot; of prot_unit |

## 4. Behaviour

- **SLOT_MAP** (256 × 6 bits, tag → slot, valid bits reset by RESET) and **SLOT_TAG** (64 × 8):
  PROT_SLOT (0x28, W: [7:0] tag, [13:8] slot; 0 clears) sets both; tag 0 is ignored (always 0).
  `n_slots` counts the mapped tags.
- **The µop's slot**: a ring µop: SLOT_MAP[u_tag]; a firmware µop: `u_side[5:0]` (the slot of
  the packet the firmware had taken when it wrote the µop; 0 outside a packet).  `f_chk` = a
  firmware µop, not SELF (`u_side[6]`), with a slot ≠ 0.  The ring's CP-executed µops are not
  checked (they are the driver's).
- **The switch**: a µop with `u_req[0]` whose slot ≠ prot_unit (or prot_unit unknown after a
  reset or a close) gets `u_ok` = 0 and starts DRAIN → (drain_ok) INV (`sw_inv`) → SCRUB when the
  new slot ≠ 0 and resid is neither none nor that slot (`scrub`, then 2 cycles and !scrub_busy)
  → prot_unit = slot.  Then `u_ok` = 1.
- **resid** (the owner of the SUs' memories): none / slot / mixed; reset: mixed.  A µop with
  `u_req[1]` while `u_ok` adds prot_unit (none → that slot, another slot → mixed).  The scrub
  makes it none.  Clearing slot s: resid s → mixed; prot_unit s → 0 and unknown.
- **PROT_TABLE**: written (4 KiB aligned) only while `n_slots` = 0; a write of APERTURE_BASE or
  APERTURE_LIMIT or the reset sets it to 0.  PROT_TABLE_BYTES = ceil((G1 − G0) / 4096) × 4096,
  G0 = base >> 12, G1 = ceil(limit / 4096).
- **The window** (sub-bus): 0x29 PROT_INV_G, 0x33 PROT_INV_N (W: starts the invalidation of
  [G, G + N) granules, N 0: all), 0x2A GIDX, 0x2B GBASE (granule), 0x2C GLIMIT (granule,
  exclusive, 21 bits), 0x2D GCTL (W: [0] valid, [1] read, [2] write, [13:8] slot; writes the CAM
  entry GIDX), 0x2E PROT_INFO (R: [0] 1, [1] a table, [2] drained (`drain_ok`), [3] the MC's
  inv_pending, [13:8] SLOTS, [31:16] GRANTS), 0x2F PROT_TBASE, 0x30 PROT_G0, 0x31 PROT_G1.  0x32 UOP_SELF is
  atg_cpu_win's.

## 5. State machine

IDLE → (a unit µop of another slot) DRAIN → (drain_ok) INV → SCRUB → SWAIT → IDLE, or INV → IDLE
without the scrub.  The slot clear updates resid and prot_unit in any state.

## 6. Latency and throughput

A switch: the drain (the earlier work), one cycle of INV, and the scrub (the SUs' memories: about
6.2 k cycles on the KC705, estimate, R4).  The same slot again: no cycle.

## 7. Corner cases and errors

- After a reset the first unit µop (even of slot 0) switches (prot_unit unknown); the first
  protected one scrubs (resid mixed).
- A host KICK does not go through the switch (it is taken in IDLE and HALTED only; the units run
  for prot_unit, which is 0 after a reset).  Not done: the watchdog's tag during DRAIN.

## 8. What the TB checks

`sim/tb/atg_cp_prot_tb.v`: groups regs, slots, uslot, switch, close, mc; mutations
`MUT_CPPROT_CLOSEKEEP`, `MUT_CPPROT_NODRAIN`, `MUT_CPPROT_NOSCRUB`, `MUT_CPPROT_NOINV`,
`MUT_CPPROT_RESID0`, `MUT_CPPROT_FCHK` fail it.  The packet's slot and the FIFO's side:
`atg_cpu_win_tb` (side); DMA_GO[17]/[18]: `atg_cpu_dma_tb` (`MUT_CPPROT_DMACHK`); the
sequencer's u_req/u_ok: `atg_cp_seq_tb` (prot); the fence unit's side band: `atg_cp_fence_tb`.

## 9. References

docs/ghci.md §11.6; `spec/gpu/mc/atg_mc_prot.md`, `spec/gpu/cp/atg_cpu_win.md`,
`spec/gpu/cp/atg_cpu_dma.md`, `spec/gpu/cp/atg_cp_seq.md`.

## 10. Status

Implemented (session protection, R3).  The SUs' scrub (R4) is not connected yet (scrub_busy 0).
