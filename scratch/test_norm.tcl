set top test_norm
set part xc7k325tffg900-2
read_verilog scratch/test_norm.v
synth_design -top $top -part $part -mode out_of_context
create_clock -period 4.000 -name clk [get_ports clk]

set top_paths [get_timing_paths -max_paths 10 -nworst 1 -setup]
foreach p $top_paths {
    set p_slack [get_property SLACK $p]
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN $p]
    set cells [get_cells -of_objects $p]
    set lut_cnt 0
    foreach c $cells {
        set ref [get_property REF_NAME $c]
        if {[string match "LUT*" $ref]} { incr lut_cnt }
    }
    puts "PATH: $sp --> $ep | LUTs: $lut_cnt | Slack: $p_slack"
}
