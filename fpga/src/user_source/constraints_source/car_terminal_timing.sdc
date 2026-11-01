# S45 physical PLL: SD100, MEM50 phase0, SDRAM50 phase153deg (+8.5ns).
# Keep physical master relationships and all datapath timing checks.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
create_generated_clock -name sd_card_clk -source [get_ports {clk}] -master_clock clk -multiply_by 2 [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
create_generated_clock -name ext_mem_clk -source [get_ports {clk}] -master_clock clk -divide_by 1 [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
create_generated_clock -name sdram_device_clk -source [get_ports {clk}] -master_clock clk -divide_by 1 -phase 153 [get_pins {sys_pll_m0/pll_inst.clkc[2]}]
create_generated_clock -name video_clk -source [get_ports {clk}] -master_clock clk -divide_by 2 [get_pins {video_pll_m0/pll_inst.clkc[0]}]
create_generated_clock -name hdmi_5x_clk -source [get_ports {clk}] -master_clock clk -multiply_by 2.5 [get_pins {video_pll_m0/pll_inst.clkc[1]}]
# ODDR is a real output register, so explicitly propagate its clock to the
# physical SDRAM clock net. Resolving by the hard-IP pin survives pad packing.
create_generated_clock -name sdram_pad_clock -source [get_pins {sys_pll_m0/pll_inst.clkc[2]}] -master_clock sdram_device_clk -divide_by 1 [get_nets -of [get_pins {U3/sdram.clk}]]
# Only async assertion/release inputs to the reset synchronizer chains.
# S25 adds a falling-edge final release stage and a serial-clock chain.
# Do NOT include hold_reset_n1: it is the raw reference-counter reset.
# Stage1->stage2 and stage2->functional-reset timing remain checked.
set_false_path -through [get_nets {u_reset/hold_reset u_reset/hold_reset_dup_*}]
# This named net feeds only the vendor FIFO's four reset-release flops.
# Pointer/data flops receive its locally synchronized outputs, not this net.
set_false_path -through [get_nets {u_frame_writer/fifo_async_reset}]
# The writer's MEM reset/abort enters only its two reset-release flops in
# SD. Its MEM functional consumers remain timed. S24 routed-netlist audit
# found exactly those two SD SR sinks; audit this again after S25 packing.
set_false_path -through [get_nets {u_frame_writer/writer/rst u_frame_writer/writer/rst_dup_*}] -to [get_clocks {sd_card_clk}]
# External key/PLL-loss assertion enters only reset-release boundaries.
# Reference counter is now released by a local falling-edge register; its
# recovery/removal and all ordinary functional paths remain timed.
set_false_path -through [get_nets {u_reset/reference_async_reset}]

# Local common-reset input to the raster/audio reset-release chains only.
# S26 packed audit: exactly 8 PIX SR pins / 11 configured reset FF lanes;
# all lanes are stage0 D=0 or stage1 D=stage0, asynchronous SET, rising edge.
# The same raw net also feeds 2 MEM SR pins, which remain timed here.
# Do not match rst_p/px_reset[1] outputs or any functional data path.
# Re-audit every routed candidate; never substitute old packed-cell names.
set_false_path -through [get_nets {u_raster/engine/rst}] -to [get_clocks {video_clk}]
