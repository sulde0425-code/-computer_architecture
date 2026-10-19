module RegFiles (
    input  wire        clk,
    // 读端口 1 (连接 ID 阶段)
    input  wire [ 4:0] raddr1,
    output wire [31:0] rdata1,
    // 读端口 2 (连接 ID 阶段)
    input  wire [ 4:0] raddr2,
    output wire [31:0] rdata2,
    // 同步写端口 (连接 WB 阶段送回的数据)
    input  wire [ 4:0] waddr,
    input  wire [31:0] wdata,
    input  wire        wen,
    // 调试引脚
    output wire [31:0] io_a0_val
);

    reg [31:0] rf [0:31];

    // ==========================================
    // 1. 同步写逻辑：在时钟上升沿写入 (x0 寄存器禁止写入)
    // ==========================================
    always @(posedge clk) begin
        if (wen && (waddr != 5'b0)) begin
            rf[waddr] <= wdata;
        end
    end

    // ==========================================
    // 2. 异步读逻辑：集成内部写直通 (Internal Forwarding)
    // 优先级：x0 恒为 0 > 读写冲突时优先直通 wdata > 读寄存器堆阵列
    // ==========================================
    assign rdata1 = (raddr1 == 5'b0)                 ? 32'h0 :
                    (wen && (raddr1 == waddr))       ? wdata : rf[raddr1];

    assign rdata2 = (raddr2 == 5'b0)                 ? 32'h0 :
                    (wen && (raddr2 == waddr))       ? wdata : rf[raddr2];

    // 暴露 a0 ($10) 给 ebreak 检查
    assign io_a0_val = (waddr == 5'd10 && wen) ? wdata : rf[5'd10];

endmodule