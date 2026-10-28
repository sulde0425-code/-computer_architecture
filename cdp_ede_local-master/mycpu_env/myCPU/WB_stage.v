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
    output wire [31:0]                  ws_forward_data,

    // ---------------- 第 6 章：异常报出接口 ----------------
    output wire                         wb_ex,        // 写回级指令触发异常
    output wire [ 5:0]                  wb_ecode,     // 异常代号
    output wire [ 8:0]                  wb_esubcode,  // 异常副代号
    output wire [31:0]                  wb_pc,        // 触发异常指令的 PC
    output wire [31:0]                  wb_badv,      // 触发异常指令的出错虚地址
    output wire                         wb_ertn_flush // ERTN 执行有效
);

    // ==========================================
    // 1. 流水级握手与级间寄存器 (遵照指导书规范)
    // ==========================================
    reg         ws_valid;
    wire        ws_ready_go;
    wire        flush;      // 第 6 章：异常 / ERTN 清空（在下面 2b 节赋值，此处先声明）

    // 写回级为流水线最后一级，无下游反压，ready_go 恒为 1
    assign ws_ready_go = 1'b1;
    assign ws_allowin  = !ws_valid || ws_ready_go;

    reg [`MS_TO_WS_BUS_WD-1:0] ms_to_ws_bus_r;

    always @(posedge clk) begin
        if (reset) begin
            ws_valid <= 1'b0;
        end else if (flush) begin
            // 第 6 章：报出异常 / ERTN 时，本级随所有流水级一起被清空
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
    wire        ws_ertn;          // 第 6 章：ERTN 指令
    wire [ 5:0] ws_ex_flags;      // 第 6 章扩展档：异常标志组 {adef,ale,sys,brk,ine,int}
    wire        ws_reg_write_en;
    wire [ 4:0] ws_rd;
    wire [31:0] ws_final_result;
    wire [31:0] ws_pc;

    assign {
        ws_ertn,
        ws_ex_flags,
        ws_reg_write_en,
        ws_rd,
        ws_final_result,
        ws_pc
    } = ms_to_ws_bus_r;

    // ========================================================================
    // 2b. 第 6 章：在写回级报出异常（精确异常）
    //   异常标志由译码级产生后一直随指令走到写回级才生效，这样能保证：
    //   "异常指令之前的所有指令都已完成，之后的所有指令都未产生架构状态修改"。
    //   报出异常的同时清空所有流水级，并把取指 PC 改指异常入口（由顶层完成）。
    // ========================================================================
    // 把随指令一路携带过来的异常标志编码成 Ecode / EsubCode。
    // 优先级：指令自身触发的异常优先于中断 ——
    //   若某条指令本身就非法，应当先报它的异常，而不是"顺手"响应一个中断。
    wire ws_ex_adef = ws_ex_flags[5];
    wire ws_ex_ale  = ws_ex_flags[4];
    wire ws_ex_sys  = ws_ex_flags[3];
    wire ws_ex_brk  = ws_ex_flags[2];
    wire ws_ex_ine  = ws_ex_flags[1];
    wire ws_ex_int  = ws_ex_flags[0];

    assign wb_ex        = ws_valid && (|ws_ex_flags);
    assign wb_ecode     = ws_ex_adef ? `ECODE_ADEF :   // 0x08 取指地址错
                          ws_ex_ale  ? `ECODE_ALE  :   // 0x09 地址非对齐
                          ws_ex_sys  ? `ECODE_SYS  :   // 0x0B 系统调用
                          ws_ex_brk  ? `ECODE_BRK  :   // 0x0C 断点
                          ws_ex_ine  ? `ECODE_INE  :   // 0x0D 指令不存在
                          ws_ex_int  ? `ECODE_INT  :   // 0x00 中断
                                        6'b0;
    assign wb_esubcode  = 9'b0;
    assign wb_pc        = ws_pc;
    // BADV：ADEF 记录出错的取指 PC；ALE 记录出错的访存地址；其余异常没有虚地址
    assign wb_badv      = ws_ex_adef ? ws_pc            :
                          ws_ex_ale  ? ws_final_result  : 32'b0;
    assign wb_ertn_flush= ws_valid && ws_ertn;

    assign flush = wb_ex | wb_ertn_flush;

    // ==========================================
    // 3. 生成写寄存器堆控制信号
    // ==========================================
    // 保护逻辑：仅在指令有效、声明写使能，且写目标不是 x0 (rd != 0) 时写使能有效
    wire        rf_we;
    wire [ 4:0] rf_waddr;
    wire [31:0] rf_wdata;

    // 第 6 章扩展档：触发异常/被中断打断的指令不得写回寄存器
    // （ID 级已经把 gr_we 清零过一次，这里再兜一道底）
    assign rf_we    = ws_valid && ws_reg_write_en && (ws_rd != 5'd0)
                      && !(|ws_ex_flags);
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