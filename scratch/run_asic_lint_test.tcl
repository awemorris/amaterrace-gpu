set top "atg_cp"
set clk_period 4.000
set part xc7k325tffg900-2
set root [file normalize [file join [file dirname [info script]] ".."]]
set incdirs [list [file join $root include]]

set v_files [glob -nocomplain [file join $root rtl library * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl library *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu cp *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu fmt *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu atg_cp.v]]

set unique_files [lsort -unique $v_files]
foreach f $unique_files {
    read_verilog $f
}

set vdefs [list "SYNTH_KINTEX7"]
synth_design -top $top -part $part -mode out_of_context -include_dirs $incdirs -verilog_define $vdefs

create_clock -period $clk_period -name clk [get_ports clk]

# Check Timing
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "=== TIMING SLACK: $wns ns ==="

# Check Rule 1 count
set top_paths [get_timing_paths -max_paths 100 -nworst 1 -setup]
set r1_errors 0
foreach p $top_paths {
    set cells [get_cells -of_objects $p]
    set lut_cnt 0
    set carry_cnt 0
    set dsp_cnt 0
    set pre_carry_lut 0
    set post_carry_lut 0
    set post_dsp_lut 0
    set seen_carry 0
    set seen_dsp 0
    foreach c $cells {
        set ref [get_property REF_NAME $c]
        if {[string match "LUT*" $ref]} {
            incr lut_cnt
            if {!$seen_carry} { incr pre_carry_lut } else { incr post_carry_lut }
            if {$seen_dsp} { incr post_dsp_lut }
        } elseif {[string match "CARRY*" $ref]} {
            incr carry_cnt
            set seen_carry 1
        } elseif {[string match "DSP*" $ref]} {
            incr dsp_cnt
            set seen_dsp 1
        }
    }
    if {$carry_cnt == 0 && $dsp_cnt == 0} {
        if {$lut_cnt > 4} { incr r1_errors }
    }
    if {$carry_cnt > 0} {
        if {$pre_carry_lut > 1 || $post_carry_lut > 1} { incr r1_errors }
    }
}
puts "=== RULE 1 ERRORS: $r1_errors ==="

# Check Rule 2 count
set internal_nets [get_nets -hierarchical -top_net_of_hierarchical_group -filter {
    TYPE != "GLOBAL_CLOCK" && TYPE != "LOCAL_CLOCK" && TYPE != "GROUND" && TYPE != "POWER" &&
    NAME !~ "*clk*" && NAME !~ "*rst*" && NAME !~ "*reset*" &&
    NAME !~ "*<const*" && NAME !~ "*GND*" && NAME !~ "*VCC*" && NAME !~ "*GLOBAL_LOGIC*"
}]
set r2_errors 0
foreach n $internal_nets {
    set pin_cnt [get_property FLAT_PIN_COUNT $n]
    set fo [expr {$pin_cnt - 1}]
    if {$fo > 24} {
        incr r2_errors
    }
}
puts "=== RULE 2 HARD ERRORS: $r2_errors ==="

# Check Rule 3 count
set in_ports [get_ports -filter {DIRECTION == "IN" && NAME !~ "*clk*" && NAME !~ "*rst*" && NAME !~ "*reset*"}]
set out_ports [get_ports -filter {DIRECTION == "OUT"}]
set r3_errors 0
if {[llength $in_ports] > 0 && [llength $out_ports] > 0} {
    set feedthrough_paths [get_timing_paths -from $in_ports -to $out_ports -max_paths 50]
    set r3_errors [llength $feedthrough_paths]
}
puts "=== RULE 3 FEEDTHROUGH ERRORS: $r3_errors ==="

# Check Rule 4 count
set r4_errors 0
set mem_cells [get_cells -hierarchical -filter {
    REF_NAME =~ "RAMB*" || REF_NAME =~ "RAM32*" || REF_NAME =~ "RAM64*" || REF_NAME =~ "RAM128*"
}]
foreach m $mem_cells {
    set addr_pins [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*ADDR*"}]
    if {[llength $addr_pins] > 0} {
        set a_paths [get_timing_paths -to $addr_pins -max_paths 10]
        foreach ap $a_paths {
            set lev [get_property LOGIC_LEVELS $ap]
            if {$lev > 0} { incr r4_errors }
        }
    }
    set dout_pins [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*DO*" || REF_PIN_NAME =~ "*DOUT*"}]
    if {[llength $dout_pins] > 0} {
        set d_paths [get_timing_paths -from $dout_pins -max_paths 10]
        foreach dp $d_paths {
            set lev [get_property LOGIC_LEVELS $dp]
            if {$lev > 0} { incr r4_errors }
        }
    }
}
puts "=== RULE 4 MEM ERRORS: $r4_errors ==="
