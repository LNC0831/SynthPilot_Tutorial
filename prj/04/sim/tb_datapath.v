// tb_datapath.v — System-level datapath testbench
// Tests: width adaptation (128<->32/16) + FFT config driver + FFT IP + magnitude_calc
// Does NOT instantiate top.v or BD wrapper (PCIe not simulatable)
//
// Sender drives at negedge (Xilinx IP behavioral model requirement)
// Receiver captures with NBA

`timescale 1ns / 1ps

module tb_datapath;

    // ================================================================
    // Parameters
    // ================================================================
    localparam NFFT       = 1024;
    localparam CLK_PERIOD = 10;          // 100 MHz
    localparam [15:0] CFG_WORD = 16'h0557;

    // ================================================================
    // Clock & reset
    // ================================================================
    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg rst_n = 0;

    // ================================================================
    // H2C input AXI-Stream (128-bit, TB drives this)
    // ================================================================
    reg  [127:0] h2c_tdata;
    reg          h2c_tvalid;
    reg          h2c_tlast;
    wire         h2c_tready;

    // ================================================================
    // C2H output AXI-Stream (128-bit, TB captures this)
    // ================================================================
    wire [127:0] c2h_tdata;
    wire         c2h_tvalid;
    wire         c2h_tlast;
    wire [15:0]  c2h_tkeep;
    reg          c2h_tready;

    // ================================================================
    // Internal wires (replicate top.v datapath, no BD)
    // ================================================================

    // FFT config
    wire [15:0]  fft_cfg_tdata;
    wire         fft_cfg_tvalid;
    wire         fft_cfg_tready;

    // FFT data in (32-bit)
    wire [31:0]  fft_din_tdata;
    wire         fft_din_tvalid;
    wire         fft_din_tready;
    wire         fft_din_tlast;

    // FFT data out (32-bit)
    wire [31:0]  fft_dout_tdata;
    wire         fft_dout_tvalid;
    wire         fft_dout_tready;
    wire         fft_dout_tlast;

    // Magnitude out (16-bit)
    wire [15:0]  mag_tdata;
    wire         mag_tvalid;
    wire         mag_tready;
    wire         mag_tlast;

    // FFT events
    wire evt_frame_started;
    wire evt_tlast_unexpected;
    wire evt_tlast_missing;
    wire evt_status_channel_halt;
    wire evt_data_in_channel_halt;
    wire evt_data_out_channel_halt;

    // ================================================================
    // H2C width adaptation: 128 -> 32
    // ================================================================
    assign fft_din_tdata  = {16'b0, h2c_tdata[15:0]};
    assign fft_din_tvalid = h2c_tvalid;
    assign fft_din_tlast  = h2c_tlast;
    assign h2c_tready     = fft_din_tready;

    // ================================================================
    // FFT config driver (same logic as top.v)
    // ================================================================
    reg cfg_sent;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cfg_sent <= 1'b0;
        else if (fft_cfg_tvalid && fft_cfg_tready)
            cfg_sent <= 1'b1;
        else if (fft_din_tvalid && fft_din_tready && fft_din_tlast)
            cfg_sent <= 1'b0;
    end

    assign fft_cfg_tdata  = CFG_WORD;
    assign fft_cfg_tvalid = ~cfg_sent;

    // ================================================================
    // FFT IP
    // ================================================================
    xfft_0 u_fft (
        .aclk                       (clk),
        .s_axis_config_tdata        (fft_cfg_tdata),
        .s_axis_config_tvalid       (fft_cfg_tvalid),
        .s_axis_config_tready       (fft_cfg_tready),
        .s_axis_data_tdata          (fft_din_tdata),
        .s_axis_data_tvalid         (fft_din_tvalid),
        .s_axis_data_tready         (fft_din_tready),
        .s_axis_data_tlast          (fft_din_tlast),
        .m_axis_data_tdata          (fft_dout_tdata),
        .m_axis_data_tvalid         (fft_dout_tvalid),
        .m_axis_data_tready         (fft_dout_tready),
        .m_axis_data_tlast          (fft_dout_tlast),
        .event_frame_started        (evt_frame_started),
        .event_tlast_unexpected     (evt_tlast_unexpected),
        .event_tlast_missing        (evt_tlast_missing),
        .event_status_channel_halt  (evt_status_channel_halt),
        .event_data_in_channel_halt (evt_data_in_channel_halt),
        .event_data_out_channel_halt(evt_data_out_channel_halt)
    );

    // ================================================================
    // Magnitude calculator
    // ================================================================
    magnitude_calc u_mag (
        .clk          (clk),
        .rst_n        (rst_n),
        .s_axis_tdata (fft_dout_tdata),
        .s_axis_tvalid(fft_dout_tvalid),
        .s_axis_tlast (fft_dout_tlast),
        .s_axis_tready(fft_dout_tready),
        .m_axis_tdata (mag_tdata),
        .m_axis_tvalid(mag_tvalid),
        .m_axis_tlast (mag_tlast),
        .m_axis_tready(mag_tready)
    );

    // ================================================================
    // C2H width adaptation: 16 -> 128
    // ================================================================
    assign c2h_tdata  = {112'b0, mag_tdata};
    assign c2h_tvalid = mag_tvalid;
    assign c2h_tlast  = mag_tlast;
    assign c2h_tkeep  = 16'hFFFF;
    assign mag_tready = c2h_tready;

    // ================================================================
    // Output capture (NBA)
    // ================================================================
    reg [15:0] out_buf [0:NFFT-1];
    integer    out_cnt;       // cumulative count across all frames
    integer    frame_out_cnt; // per-frame count
    integer    frame_idx;     // which output frame we're on
    reg        out_tlast_seen;

    initial begin
        out_cnt = 0;
        frame_out_cnt = 0;
        frame_idx = 0;
        out_tlast_seen = 0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            // don't reset out_cnt — cumulative
            frame_out_cnt <= 0;
            out_tlast_seen <= 0;
        end else if (c2h_tvalid && c2h_tready) begin
            out_buf[frame_out_cnt] <= c2h_tdata[15:0];
            out_cnt <= out_cnt + 1;
            frame_out_cnt <= frame_out_cnt + 1;
            if (c2h_tlast) begin
                out_tlast_seen <= 1;
                frame_idx <= frame_idx + 1;
            end
        end
    end

    // ================================================================
    // Sine-wave ROM generation (compile-time)
    // ================================================================
    // Generate signed 16-bit sine samples: A * sin(2*pi*bin*n/NFFT)
    // Use $sin in tasks below

    // ================================================================
    // Sender tasks — blocking @ negedge (Xilinx IP requirement)
    // ================================================================

    task send_h2c_sample(input [15:0] sample, input last);
        begin
            @(negedge clk);
            h2c_tdata  = {112'b0, sample};
            h2c_tvalid = 1;
            h2c_tlast  = last;
            @(posedge clk);
            while (!h2c_tready) @(posedge clk);
            @(negedge clk);
            h2c_tvalid = 0;
            h2c_tlast  = 0;
        end
    endtask

    task send_frame(input integer bin, input integer amplitude);
        integer i;
        reg signed [15:0] sample;
        real phase;
        begin
            for (i = 0; i < NFFT; i = i + 1) begin
                phase = 2.0 * 3.14159265358979 * bin * i / NFFT;
                sample = $rtoi($sin(phase) * amplitude);
                send_h2c_sample(sample, (i == NFFT - 1) ? 1 : 0);
            end
        end
    endtask

    task send_zero_frame;
        integer i;
        begin
            for (i = 0; i < NFFT; i = i + 1) begin
                send_h2c_sample(16'h0000, (i == NFFT - 1) ? 1 : 0);
            end
        end
    endtask

    task wait_frame_output;
        begin
            // Wait until out_tlast_seen is set, then clear it
            @(posedge clk);
            while (!out_tlast_seen) @(posedge clk);
            @(negedge clk);
            out_tlast_seen = 0;
            frame_out_cnt = 0;
        end
    endtask

    // ================================================================
    // Analysis helpers
    // ================================================================
    integer peak_bin;
    integer peak_val;
    integer noise_sum;
    integer noise_cnt;

    task analyze_frame(input integer expected_bin);
        integer k;
        begin
            peak_bin = 0;
            peak_val = 0;
            noise_sum = 0;
            noise_cnt = 0;
            for (k = 0; k < NFFT; k = k + 1) begin
                if (out_buf[k] > peak_val) begin
                    peak_val = out_buf[k];
                    peak_bin = k;
                end
                if (k != expected_bin && k != (NFFT - expected_bin))
                    noise_sum = noise_sum + out_buf[k];
            end
            noise_cnt = NFFT - 2;
            $display("  Peak: bin=%0d val=%0d  Noise_avg=%0d",
                     peak_bin, peak_val, noise_sum / noise_cnt);
            if (peak_bin != expected_bin) begin
                $display("  FAIL: expected peak at bin %0d, got bin %0d",
                         expected_bin, peak_bin);
                $stop;
            end else begin
                $display("  PASS: peak at bin %0d", peak_bin);
            end
        end
    endtask

    // ================================================================
    // Main test sequence
    // ================================================================
    integer tc;
    integer f;

    initial begin
        // Init
        h2c_tdata  = 0;
        h2c_tvalid = 0;
        h2c_tlast  = 0;
        c2h_tready = 1;

        // Reset
        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // ---- Warm-up frame (consume phantom config slot) ----
        $display("\n=== Warm-up: sending zero frame to consume phantom config slot ===");
        send_zero_frame;
        wait_frame_output;
        $display("  Warm-up frame received, discarded.\n");

        // ============================================================
        // TC-01: Single-frequency sine wave (bin 64)
        // ============================================================
        tc = 1;
        $display("=== TC-%02d: Single-frequency sine bin=64 ===", tc);
        send_frame(64, 16000);
        wait_frame_output;
        analyze_frame(64);

        // ============================================================
        // TC-02: Continuous 4 frames (bins 64, 128, 256, 32)
        // ============================================================
        tc = 2;
        $display("\n=== TC-%02d: Continuous 4 frames ===", tc);
        // Send all 4 frames back-to-back, collect outputs
        fork
            // Sender
            begin
                send_frame(64,  16000);
                send_frame(128, 16000);
                send_frame(256, 16000);
                send_frame(32,  16000);
            end
            // Receiver
            begin
                // Frame 1
                wait_frame_output;
                $display("  Frame 1:");
                analyze_frame(64);
                // Frame 2
                wait_frame_output;
                $display("  Frame 2:");
                analyze_frame(128);
                // Frame 3
                wait_frame_output;
                $display("  Frame 3:");
                analyze_frame(256);
                // Frame 4
                wait_frame_output;
                $display("  Frame 4:");
                analyze_frame(32);
            end
        join

        // Verify total output count: warm-up(1024) + TC01(1024) + TC02(4*1024) = 6144
        $display("  Total output samples: %0d (expected %0d)",
                 out_cnt, 6 * NFFT);
        if (out_cnt != 6 * NFFT) begin
            $display("  FAIL: output count mismatch");
            $stop;
        end
        $display("  TC-02 PASS\n");

        // ============================================================
        // TC-03: Reset recovery
        // ============================================================
        tc = 3;
        $display("=== TC-%02d: Reset recovery ===", tc);

        // Send 1 frame normally
        send_frame(64, 16000);
        wait_frame_output;
        $display("  Pre-reset frame OK");

        // Assert reset
        @(negedge clk);
        rst_n = 0;
        repeat (20) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // Warm-up again after reset (phantom config slot)
        $display("  Post-reset warm-up...");
        send_zero_frame;
        wait_frame_output;

        // Send frame and verify
        send_frame(64, 16000);
        wait_frame_output;
        analyze_frame(64);
        $display("  TC-03 PASS\n");

        // ============================================================
        // TC-04: Backpressure test
        // ============================================================
        tc = 4;
        $display("=== TC-%02d: Backpressure test ===", tc);

        // Enable backpressure pattern on c2h_tready (deterministic)
        fork
            // Sender
            begin
                send_frame(64, 16000);
            end
            // Backpressure generator (negedge driven, deterministic)
            begin : bp_gen
                integer bp_cnt;
                bp_cnt = 0;
                while (1) begin
                    @(negedge clk);
                    // Pattern: 4 cycles ready, 2 cycles not ready
                    bp_cnt = bp_cnt + 1;
                    if (bp_cnt % 6 < 4)
                        c2h_tready = 1;
                    else
                        c2h_tready = 0;
                end
            end
            // Receiver
            begin
                wait_frame_output;
                disable bp_gen;
            end
        join
        @(negedge clk);
        c2h_tready = 1;

        analyze_frame(64);
        $display("  TC-04 PASS\n");

        // ============================================================
        // All done
        // ============================================================
        $display("========================================");
        $display(" All TC-01~04 PASSED");
        $display("========================================");
        $finish;
    end

    // ================================================================
    // Timeout watchdog
    // ================================================================
    initial begin
        #(CLK_PERIOD * 500000);
        $display("TIMEOUT: simulation exceeded watchdog limit");
        $finish;
    end

endmodule
