open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
report_timing -from [get_pins u_ctl/st_reg[0]_rep/C] -to [get_pins u_ctl/fault_addr_reg[0]/CE]
report_timing -from [get_pins u_skid_fw_lo/out_data_reg[1]/C] -to [get_pins u_seq/hdr_fault_r_reg/D]
report_timing -from [get_pins r_busy_ext_reg[2]/C] -to [get_pins u_seq/sidx_reg[0]/CE]
