// top.v — XDMA + FFT Spectrum Analyzer Top-Level
// Instantiates: clk_wiz_0, xdma_subsystem_wrapper, xfft_0, magnitude_calc
// All user logic runs in clk_100m domain (100 MHz)

module top (
    // System clock (100 MHz differential)
    input  wire        sys_clk_p,
    input  wire        sys_clk_n,

    // PCIe interface
    input  wire        pcie_refclk_p,
    input  wire        pcie_refclk_n,
    input  wire        pcie_perstn,
    input  wire [3:0]  pcie_rxp,
    input  wire [3:0]  pcie_rxn,
    output wire [3:0]  pcie_txp,
    output wire [3:0]  pcie_txn,

    // Status
    output wire        led_link_up
);

    // ================================================================
    // Internal signals
    // ================================================================
    wire        clk_100m;
    wire        clk_locked;
    wire        rst_n;          // Reset: pcie_perstn & clk_locked

    // H2C AXI-Stream (128-bit, from BD)
    wire [127:0] h2c_tdata;
    wire [15:0]  h2c_tkeep;
    wire         h2c_tlast;
    wire         h2c_tvalid;
    wire         h2c_tready;

    // C2H AXI-Stream (128-bit, to BD)
    wire [127:0] c2h_tdata;
    wire [15:0]  c2h_tkeep;
    wire         c2h_tlast;
    wire         c2h_tvalid;
    wire         c2h_tready;

    // FFT config channel
    wire [15:0]  fft_cfg_tdata;
    wire         fft_cfg_tvalid;
    wire         fft_cfg_tready;

    // FFT data input (32-bit: {Im[31:16], Re[15:0]})
    wire [31:0]  fft_din_tdata;
    wire         fft_din_tvalid;
    wire         fft_din_tready;
    wire         fft_din_tlast;

    // FFT data output (32-bit)
    wire [31:0]  fft_dout_tdata;
    wire         fft_dout_tvalid;
    wire         fft_dout_tready;
    wire         fft_dout_tlast;

    // Magnitude output (16-bit)
    wire [15:0]  mag_tdata;
    wire         mag_tvalid;
    wire         mag_tready;
    wire         mag_tlast;

    // Link-up status (active-high from XDMA)
    wire         user_lnk_up_i;

    // FFT event signals (unused, keep for debug)
    wire         evt_frame_started;
    wire         evt_tlast_unexpected;
    wire         evt_tlast_missing;
    wire         evt_status_channel_halt;
    wire         evt_data_in_channel_halt;
    wire         evt_data_out_channel_halt;

    // ================================================================
    // Combined reset
    // ================================================================
    assign rst_n = pcie_perstn & clk_locked;

    // LED active-low: light on when link up
    assign led_link_up = ~user_lnk_up_i;

    // ================================================================
    // Clock Wizard: 100 MHz differential -> 100 MHz single-ended
    // ================================================================
    clk_wiz_0 u_clk_wiz (
        .clk_out1   (clk_100m),
        .resetn     (pcie_perstn),
        .locked     (clk_locked),
        .clk_in1_p  (sys_clk_p),
        .clk_in1_n  (sys_clk_n)
    );

    // ================================================================
    // XDMA Subsystem (Block Design wrapper)
    // ================================================================
    xdma_subsystem_wrapper u_xdma (
        .clk_100m           (clk_100m),
        .clk_100m_locked    (clk_locked),
        .m_axis_h2c_tdata   (h2c_tdata),
        .m_axis_h2c_tkeep   (h2c_tkeep),
        .m_axis_h2c_tlast   (h2c_tlast),
        .m_axis_h2c_tready  (h2c_tready),
        .m_axis_h2c_tvalid  (h2c_tvalid),
        .pcie_mgt_rxn       (pcie_rxn),
        .pcie_mgt_rxp       (pcie_rxp),
        .pcie_mgt_txn       (pcie_txn),
        .pcie_mgt_txp       (pcie_txp),
        .pcie_perstn        (pcie_perstn),
        .pcie_refclk_clk_n  (pcie_refclk_n),
        .pcie_refclk_clk_p  (pcie_refclk_p),
        .s_axis_c2h_tdata   (c2h_tdata),
        .s_axis_c2h_tkeep   (c2h_tkeep),
        .s_axis_c2h_tlast   (c2h_tlast),
        .s_axis_c2h_tready  (c2h_tready),
        .s_axis_c2h_tvalid  (c2h_tvalid),
        .user_lnk_up        (user_lnk_up_i)
    );

    // ================================================================
    // H2C Width Adaptation: 128-bit -> 32-bit (extract low 16-bit PCM)
    // ================================================================
    assign fft_din_tdata  = {16'b0, h2c_tdata[15:0]};   // {Im=0, Re=PCM}
    assign fft_din_tvalid = h2c_tvalid;
    assign fft_din_tlast  = h2c_tlast;
    assign h2c_tready     = fft_din_tready;

    // ================================================================
    // FFT Config Driver
    // ================================================================
    // Config word: FWD=1, SCALE_SCH=10'b10_10_10_10_11 -> 16'h0557
    localparam [15:0] CFG_WORD = 16'h0557;

    reg cfg_sent;

    always @(posedge clk_100m or negedge rst_n) begin
        if (!rst_n)
            cfg_sent <= 1'b0;
        else if (fft_cfg_tvalid && fft_cfg_tready)
            cfg_sent <= 1'b1;
        else if (fft_din_tvalid && fft_din_tready && fft_din_tlast)
            cfg_sent <= 1'b0;   // Frame ended, prepare config for next frame
    end

    assign fft_cfg_tdata  = CFG_WORD;
    assign fft_cfg_tvalid = ~cfg_sent;

    // ================================================================
    // FFT IP (1024-point, Pipelined Streaming)
    // ================================================================
    xfft_0 u_fft (
        .aclk                       (clk_100m),
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
    // Magnitude Calculator
    // ================================================================
    magnitude_calc u_mag (
        .clk          (clk_100m),
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
    // C2H Width Adaptation: 16-bit -> 128-bit (zero-extend)
    // ================================================================
    assign c2h_tdata  = {112'b0, mag_tdata};
    assign c2h_tvalid = mag_tvalid;
    assign c2h_tlast  = mag_tlast;
    assign c2h_tkeep  = 16'hFFFF;
    assign mag_tready = c2h_tready;

endmodule
