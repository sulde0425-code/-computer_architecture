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
    // 五级流水线各个阶段例化
    // ==========================================

    // 取指级 (IF)
    IF_stage if_stage (
        .clk             (clk),
        .reset           (reset),

        .ds_allowin      (ds_allowin),
        .fs_to_ds_valid  (fs_to_ds_valid),
        .fs_to_ds_bus    (fs_to_ds_bus),

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
        .ms_forward_valid (ms_forward_valid),
        .ms_forward_dest  (ms_forward_dest),
        .ms_forward_data  (ms_forward_data),
        .ms_forward_is_load (ms_forward_is_load),
        .ms_forward_data_alu (ms_forward_data_alu),
        .ws_forward_valid (ws_forward_valid),
        .ws_forward_dest  (ws_forward_dest),
        .ws_forward_data  (ws_forward_data)
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
        .es_is_mul        (es_is_mul)
    );

    // 访存级 (MEM)
    MEM_stage mem_stage (
        .clk             (clk),
        .reset           (reset),

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
        .ws_forward_data  (ws_forward_data)
    );

endmodule