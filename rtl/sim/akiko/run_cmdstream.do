# tb_akiko_cmdstream runner -- guest command in flight during an
# unsolicited media announce (the disc-insert case).
# Run with: vsim -c -do run_cmdstream.do

if {[file exists work_cmdstream]} { vdel -lib work_cmdstream -all }
vlib work_cmdstream
vmap work work_cmdstream

vlog -quiet C:/intelFPGA_lite/17.0/quartus/eda/sim_lib/altera_mf.v
vlog -sv -quiet ../../akiko_nvram.v
vlog -sv -quiet ../../akiko.v
vlog -sv -quiet tb_akiko_cmdstream.sv

vsim -c -voptargs=+acc work.tb_akiko_cmdstream
run -all

set num_errs [examine -value /tb_akiko_cmdstream/errs]
if {$num_errs != 0} {
    puts "RUN: FAIL ($num_errs errors)"
    quit -code 1
} else {
    puts "RUN: PASS"
    quit -code 0
}
