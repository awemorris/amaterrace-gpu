set top test_fadd_full
set clk_period 4.000
set root [pwd]
set part xc7k325tffg900-2
set incdirs [list [file join $root include]]

read_verilog [glob rtl/library/arith/*.v]
read_verilog scratch/test_fadd_full.v
synth_design -top $top -part $part -mode out_of_context -include_dirs $incdirs -verilog_define SYNTH_KINTEX7
create_clock -period $clk_period -name clk [get_ports clk]

# Top 50 paths
set top_paths [get_timing_paths -max_paths 50 -nworst 1 -setup]
set r1_errors 0
foreach p $top_paths {
    set p_slack [get_property SLACK $p]
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN $p]
    set cells [get_cells -of_objects $p]
    set lut_cnt 0
    set carry_cnt 0
    set pre_carry_lut 0
    set post_carry_lut 0
    set seen_carry 0
    foreach c $cells {
        set ref [get_property REF_NAME $c]
        if {[string match "LUT*" $ref]} {
            incr lut_cnt
            if {!$seen_carry} { incr pre_carry_lut } else { incr post_carry_lut }
        } elseif {[string match "CARRY*" $ref]} {
            incr carry_cnt
            set seen_carry 1
        }
    }
    if {$carry_cnt == 0 && $lut_cnt > 4} {
        puts "RANDOM VIOLATION: $sp --> $ep | LUTs: $lut_cnt | Slack: $p_slack"
        incr r1_errors
    }
    if {$carry_cnt > 0 && ($pre_carry_lut > 1 || $post_carry_lut > 1)} {
        puts "CARRY VIOLATION: $sp --> $ep | CARRY: $carry_cnt | Pre: $pre_carry_lut | Post: $post_carry_lut | Slack: $p_slack"
        incr r1_errors
    }
}
puts "TOTAL R1 ERRORS IN TOP 50: $r1_errors"
