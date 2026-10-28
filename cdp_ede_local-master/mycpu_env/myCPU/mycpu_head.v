`include "mycpu_h.v"

module mycpu_top(
    input  wire        clk,
    input  wire        resetn,

    // 1. 指令 RAM 接口 (由 IF 阶段驱动和接收)
    output wire        inst_sram_en,
    output wire [ 3:0] inst_sram_we,
    output wire [31:0] inst_sram_addr,
    output wire [31:0] inst_sram_wdata,
    input  wire [31:0] inst_sram_rdata,

    // 2. 数据 RAM 接口 (由 EXE/MEM 阶段驱动和接收)
    output wire        data_sram_en,
    output wire [ 3:0] data_sram_we,
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata,
    input  wire [31:0] data_sram_rdata,

    // 3. 仿真与上板 Trace 调试比对接口 (由 WB 阶段提供)
    output wire [31:0] debug_wb_pc,
    output wire [ 3:0] debug_wb_rf_we,
    output wire [ 4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata
);

    // 内部生成高电平有效复位信号
    wire reset;
    assign reset = ~resetn;

    // ==========================================
    // 流水线级间握手与数据总线定义
    // ==========================================
    // IF <-> ID
    wire                        fs_to_ds_valid;
    wire [`FS_TO_DS_BUS_WD-1:0] fs_to_ds_bus;
    wire                        ds_allowin;
    wire [`BR_BUS_WD-1:0]       br_bus;

    // ID <-> EXE
    wire                        ds_to_es_valid;
    wire [`DS_TO_ES_BUS_WD-1:0] ds_to_es_bus;
    wire                        es_allowin;

    // EXE <-> MEM
    wire                        es_to_ms_valid;
    wire [`ES_TO_MS_BUS_WD-1:0] es_to_ms_bus;
    wire                        ms_allowin;

    // MEM <-> WB
    wire                        ms_to_ws_valid;
    wire [`MS_TO_WS_BUS_WD-1:0] ms_to_ws_bus;
    wire                        ws_allowin;

    // WB -> ID (寄存器写回总线)
    wire [`WS_TO_RF_BUS_WD-1:0] ws_to_rf_bus;

    // 数据前递（转发）信号：EXE/MEM/WB -> ID
    wire        es_forward_valid;
    wire [ 4:0] es_forward_dest;
    wire [31:0] es_forward_data;
    wire        es_is_load;
    wire        es_is_div;      // 第 5 章：EXE 级是除/取模指令
    wire        es_div_ready;   // 第 5 章：该除法结果已就绪
    wire        es_is_mul;      // 第 5 章：EXE 级是乘法指令（结果只从 MEM 前递）
    wire        ms_forward_valid;
    wire [ 4:0] ms_forward_dest;
    wire [31:0] ms_forward_data;
    wire        ms_forward_is_load; // 第 5 章·时序修复：MEM 级前递值是否来自数据 RAM
    wire [31:0] ms_forward_data_alu;// 第 5 章·时序修复：MEM 级纯 ALU 结果（与 data_ram 无关）
    wire        ws_forward_valid;
    wire [ 4:0] ws_forward_dest;
    wire [31:0] ws_forward_data;

    // ==========================================
    // 第 6 章：控制状态寄存器（CSR）与异常通路
    // ==========================================
    // 指令访问接口（由 EXE 级驱动，读写都在 EXE 级完成）
    wire        csr_re;
    wire [13:0] csr_num;
    wire [31:0] csr_rvalue;
    wire        csr_we;
    wire [31:0] csr_wmask;
    wire [31:0] csr_wvalue;

    // 与处理器内部硬件直接交互的接口
    wire [31:0] ex_entry;      // 异常处理程序入口地址
    wire [31:0] era_pc;        // ERTN 返回地址
    wire        has_int;       // 核内中断有效
    // 第 6 章扩展档：定时器 / 稳定计数器 / TID
    wire [63:0] counter;       // 64 位稳定计数器（rdcntvl.w / rdcntvh.w）
    wire [31:0] tid;           // CSR.TID（rdcntid）
    // 本 SoC 没有外部中断引脚，硬中断与核间中断恒 0
    // （定时器中断与两个软中断由 CSR 内部产生，不受此影响）
    wire [ 7:0] hw_int_in = 8'b0;
    wire        ipi_int_in = 1'b0;

    wire        wb_ex;         // 写回级报出异常
    wire [ 5:0] wb_ecode;
    wire [ 8:0] wb_esubcode;
    wire [31:0] wb_pc;
    wire [31:0] wb_badv;
    wire        wb_ertn_flush; // ERTN 在写回级执行有效

    // 全局清空：异常与 ERTN 都会清空所有流水级并改指取指 PC
    wire        flush        = wb_ex | wb_ertn_flush;
    wire [31:0] flush_pc     = wb_ex ? ex_entry : era_pc;

    // 控制状态寄存器模块
    csr u_csr (
        .clk         (clk        ),
        .reset       (reset      ),

        .csr_re      (csr_re     ),
        .csr_num     (csr_num    ),
        .csr_rvalue  (csr_rvalue ),
        .csr_we      (csr_we     ),
        .csr_wmask   (csr_wmask  ),
        .csr_wvalue  (csr_wvalue ),

        .ex_entry    (ex_entry   ),
        .era_pc      (era_pc     ),
        .has_int     (has_int    ),
        .counter     (counter    ),
        .tid         (tid        ),

        .hw_int_in   (hw_int_in  ),
        .ipi_int_in  (ipi_int_in ),

        .ertn_flush  (wb_ertn_flush),
        .wb_ex       (wb_ex      ),
        .wb_ecode    (wb_ecode   ),
        .wb_esubcode (wb_esubcode),
        .wb_pc       (wb_pc      ),
        .wb_badv     (wb_badv    )
    );

    // ==========================================
    // 五级流水线各个阶段例化
    // ==========================================

    // 取指级 (IF)
    IF_stage if_stage (
        .clk             (clk),
        .reset           (reset),

        .ds_allowin      (ds_allowin),
        .fs_to_ds_valid  (fs_to_ds_valid),
        .fs_to_ds_bus    (fs_to_ds_bus),

        .flush           (flush),
        .flush_pc        (flush_pc),
        .br_bus          (br_bus),

        .inst_sram_en    (inst_sram_en),
        .inst_sram_we    (inst_sram_we),
        .inst_sram_addr  (inst_sram_addr),
        .inst_sram_wdata (inst_sram_wdata),
        .inst_sram_rdata (inst_sram_rdata)
    );

    // 译码级 (ID)
    ID_stage id_stage (
        .clk             (clk),
        .reset           (reset),

        .es_allowin      (es_allowin),
        .ds_allowin      (ds_allowin),
        .fs_to_ds_valid  (fs_to_ds_valid),
        .fs_to_ds_bus    (fs_to_ds_bus),
        .ds_to_es_valid  (ds_to_es_valid),
        .ds_to_es_bus    (ds_to_es_bus),

        .br_bus          (br_bus),
        .ws_to_rf_bus    (ws_to_rf_bus),

        .es_forward_valid (es_forward_valid),
        .es_forward_dest  (es_forward_dest),
        .es_forward_data  (es_forward_data),
        .es_is_load       (es_is_load),
        .es_is_div        (es_is_div),
        .es_div_ready     (es_div_ready),
        .es_is_mul        (es_is_mul),
        .es_is_csr        (es_is_csr),
        .has_int          (has_int),      // 第 6 章扩展档：中断有效
        .counter          (counter),      // 第 6 章扩展档：稳定计数器
        .tid              (tid),          // 第 6 章扩展档：CSR.TID
        .ms_forward_valid (ms_forward_valid),
        .ms_forward_dest  (ms_forward_dest),
        .ms_forward_data  (ms_forward_data),
        .ms_forward_is_load (ms_forward_is_load),
        .ms_forward_data_alu (ms_forward_data_alu),
        .ws_forward_valid (ws_forward_valid),
        .ws_forward_dest  (ws_forward_dest),
        .ws_forward_data  (ws_forward_data),

        .flush           (flush)
    );

    // 执行级 (EXE)
    EXE_stage exe_stage (
        .clk             (clk),
        .reset           (reset),

        .ms_allowin      (ms_allowin),
        .es_allowin      (es_allowin),
        .ds_to_es_valid  (ds_to_es_valid),
        .ds_to_es_bus    (ds_to_es_bus),
        .es_to_ms_valid  (es_to_ms_valid),
        .es_to_ms_bus    (es_to_ms_bus),

        .data_sram_en    (data_sram_en),
        .data_sram_we    (data_sram_we),
        .data_sram_addr  (data_sram_addr),
        .data_sram_wdata (data_sram_wdata),

        .es_forward_valid (es_forward_valid),
        .es_forward_dest  (es_forward_dest),
        .es_forward_data  (es_forward_data),
        .es_is_load       (es_is_load),
        .es_is_div        (es_is_div),
        .es_div_ready     (es_div_ready),
        .es_is_mul        (es_is_mul),
        .es_is_csr        (es_is_csr),

        .csr_re          (csr_re),
        .csr_num         (csr_num),
        .csr_rvalue      (csr_rvalue),
        .csr_we          (csr_we),
        .csr_wmask       (csr_wmask),
        .csr_wvalue      (csr_wvalue),

        .flush           (flush)
    );

    // 访存级 (MEM)
    MEM_stage mem_stage (
        .clk             (clk),
        .reset           (reset),

        .flush           (flush),
        .ws_allowin      (ws_allowin),
        .ms_allowin      (ms_allowin),
        .es_to_ms_valid  (es_to_ms_valid),
        .es_to_ms_bus    (es_to_ms_bus),
        .ms_to_ws_valid  (ms_to_ws_valid),
        .ms_to_ws_bus    (ms_to_ws_bus),

        .data_sram_rdata (data_sram_rdata),

        .ms_forward_valid (ms_forward_valid),
        .ms_forward_dest  (ms_forward_dest),
        .ms_forward_data  (ms_forward_data),
        .ms_forward_is_load (ms_forward_is_load),
        .ms_forward_data_alu (ms_forward_data_alu)
    );

    // 写回级 (WB)
    WB_stage wb_stage (
        .clk               (clk),
        .reset             (reset),

        .ws_allowin        (ws_allowin),
        .ms_to_ws_valid    (ms_to_ws_valid),
        .ms_to_ws_bus      (ms_to_ws_bus),

        .ws_to_rf_bus      (ws_to_rf_bus),

        .debug_wb_pc       (debug_wb_pc),
        .debug_wb_rf_wen   (debug_wb_rf_we),
        .debug_wb_rf_wnum  (debug_wb_rf_wnum),
        .debug_wb_rf_wdata (debug_wb_rf_wdata),

        .ws_forward_valid (ws_forward_valid),
        .ws_forward_dest  (ws_forward_dest),
        .ws_forward_data  (ws_forward_data),

        .wb_ex           (wb_ex),
        .wb_ecode        (wb_ecode),
        .wb_esubcode     (wb_esubcode),
        .wb_pc           (wb_pc),
        .wb_badv         (wb_badv),
        .wb_ertn_flush   (wb_ertn_flush)
    );

endmodule