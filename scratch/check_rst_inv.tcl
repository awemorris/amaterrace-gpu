open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
puts "NET scan/rst_inv_net: [get_nets scan/rst_inv_net]"
puts "TOP NET OF rst_inv_net: [get_property TOP_NET_OF_HIERARCHICAL_GROUP [get_nets scan/rst_inv_net]]"
