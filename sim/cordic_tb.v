// =============================================================================
// cordic_tb.v  –  Testbench for cordic_division
//
// Demonstrates the doubly pipelined CORDIC architecture for division.
// Eight division operations are fed into the pipeline on consecutive clock
// cycles to exercise its fully-pipelined behaviour (throughput = 1/cycle,
// latency = N+1 cycles).
//
// Outputs
// -------
//   cordic_tb.vcd     – waveform dump (open with GTKWave)
//   sim_results.csv   – CSV with dividend, divisor, expected and CORDIC result
//
// Real-time example context
// -------------------------
//   These test cases represent normalised sensor/signal ratios that might
//   appear in a real-time DSP or control pipeline (e.g. computing a gain
//   factor, a frequency ratio, or a velocity/reference ratio).
// =============================================================================

`timescale 1ns / 1ps

module cordic_tb;

    // -----------------------------------------------------------------------
    // Parameters – must match DUT
    // -----------------------------------------------------------------------
    localparam integer N         = 16;
    localparam integer W         = 32;
    localparam integer FRAC      = 16;
    localparam integer CLK_T     = 10;   // clock period (ns)
    localparam integer NUM_TESTS = 8;

    // -----------------------------------------------------------------------
    // DUT interface
    // -----------------------------------------------------------------------
    reg          clk, rst_n, valid_in;
    reg  [W-1:0] dividend, divisor;
    wire         valid_out;
    wire [W-1:0] quotient;

    cordic_division #(.N(N), .W(W), .FRAC(FRAC)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .dividend  (dividend),
        .divisor   (divisor),
        .valid_out (valid_out),
        .quotient  (quotient)
    );

    // -----------------------------------------------------------------------
    // Clock
    // -----------------------------------------------------------------------
    initial clk = 1'b0;
    always  #(CLK_T / 2) clk = ~clk;

    // -----------------------------------------------------------------------
    // Fixed-point helpers
    //   Q16.16: value = fp_integer / 65536.0
    // -----------------------------------------------------------------------
    function [W-1:0] real_to_fp;
        input real val;
        integer raw;
        begin
            raw = $rtoi(val * (1 << FRAC));
            real_to_fp = raw[W-1:0];
        end
    endfunction

    function real fp_to_real;
        input [W-1:0] fp;
        begin
            fp_to_real = $itor($signed(fp)) / $itor(1 << FRAC);
        end
    endfunction

    // -----------------------------------------------------------------------
    // Test vectors (quotient = dividend / divisor, all |quotient| < 2)
    //
    //  #   dividend   divisor   exact quotient
    //  0      3.0       4.0       0.750 000
    //  1      7.0       8.0       0.875 000
    //  2      5.0       4.0       1.250 000
    //  3      3.0       2.0       1.500 000
    //  4      1.0       8.0       0.125 000
    //  5      7.0       4.0       1.750 000
    //  6      2.0       3.0       0.666 667
    //  7     11.0       7.0       1.571 429
    // -----------------------------------------------------------------------
    reg [W-1:0] tv_dividend [0:NUM_TESTS-1];
    reg [W-1:0] tv_divisor  [0:NUM_TESTS-1];
    real        tv_expected [0:NUM_TESTS-1];

    task init_vectors;
        real a, b;
        begin
            a= 3.0; b= 4.0; tv_dividend[0]=real_to_fp(a); tv_divisor[0]=real_to_fp(b); tv_expected[0]=a/b;
            a= 7.0; b= 8.0; tv_dividend[1]=real_to_fp(a); tv_divisor[1]=real_to_fp(b); tv_expected[1]=a/b;
            a= 5.0; b= 4.0; tv_dividend[2]=real_to_fp(a); tv_divisor[2]=real_to_fp(b); tv_expected[2]=a/b;
            a= 3.0; b= 2.0; tv_dividend[3]=real_to_fp(a); tv_divisor[3]=real_to_fp(b); tv_expected[3]=a/b;
            a= 1.0; b= 8.0; tv_dividend[4]=real_to_fp(a); tv_divisor[4]=real_to_fp(b); tv_expected[4]=a/b;
            a= 7.0; b= 4.0; tv_dividend[5]=real_to_fp(a); tv_divisor[5]=real_to_fp(b); tv_expected[5]=a/b;
            a= 2.0; b= 3.0; tv_dividend[6]=real_to_fp(a); tv_divisor[6]=real_to_fp(b); tv_expected[6]=a/b;
            a=11.0; b= 7.0; tv_dividend[7]=real_to_fp(a); tv_divisor[7]=real_to_fp(b); tv_expected[7]=a/b;
        end
    endtask

    // -----------------------------------------------------------------------
    // Shared state between initial and always blocks
    // -----------------------------------------------------------------------
    integer fd;
    integer rcv_count;

    // -----------------------------------------------------------------------
    // Main stimulus
    // -----------------------------------------------------------------------
    integer i;
    initial begin
        init_vectors();

        fd        = $fopen("sim_results.csv", "w");
        rcv_count = 0;

        $fwrite(fd, "dividend,divisor,expected,result\n");

        // Reset
        rst_n    = 1'b0;
        valid_in = 1'b0;
        dividend = {W{1'b0}};
        divisor  = {W{1'b0}};
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        // ----------------------------------------------------------------
        // Feed all NUM_TESTS operands on consecutive rising edges.
        // This is the pipelined mode: throughput = 1 result per cycle,
        // latency = N+1 = 17 cycles.
        // ----------------------------------------------------------------
        $display("--- Feeding %0d test vectors into the pipeline ---", NUM_TESTS);
        for (i = 0; i < NUM_TESTS; i = i + 1) begin
            @(negedge clk);
            dividend = tv_dividend[i];
            divisor  = tv_divisor[i];
            valid_in = 1'b1;
        end
        @(negedge clk); valid_in = 1'b0;

        // Wait until all outputs have been received
        wait (rcv_count == NUM_TESTS);
        repeat (2) @(posedge clk);

        $fclose(fd);
        $display("--- Simulation complete: %0d results written to sim_results.csv ---",
                 NUM_TESTS);
        $finish;
    end

    // -----------------------------------------------------------------------
    // Output monitor – captures each valid result as it exits the pipeline
    // -----------------------------------------------------------------------
    real got_q, exp_q, abs_err;

    always @(posedge clk) begin
        if (valid_out && rcv_count < NUM_TESTS) begin
            got_q   = fp_to_real(quotient);
            exp_q   = tv_expected[rcv_count];
            abs_err = exp_q - got_q;
            if (abs_err < 0.0) abs_err = -abs_err;

            $display("[%0d] %6.3f / %6.3f | expected = %10.6f | cordic = %10.6f | |error| = %e",
                     rcv_count,
                     fp_to_real(tv_dividend[rcv_count]),
                     fp_to_real(tv_divisor[rcv_count]),
                     exp_q, got_q, abs_err);

            $fwrite(fd, "%.8f,%.8f,%.8f,%.8f\n",
                    fp_to_real(tv_dividend[rcv_count]),
                    fp_to_real(tv_divisor[rcv_count]),
                    exp_q, got_q);

            rcv_count = rcv_count + 1;
        end
    end

    // -----------------------------------------------------------------------
    // Waveform dump
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("cordic_tb.vcd");
        $dumpvars(0, cordic_tb);
    end

endmodule
