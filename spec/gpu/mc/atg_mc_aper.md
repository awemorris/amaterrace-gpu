# atg_mc_aper

RTL: `rtl/gpu/mc/atg_mc_aper.v`.  Parent: atg_mc.  Implemented in: p015 (split of atg_mc).

## 1. Purpose and place

The aperture check of an AMB request: the line is inside [APERTURE_BASE, APERTURE_LIMIT) (line granularity).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | Address width. |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |

## 3. Ports

Clock/reset domain: none (combinational) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `line` | in | ADDR_W-LINE_SHIFT | Line address. |
| `base` | in | ADDR_W | APERTURE_BASE. |
| `limit` | in | ADDR_W | APERTURE_LIMIT (exclusive). |
| `ok` | out | 1 | base ≤ line < limit (low bits ignored). |

4 ports.

## 4. Behaviour

ok = line >= base[ADDR_W-1:LINE_SHIFT] && line < limit[ADDR_W-1:LINE_SHIFT].  A future MMU (design §4.1) replaces this module.

## 5. State machine

None.

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_mc_aper_tb.v` prints, in this order:

- `PASS atg_mc_aper.bounds` — edges of the range
- `PASS atg_mc_aper` at the end.

## 9. References

design §4.1, §2.2 (APERTURE_*).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
