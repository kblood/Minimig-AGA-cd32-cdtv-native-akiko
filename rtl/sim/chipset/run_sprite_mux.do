# tb_sprite_mux_load runner.
#
#   vsim -c -do run_sprite_mux.do
#   vsim -c -do "set dut spritedma_mut_win00.v; set frames 6; do run_sprite_mux.do"
#
# Exit 0 = PASS, 1 = FAIL.  Free ModelSim ASE (Quartus 17.0.2 Lite) is enough;
# Questa FSE needs a licence and will not run this.

if {![info exists dut]}    { set dut    ../../agnus_spritedma.v }
if {![info exists frames]} { set frames 16 }
if {![info exists stag]}   { set stag   0 }
if {![info exists lib]}    { set lib    work_sprmux }

if {[file exists $lib]} { vdel -lib $lib -all }
vlib $lib
vmap work $lib

vlog -quiet -work $lib -timescale "1ns/1ps" ../../amiga_clk.v
# sim shim = agnus_beamcounter.v with 4 forward declarations hoisted so
# ModelSim accepts them. Generated mechanically; no behavioural change.
vlog -quiet -work $lib -timescale "1ns/1ps" agnus_beamcounter_simshim.v
vlog -quiet -work $lib -timescale "1ns/1ps" $dut
vlog -sv -quiet -work $lib -timescale "1ns/1ps" tb_sprite_mux_load.sv

puts "RUN: dut=$dut frames=$frames stagger=$stag"
vsim -c -voptargs=+acc -gFRAMES=$frames -gSTAGGER=$stag $lib.tb_sprite_mux_load
run -all

set n [examine -value /tb_sprite_mux_load/tb_errs]
if {$n != 0} {
    puts "RUN: FAIL ($n)"
    quit -code 1
} else {
    puts "RUN: PASS"
    quit -code 0
}
