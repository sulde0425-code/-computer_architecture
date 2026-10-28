`include "mycpu_h.v"

module EXE_stage(
    input  wire                         clk,
    input  wire                         reset,

    // ---------------- 流水线握手信号 ----------------
    input  wire                         ms_allowin,     // 后级(MEM)允许接收
    output wire                         es_allowin,     // 本级允许前级(ID)送入
    input  wire                         ds_to_es_valid, // 前级(ID)数据有效
    input  wire [`DS_TO_ES_BUS_WD-1:0]  ds_to_es_bus,   // 前级(ID)传递的数据
    output wire                         es_to_ms_valid, // 本级数据对后级有效
    output wire [`ES_TO_MS_BUS_WD-1:0]  es_to_ms_bus,   // 传递给 MEM 级的总线

    // ---------------- 访存接口 (数据 RAM) ----------------
    output wire                         data_sram_en,
    output wire [3:0]                   data_sram_we,
    output wire [31:0]                  data_sram_addr,
    output wire [31:0]                  data_sram_wdata,

    // ---------------- 数据前递（转发）接口 ----------------
    output wire                         es_forward_valid,
    output wire [ 4:0]                  es_forward_dest,
    output wire [31:0]                  es_forward_data,
    output wire                         es_is_load,
    output wire                         es_is_div,      // 第 5 章：本级是除/取模指令
    output wire                         es_div_ready,   // 第 5 章：该除法结果已就绪
    output wire                         es_is_mul,      // 第 5 章：本级是乘法指令（结果只从 MEM 前递）
    output wire                         es_is_csr,      // 第 6 章：本级是 CSR 访问指令

    // ---------------- 第 6 章：CSR 访问接口 ----------------
    // 读写都在本级完成（指导书 6.5 建议：CSR 读写放同一流水级，避免写后读冲突）
    output wire                         csr_re,
    output wire [13:0]                  csr_num,
    input  wire [31:0]                  csr_rvalue,
    output wire                         csr_we,
    output wire [31:0]                  csr_wmask,
    output wire [31:0]                  csr_wvalue,

    // 第 6 章：写回级报出异常 / ERTN 时的全局清空信号
    input  wire                         flush
);

    // ==========================================
    // 1. 流水级握手与级间触发器
    // ==========================================
    reg         es_valid;
    wire        es_ready_go;
    wire        es_div_inst;    // 提前声明，供 es_ready_go 使用（第 5 章）

    // 说明：普通指令 ready_go 恒为 1；除法/取模指令要等多拍除法器出结果，
    //       只有结果就绪（或被锁存）后本级的 ready_go 才拉高。
    assign es_ready_go    = !es_div_inst || es_div_ready;
    assign es_allowin     = !es_valid || (es_ready_go && ms_allowin);
    assign es_to_ms_valid = es_valid && es_ready_go;

    reg [`DS_TO_ES_BUS_WD-1:0] ds_to_es_bus_r;

    always @(posedge clk) begin
        if (reset) begin
            es_valid <= 1'b0;
        end else if (flush) begin
            es_valid <= 1'b0;          // 第 6 章：异常/ERTN 时作废本级指令
        end else if (es_allowin) begin
            es_valid <= ds_to_es_valid;
        end

        if (ds_to_es_valid && es_allowin) begin
            ds_to_es_bus_r <= ds_to_es_bus;
        end
    end

    // ==========================================
    // 2. 解包 ID 传递过来的信号（与 ID_stage 打包顺序一致）
    // ==========================================
    wire        es_ertn;        // 第 6 章：ERTN 指令
    wire [ 5:0] es_ex_flags;    // 第 6 章扩展档：异常标志组 {adef,ale,sys,brk,ine,int}
    wire [13:0] es_csr_num;     // 第 6 章：CSR 寻址值
    wire        es_csr_re;      // 第 6 章：CSR 读使能
    wire        es_csr_we;      // 第 6 章：CSR 写使能
    wire        es_csr_xchg;    // 第 6 章：csrxchg（写掩码取 rj 值）
    wire        es_spare;       // 保留位
    wire [15:0] alu_op;
    wire        es_div_en;
    wire        es_div_signed;
    wire        es_div_rem;
    wire        es_res_from_mem;
    wire [31:0] es_alu_src1;
    wire [31:0] es_alu_src2;
    wire        es_gr_we;
    wire        es_mem_we;
    wire [ 2:0] es_mem_size;    // 1=字节 2=半字 4=字
    wire        es_ld_signed;   // load 是否符号扩展
    wire [ 4:0] es_dest;
    wire [31:0] es_rkd_value;
    wire [31:0] es_pc;

    assign {
        es_ertn,         // 1 bit
        es_ex_flags,     // 6 bit
        es_csr_num,      // 14 bit
        es_csr_re,       // 1 bit
        es_csr_we,       // 1 bit
        es_csr_xchg,     // 1 bit
        es_spare,        // 1 bit
        alu_op,          // 16 bit
        es_div_en,       // 1 bit
        es_div_signed,   // 1 bit
        es_div_rem,      // 1 bit
        es_res_from_mem, // 1 bit
        es_alu_src1,     // 32 bit
        es_alu_src2,     // 32 bit
        es_gr_we,        // 1 bit
        es_mem_we,       // 1 bit
        es_mem_size,     // 3 bit
        es_ld_signed,    // 1 bit
        es_dest,         // 5 bit
        es_rkd_value,    // 32 bit
        es_pc            // 32 bit
    } = ds_to_es_bus_r;

    // ==========================================
    // 2b. 乘法指令识别
    //     独热操作码 12/13/14 = mul.w / mulh.w / mulh.wu
    // ==========================================
    wire es_mul_inst = alu_op[12] | alu_op[13] | alu_op[14];

    // ========================================================================
    // 2c. 第 6 章：CSR 访问
    //     csrrd/csrwr/csrxchg 三条指令都伴随一次"读 CSR 旧值"的动作，区别只在
    //     要不要把 rd 的旧值写回 CSR、以及写掩码从哪来：
    //       csrrd    ：wmask 无意义（不写），rd <- 旧值
    //       csrwr    ：wmask = 全 1，      rd <- 旧值
    //       csrxchg  ：wmask = rj 的值，   rd <- 旧值
    //     写值一律是 rd 寄存器的旧值，它已经由 ID 级放到 alu_src2 上
    //     （ID 级对这三条指令把第二个读口指向了 rd）；写掩码则复用 alu_src1（= rj）。
    // ========================================================================
    wire        es_csr_inst = es_csr_re;

    assign csr_re    = es_valid && es_csr_re;
    assign csr_num   = es_csr_num;
    assign csr_wmask = es_csr_xchg ? es_alu_src1 : 32'hffffffff;
    assign csr_wvalue= es_alu_src2;
    // 只在指令真正流出 EXE 级的那一拍执行一次写入：
    //   若 MEM 级反压（ms_allowin=0）指令原地停留，不会重复写；
    //   若写回级正在 flush，说明本指令本不该执行，屏蔽掉写入。
    assign csr_we    = es_valid && es_csr_we && es_ready_go && ms_allowin && !flush;

    // ==========================================
    // 3. 例化 ALU（16 位独热操作码，含乘法）
    // ==========================================
    wire [31:0] alu_result;

    ALU alu_inst (
        .alu_op     (alu_op),
        .alu_src1   (es_alu_src1),
        .alu_src2   (es_alu_src2),
        .alu_result (alu_result)
    );

    // ==========================================
    // 3b. 乘法器（第 5 章）
    //     刻意独立于 ALU 之外，而不是并进 alu.v 的"或树"里。
    //     ALU 的输出 alu_result 同时是 EXE->ID 前递数据的来源；只要乘法器的
    //     输出出现在 alu_result 的锥内，综合器就无法把它剪掉（op_mul 是运行期
    //     信号而非常量），于是乘法器会随前递串到 ID 分支比较再驱动 IF 取指地址，
    //     形成跨三级的组合长路径（实测 21~22ns > 20ns，50MHz 时序不收敛）。
    //     放在这里之后：mul_result 只流向 es_to_ms_result（进 EXE->MEM 寄存器），
    //     彻底不出现在 es_forward_data 中，长路径被切断。
    //     使用 Verilog "*"：Artix-7 上 Vivado 会映射到 DSP48，几乎不耗 LUT，
    //     单周期延迟（指导书 §5.1 建议做法）。
    //     三个结果从 64 位乘积里取：
    //       mul.w    → [31:0]（有符号/无符号的低 32 位相同）
    //       mulh.w   → 有符号乘积[63:32]
    //       mulh.wu  → 无符号乘积[63:32]
    // ==========================================
    wire signed [63:0] mul_signed_prod   = $signed(es_alu_src1) * $signed(es_alu_src2);
    wire        [63:0] mul_unsigned_prod = es_alu_src1 * es_alu_src2;

    wire [31:0] mul_result = alu_op[12] ? mul_unsigned_prod[31:0] :   // mul.w
                             alu_op[13] ? mul_signed_prod  [63:32] :  // mulh.w
                                          mul_unsigned_prod[63:32];   // mulh.wu

    // ==========================================
    // 4. 除法/取模部件（第 5 章）
    //    有符号、无符号各例化一个除法器，接口与 Xilinx Divider Generator 一致：
    //      * 除法指令刚进入 EXE 时把两个输入通道的 tvalid 置 1；
    //      * 一旦某个上升沿同时看到 tvalid 与 tready，握手成功 —— 下一拍
    //        立即把 tvalid 撤销，否则除法器会认为又来了一次新的除法；
    //      * 随后等待 m_axis_dout_tvalid，结果取
    //        [63:32]=商、[31:0]=余数。
    // ==========================================
    // es_div_inst 已在文件前部声明，此处只做赋值
    assign es_div_inst = es_valid && es_div_en;

    reg         div_sent;       // 本次除法请求已经发出且握手成功（tvalid 已撤销）
    reg         div_done;       // 本次除法的结果已锁存（防下层反压时丢失）
    reg  [31:0] div_result_r;

    wire        div_req = es_div_inst && !div_sent && !div_done;

    wire        s_div_tready;
    wire        u_div_tready;
    wire        s_div_dout_valid;
    wire        u_div_dout_valid;
    wire [63:0] s_div_dout;
    wire [63:0] u_div_dout;

    // 有符号除法器（div.w / mod.w）
    divider #(.SIGNED(1)) u_divider_signed (
        .clk                    (clk),
        .resetn                 (~reset),
        .s_axis_dividend_tvalid (div_req &  es_div_signed),
        .s_axis_dividend_tready (s_div_tready),
        .s_axis_dividend_tdata  (es_alu_src1),
        .s_axis_divisor_tvalid  (div_req &  es_div_signed),
        .s_axis_divisor_tready  (),
        .s_axis_divisor_tdata   (es_alu_src2),
        .m_axis_dout_tvalid     (s_div_dout_valid),
        .m_axis_dout_tdata      (s_div_dout)
    );

    // 无符号除法器（div.wu / mod.wu）
    divider #(.SIGNED(0)) u_divider_unsigned (
        .clk                    (clk),
        .resetn                 (~reset),
        .s_axis_dividend_tvalid (div_req & ~es_div_signed),
        .s_axis_dividend_tready (u_div_tready),
        .s_axis_dividend_tdata  (es_alu_src1),
        .s_axis_divisor_tvalid  (div_req & ~es_div_signed),
        .s_axis_divisor_tready  (),
        .s_axis_divisor_tdata   (es_alu_src2),
        .m_axis_dout_tvalid     (u_div_dout_valid),
        .m_axis_dout_tdata      (u_div_dout)
    );

    // 选中本次除法所使用的那一路除法器
    wire [63:0] div_active_dout = es_div_signed ? s_div_dout : u_div_dout;
    wire        div_dout_valid  = es_div_signed ? s_div_dout_valid : u_div_dout_valid;
    wire        div_handshake   = div_req && (es_div_signed ? s_div_tready : u_div_tready);

    // [63:32]=商，[31:0]=余数；div/mod 决定取哪一半
    wire [31:0] div_result_now = es_div_rem ? div_active_dout[31:0]
                                            : div_active_dout[63:32];
    // 结果若已锁存则用锁存值，否则用除法器当拍输出
    wire [31:0] div_result     = div_done ? div_result_r : div_result_now;

    assign es_div_ready = div_done | div_dout_valid;

    always @(posedge clk) begin
        if (reset) begin
            div_sent     <= 1'b0;
            div_done     <= 1'b0;
            div_result_r <= 32'b0;
        end
        else if (es_div_inst && es_ready_go && ms_allowin) begin
            // 除法指令本拍流出 EXE，控制状态复位，准备迎接下一条除法指令
            div_sent <= 1'b0;
            div_done <= 1'b0;
        end
        else begin
            if (div_handshake) begin
                div_sent <= 1'b1;          // 已握手 → 下一拍撤销 tvalid
            end
            if (div_dout_valid) begin
                div_done     <= 1'b1;
                div_result_r <= div_result_now;
            end
        end
    end

    // ==========================================
    // 5. 本级最终运算结果
    //    ★ 两条结果通路刻意分开，这是时序收敛的关键 ★
    //      es_forward_result：可能参与 EXE->ID 前递的结果（ALU / 除法），不含乘法；
    //                        它的逻辑锥里没有乘法器，因此前递链路很短。
    //      es_final_result  ：送 MEM/写回的最终结果（乘法 > 除法 > ALU），
    //                        乘法结果只出现在这里，终点是 EXE->MEM 寄存器。
    // ==========================================
    // ==================================================================
    // 5b. 第 6 章扩展档：地址非对齐异常 ALE（指导书 6.2.4）
    //   判定放在"发起访存请求"这一级，这样发现异常时可以立刻用错误地址
    //   停止访存 —— 与指导书的建议完全一致。
    //   ID 级已经用地址低两位预判过一次（用于提前关闭流水线入口），
    //   这里用真实的 alu_result 再复核一次并取或，双保险。
    //     ld.w / st.w (size=4) ：要求 addr[1:0] == 00
    //     ld.h / ld.hu / st.h (size=2)：要求 addr[0] == 0
    //     ld.b / ld.bu / st.b (size=1)：任意地址都合法
    // ==================================================================
    wire es_ale_addr = (es_mem_size == 3'd4) ? (alu_result[1:0] != 2'b00) :
                       (es_mem_size == 3'd2) ? (alu_result[   0] != 1'b0) : 1'b0;
    wire es_ale      = es_ex_flags[4] | es_ale_addr;

    wire [31:0] es_forward_result = es_div_inst ? div_result : alu_result;
    wire [31:0] es_alu_mul_result = es_mul_inst ? mul_result : es_forward_result;
    // 第 6 章：CSR 访问指令的写回值是 CSR 读出的旧值
    // 第 6 章扩展档：ALE 指令把出错的访存地址放进结果通路，
    //   一路传到写回级当作 BADV.VAddr（省掉一条 32 位的专用总线）
    wire [31:0] es_final_result   = es_ale      ? alu_result  :
                                    es_csr_inst ? csr_rvalue  : es_alu_mul_result;

    // ==========================================
    // 6. 生成数据 RAM 访问信号
    //    - 地址低两位决定字节通道（小端：vaddr[1:0] 即字内字节偏移）
    //    - st.b 写使能：00->0001 01->0010 10->0100 11->1000
    //    - st.h 写使能：00->0011 10->1100
    //    - 写数据用"复制到各通道"的方式生成，配合写使能即可落到正确字节
    // ==========================================
    wire [ 1:0] es_addr_low   = alu_result[1:0];

    wire [ 3:0] we_byte        = 4'b0001 << es_addr_low;              // st.b
    wire [ 3:0] we_half        = es_addr_low[1] ? 4'b1100 : 4'b0011;  // st.h
    wire [ 3:0] we_word        = 4'b1111;                             // st.w

    wire [31:0] wdata_byte     = {4{es_rkd_value[7:0]}};              // 字节复制 4 份
    wire [31:0] wdata_half     = {2{es_rkd_value[15:0]}};             // 半字复制 2 份

    wire [ 3:0] es_store_we    = (es_mem_size == 3'd1) ? we_byte :
                                 (es_mem_size == 3'd2) ? we_half : we_word;
    wire [31:0] es_store_wdata = (es_mem_size == 3'd1) ? wdata_byte :
                                 (es_mem_size == 3'd2) ? wdata_half : es_rkd_value;

    // 第 6 章：写回级正在报异常 / ERTN 时，本级这条指令其实属于"不该执行"的
    // 后续指令，必须屏蔽掉它的访存副作用，否则会污染内存。
    // 第 6 章扩展档：出现 ALE 时不得用错误地址发起访存
    assign data_sram_en    = es_valid && !flush && (es_res_from_mem || es_mem_we) && !es_ale;
    assign data_sram_we    = (es_valid && !flush && es_mem_we && !es_ale) ? es_store_we : 4'b0000;
    assign data_sram_addr  = alu_result;
    assign data_sram_wdata = es_store_wdata;

    // ==========================================
    // 7. 打包传递给 MEM 级
    // ==========================================
    assign es_to_ms_bus = {
        es_ertn,         // 1 bit:  ERTN（随指令走到写回级触发 flush）
        es_ex_flags,     // 6 bit:  异常标志组 {adef,ale,sys,brk,ine,int}
        es_res_from_mem, // 1 bit: 结果是否取自数据 RAM
        es_gr_we,        // 1 bit: 寄存器写使能
        es_mem_size,     // 3 bit: 访存宽度（MEM 做字节选择）
        es_ld_signed,    // 1 bit: 符号/零扩展
        es_dest,         // 5 bit: 写回目标寄存器号
        es_final_result, // 32 bit: ALU / 除法 / CSR 读出值（load 的写回值在 MEM 级产生）
        es_pc            // 32 bit: 调试追踪 PC
    };

    // ==========================================
    // 8. 数据前递（转发）输出
    //    除法指令在结果没出来之前不允许前递，否则前级会拿到未定义的值；
    //    对应的 RAW 冲突由 ID 级的 div_stall 负责阻塞。
    //
    //    ★ 乘法指令同样不参与 EXE 级前递，只从 MEM/WB 前递（mul_stall）。
    //    关键点：前递数据必须取自 es_forward_result（ALU/除法），而不是
    //    es_final_result —— 后者含 mul_result，会把乘法器拉进前递逻辑锥，
    //    经 ID 分支比较/跳转目标加法器直抵 IF 取指地址，跨三级组合路径超时。
    // ==========================================
    assign es_is_mul = es_valid & es_mul_inst;
    // 第 6 章：CSR 指令的结果来自 csr_rvalue，不在 es_forward_result 里，
    // 因此不能参与本级前递 —— 否则前递出去的是 alu_result（alu_op 全 0 的垃圾值）。
    // 对应的 RAW 冲突由 ID 级的 csr_stall 阻塞一拍解决。
    assign es_is_csr = es_valid & es_csr_inst;

    assign es_forward_valid = es_valid && es_gr_we && (es_dest != 5'd0)
                            && !es_mul_inst
                            && !es_csr_inst
                            && (!es_div_inst || es_div_ready);
    assign es_forward_dest  = es_dest;
    assign es_forward_data  = es_forward_result;
    assign es_is_load       = es_valid && es_res_from_mem;
    assign es_is_div        = es_div_inst;

endmodule
