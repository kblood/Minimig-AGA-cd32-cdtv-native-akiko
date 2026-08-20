#requires -Version 5.0
# tb_sprite_mux_load: clean RTL + the full mutant negative-control suite.
#
#   .\run_sprite_mux.ps1              # clean at stagger 0 and 1, then all mutants
#   .\run_sprite_mux.ps1 -CleanOnly
#
# A PASS on the clean RTL only means something if every broken mutant FAILS and
# the identity mutant PASSES. That is what this script asserts.
param(
    [switch]$CleanOnly,
    [int]$Frames = 16,
    [int]$MutantFrames = 4
)
$ErrorActionPreference = "Stop"

$vsim = "C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem\vsim.exe"
if (-not (Test-Path -LiteralPath $vsim)) {
    Write-Error "ModelSim ASE not found at $vsim"; exit 2
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $here
$fail = 0
try {
    foreach ($stag in 0, 1) {
        Write-Host "=== clean RTL, stagger=$stag ===" -ForegroundColor Cyan
        & $vsim -c -do "set frames $Frames; set stag $stag; set lib work_sprmux; do run_sprite_mux.do"
        if ($LASTEXITCODE -ne 0) { Write-Host "clean stagger=$stag FAILED" -ForegroundColor Red; $fail++ }
        else { Write-Host "clean stagger=$stag PASS" -ForegroundColor Green }
    }
    if ($CleanOnly) { exit $fail }

    # negative controls: null must pass, every other mutant must fail
    foreach ($m in "null", "win00", "alias", "lock", "slow") {
        python patch_sprmux_mutant.py $m "spritedma_mut_$m.v" | Out-Null
        Write-Host "=== mutant $m ===" -ForegroundColor Cyan
        & $vsim -c -do "set dut spritedma_mut_$m.v; set frames $MutantFrames; set stag 1; set lib work_sprmut; do run_sprite_mux.do"
        $rc = $LASTEXITCODE
        $want = if ($m -eq "null") { 0 } else { 1 }
        if ($rc -eq $want) { Write-Host "mutant $m behaved as required (rc=$rc)" -ForegroundColor Green }
        else { Write-Host "mutant $m DID NOT behave as required (rc=$rc, want $want)" -ForegroundColor Red; $fail++ }
        Remove-Item -LiteralPath "spritedma_mut_$m.v" -ErrorAction SilentlyContinue
    }
} finally { Pop-Location }

if ($fail -eq 0) { Write-Host "tb_sprite_mux_load SUITE PASSED" -ForegroundColor Green }
else { Write-Host "tb_sprite_mux_load SUITE FAILED ($fail)" -ForegroundColor Red }
exit $fail
