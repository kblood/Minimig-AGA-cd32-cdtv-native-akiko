# tb_akiko_txrx_concurrent runner -- guest command in flight during an
# unsolicited media announce (the disc-insert case).
# Run with: vsim -c -do run_concurrent.do

if {[file exists work_concurrent]} { vdel -lib work_concurrent -all }
vlib work_concurrent
vmap work work_concurrent

vlog -quiet C:/intelFPGA_lite/17.0/quartus/eda/sim_lib/altera_mf.v
vlog -sv -quiet ../../akiko_nvram.v
vlog -sv -quiet ../../akiko.v
vlog -sv -quiet tb_akiko_txrx_concurrent.sv

vsim -c -voptargs=+acc work.tb_akiko_txrx_concurrent
run -all

set num_errs [examine -value /tb_akiko_txrx_concurrent/errs]
if {$num_errs != 0} {
    puts "RUN: FAIL ($num_errs errors)"
    quit -code 1
} else {
    puts "RUN: PASS"
    quit -code 0
}
