#!/usr/bin/env python3
"""
verify.py – Python Reference & Verification for the Doubly Pipelined CORDIC Division
======================================================================================

This script serves two purposes:

  1. **Reference implementation** – Simulates the same linear CORDIC algorithm
     (vectoring mode, m = 0) in pure Python/floating-point, providing a bit-accurate
     software model of the Verilog design.

  2. **Verification & error analysis** – If Verilog simulation output
     (sim/sim_results.csv) is available, this script loads it and computes:
       * absolute error  |expected − result|
       * relative error  |expected − result| / |expected|
     for each test case, and prints a summary table.

Algorithm
---------
  Linear CORDIC, vectoring mode (drives y → 0):

    For i = 0 … N-1:
        d[i]     = −sign(y[i])          # +1 if y<0 (add x·2^{−i}), −1 if y≥0 (subtract)
        x[i+1]   = x[i]                 # x unchanged
        y[i+1]   = y[i] + d[i]*x[i]*2^{−i}
        z[i+1]   = z[i] − d[i]*2^{−i}

    Initial:  x = divisor,  y = dividend,  z = 0
    Result:   z_N ≈ dividend / divisor      (when y_N ≈ 0)

Fixed-point format: Q16.16 (W=32, FRAC=16, signed two's complement).

Convergence constraint: |dividend / divisor| < 2·(1 − 2^{-N}) ≈ 2  for N=16.
"""

import os
import csv
import math

# ── Constants (must match Verilog parameters) ────────────────────────────────
N      = 16          # CORDIC iterations
W      = 32          # Total bit width
FRAC   = 16          # Fractional bits
SCALE  = 1 << FRAC   # 2^16 = 65536
MASK_W = (1 << W) - 1


# ── Fixed-point helpers ───────────────────────────────────────────────────────

def real_to_fp(value: float) -> int:
    """Convert a real number to signed Q16.16 fixed-point (stored as uint32)."""
    raw = int(round(value * SCALE))
    raw = max(-(1 << (W - 1)), min((1 << (W - 1)) - 1, raw))
    if raw < 0:
        raw += (1 << W)
    return raw & MASK_W


def fp_to_real(fp: int) -> float:
    """Convert an unsigned uint32 Q16.16 value back to a real number."""
    fp &= MASK_W
    if fp >= (1 << (W - 1)):          # negative in two's complement
        fp -= (1 << W)
    return fp / SCALE


# ── Floating-point CORDIC reference ─────────────────────────────────────────

def cordic_fp_reference(dividend: float, divisor: float):
    """
    Simulate CORDIC division in floating-point (exact algorithm, no rounding).

    Returns
    -------
    result : float   – computed quotient after N iterations
    trace  : list    – list of (x, y, z) tuples at each stage
    """
    x, y, z = divisor, dividend, 0.0
    trace = [(x, y, z)]
    for i in range(N):
        d_i   = 1.0 if y < 0.0 else -1.0      # d = −sign(y): +1 if y<0, −1 if y≥0
        shift = 2.0 ** (-i)
        x     = x                              # x unchanged in linear mode
        y     = y + d_i * x * shift            # y[i+1] = y[i] + d[i]*x[i]*2^{−i}
        z     = z - d_i * shift               # z[i+1] = z[i] − d[i]*2^{−i}
        trace.append((x, y, z))
    return z, trace


# ── Fixed-point CORDIC (mirrors Verilog exactly) ─────────────────────────────

def cordic_fixed_reference(dividend: float, divisor: float) -> float:
    """
    Simulate CORDIC division using Q16.16 integer arithmetic, mirroring
    the Verilog implementation exactly (arithmetic right-shifts, integer add/sub).

    Returns the quotient as a real number.
    """
    def to_signed(v: int) -> int:
        v &= MASK_W
        return v - (1 << W) if v >= (1 << (W - 1)) else v

    x = to_signed(real_to_fp(divisor))
    y = to_signed(real_to_fp(dividend))
    z = 0

    for i in range(N):
        d     = 1 if y < 0 else -1                   # direction
        x_sh  = x >> i                                # arithmetic right-shift
        step  = (1 << (FRAC - i)) if i <= FRAC else 0

        x_new = x
        y_new = y + d * x_sh                              # y[i+1] = y[i] + d[i]*x[i]>>i
        z_new = z - d * step                              # z[i+1] = z[i] − d[i]*step

        x, y, z = x_new, y_new, z_new

    return fp_to_real(z & MASK_W)


# ── Test cases ────────────────────────────────────────────────────────────────

TEST_CASES = [
    ( 3.0,  4.0),   # 0.750 000
    ( 7.0,  8.0),   # 0.875 000
    ( 5.0,  4.0),   # 1.250 000
    ( 3.0,  2.0),   # 1.500 000
    ( 1.0,  8.0),   # 0.125 000
    ( 7.0,  4.0),   # 1.750 000
    ( 2.0,  3.0),   # 0.666 667
    (11.0,  7.0),   # 1.571 429
]


# ── Main report ───────────────────────────────────────────────────────────────

def run_software_verification():
    """Run all test cases through both reference models and print a report."""
    print("=" * 90)
    print("  CORDIC Division – Python Reference Verification  (N={}, Q{}.{})".format(
        N, W - FRAC, FRAC))
    print("=" * 90)

    header = (
        f"{'#':>3}  {'Dividend':>10}  {'Divisor':>10}  "
        f"{'Expected':>14}  {'FP-CORDIC':>14}  {'FX-CORDIC':>14}  "
        f"{'|FP err|':>12}  {'|FX err|':>12}"
    )
    print(header)
    print("-" * 90)

    fp_errors, fx_errors = [], []
    records = []

    for idx, (a, b) in enumerate(TEST_CASES):
        expected  = a / b
        fp_result, trace = cordic_fp_reference(a, b)
        fx_result = cordic_fixed_reference(a, b)

        fp_err = abs(expected - fp_result)
        fx_err = abs(expected - fx_result)

        fp_errors.append(fp_err)
        fx_errors.append(fx_err)
        records.append({
            'dividend': a, 'divisor': b,
            'expected': expected,
            'fp_result': fp_result, 'fx_result': fx_result,
            'fp_err': fp_err, 'fx_err': fx_err,
        })

        print(
            f"{idx:>3}  {a:>10.4f}  {b:>10.4f}  "
            f"{expected:>14.8f}  {fp_result:>14.8f}  {fx_result:>14.8f}  "
            f"{fp_err:>12.4e}  {fx_err:>12.4e}"
        )

    print("-" * 90)
    print(f"  Floating-point CORDIC  | max |err| = {max(fp_errors):.4e}"
          f"  mean |err| = {sum(fp_errors)/len(fp_errors):.4e}")
    print(f"  Fixed-point CORDIC     | max |err| = {max(fx_errors):.4e}"
          f"  mean |err| = {sum(fx_errors)/len(fx_errors):.4e}")
    print(f"  Fixed-point resolution (1 LSB) = {1/SCALE:.6e}  (2^-{FRAC})")
    print("=" * 90)

    return records


def compare_with_simulation(csv_path: str, ref_records: list):
    """
    Load the Verilog simulation CSV and compare each result against both the
    floating-point exact value and the fixed-point Python model.
    """
    if not os.path.isfile(csv_path):
        print(f"\n[Info] '{csv_path}' not found – run 'make sim' first to generate it.")
        return

    print(f"\n{'=' * 90}")
    print(f"  Verilog RTL vs. Python Reference  (reading: {csv_path})")
    print(f"{'=' * 90}")

    header = (
        f"{'#':>3}  {'Expected':>14}  {'RTL result':>14}  "
        f"{'FX-Python':>14}  {'|RTL err|':>12}  {'|FX err|':>12}  Match?"
    )
    print(header)
    print("-" * 90)

    hw_errors = []
    all_match = True

    with open(csv_path, newline='') as f:
        reader = csv.DictReader(f)
        for idx, row in enumerate(reader):
            expected   = float(row['expected'])
            hw_result  = float(row['result'])
            fx_result  = ref_records[idx]['fx_result'] if idx < len(ref_records) else float('nan')

            hw_err = abs(expected - hw_result)
            fx_err = abs(expected - fx_result)
            hw_errors.append(hw_err)

            # Accept match if RTL result equals fixed-point Python result
            match = abs(hw_result - fx_result) < (1.5 / SCALE)
            if not match:
                all_match = False

            print(
                f"{idx:>3}  {expected:>14.8f}  {hw_result:>14.8f}  "
                f"{fx_result:>14.8f}  {hw_err:>12.4e}  {fx_err:>12.4e}  "
                f"{'OK' if match else 'MISMATCH'}"
            )

    print("-" * 90)
    if hw_errors:
        print(f"  RTL max  |error|  = {max(hw_errors):.4e}")
        print(f"  RTL mean |error|  = {sum(hw_errors)/len(hw_errors):.4e}")
    status = "PASS – all RTL results match fixed-point Python model." if all_match \
             else "FAIL – one or more RTL results differ from Python model."
    print(f"  Verification: {status}")
    print("=" * 90)


def print_iteration_trace(dividend: float, divisor: float):
    """Print the step-by-step CORDIC iteration trace for one example."""
    expected = dividend / divisor
    print(f"\n--- CORDIC iteration trace: {dividend} / {divisor} = {expected:.8f} ---")
    print(f"{'Iter':>5}  {'x':>14}  {'y':>14}  {'z':>14}  {'d':>4}")
    print("-" * 58)

    x, y, z = divisor, dividend, 0.0
    print(f"{'init':>5}  {x:>14.8f}  {y:>14.8f}  {z:>14.8f}  {'–':>4}")

    for i in range(N):
        d_i   = 1 if y < 0.0 else -1
        shift = 2.0 ** (-i)
        x     = x
        y     = y + d_i * x * shift            # y[i+1] = y[i] + d[i]*x[i]*2^{−i}
        z     = z - d_i * shift               # z[i+1] = z[i] − d[i]*2^{−i}
        print(f"{i:>5}  {x:>14.8f}  {y:>14.8f}  {z:>14.8f}  {d_i:>+4d}")

    print(f"  → z_N = {z:.8f}  (expected {expected:.8f},  |error| = {abs(z-expected):.4e})")


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # 1. Software-only verification
    ref = run_software_verification()

    # 2. Detailed trace for one representative example
    print_iteration_trace(11.0, 7.0)

    # 3. Compare RTL output (if simulation has been run)
    sim_csv = os.path.join(os.path.dirname(__file__), "..", "sim", "sim_results.csv")
    compare_with_simulation(sim_csv, ref)
