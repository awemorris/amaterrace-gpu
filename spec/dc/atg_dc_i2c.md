# atg_dc_i2c

RTL: `rtl/dc/atg_dc_i2c.v`.  Parent: atg_dc.  Implemented in: p012.

## 1. Purpose and place

A small I2C master for the KC705's ADV7511 HDMI transmitter configuration (I2C_CTRL/DATA/STATUS of design §5.1).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `CLK_DIV` | `250` | gclk cycles per quarter SCL period (100 MHz → 100 kHz). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `i_we` | in | 1 | Register write. |
| `i_idx` | in | 2 | Register. |
| `i_wdata` | in | 32 | Data. |
| `i_rdata` | out | 32 | Read data of i_idx (combinational). |
| `scl_t` | out | 1 | 1: release SCL (pull-up), 0: drive low. |
| `scl_i` | in | 1 | SCL level (clock stretching). |
| `sda_t` | out | 1 | 1: release SDA, 0: drive low. |
| `sda_i` | in | 1 | SDA level. |

10 ports.

## 4. Behaviour

CTRL: [0] START, [1] STOP, [2] WRITE byte, [3] READ byte, [4] ACK on read; DATA [7:0]; STATUS [0] busy, [1] NACK.  One byte operation per command.

## 5. State machine

IDLE → START → BIT×8 → ACK → (STOP) → IDLE.

## 6. Latency and throughput

100 kHz.

## 7. Corner cases and errors

- Unconnected I2C (ZYBO): HAS_I2C 0 in atg_dc ties this off.

## 8. What the TB checks

`sim/tb/atg_dc_i2c_tb.v` prints, in this order:

- `PASS atg_dc_i2c.write` — a write transaction against an I2C slave model
- `PASS atg_dc_i2c.read` — a read with ACK/NACK
- `PASS atg_dc_i2c` at the end.

## 9. References

design §5.1, Values referenced: UG810 (ADV7511 address and mux, unread: design U7).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
