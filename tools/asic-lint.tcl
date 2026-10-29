# asic-lint.tcl: Automated Linter for ASIC 5nm 1.5 GHz High-Frequency Design Rules
#
# Rules checked (docs/style.md: High-Frequency ASIC Scaling):
#   Rule 1: Primitive & Logic Level Budget (Random logic <= 4 LUTs; Adder/Sub <= 1 LUT pre/post; Multiplier LAT >= 2, <= 1 LUT post)
#   Rule 2: Fanout Limitation & Tree Buffering (Max fanout <= 16, hard error > 24)
#   Rule 3: Flop-to-Flop Boundary Rule (Zero combinational feed-through between ports)
#   Rule 4: Clean Single-Cycle Memory Pipeline (Zero combinational logic on RAM ADDR and DOUT)
#   Rule 5: Backpressure Decoupling (Zero combinational ripple on ready/valid handshakes)

if {[info exists ::env(VIVADO_THREADS)]} {
    set_param general.maxThreads $::env(VIVADO_THREADS)
} elseif {[info exists ::env(VIVADO_MAX_THREADS)]} {
    set_param general.maxThreads $::env(VIVADO_MAX_THREADS)
} else {
    set_param general.maxThreads 2
}

if {$argc < 1} {
    puts "Usage: vivado -mode batch -source asic-lint.tcl -tclargs <top_module> ?clock_period_ns? ?extra_defines? ?out_dir?"
    exit 1
}

set top [lindex $argv 0]
set clk_period 4.000
if {$argc >= 2 && [lindex $argv 1] != ""} {
    set clk_period [lindex $argv 1]
}
set extra_defines ""
if {$argc >= 3} {
    set extra_defines [lindex $argv 2]
}

set root [file normalize [file join [file dirname [info script]] ".."]]
set out_name $top
if {$extra_defines != ""} {
    set clean_def [regsub -all {[^a-zA-Z0-9_]} $extra_defines "_"]
    set out_name "${top}_${clean_def}"
}

set out [file join $root "build" "asic_lint" $out_name]
if {$argc >= 4 && [lindex $argv 3] != ""} {
    set out [lindex $argv 3]
}
file mkdir $out

set rpt_file [file join $out "asic_lint.rpt"]
set rpt [open $rpt_file "w"]

proc rpt_puts {str} {
    global rpt
    puts $str
    puts $rpt $str
}

rpt_puts "================================================================================"
rpt_puts "  ASIC 5nm 1.5 GHz High-Frequency Architecture Linter"
rpt_puts "  Target Module: $top"
rpt_puts "  FPGA Surrogate Target: Kintex-7 -2 @ ${clk_period} ns (250 MHz)"
rpt_puts "  Report file: $rpt_file"
rpt_puts "================================================================================"

# If design is not already synthesized/opened, synthesize it now OOC
if {[get_designs -quiet] == ""} {
    set part xc7k325tffg900-2
    set incdirs [list [file join $root include]]

    # Collect verilog files
    set v_files [glob -nocomplain [file join $root rtl library * *.v]]
    lappend v_files {*}[glob -nocomplain [file join $root rtl library *.v]]
    lappend v_files {*}[glob -nocomplain [file join $root rtl gpu * *.v]]
    lappend v_files {*}[glob -nocomplain [file join $root rtl gpu *.v]]
    lappend v_files {*}[glob -nocomplain [file join $root rtl bsp * *.v]]
    lappend v_files {*}[glob -nocomplain [file join $root rtl bsp *.v]]
    lappend v_files {*}[glob -nocomplain [file join $root rtl *.v]]

    set unique_files [lsort -unique $v_files]
    foreach f $unique_files {
        read_verilog $f
    }

    set vdefs [list "SYNTH_KINTEX7"]
    set generics [list]
    if {$extra_defines != ""} {
        foreach d [split $extra_defines " "] {
            if {$d != ""} {
                lappend vdefs $d
                if {[string match "*=*" $d]} {
                    lappend generics "-generic" $d
                }
            }
        }
    }

    rpt_puts "==> Synthesizing OOC design for $top..."
    if {[llength $generics] > 0} {
        synth_design -top $top -part $part -mode out_of_context -include_dirs $incdirs -verilog_define $vdefs {*}$generics
    } else {
        synth_design -top $top -part $part -mode out_of_context -include_dirs $incdirs -verilog_define $vdefs
    }
}

# Clock definition for timing analysis
if {[get_clocks -quiet clk] == ""} {
    if {[get_ports -quiet clk] != ""} {
        create_clock -period $clk_period -name clk [get_ports clk]
    }
}

set num_errors 0
set num_warnings 0

# -----------------------------------------------------------------------------
# Check Timing Closure (WNS)
# -----------------------------------------------------------------------------
set timing_paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
set wns 0.000
if {[llength $timing_paths] > 0} {
    set wns [get_property SLACK [lindex $timing_paths 0]]
}
rpt_puts "\n\[TIMING SUMMARY\]"
rpt_puts "  Clock period: ${clk_period} ns"
rpt_puts "  WNS: ${wns} ns"
if {$wns < 0.000} {
    rpt_puts "  Status: TIMING VIOLATED (Slack < 0.000 ns)"
    incr num_errors
} else {
    rpt_puts "  Status: TIMING MET"
}

# -----------------------------------------------------------------------------
# RULE 1: Primitive & Logic Level Budget
# -----------------------------------------------------------------------------
rpt_puts "\n--------------------------------------------------------------------------------"
rpt_puts "\[RULE 1\] Primitive & Logic Level Budget"
rpt_puts "  Constraints:"
rpt_puts "    - Pure random logic: <= 4 LUT6 levels (target <= 3)"
rpt_puts "    - 32-bit Adder/Subtractor: <= 1 LUT before CARRY4, <= 1 LUT after CARRY4"
rpt_puts "    - Multiplier: LAT >= 2, <= 1 LUT after DSP output"
rpt_puts "--------------------------------------------------------------------------------"

set r1_errors 0
set r1_warnings 0

# Analyze top 100 paths
set top_paths [get_timing_paths -max_paths 100 -nworst 1 -setup]
foreach p $top_paths {
    set p_slack [get_property SLACK $p]
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN $p]
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
            if {!$seen_carry} {
                incr pre_carry_lut
            } else {
                incr post_carry_lut
            }
            if {$seen_dsp} {
                incr post_dsp_lut
            }
        } elseif {[string match "CARRY*" $ref]} {
            incr carry_cnt
            set seen_carry 1
        } elseif {[string match "DSP*" $ref]} {
            incr dsp_cnt
            set seen_dsp 1
        }
    }

    # Evaluate pure random logic path
    if {$carry_cnt == 0 && $dsp_cnt == 0} {
        if {$lut_cnt > 4} {
            rpt_puts "  VIOLATION (Random Logic): $lut_cnt LUTs (> 4 max allowed)"
            rpt_puts "    Path: $sp --> $ep (Slack: ${p_slack} ns)"
            incr r1_errors
        } elseif {$lut_cnt == 4} {
            rpt_puts "  WARNING (Random Logic): 4 LUT levels (target is <= 3)"
            rpt_puts "    Path: $sp --> $ep (Slack: ${p_slack} ns)"
            incr r1_warnings
        }
    }

    # Evaluate carry chain arithmetic path
    if {$carry_cnt > 0} {
        if {$pre_carry_lut > 1 || $post_carry_lut > 1} {
            rpt_puts "  VIOLATION (Adder/Sub Path): Pre-LUTs: $pre_carry_lut (>1) or Post-LUTs: $post_carry_lut (>1)"
            rpt_puts "    CARRY4 count: $carry_cnt | Path: $sp --> $ep (Slack: ${p_slack} ns)"
            incr r1_errors
        }
    }

    # Evaluate multiplier path
    if {$dsp_cnt > 0} {
        if {$post_dsp_lut > 1} {
            rpt_puts "  VIOLATION (Multiplier Path): Post-DSP LUTs: $post_dsp_lut (> 1 max allowed)"
            rpt_puts "    Path: $sp --> $ep (Slack: ${p_slack} ns)"
            incr r1_errors
        }
    }
}

# Check DSP internal pipeline registers (LAT >= 2)
set dsps [get_cells -hierarchical -filter {REF_NAME =~ "DSP48E1*"}]
foreach d $dsps {
    set mreg [get_property MREG $d]
    set preg [get_property PREG $d]
    if {$mreg == 0 || $preg == 0} {
        rpt_puts "  VIOLATION (DSP Internal Latency): $d has MREG=$mreg, PREG=$preg (requires LAT >= 2)"
        incr r1_errors
    }
}

if {$r1_errors == 0} {
    rpt_puts "  \[PASS\] Rule 1 Check Succeeded (0 violations, $r1_warnings warnings)."
} else {
    rpt_puts "  \[FAIL\] Rule 1 Check Failed with $r1_errors violation(s)."
    set num_errors [expr {$num_errors + $r1_errors}]
}
set num_warnings [expr {$num_warnings + $r1_warnings}]

# -----------------------------------------------------------------------------
# RULE 2: Fanout Limitation & Tree Buffering
# -----------------------------------------------------------------------------
rpt_puts "\n--------------------------------------------------------------------------------"
rpt_puts "\[RULE 2\] Fanout Limitation & Tree Buffering"
rpt_puts "  Constraints:"
rpt_puts "    - Soft Limit: Fanout <= 16 (flagged as WARNING)"
rpt_puts "    - Hard Limit: Fanout <= 24 (flagged as VIOLATION)"
rpt_puts "--------------------------------------------------------------------------------"

set r2_errors 0
set r2_warnings 0

# Check non-clock, non-reset and non-constant internal nets
set internal_nets [get_nets -hierarchical -filter {
    TYPE != "GLOBAL_CLOCK" && NAME !~ "*clk*" && NAME !~ "*rst*" && NAME !~ "*reset*" &&
    NAME !~ "*<const*" && NAME !~ "*GND*" && NAME !~ "*VCC*" && NAME !~ "*GLOBAL_LOGIC*"
}]

set top_high_fo [list]
foreach n $internal_nets {
    set pin_cnt [get_property FLAT_PIN_COUNT $n]
    # Subtract driver pin to get fanout
    set fo [expr {$pin_cnt - 1}]
    if {$fo > 24} {
        rpt_puts "  VIOLATION (Hard Fanout): Net '$n' has fanout $fo (> 24 hard limit)"
        incr r2_errors
    } elseif {$fo > 16} {
        rpt_puts "  WARNING (Soft Fanout): Net '$n' has fanout $fo (> 16 soft limit)"
        incr r2_warnings
    }
}

if {$r2_errors == 0} {
    rpt_puts "  \[PASS\] Rule 2 Check Succeeded (0 hard violations, $r2_warnings soft warnings)."
} else {
    rpt_puts "  \[FAIL\] Rule 2 Check Failed with $r2_errors violation(s)."
    set num_errors [expr {$num_errors + $r2_errors}]
}
set num_warnings [expr {$num_warnings + $r2_warnings}]

# -----------------------------------------------------------------------------
# RULE 3: Flop-to-Flop Boundary Rule (Zero Combinational Feedthrough)
# -----------------------------------------------------------------------------
rpt_puts "\n--------------------------------------------------------------------------------"
rpt_puts "\[RULE 3\] Flop-to-Flop Boundary Rule (Feedthrough Check)"
rpt_puts "  Constraints:"
rpt_puts "    - Inter-module input-to-output combinational feedthrough: strictly 0 paths"
rpt_puts "--------------------------------------------------------------------------------"

set r3_errors 0
set in_ports [get_ports -filter {DIRECTION == "IN" && NAME !~ "*clk*" && NAME !~ "*rst*" && NAME !~ "*reset*"}]
set out_ports [get_ports -filter {DIRECTION == "OUT"}]

if {[llength $in_ports] > 0 && [llength $out_ports] > 0} {
    set feedthrough_paths [get_timing_paths -from $in_ports -to $out_ports -max_paths 50]
    if {[llength $feedthrough_paths] > 0} {
        foreach fp $feedthrough_paths {
            set sp [get_property STARTPOINT_PIN $fp]
            set ep [get_property ENDPOINT_PIN $fp]
            set levels [get_property LOGIC_LEVELS $fp]
            rpt_puts "  VIOLATION (Feedthrough): Combinational path from Port '$sp' to Port '$ep' ($levels logic levels)"
            incr r3_errors
        }
    }
}

if {$r3_errors == 0} {
    rpt_puts "  \[PASS\] Rule 3 Check Succeeded (0 combinational feedthrough paths)."
} else {
    rpt_puts "  \[FAIL\] Rule 3 Check Failed with $r3_errors feedthrough path(s)."
    set num_errors [expr {$num_errors + $r3_errors}]
}

# -----------------------------------------------------------------------------
# RULE 4: Clean Single-Cycle Memory Pipeline
# -----------------------------------------------------------------------------
rpt_puts "\n--------------------------------------------------------------------------------"
rpt_puts "\[RULE 4\] Clean Single-Cycle Memory Pipeline"
rpt_puts "  Constraints:"
rpt_puts "    - RAM Address Input: 0 combinational logic levels (direct from register)"
rpt_puts "    - RAM Data Output: 0 combinational logic levels before first register stage"
rpt_puts "--------------------------------------------------------------------------------"

set r4_errors 0
set mem_cells [get_cells -hierarchical -filter {
    REF_NAME =~ "RAMB*" || REF_NAME =~ "RAM32*" || REF_NAME =~ "RAM64*" || REF_NAME =~ "RAM128*"
}]

if {[llength $mem_cells] > 0} {
    foreach m $mem_cells {
        # Check Address pins
        set addr_pins [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*ADDR*"}]
        if {[llength $addr_pins] > 0} {
            set a_paths [get_timing_paths -to $addr_pins -max_paths 10]
            foreach ap $a_paths {
                set lev [get_property LOGIC_LEVELS $ap]
                if {$lev > 0} {
                    set sp [get_property STARTPOINT_PIN $ap]
                    set ep [get_property ENDPOINT_PIN $ap]
                    rpt_puts "  VIOLATION (RAM Address Logic): Memory '$m' address pin '$ep' has $lev logic levels from '$sp'"
                    incr r4_errors
                }
            }
        }

        # Check Data Output pins
        set dout_pins [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*DO*" || REF_PIN_NAME =~ "*DOUT*"}]
        if {[llength $dout_pins] > 0} {
            set d_paths [get_timing_paths -from $dout_pins -max_paths 10]
            foreach dp $d_paths {
                set lev [get_property LOGIC_LEVELS $dp]
                if {$lev > 0} {
                    set sp [get_property STARTPOINT_PIN $dp]
                    set ep [get_property ENDPOINT_PIN $dp]
                    rpt_puts "  VIOLATION (RAM DataOut Logic): Memory '$m' data pin '$sp' has $lev logic levels before '$ep'"
                    incr r4_errors
                }
            }
        }
    }
}

if {$r4_errors == 0} {
    rpt_puts "  \[PASS\] Rule 4 Check Succeeded (Clean 1-cycle memory interfaces, [llength $mem_cells] RAM instances checked)."
} else {
    rpt_puts "  \[FAIL\] Rule 4 Check Failed with $r4_errors violation(s)."
    set num_errors [expr {$num_errors + $r4_errors}]
}

# -----------------------------------------------------------------------------
# RULE 5: Backpressure Decoupling (Skid Buffer Isolation)
# -----------------------------------------------------------------------------
rpt_puts "\n--------------------------------------------------------------------------------"
rpt_puts "\[RULE 5\] Backpressure Decoupling (Skid Buffer Isolation)"
rpt_puts "  Constraints:"
rpt_puts "    - Handshake 'ready' signals must not ripple combinationally across modules"
rpt_puts "--------------------------------------------------------------------------------"

set r5_errors 0
set ready_ins [get_ports -filter {NAME =~ "*ready*" && DIRECTION == "IN"}]
set ready_outs [get_ports -filter {NAME =~ "*ready*" && DIRECTION == "OUT"}]

if {[llength $ready_ins] > 0 && [llength $ready_outs] > 0} {
    set ready_paths [get_timing_paths -from $ready_ins -to $ready_outs -max_paths 20]
    if {[llength $ready_paths] > 0} {
        foreach rp $ready_paths {
            set sp [get_property STARTPOINT_PIN $rp]
            set ep [get_property ENDPOINT_PIN $rp]
            set lev [get_property LOGIC_LEVELS $rp]
            if {$lev > 0} {
                rpt_puts "  VIOLATION (Ready Ripple): Combinational path from '$sp' to '$ep' ($lev logic levels)"
                incr r5_errors
            }
        }
    }
}

if {$r5_errors == 0} {
    rpt_puts "  \[PASS\] Rule 5 Check Succeeded (Zero combinational ready ripples across module boundaries)."
} else {
    rpt_puts "  \[FAIL\] Rule 5 Check Failed with $r5_errors violation(s)."
    set num_errors [expr {$num_errors + $r5_errors}]
}

# -----------------------------------------------------------------------------
# Final Verdict & Summary Scoreboard
# -----------------------------------------------------------------------------
rpt_puts "\n================================================================================"
rpt_puts "  ASIC 5nm 1.5 GHz COMPLIANCE SUMMARY FOR $top"
rpt_puts "================================================================================"
set s1 [expr {$r1_errors == 0 ? "PASS" : "FAIL"}]
set s2 [expr {$r2_errors == 0 ? "PASS" : "FAIL"}]
set s3 [expr {$r3_errors == 0 ? "PASS" : "FAIL"}]
set s4 [expr {$r4_errors == 0 ? "PASS" : "FAIL"}]
set s5 [expr {$r5_errors == 0 ? "PASS" : "FAIL"}]

rpt_puts "  Rule 1: Primitive & Logic Level Budget   \[$s1\] ($r1_errors violations, $r1_warnings warnings)"
rpt_puts "  Rule 2: Fanout Limitation & Buffering     \[$s2\] ($r2_errors violations, $r2_warnings warnings)"
rpt_puts "  Rule 3: Flop-to-Flop Boundary Rule        \[$s3\] ($r3_errors violations)"
rpt_puts "  Rule 4: Clean Single-Cycle Memory         \[$s4\] ($r4_errors violations)"
rpt_puts "  Rule 5: Skid Backpressure Decoupling      \[$s5\] ($r5_errors violations)"
rpt_puts "--------------------------------------------------------------------------------"
rpt_puts "  TOTAL VIOLATIONS: $num_errors"
rpt_puts "  TOTAL WARNINGS:   $num_warnings"
if {$num_errors == 0} {
    rpt_puts "  OVERALL VERDICT: PASSED (Fully compliant with ASIC 5nm 1.5 GHz architecture)"
    rpt_puts "================================================================================"
    close $rpt
    exit 0
} else {
    rpt_puts "  OVERALL VERDICT: FAILED ($num_errors violations need microarchitectural fix)"
    rpt_puts "================================================================================"
    close $rpt
    exit 1
}
