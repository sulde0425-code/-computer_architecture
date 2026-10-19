`include "mycpu_h.v"

module MEM_stage(
    input  wire                         clk,
    input  wire                         reset,

    // ---------------- 流水线握手信号 ----------------
    input  wire                         ws_allowin,     // 来自 WB 级的反压信号
    output wire                         ms_allowin,     // 送往 EXE 级的反压信号
    input  wire                         es_to_ms_valid, // 来自 EXE 级的有效信号
    input  wire [`ES_TO_MS_BUS_WD-1:0]  es_to_ms_bus,   // 来自 EXE 级的流水总线
    output wire                         ms_to_ws_valid, // 送往 WB 级的有效信号
    output wire [`MS_TO_WS_BUS_WD-1:0]  ms_to_ws_bus,   // 送往 WB 级的流水总线

    // ---------------- 接收来自数据 RAM 的读数据 ----------------
    input  wire [31:0]                  data_sram_rdata,

    // ---------------- 数据前递（转发）接口 ----------------
    output wire                         ms_forward_valid,
    output wire [ 4:0]                  ms_forward_dest,
    output wire [31:0]                  ms_forward_data,
    output wire                         ms_forward_is_load, // 本级是 load（前递值来自 data_ram）
    output wire [31:0]                  ms_forward_data_alu  // 本级 ALU 结果（与 data_ram 无关，供分支用）
);

    // ==========================================
    // 1. 流水级握手与级间寄存器
    // ==========================================
    reg         ms_valid;
    wire        ms_ready_go;

    // 第一章不考虑访存等待，恒置为 1
    assign ms_ready_go    = 1'b1;
    assign ms_allowin     = !ms_valid || (ms_ready_go && ws_allowin);
    assign ms_to_ws_valid = ms_valid && ms_ready_go;

    reg [`ES_TO_MS_BUS_WD-1:0] es_to_ms_bus_r;

    always @(posedge clk) begin
        if (reset) begin
            ms_valid <= 1'b0;
        end else if (ms_allowin) begin
            ms_valid <= es_to_ms_valid;
        end

        if (es_to_ms_valid && ms_allowin) begin
            es_to_ms_bus_r <= es_to_ms_bus;
        end
    end

    // ==========================================
    // 2. 解包来自 EXE 级的总线（与 EXE_stage 打包顺序一致）
    // ==========================================
    wire        ms_res_from_mem;
    wire        ms_gr_we;
    wire [ 2:0] ms_mem_size;    // 1=字节 2=半字 4=字
    wire        ms_ld_signed;   // load 是否符号扩展
    wire [ 4:0] ms_dest;
    wire [31:0] ms_alu_result;
    wire [31:0] ms_pc;

    assign {
        ms_res_from_mem, // 1 bit
        ms_gr_we,        // 1 bit
        ms_mem_size,     // 3 bit
        ms_ld_signed,    // 1 bit
        ms_dest,         // 5 bit
        ms_alu_result,   // 32 bit
        ms_pc            // 32 bit
    } = es_to_ms_bus_r;

    // ==========================================
    // 3. 汇总本级最终写回值
    //    load 类需要按访存地址低两位（小端）从整字中选出字节/半字，
    //    再按指令类型做符号扩展（ld.b/ld.h）或零扩展（ld.bu/ld.hu）。
    // ==========================================
    wire [ 1:0] ms_addr_low = ms_alu_result[1:0];

    // 字节选取：00/01/10/11 -> byte0/1/2/3
    wire [ 7:0] ld_byte = (ms_addr_low == 2'b00) ? data_sram_rdata[ 7: 0] :
                          (ms_addr_low == 2'b01) ? data_sram_rdata[15: 8] :
                          (ms_addr_low == 2'b10) ? data_sram_rdata[23:16] :
                                                   data_sram_rdata[31:24];
    // 半字选取：地址 bit1 = 0 取低半字，=1 取高半字
    wire [15:0] ld_half = ms_addr_low[1] ? data_sram_rdata[31:16]
                                         : data_sram_rdata[15: 0];

    wire [31:0] mem_load_data = (ms_mem_size == 3'd1) ?
                                    (ms_ld_signed ? {{24{ld_byte[7]}},  ld_byte}  :
                                                    {24'b0,             ld_byte}) :
                                (ms_mem_size == 3'd2) ?
                                    (ms_ld_signed ? {{16{ld_half[15]}}, ld_half}  :
                                                    {16'b0,             ld_half}) :
                                    data_sram_rdata;   // 字访问直接取整字

    wire [31:0] ms_final_result = ms_res_from_mem ? mem_load_data : ms_alu_result;

    // ==========================================
    // 4. 打包总线并传递给 WB 阶段
    // ==========================================
    assign ms_to_ws_bus = {
        ms_gr_we,        // 1 bit: 寄存器写回使能
        ms_dest,         // 5 bit: 目标寄存器号
        ms_final_result, // 32 bit: 最终写回数据
        ms_pc            // 32 bit: 调试追踪 PC
    };

    // ==========================================
    // 5. 数据前递（转发）输出
    // ==========================================
    assign ms_forward_valid = ms_valid && ms_gr_we && (ms_dest != 5'd0);
    assign ms_forward_dest  = ms_dest;
    assign ms_forward_data  = ms_final_result;
    // 前递值是否来自数据 RAM。ID 级用它做一条保守冒险规则：分支指令不消费
    // "MEM 级 load 的前递值"，而是再多等一拍从 WB 级寄存器取。原因见 ID_stage.v
    // 中 branch_load_stall 的说明（切断 data_ram->inst_ram 的长组合路径）。
    assign ms_forward_is_load = ms_valid && ms_res_from_mem;

    // ==========================================
    // 6. 供"分支/跳转"使用的无 BRAM 前递值（第 5 章·时序修复）
    // ==========================================
    // ms_forward_data 对 load 指令 = data_ram 的读数据，其组合锥从 BRAM 输出出发
    // 并带一级字节选取 + 符号/零扩展。如果这种值进入 ID 级的分支比较/转移目标加法，
    // 就会连成 data_ram(BRAM) -> ... -> inst_ram(ENARDEN) 的跨器件长路径（实测 20.2ns）。
    // 这里单独引出一条 ms_alu_result（直接来自 es_to_ms_bus_r 触发器，与 data_ram 无关），
    // 供 ID 级的分支通路使用，从而在物理上切断上述长路径。
    // 本级是 load 时该值无意义，由 ID 级 branch_load_stall 保证它不会被选中。
    assign ms_forward_data_alu = ms_alu_result;

endmodule
