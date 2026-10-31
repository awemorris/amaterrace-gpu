`timescale 1ns / 1ps
module test_cmp (
    input wire clk,
    input wire [5:0] a,
    input wire [5:0] b,
    input wire is_small,
    output reg q
);
    wire le_lo = (a[2:0] <= b[2:0]);
    wire lt_hi = (a[5:3] < b[5:3]);
    wire eq_hi = (a[5:3] == b[5:3]);

    wire last = is_small && (lt_hi || (eq_hi && le_lo));

    always @(posedge clk) begin
        q <= last;
    end
endmodule
