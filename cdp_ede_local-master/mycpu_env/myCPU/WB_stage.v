`include "mycpu_h.v"

module WB_stage(
    input  wire                         clk,
    input  wire                         reset,

    // ---------------- 流水线握手信号 ----------------
    output wire                         ws_allowin,     // 送往 MEM 级的反压信号
    input  wire                         ms_to_ws_valid, // 来自 MEM 级的有效信号
    input  wire [`MS_TO_WS_BUS_WD-1:0]  ms_to_ws_bus,   // 来自 MEM 级的流水总线

    // ---------------- 送回 ID 级的通用寄存器堆写端口 ----------------
    output wire [`WS_TO_RF_BUS_WD-1:0]  ws_to_rf_bus,

    // ---------------- 调试/比对追踪接口 ----------------
    output wire [31:0]                  debug_wb_pc,
    output wire [ 3:0]                  debug_wb_rf_wen,
    output wire [ 4:0]                  debug_wb_rf_wnum,
    output wire [31:0]                  debug_wb_rf_wdata,

    // ---------------- 数据前递（转发）接口 ----------------
    output wire                         ws_forward_valid,
    output wire [ 4:0]                  ws_forward_dest,
    output wire [31:0]                  ws_forward_data
);

    // ==========================================
    // 1. 流水级握手与级间寄存器 (遵照指导书规范)
    // ==========================================
    reg         ws_valid;
    wire        ws_ready_go;

    // 写回级为流水线最后一级，无下游反压，ready_go 恒为 1
    assign ws_ready_go = 1'b1;
    assign ws_allowin  = !ws_valid || ws_ready_go;

    reg [`MS_TO_WS_BUS_WD-1:0] ms_to_ws_bus_r;

    always @(posedge clk) begin
        if (reset) begin
            ws_valid <= 1'b0;
        end else if (ws_allowin) begin
            ws_valid <= ms_to_ws_valid;
        end

        if (ms_to_ws_valid && ws_allowin) begin
            ms_to_ws_bus_r <= ms_to_ws_bus;
        end
    end

    // ==========================================
    // 2. 解包来自 MEM 级的总线
    // ==========================================
    wire        ws_reg_write_en;
    wire [ 4:0] ws_rd;
    wire [31:0] ws_final_result;
    wire [31:0] ws_pc;

    assign {
        ws_reg_write_en,
        ws_rd,
        ws_final_result,
        ws_pc
    } = ms_to_ws_bus_r;

    // ==========================================
    // 3. 生成写寄存器堆控制信号
    // ==========================================
    // 保护逻辑：仅在指令有效、声明写使能，且写目标不是 x0 (rd != 0) 时写使能有效
    wire        rf_we;
    wire [ 4:0] rf_waddr;
    wire [31:0] rf_wdata;

    assign rf_we    = ws_valid && ws_reg_write_en && (ws_rd != 5'd0);
    assign rf_waddr = ws_rd;
    assign rf_wdata = ws_final_result;

    // 打包送往 ID 级寄存器堆
    assign ws_to_rf_bus = {
        rf_we,      // 1 bit
        rf_waddr,   // 5 bit
        rf_wdata    // 32 bit
    };

    // ==========================================
    // 4. 对接仿真验证环境的 Debug Trace
    // ==========================================
    assign debug_wb_pc       = ws_pc;
    assign debug_wb_rf_wen   = {4{rf_we}}; // 仿真平台通常采用 4 位字节写掩码
    assign debug_wb_rf_wnum  = rf_waddr;
    assign debug_wb_rf_wdata = rf_wdata;

    // ==========================================
    // 5. 数据前递（转发）输出
    // ==========================================
    assign ws_forward_valid = ws_valid && ws_reg_write_en && (ws_rd != 5'd0);
    assign ws_forward_dest  = ws_rd;
    assign ws_forward_data  = ws_final_result;

endmodule