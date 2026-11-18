# atg_mc_grant

RTL: `rtl/gpu/mc/atg_mc_grant.v`.  Parent: `atg_mc_prot` (instance `cam`).  Written for session
protection (docs/ghci.md §11.6, 2026-10-25).

## 1. Purpose and place

The grant CAM: the ranges of memory that the driver's BUFFER_GRANT gives a protected session
beyond what it owns.  The firmware writes the entries; `atg_mc_prot` looks the request up in all
of them at once.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NGRANT` | 8 | Entries (PROT_CAPS[31:16]; KC705 64) |
| `IDX_W` | 3 | clog2(`NGRANT`) |

## 3. Ports

Domain `clk`.  10 ports.

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst_n`, `flush` | in | 1 | Reset and flush make every entry invalid |
| `w_valid`, `w_idx`, `w_data` | in | 1, `IDX_W`, 50 | One cycle: entry `w_idx` = `w_data` {limit[20:0], base[19:0], write, read, slot[5:0], valid} |
| `slot`, `g`, `write` | in | 6, 20, 1 | The request's slot, granule (address >> 12) and direction |
| `hit` | out | 1 | Combinational: a valid entry with that slot, base ≤ g < limit and the permission |

## 4. Behaviour

An entry is {valid, slot, read, write, base, limit} with granules [base, limit) (limit has 21
bits so that 2^20 can be the end).  Slot 0 never hits.  Two entries with the same range are two
grants; the firmware's REVOKE removes one.

## 5. State machine

None.

## 6. Latency and throughput

Lookup combinational (inside `atg_mc_prot`'s one-cycle judgement); a write takes effect at the
next clock edge.

## 7. Corner cases and errors

The firmware keeps the entries' count per session (PROT_GRANTS / 4) and their place; the CAM
does not check overlaps.

## 8. What the TB checks

Through `sim/tb/atg_mc_prot_tb.v` (vec: reads by grant, the limit and one past it, a write on a
read-only grant, two equal entries, an entry removed while a request is judged); `MUT_PROT_LIMIT`
(limit taken as inclusive) must fail it.

## 9. References

docs/ghci.md §11.6; `spec/gpu/mc/atg_mc_prot.md`.

## 10. Status

Implemented (session protection, R2).  About 90 lines.
