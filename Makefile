# =============================================================================
# Makefile – Doubly Pipelined CORDIC Division
# =============================================================================
#
# Targets
# -------
#   make all     : compile, simulate, and run Python verification (default)
#   make compile : compile Verilog source + testbench with Icarus Verilog
#   make sim     : run the simulation (generates sim/sim_results.csv + .vcd)
#   make verify  : run Python verification script
#   make clean   : remove generated artefacts
#
# Requirements
# ------------
#   iverilog / vvp  (Icarus Verilog)   – RTL compilation and simulation
#   python3                            – verification and error analysis

IVERILOG = iverilog
VVP      = vvp
PYTHON   = python3

SRC_DIR  = src
SIM_DIR  = sim
PY_DIR   = python

TOP_SRC  = $(SRC_DIR)/cordic_division.v
TB_SRC   = $(SIM_DIR)/cordic_tb.v

SIM_BIN  = $(SIM_DIR)/cordic_sim
CSV_FILE = $(SIM_DIR)/sim_results.csv
VCD_FILE = $(SIM_DIR)/cordic_tb.vcd

.PHONY: all compile sim verify clean

# Default target
all: sim verify

# ── Compilation ──────────────────────────────────────────────────────────────
compile: $(SIM_BIN)

$(SIM_BIN): $(TOP_SRC) $(TB_SRC)
	$(IVERILOG) -g2005-sv -Wall -o $(SIM_BIN) $(TOP_SRC) $(TB_SRC)
	@echo "[compile] OK → $(SIM_BIN)"

# ── Simulation ───────────────────────────────────────────────────────────────
sim: $(SIM_BIN)
	@echo "[sim] running CORDIC division simulation..."
	cd $(SIM_DIR) && $(VVP) $(abspath $(SIM_BIN))
	@echo "[sim] done  → $(CSV_FILE)  $(VCD_FILE)"

$(CSV_FILE): sim

# ── Python verification ───────────────────────────────────────────────────────
verify:
	@echo "[verify] running Python verification..."
	$(PYTHON) $(PY_DIR)/verify.py
	@echo "[verify] done"

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -f $(SIM_BIN) $(CSV_FILE) $(VCD_FILE)
	@echo "[clean] done"
