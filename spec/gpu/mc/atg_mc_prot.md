# atg_mc_prot

RTL: `rtl/gpu/mc/atg_mc_prot.v`.  Parent: `atg_mc` (instance `grant`).  Child: `atg_mc_grant`
(the grant CAM), `atg_mc_aper` (two).  Written for session protection (docs/ghci.md §11.6,
2026-10-25).  The RTL is authoritative.

## 1. Purpose and place

The root's grant: it takes the complete requests of the root's assembly buffers (the tree's, A,
and with `HAS_DC` the display controller's own entry, D), and each cycle gives one to the AXI
master or refuses one.  Without `HAS_PROT` it only checks the aperture and the VRAM window (the
grant that was in `atg_mc` before).  With `HAS_PROT` it also checks the requests that carry chk
against the **protection table** (one byte per 4 KiB granule of the aperture, in memory the
driver lends at `tbase`) and the grant CAM, and keeps writes without tbl out of the table.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `HAS_PROT` | 0 | Session protection | 0, 1 |
| `HAS_DC` | 0 | The D entry (atg_mc: `HAS_PROT` and a `ROOT_CLIENT`) | 0, 1 |
| `NCLIENT`, `RMW_MASK` | 2, 0 | Clients; those whose reads are judged as writes (the atomic unit) | |
| `ADDR_W`, `LINE_BYTES`, `LINE_SHIFT`, `VRAM_AW`, `VRAM_BASE`, `RW` | | As atg_mc | ADDR_W 32 |
| `PLB`, `PLB_W` | 4, 2 | PLB lines and clog2 | KC705 16, 4 |
| `NGRANT`, `GIDX_W` | 8, 3 | Grant CAM entries and clog2 | KC705 64, 6 |

## 3. Ports

Domain `clk`.  39 ports; in groups (U38): clock (3), A (4), D (4), aperture (2), the AXI request
(7), refusal and done (8), the walk's response (3), the CP's protection registers (5), the CAM's
write port (3).

| Name | Dir | Width | Meaning, handshake, timing |
| --- | --- | --- | --- |
| `clk`, `rst_n`, `flush` | in | 1 | flush (the CP's RESET) empties J, P, the PLB and the CAM |
| `a_valid`, `a_head`, `a_data` / `a_take` | in / out | 1, line, line / 1 | The tree's complete request (header and write data flits, held); `a_take` when it is granted, refused or moved to J |
| `d_valid`, `d_head`, `d_data` / `d_take` | in / out | as A | The DC's request (HAS_DC; else tie 0) |
| `aperture_base`, `aperture_limit` | in | `ADDR_W` | The aperture; G0 = base >> 12, G1 = ceil(limit / 4096) |
| `g_valid` / `g_ready`, `g_write`, `g_line`, `g_be`, `g_wdata`, `g_user` | out / in, out | | To `am_axi_master` (user = {route, client, tag}; a walk: client 0xFF) |
| `err_busy` | in | 1 | atg_mc's `err_v`: nothing is granted or refused while a refusal's response waits |
| `bad`, `bad_head`, `bad_line`, `bad_prot`, `bad_mem` | out | 1, header, line, 1, 1 | One cycle: a request is refused; protection (FAULT_INFO[9]) or a table read's AXI error (kind 5), else aperture |
| `done`, `done_chk` | out | 1 | A request left the root (granted or refused, not a walk); it had chk |
| `w_valid`, `w_error`, `w_rdata` | in | 1, 1, line | The walk's response (the AXI master's response with client 0xFF) |
| `tbase` | in | `ADDR_W` | PROT_TABLE (0: none) |
| `inv_valid`, `inv_g`, `inv_n` / `inv_pending` | in / out | 1, 20, 32 / 1 | One cycle: invalidate the PLB lines that overlap the granules [inv_g, inv_g + inv_n) (inv_n 0: all) |
| `gw_valid`, `gw_idx`, `gw_data` | in | 1, `GIDX_W`, 50 | One cycle: write a CAM entry (`atg_mc_grant`) |

## 4. Behaviour

- **Header** (spec/common/am_amb_to_rt.md): [1] write, [2] outside the window, [3] chk, [11:4] tag,
  [19:12] client, route, line, byte enables, then tbl and the 6-bit slot.
- **A and D**: refused at once when outside the aperture or the window (aperture fault), or when
  a write into [tbase, tbase + table bytes) without tbl while tbase ≠ 0 (protection; with or
  without chk).  A request without chk (or without `HAS_PROT`) is granted from A or D directly.
  D is never checked for protection (the scanout belongs to the driver).
- **J (the judge stage)**: a request with chk moves from A to J when J is empty or leaves in the
  same cycle (throughput one per cycle).  The judgement of J (or of P, below) is combinational:
  g = line >> (12 − LINE_SHIFT); refused when tbase = 0 or g ∉ [G0, G1); the PLB is looked up at
  the table index g − G0 (tag = index >> LINE_SHIFT, byte = its low bits) and the CAM at the same
  time.  With the slot s and w (a write, or a read of `RMW_MASK`'s client): own = s ≠ 0 and
  byte[5:0] = s and not (w and byte[6]); public = byte[7] and not w; grant = the CAM.  Allowed
  when grant, or a PLB hit with own or public; refused when a PLB hit allows nothing; else a miss.
- **P (the park)**: J's miss moves to P when P is empty.  P reads the table's line
  (tbase + (g − G0) aligned to the line) through the AXI master (the walk, client 0xFF in the
  user bits; atg_mc gives its response to `w_*` and not to the tree), fills the PLB (round-robin)
  and is judged again; a walk's AXI error refuses P with `bad_mem`.  While P waits, J and A go on
  with the requests of other clients.
- **Order per client**: a request in A waits while J or P holds a request of the same client; J
  waits while P holds one of its client.  So every client's requests leave the root in the order
  they arrived, with and without chk.
- **Changes**: in a cycle with a fill, `inv_valid` or `gw_valid` no judgement is used; J and P
  are judged again in the next cycle.
- **Invalidation**: the PLB lines that overlap the granule range are dropped.  If the range
  overlaps the line of a walk in flight (or its response arrives in that cycle), that line is
  not filled; P misses again and walks again.  `inv_pending` is 1 from such an invalidation until
  a walk's line is filled or P leaves.  The firmware waits for `inv_pending` = 0 before its next
  invalidation.  (A further overlapping invalidation is still taken and makes the walk stale
  again: correct, and the firmware's wait keeps it from repeating.)
- **Priorities**: the AXI request goes to D, then the walk, then J or P, then A; a refusal (only
  in a cycle without an AXI grant) to D, then J or P, then A.
- **The table's bytes**: one per granule of [G0, G1), rounded up to 4 KiB (PROT_TABLE_BYTES).

## 5. State machine

J: empty / full.  P: empty → (J's miss) parked → (walk granted) walking → (response) parked →
(granted or refused) empty; `p_stale` and `inv_pending` as above.  PLB: `PLB` lines {valid, tag,
line}, a round-robin pointer.

## 6. Latency and throughput

- Without chk: as before (granted from A in the cycle it is complete).
- With chk, a PLB or CAM hit: one cycle more (J), one request per cycle.
- A miss: the walk's read (40–80 cycles of DDR3 at the KC705's 100 MHz gclk, estimate) and one
  cycle for the fill and the judgement.  A further request of the same client, or another miss,
  waits in A and stops the tree; D does not wait for it (it has its own entry).

## 7. Corner cases and errors

- tbase = 0 with chk: refused.  Slot 0 with chk: only public reads.
- The CAM's grant counts without a PLB hit (no walk is needed).
- A refused read's data is 0 (atg_mc).
- The DC's writes (none) are not checked against the table.

## 8. What the TB checks

`sim/tb/atg_mc_prot_tb.v` (sim/vec/prot.txt from `tools/protmodel.py --vectors`): groups vec,
order, park, dc, mem, inv, race, recheck, walkerr (see the TB's header), and the mutations
`MUT_PROT_NOCHK`, `MUT_PROT_STALE`, `MUT_PROT_RO`, `MUT_PROT_DATA`, `MUT_PROT_RECHECK`,
`MUT_PROT_LIMIT`, `MUT_PROT_TBL` (each must fail it).  `sim/tb/atg_mc_tb.v` shape C: `HAS_PROT`
built in, no chk: the same behaviour as shape B.

## 9. References

docs/ghci.md §11.6; `spec/gpu/mc/atg_mc.md`, `spec/gpu/mc/atg_mc_grant.md`,
`spec/common/am_amb_to_rt.md`; `tools/protmodel.py`.

## 10. Status

Implemented (session protection, R2).  Not measured: the 1-cycle judgement at the gclk (the PLB
compare, the byte select and the CAM in one cycle; a synthesis run is pending), the cells.
