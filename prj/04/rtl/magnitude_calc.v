// magnitude_calc.v — L1 magnitude approximation: |Re| + |Im|
// Combinational pass-through AXI4-Stream, zero latency

module magnitude_calc #(
    parameter DATA_WIDTH = 32,   // FFT output tdata width (Re + Im concatenated)
    parameter OUT_WIDTH  = 16    // Output magnitude width (unsigned)
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // AXI4-Stream slave (from FFT output)
    input  wire [DATA_WIDTH-1:0]   s_axis_tdata,
    input  wire                    s_axis_tvalid,
    input  wire                    s_axis_tlast,
    output wire                    s_axis_tready,

    // AXI4-Stream master (to Output FIFO)
    output wire [OUT_WIDTH-1:0]    m_axis_tdata,
    output wire                    m_axis_tvalid,
    output wire                    m_axis_tlast,
    input  wire                    m_axis_tready
);

    // ---- Pass-through handshake (combinational) ----
    assign s_axis_tready = m_axis_tready;
    assign m_axis_tvalid = s_axis_tvalid;
    assign m_axis_tlast  = s_axis_tlast;

    // ---- Extract Re / Im (signed 16-bit) ----
    wire signed [15:0] re = s_axis_tdata[15:0];
    wire signed [15:0] im = s_axis_tdata[31:16];

    // ---- Sign-extend to 17-bit to handle -32768 correctly ----
    wire signed [16:0] re_ext = {re[15], re};
    wire signed [16:0] im_ext = {im[15], im};

    // ---- Absolute values (17-bit unsigned, range [0, 32768]) ----
    wire [16:0] abs_re = (re_ext < 0) ? -re_ext : re_ext;
    wire [16:0] abs_im = (im_ext < 0) ? -im_ext : im_ext;

    // ---- Sum (18-bit, max 65536) ----
    wire [17:0] mag_sum = abs_re + abs_im;

    // ---- Saturate to OUT_WIDTH bits ----
    assign m_axis_tdata = (mag_sum > {OUT_WIDTH{1'b1}}) ? {OUT_WIDTH{1'b1}} : mag_sum[OUT_WIDTH-1:0];

endmodule
