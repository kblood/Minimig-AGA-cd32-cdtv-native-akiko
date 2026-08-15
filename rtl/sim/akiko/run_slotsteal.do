# tb_akiko_slot_steal runner -- chip-slot steal during an armed Akiko transaction.
# Run with: vsim -c -do run_slotsteal.do
# This bench REPORTS rather than asserts: exit code is 0 unless the bench itself
# errored (timeout), so the steal result is read from the printed table.

if {[file exists work_slotsteal]} { vdel -lib work_slotsteal -all }
vlib work_slotsteal
vmap work work_slotsteal

vlog -sv -quiet ../../memory_router.v
vlog -sv -quiet ../../chipdma_arb.v
vlog -sv -quiet tb_akiko_slot_steal.sv

vsim -c -voptargs=+acc work.tb_akiko_slot_steal
run -all

set num_errs [examine -value /tb_akiko_slot_steal/errs]
if {$num_errs != 0} {
    puts "RUN: BENCH ERRORS ($num_errs)"
    quit -code 1
} else {
    puts "RUN: OK"
    quit -code 0
}
