// =============================================================================
// cordic_division.v
//
// Doubly Pipelined CORDIC Architecture for Real-Time Division
// ===========================================================
//
// Uses linear-mode CORDIC in vectoring configuration to compute
//   quotient = dividend / divisor
// with a fully pipelined architecture: a new division can be started on
// every rising clock edge, and the result emerges N+1 cycles later.
//
// "Doubly pipelined" means two sets of pipeline registers are used:
//   Stage 0  : input capture registers (first pipeline stage)
//   Stages 1..N : N CORDIC-iteration registers (second pipeline stage onward)
// This separates the input-sampling clock domain from the datapath,
// reducing combinational depth and supporting high clock frequencies.
//
// Algorithm  (linear CORDIC, vectoring mode, m = 0)
// -------------------------------------------------
//   Recurrence (i = 0 … N-1):
//     x[i+1] = x[i]                               (x unchanged in linear mode)
//     y[i+1] = y[i] + d[i] * x[i] * 2^{-i}
//     z[i+1] = z[i] - d[i] * 2^{-i}
//
//   Decision:  d[i] = +1 if y[i] < 0  (add to drive y toward 0)
//              d[i] = -1 if y[i] >= 0 (subtract to drive y toward 0)
//              i.e. d[i] = −sign(y[i])
//
//   Initial values: x[0] = divisor,  y[0] = dividend,  z[0] = 0
//   Convergence:    y -> 0,  z -> dividend / divisor
//
// Fixed-point format: Q(W-FRAC).FRAC  (default Q16.16, signed two's-complement)
//   e.g. W=32, FRAC=16 → value = raw_integer / 2^16
//
// Constraints
// -----------
//   * divisor must be > 0  (the algorithm drives y → 0 assuming x > 0)
//   * |dividend/divisor| < 2·(1 − 2^{-N}) ≈ 2  for convergence at N=16
//
// Parameters
// ----------
//   N    : number of CORDIC iterations (pipeline depth = N+1)
//   W    : total data width in bits
//   FRAC : number of fractional bits (W-FRAC integer bits)
//
// Ports
// -----
//   clk       : clock (rising-edge triggered)
//   rst_n     : active-low synchronous reset
//   valid_in  : asserted for one cycle to present new operands
//   dividend  : numerator   (Q(W-FRAC).FRAC)
//   divisor   : denominator (Q(W-FRAC).FRAC, must be > 0)
//   valid_out : asserted N+1 cycles after valid_in
//   quotient  : result = dividend / divisor  (Q(W-FRAC).FRAC)
// =============================================================================

`timescale 1ns / 1ps

module cordic_division #(
    parameter integer N    = 16,   // CORDIC iterations  (pipeline depth = N+1)
    parameter integer W    = 32,   // Data width (bits)
    parameter integer FRAC = 16    // Fractional bits  (Q(W-FRAC).FRAC format)
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             valid_in,
    input  wire [W-1:0]     dividend,
    input  wire [W-1:0]     divisor,
    output wire             valid_out,
    output wire [W-1:0]     quotient
);

    // -------------------------------------------------------------------------
    // Pipeline register arrays  (index 0 = output of Stage 0, index N = output)
    // -------------------------------------------------------------------------
    reg [W-1:0] px [0:N];   // x data path (holds divisor, unchanged per stage)
    reg [W-1:0] py [0:N];   // y data path (driven towards 0)
    reg [W-1:0] pz [0:N];   // z data path (accumulates quotient)
    reg         pv [0:N];   // valid flag propagation

    // -------------------------------------------------------------------------
    // Stage 0 – input capture (first pipeline stage)
    //   Samples dividend / divisor on the rising edge when valid_in is asserted.
    //   This register stage decouples the input bus from the CORDIC datapath.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            px[0] <= {W{1'b0}};
            py[0] <= {W{1'b0}};
            pz[0] <= {W{1'b0}};
            pv[0] <= 1'b0;
        end else begin
            px[0] <= divisor;           // x_0 = divisor
            py[0] <= dividend;          // y_0 = dividend  (to be driven → 0)
            pz[0] <= {W{1'b0}};         // z_0 = 0
            pv[0] <= valid_in;
        end
    end

    // -------------------------------------------------------------------------
    // Stages 1 .. N – CORDIC iteration registers (second pipeline stage onward)
    //   Each generate-block iteration k computes one CORDIC step:
    //     d     = -sign(y[k]) = +1 if y[k] < 0, else -1
    //     x_sh  = x[k] >> k   (arithmetic right shift → x[k] * 2^{-k})
    //     step  = 2^{-k} in Q(W-FRAC).FRAC = 1 << (FRAC - k)
    // -------------------------------------------------------------------------
    genvar k;
    generate
        for (k = 0; k < N; k = k + 1) begin : g_stage

    // Step size: 2^{-k} encoded in Q(W-FRAC).FRAC
            //   For k < FRAC  : step = 1 << (FRAC-k)  (e.g. k=0 → 2^FRAC = 1.0)
            //   For k = FRAC  : step = 1 << 0 = 1     (smallest representable value, 2^{-FRAC})
            //   For k > FRAC  : step = 0               (below fixed-point resolution)
            localparam [W-1:0] STEP =
                (k <= FRAC) ? ({{(W-1){1'b0}}, 1'b1} << (FRAC - k)) : {W{1'b0}};

            // Arithmetic right-shift of x by k positions: x[k] * 2^{-k}
            wire signed [W-1:0] x_sh = $signed(px[k]) >>> k;

            // Direction bit: 1 ↔ y[k] < 0 (MSB = 1 in two's complement)
            wire d_k = py[k][W-1];

            always @(posedge clk) begin
                if (!rst_n) begin
                    px[k+1] <= {W{1'b0}};
                    py[k+1] <= {W{1'b0}};
                    pz[k+1] <= {W{1'b0}};
                    pv[k+1] <= 1'b0;
                end else begin
                    pv[k+1] <= pv[k];
                    px[k+1] <= px[k];          // x unchanged in linear CORDIC

                    if (d_k) begin
                        // y[k] < 0  →  d = +1:  add  x_sh to y, subtract step from z
                        py[k+1] <= $signed(py[k]) + x_sh;
                        pz[k+1] <= $signed(pz[k]) - $signed(STEP);
                    end else begin
                        // y[k] >= 0 →  d = -1:  subtract x_sh from y, add step to z
                        py[k+1] <= $signed(py[k]) - x_sh;
                        pz[k+1] <= $signed(pz[k]) + $signed(STEP);
                    end
                end
            end

        end // for k
    endgenerate

    // -------------------------------------------------------------------------
    // Outputs
    // -------------------------------------------------------------------------
    assign valid_out = pv[N];
    assign quotient  = pz[N];

endmodule
