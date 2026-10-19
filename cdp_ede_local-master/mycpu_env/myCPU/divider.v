//============================================================================
// divider.v —— 32 位整数除法器（Radix-2 恢复余数法，迭代 32 拍出结果）
//
// 说明：
//   指导书 §5.1 建议调用 Xilinx 的 Divider Generator IP（Radix2 算法）。
//   本模块用纯 Verilog 实现了同样功能的电路级除法器（指导书 §5.2 允许的
//   做法），好处是不依赖任何 IP，仿真与上板都能直接使用。
//
//   接口完全按照 Divider Generator 的 AXI-Stream 形式定义，因此如果之后
//   想换成 IP 核，只需用 IP Catalog 生成一个同名（或改例化名）的除法器，
//   端口保持下面这套名字即可直接替换，EXE 级无需改动。
//
//   ── 输入通道（被除数 / 除数）──
//     s_axis_dividend_tvalid / tready / tdata[31:0]
//     s_axis_divisor_tvalid  / tready / tdata[31:0]
//     * 两个通道必须"同时"握手成功（同一上升沿看到 tvalid 与 tready 都为 1）。
//     * 握手成功后调用方必须撤销 tvalid，否则会被当成一次新的除法请求。
//
//   ── 输出通道 ──
//     m_axis_dout_tvalid —— 结果有效，只持续 1 拍
//     m_axis_dout_tdata[63:32] = 商，m_axis_dout_tdata[31:0] = 余数
//
//   SIGNED = 1 → 有符号除：商向零取整，余数与被除数同号（LA32R 规定）
//   SIGNED = 0 → 无符号除
//
//   除数为 0 时结果为任意值，不触发任何异常（LA32R 规定），本实现返回
//   商 = 0xFFFFFFFF、余数 = 被除数。
//============================================================================
module divider #(
    parameter SIGNED = 1        // 1 = 有符号除法器，0 = 无符号除法器
)(
    input  wire        clk,
    input  wire        resetn,   // 低电平有效复位

    // 被除数输入通道
    input  wire        s_axis_dividend_tvalid,
    output wire        s_axis_dividend_tready,
    input  wire [31:0] s_axis_dividend_tdata,

    // 除数输入通道
    input  wire        s_axis_divisor_tvalid,
    output wire        s_axis_divisor_tready,
    input  wire [31:0] s_axis_divisor_tdata,

    // 结果输出通道
    output wire        m_axis_dout_tvalid,
    output wire [63:0] m_axis_dout_tdata
);

    localparam S_IDLE = 1'b0;
    localparam S_BUSY = 1'b1;

    reg        state;
    reg        dout_valid_r;
    reg [63:0] dout_r;

    reg [31:0] dividend_r;   // 被除数绝对值，逐拍左移取最高位
    reg [31:0] divisor_r;    // 除数绝对值
    reg [32:0] rem_r;        // 余数寄存器（多 1 位容纳移位）
    reg [31:0] quo_r;        // 商（绝对值，逐拍从低位补入）
    reg [ 5:0] cnt;          // 剩余迭代次数
    reg        quo_sign;     // 商符号（被除数符号 ^ 除数符号）
    reg        rem_sign;     // 余数符号（与被除数一致）

    //------------------------------------------------------------------------
    // 输入通道：只有空闲时才接收
    //------------------------------------------------------------------------
    assign s_axis_dividend_tready = (state == S_IDLE);
    assign s_axis_divisor_tready  = (state == S_IDLE);

    wire in_handshake = s_axis_dividend_tvalid & s_axis_divisor_tvalid
                      & (state == S_IDLE);

    assign m_axis_dout_tvalid = dout_valid_r;
    assign m_axis_dout_tdata  = dout_r;

    //------------------------------------------------------------------------
    // 取绝对值（只有有符号除法器需要）
    //------------------------------------------------------------------------
    wire [31:0] dividend_abs =
        (SIGNED && s_axis_dividend_tdata[31]) ? (~s_axis_dividend_tdata + 32'b1)
                                              :  s_axis_dividend_tdata;
    wire [31:0] divisor_abs  =
        (SIGNED && s_axis_divisor_tdata[31])  ? (~s_axis_divisor_tdata  + 32'b1)
                                              :  s_axis_divisor_tdata;

    //------------------------------------------------------------------------
    // 单拍迭代的组合逻辑（恢复余数法）
    //   rem_shift = {余数, 被除数当前最高位}
    //   若 rem_shift >= 除数 → 相减，商补 1；否则保持，商补 0
    //------------------------------------------------------------------------
    wire [32:0] rem_shift = {rem_r[31:0], dividend_r[31]};
    wire        rem_ge    = (rem_shift >= {1'b0, divisor_r});
    wire [32:0] rem_next  = rem_ge ? (rem_shift - {1'b0, divisor_r}) : rem_shift;
    wire [31:0] quo_next  = {quo_r[30:0], rem_ge};

    // 末拍结果：按符号还原（求相反数 = 取反加一）
    wire [31:0] quo_final = quo_sign ? (~quo_next        + 32'b1) : quo_next;
    wire [31:0] rem_final = rem_sign ? (~rem_next[31:0]  + 32'b1) : rem_next[31:0];

    //------------------------------------------------------------------------
    // 主状态机
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (~resetn) begin
            state        <= S_IDLE;
            dout_valid_r <= 1'b0;
            dout_r       <= 64'b0;
            dividend_r   <= 32'b0;
            divisor_r    <= 32'b0;
            rem_r        <= 33'b0;
            quo_r        <= 32'b0;
            cnt          <= 6'b0;
            quo_sign     <= 1'b0;
            rem_sign     <= 1'b0;
        end
        else if (state == S_IDLE) begin
            dout_valid_r <= 1'b0;                 // 输出脉冲只维持 1 拍
            if (in_handshake) begin
                dividend_r <= dividend_abs;
                divisor_r  <= divisor_abs;
                rem_r      <= 33'b0;
                quo_r      <= 32'b0;
                cnt        <= 6'd32;
                quo_sign   <= SIGNED ? (s_axis_dividend_tdata[31]
                                        ^ s_axis_divisor_tdata[31]) : 1'b0;
                rem_sign   <= SIGNED ?  s_axis_dividend_tdata[31]  : 1'b0;
                state      <= S_BUSY;
            end
        end
        else begin // S_BUSY：迭代 32 次
            rem_r      <= rem_next;
            quo_r      <= quo_next;
            dividend_r <= {dividend_r[30:0], 1'b0};
            if (cnt == 6'd1) begin
                state        <= S_IDLE;
                dout_valid_r <= 1'b1;
                dout_r       <= {quo_final, rem_final};
            end
            else begin
                cnt <= cnt - 6'd1;
            end
        end
    end

endmodule
