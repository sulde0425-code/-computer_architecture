`include "mycpu_h.v"

module ID_stage(
    input  wire                         clk,
    input  wire                         reset,

    // 来自与去向各级的流水握手和总线信号
    input  wire                         es_allowin,
    output wire                         ds_allowin,
    input  wire                         fs_to_ds_valid,
    input  wire [`FS_TO_DS_BUS_WD -1:0] fs_to_ds_bus,
    output wire                         ds_to_es_valid,
    output wire [`DS_TO_ES_BUS_WD -1:0] ds_to_es_bus,

    // 分支总线（送往 IF 级）
    output wire [`BR_BUS_WD       -1:0] br_bus,

    // 写回级写寄存器堆总线
    input  wire [`WS_TO_RF_BUS_WD -1:0] ws_to_rf_bus,

    // ---------------- 数据前递（转发）接口：EXE/MEM/WB -> ID ----------------
    input  wire        es_forward_valid,
    input  wire [ 4:0] es_forward_dest,
    input  wire [31:0] es_forward_data,
    input  wire        es_is_load,
    input  wire        es_is_div,       // EXE 级当前是除/取模指令（第 5 章）
    input  wire        es_div_ready,    // 该除法指令的结果已就绪
    input  wire        es_is_mul,       // EXE 级当前是乘法指令（第 5 章）
    input  wire        ms_forward_valid,
    input  wire [ 4:0] ms_forward_dest,
    input  wire [31:0] ms_forward_data,
    input  wire        ms_forward_is_load, // MEM 级前递值是否来自数据 RAM（第 5 章·时序修复）
    input  wire [31:0] ms_forward_data_alu, // MEM 级纯 ALU 结果，与 data_ram 无关（供分支用）
    input  wire        ws_forward_valid,
    input  wire [ 4:0] ws_forward_dest,
    input  wire [31:0] ws_forward_data
);

    // ---------------- 流水控制与级间寄存器 ----------------
    reg         ds_valid;
    wire        ds_ready_go;
    wire        load_stall;   // Load-Use 阻塞标志（声明提前，供 ds_ready_go 使用）
    wire        div_stall;    // 乘除结果未就绪的阻塞标志（第 5 章）
    wire        mul_stall;    // 乘法结果需从 MEM 前递的阻塞标志（第 5 章）
    wire        branch_load_stall; // 分支等待 load 走到 WB 的阻塞标志（第 5 章·时序修复）

    wire [31:0] ds_inst;
    wire [31:0] ds_pc;
    reg  [`FS_TO_DS_BUS_WD -1:0] fs_to_ds_bus_r;

    assign {ds_inst, ds_pc} = fs_to_ds_bus_r;

    // 写回级信号解包
    wire        rf_we;
    wire [ 4:0] rf_waddr;
    wire [31:0] rf_wdata;
    assign {rf_we, rf_waddr, rf_wdata} = ws_to_rf_bus;

    // ---------------- 内部控制与译码信号 ----------------
    wire        br_taken;
    wire [31:0] br_target;

    wire [15:0] alu_op;
    wire        src1_is_pc;
    wire        src2_is_imm;
    wire        res_from_mem;
    wire        dst_is_r1;
    wire        gr_we;
    wire        mem_we;
    wire        src_reg_is_rd;
    wire [4: 0] dest;
    wire [31:0] rj_value;
    wire [31:0] rkd_value;
    wire [31:0] ds_imm;

    // 指令字段切分
    wire [ 5:0] op_31_26;
    wire [ 3:0] op_25_22;
    wire [ 1:0] op_21_20;
    wire [ 4:0] op_19_15;
    wire [ 4:0] rd;
    wire [ 4:0] rj;
    wire [ 4:0] rk;
    wire [11:0] i12;
    wire [19:0] i20;
    wire [15:0] i16;
    wire [25:0] i26;

    // 译码中间信号
    wire [63:0] op_31_26_d;
    wire [15:0] op_25_22_d;
    wire [ 3:0] op_21_20_d;
    wire [31:0] op_19_15_d;

    // 指令识别信号
    wire        inst_add_w;
    wire        inst_sub_w;
    wire        inst_slt;
    wire        inst_sltu;
    wire        inst_nor;
    wire        inst_and;
    wire        inst_or;
    wire        inst_xor;
    wire        inst_slli_w;
    wire        inst_srli_w;
    wire        inst_srai_w;
    wire        inst_addi_w;
    wire        inst_ld_w;
    wire        inst_st_w;
    wire        inst_jirl;
    wire        inst_b;
    wire        inst_bl;
    wire        inst_beq;
    wire        inst_bne;
    wire        inst_lu12i_w;
    wire        inst_slti;
    wire        inst_sltui;
    wire        inst_andi;
    wire        inst_ori;
    wire        inst_xori;
    wire        inst_pcaddu12i;
    wire        inst_sll_w;
    wire        inst_srl_w;
    wire        inst_sra_w;
    wire        inst_blt;
    wire        inst_bge;
    wire        inst_bltu;
    wire        inst_bgeu;
    // 第 4 章：访存指令
    wire        inst_ld_b;
    wire        inst_ld_h;
    wire        inst_ld_bu;
    wire        inst_ld_hu;
    wire        inst_st_b;
    wire        inst_st_h;
    // 第 5 章：乘除指令
    wire        inst_mul_w;
    wire        inst_mulh_w;
    wire        inst_mulh_wu;
    wire        inst_div_w;
    wire        inst_mod_w;
    wire        inst_div_wu;
    wire        inst_mod_wu;

    wire        need_ui5;
    wire        need_ui12;
    wire        need_si12;
    wire        need_si16;
    wire        need_si20;
    wire        need_si26;
    wire        src2_is_4;

    wire [ 4:0] rf_raddr1;
    wire [31:0] rf_rdata1;
    wire [ 4:0] rf_raddr2;
    wire [31:0] rf_rdata2;

    wire        rj_eq_rd;

    // ---------------- 握手与级间使能 ----------------
    assign ds_ready_go    = ~load_stall & ~div_stall & ~mul_stall & ~branch_load_stall; // 第二章 Load-Use / 第五章三类结果未就绪时的阻塞
    assign ds_allowin     = !ds_valid || ds_ready_go && es_allowin;
    assign ds_to_es_valid = ds_valid && ds_ready_go;

    always @(posedge clk) begin
        if (reset) begin
            ds_valid <= 1'b0;
        end else if (ds_allowin) begin
            ds_valid <= fs_to_ds_valid;
        end

        if (fs_to_ds_valid && ds_allowin) begin
            fs_to_ds_bus_r <= fs_to_ds_bus;
        end
    end

    // ---------------- 指令字段与译码逻辑 ----------------
    assign op_31_26 = ds_inst[31:26];
    assign op_25_22 = ds_inst[25:22];
    assign op_21_20 = ds_inst[21:20];
    assign op_19_15 = ds_inst[19:15];

    assign rd  = ds_inst[ 4: 0];
    assign rj  = ds_inst[ 9: 5];
    assign rk  = ds_inst[14:10];

    assign i12 = ds_inst[21:10];
    assign i20 = ds_inst[24: 5];
    assign i16 = ds_inst[25:10];
    assign i26 = {ds_inst[ 9: 0], ds_inst[25:10]};

    // 使用简易译码生成 one-hot
    decoder_6_64 u_dec0(.in(op_31_26), .out(op_31_26_d));
    decoder_4_16 u_dec1(.in(op_25_22), .out(op_25_22_d));
    decoder_2_4  u_dec2(.in(op_21_20), .out(op_21_20_d));
    decoder_5_32 u_dec3(.in(op_19_15), .out(op_19_15_d));

    assign inst_add_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h00];
    assign inst_sub_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h02];
    assign inst_slt    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h04];
    assign inst_sltu   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h05];
    assign inst_nor    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h08];
    assign inst_and    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h09];
    assign inst_or     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0a];
    assign inst_xor    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0b];
    assign inst_slli_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h01];
    assign inst_srli_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h09];
    assign inst_srai_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h11];
    assign inst_addi_w = op_31_26_d[6'h00] & op_25_22_d[4'ha];
    assign inst_ld_w   = op_31_26_d[6'h0a] & op_25_22_d[4'h2];
    assign inst_st_w   = op_31_26_d[6'h0a] & op_25_22_d[4'h6];
    // ---- 第 4 章：访存指令（op[31:26]=001010，op[25:22] 区分） ----
    //   0000 = LD.B    0001 = LD.H    0010 = LD.W
    //   0100 = ST.B    0101 = ST.H    0110 = ST.W
    //   1000 = LD.BU   1001 = LD.HU   （均为 2RI12 格式：rd, rj, si12）
    assign inst_ld_b   = op_31_26_d[6'h0a] & op_25_22_d[4'h0];
    assign inst_ld_h   = op_31_26_d[6'h0a] & op_25_22_d[4'h1];
    assign inst_ld_bu  = op_31_26_d[6'h0a] & op_25_22_d[4'h8];
    assign inst_ld_hu  = op_31_26_d[6'h0a] & op_25_22_d[4'h9];
    assign inst_st_b   = op_31_26_d[6'h0a] & op_25_22_d[4'h4];
    assign inst_st_h   = op_31_26_d[6'h0a] & op_25_22_d[4'h5];
    // ---- 第 5 章：乘除指令（均为 3R 格式，op[31:26]=000000、op[25:22]=0000）----
    //   op[21:20]=01 → 乘法类，op[19:15] 区分：
    //       11000 = MUL.W    11001 = MULH.W    11010 = MULH.WU
    //   op[21:20]=10 → 除法类，op[19:15] 区分：
    //       00000 = DIV.W    00001 = MOD.W
    //       00010 = DIV.WU   00011 = MOD.WU
    assign inst_mul_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h18];
    assign inst_mulh_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h19];
    assign inst_mulh_wu = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h1a];
    assign inst_div_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h00];
    assign inst_mod_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h01];
    assign inst_div_wu  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h02];
    assign inst_mod_wu  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h03];
    // 访存类指令汇总，供下面的控制信号统一使用
    wire   inst_ld_all    = inst_ld_w  | inst_ld_b  | inst_ld_h  | inst_ld_bu | inst_ld_hu;
    wire   inst_st_all    = inst_st_w  | inst_st_b  | inst_st_h;
    // 访存数据宽度：1=字节 2=半字 4=字（EXE 生成写使能 / MEM 做字节选择均需要）
    wire [2:0] ds_mem_size = (inst_ld_b | inst_ld_bu | inst_st_b) ? 3'd1 :
                             (inst_ld_h | inst_ld_hu | inst_st_h) ? 3'd2 :
                                                                    3'd4;
    // 是否符号扩展：ld.b / ld.h 符号扩展，ld.bu / ld.hu 零扩展（字访问无影响）
    wire       ds_ld_signed = inst_ld_b | inst_ld_h;
    // 第 5 章：除法/取模控制（EXE 级据此驱动 divider 的两个实例）
    wire       ds_div_en     = inst_div_w | inst_mod_w | inst_div_wu | inst_mod_wu;
    wire       ds_div_signed = inst_div_w | inst_mod_w;   // 有符号除
    wire       ds_div_rem    = inst_mod_w | inst_mod_wu;  // 取余数（否则取商）
    assign inst_jirl   = op_31_26_d[6'h13];
    assign inst_b      = op_31_26_d[6'h14];
    assign inst_bl     = op_31_26_d[6'h15];
    assign inst_beq    = op_31_26_d[6'h16];
    assign inst_bne    = op_31_26_d[6'h17];
    assign inst_lu12i_w= op_31_26_d[6'h05] & ~ds_inst[25];
    // ---- 第 3 章：算术逻辑类 2RI12 指令 ----
    // LOONGARCH 2RI12 编码：op[31:26]=000000，op[25:22] 区分具体指令
    //   1000 = SLTI     1001 = SLTUI    1010 = ADDI.W（第 1 章已有）
    //   1101 = ANDI     1110 = ORI      1111 = XORI
    assign inst_slti     = op_31_26_d[6'h00] & op_25_22_d[4'h8];
    assign inst_sltui    = op_31_26_d[6'h00] & op_25_22_d[4'h9];
    assign inst_andi     = op_31_26_d[6'h00] & op_25_22_d[4'hd];
    assign inst_ori      = op_31_26_d[6'h00] & op_25_22_d[4'he];
    assign inst_xori     = op_31_26_d[6'h00] & op_25_22_d[4'hf];
    assign inst_pcaddu12i= op_31_26_d[6'h07] & ~ds_inst[25];
    assign inst_sll_w    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0e];
    assign inst_srl_w    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0f];
    assign inst_sra_w    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h10];
    assign inst_blt      = op_31_26_d[6'h18];
    assign inst_bge      = op_31_26_d[6'h19];
    assign inst_bltu     = op_31_26_d[6'h1a];
    assign inst_bgeu     = op_31_26_d[6'h1b];

    // ALU 操作码独热编码
    assign alu_op[ 0] = inst_add_w | inst_addi_w | inst_ld_all | inst_st_all
                      | inst_jirl  | inst_bl     | inst_pcaddu12i;
    assign alu_op[ 1] = inst_sub_w;
    assign alu_op[ 2] = inst_slt   | inst_slti;
    assign alu_op[ 3] = inst_sltu  | inst_sltui;
    assign alu_op[ 4] = inst_and   | inst_andi;
    assign alu_op[ 5] = inst_nor;
    assign alu_op[ 6] = inst_or    | inst_ori;
    assign alu_op[ 7] = inst_xor   | inst_xori;
    assign alu_op[ 8] = inst_slli_w| inst_sll_w;
    assign alu_op[ 9] = inst_srli_w| inst_srl_w;
    assign alu_op[10] = inst_srai_w| inst_sra_w;
    assign alu_op[11] = inst_lu12i_w;
    // 第 5 章：乘法（除法不走 ALU，由 EXE 级 divider 多拍完成）
    assign alu_op[12] = inst_mul_w;
    assign alu_op[13] = inst_mulh_w;
    assign alu_op[14] = inst_mulh_wu;
    assign alu_op[15] = 1'b0;   // 保留

    // 立即数选择与扩展
    assign need_ui12  =  inst_andi   | inst_ori    | inst_xori;
    assign need_ui5   =  inst_slli_w | inst_srli_w | inst_srai_w;
    assign need_si12  =  inst_addi_w | inst_ld_all | inst_st_all | inst_slti | inst_sltui;
    assign need_si16  =  inst_jirl   | inst_beq    | inst_bne  | inst_blt  | inst_bge | inst_bltu | inst_bgeu;
    assign need_si20  =  inst_lu12i_w| inst_pcaddu12i;
    assign need_si26  =  inst_b      | inst_bl;
    assign src2_is_4  =  inst_jirl   | inst_bl;

    // 立即数扩展：按"哪一种立即数"逐类处理，未命中的指令取 0
    assign ds_imm = src2_is_4  ? 32'h4                       : // jirl/bl：链接值 PC+4
                    need_si20  ? {i20[19:0], 12'b0}          : // lu12i.w / pcaddu12i
                    need_ui5   ? {27'b0, rk[4:0]}            : // slli/srli/srai.w
                    need_ui12  ? {20'b0, i12[11:0]}          : // andi / ori / xori
                    need_si12  ? {{20{i12[11]}}, i12[11:0]}  : // addi.w/ld.w/st.w/slti/sltui
                                 32'b0;                       // 未译码指令，避免误用脏立即数

    // 控制信号
    assign src1_is_pc    = inst_jirl | inst_bl | inst_pcaddu12i;
    assign src2_is_imm   = inst_slli_w    |
                           inst_srli_w    |
                           inst_srai_w    |
                           inst_addi_w    |
                           inst_ld_all    |
                           inst_st_all    |
                           inst_lu12i_w   |
                           inst_jirl      |
                           inst_bl        |
                           inst_slti      |
                           inst_sltui     |
                           inst_andi      |
                           inst_ori       |
                           inst_xori      |
                           inst_pcaddu12i;

    assign res_from_mem  = inst_ld_all;
    assign dst_is_r1     = inst_bl;
    // 正向译码：只有确实写通用寄存器的指令才置 gr_we。
    // 若沿用"反向屏蔽"写法，后续章节新增的未译码指令（如 ld.b）会带着
    // gr_we=1、alu_op=0 走进默认通路执行 rd = rj + rk 并写回，静默破坏寄存器堆。
    assign gr_we         = inst_add_w  | inst_sub_w  | inst_slt   | inst_sltu  |
                           inst_nor    | inst_and    | inst_or    | inst_xor   |
                           inst_slli_w | inst_srli_w | inst_srai_w|
                           inst_addi_w | inst_lu12i_w |
                           inst_slti   | inst_sltui  | inst_andi  | inst_ori   | inst_xori |
                           inst_pcaddu12i | inst_sll_w | inst_srl_w | inst_sra_w |
                           inst_jirl   | inst_bl     | inst_ld_all |
                           // 第 5 章：乘除指令都会写 rd
                           inst_mul_w  | inst_mulh_w | inst_mulh_wu |
                           inst_div_w  | inst_mod_w  | inst_div_wu | inst_mod_wu;
    assign mem_we        = inst_st_all;
    assign dest          = dst_is_r1 ? 5'd1 : rd;

    // 寄存器堆读地址
    assign src_reg_is_rd = inst_beq | inst_bne | inst_st_all
                         | inst_blt | inst_bge | inst_bltu | inst_bgeu;
    assign rf_raddr1     = rj;
    assign rf_raddr2     = src_reg_is_rd ? rd : rk;

    // 实例化寄存器堆
    RegFiles u_regfile(
        .clk    (clk      ),
        .raddr1 (rf_raddr1),
        .rdata1 (rf_rdata1),
        .raddr2 (rf_raddr2),
        .rdata2 (rf_rdata2),
        .wen    (rf_we    ),
        .waddr  (rf_waddr ),
        .wdata  (rf_wdata )
    );

    // ---------------- 数据前递（转发）与 Load-Use 阻塞 ----------------
    // 本指令是否真正使用 rj / rkd 作为源操作数
    wire ds_use_rj = inst_add_w | inst_sub_w | inst_slt  | inst_sltu |
                     inst_and   | inst_nor   | inst_or   | inst_xor  |
                     inst_slli_w| inst_srli_w| inst_srai_w|
                     inst_addi_w| inst_ld_all| inst_st_all |
                     inst_jirl  | inst_beq   | inst_bne  |
                     inst_slti  | inst_sltui | inst_andi | inst_ori  | inst_xori |
                     inst_sll_w | inst_srl_w | inst_sra_w|
                     inst_blt   | inst_bge   | inst_bltu | inst_bgeu |
                     // 第 5 章：乘除指令的两个源都是寄存器
                     inst_mul_w | inst_mulh_w | inst_mulh_wu |
                     inst_div_w | inst_mod_w  | inst_div_wu | inst_mod_wu;

    wire ds_use_rkd = inst_add_w | inst_sub_w | inst_slt  | inst_sltu |
                      inst_and   | inst_nor   | inst_or   | inst_xor  |
                      inst_st_all| inst_beq   | inst_bne  |
                      inst_sll_w | inst_srl_w | inst_sra_w|
                      inst_blt   | inst_bge   | inst_bltu | inst_bgeu |
                      // 第 5 章：乘除指令的两个源都是寄存器
                      inst_mul_w | inst_mulh_w | inst_mulh_wu |
                      inst_div_w | inst_mod_w  | inst_div_wu | inst_mod_wu;

    // ★ 时序修复（第 5 章）：分支指令一律不消费"MEM 级 load 的前递值"。
    //   原因：load 的写回数据直接来自 data_ram 的 BRAM 输出，而 MEM 级还要做
    //   字节选取 + 符号/零扩展，这段组合逻辑若接着走 ID 前递 -> 分支比较 ->
    //   IF 取指地址 -> inst_ram 使能译码，就会形成一条 data_ram -> inst_ram 的
    //   超长路径（实测 20.21ns，其中布线占 76%，@50MHz 差 1.26ns 不收敛）。
    //   改为：分支遇到 MEM 级 load 时多阻塞一拍（branch_load_stall），
    //   等该 load 进入 WB 级后由 ws_forward 提供。
    //   ⚠ 单靠这条规则**不足以**修好时序：实测违例端点从 752 降到 371、
    //     TNS 从 -282ns 降到 -124ns，但 WNS 仍是 -1.26ns（几乎没动）。
    //     因为只要 ms_forward_data 还是多路选择器的数据输入，静态时序分析就会
    //     照常分析这条路径。真正常规切断它的是下面 rj_br_value/rkd_br_value
    //     换用 ms_forward_data_alu（无 BRAM）——两者必须成对使用：
    //     branch_load_stall 负责功能正确性，换源负责物理切断路径。
    //   性能影响仅限"分支直接依赖 load 结果"这一少数情形。
    wire ds_is_branch = inst_beq | inst_bne | inst_blt | inst_bge | inst_bltu | inst_bgeu | inst_jirl;
    // 非分支指令在 MEM 级照常使用 ms_forward_data（含 load 数据），走 EXE 通路
    wire mem_fwd_ok   = ms_forward_valid && !(ds_is_branch && ms_forward_is_load);

    // 前递优先级：EXE > MEM > WB > 寄存器堆
    wire [31:0] rj_forward_data =
        (es_forward_valid && ds_use_rj && (es_forward_dest == rf_raddr1)) ? es_forward_data :
        (mem_fwd_ok       && ds_use_rj && (ms_forward_dest == rf_raddr1)) ? ms_forward_data :
        (ws_forward_valid && ds_use_rj && (ws_forward_dest == rf_raddr1)) ? ws_forward_data :
                                                                            rf_rdata1;

    wire [31:0] rkd_forward_data =
        (es_forward_valid && ds_use_rkd && (es_forward_dest == rf_raddr2)) ? es_forward_data :
        (mem_fwd_ok       && ds_use_rkd && (ms_forward_dest == rf_raddr2)) ? ms_forward_data :
        (ws_forward_valid && ds_use_rkd && (ws_forward_dest == rf_raddr2)) ? ws_forward_data :
                                                                             rf_rdata2;

    assign rj_value  = rj_forward_data;
    assign rkd_value = rkd_forward_data;

    // ★ 时序修复（第 5 章·第二轮）：分支/跳转专用的前递通路
    //   上面两条通路在 MEM 级复用了 ms_forward_data，而对 load 指令它等于
    //   data_ram 的读数据（BRAM 输出 + 一级字节选取 + 符号/零扩展）。这个值一旦
    //   进入 br_taken / br_target，就会连成
    //       data_ram(BRAM 输出) -> 字节扩展 -> ID 前递多路选择 -> 分支比较 / 转移加法
    //       -> IF next_pc -> inst_ram 地址译码 -> inst_ram ENARDEN
    //   一条跨整个器件的长路径：实测 20.21ns，@50MHz(20ns) 差 1.26ns 不收敛，其中
    //   布线占 76%（inst_ram 有 256 个 RAMB36，其 ENARDEN 译码网络铺满全芯片）。
    //
    //   注意：只做"功能上不选它"是不够的 —— branch_load_stall 单独使用后违例端点
    //   从 752 降到 371、TNS 减半，但 WNS 纹丝不动，原因就是只要 ms_forward_data 仍
    //   是多路选择器的数据输入，静态时序分析就会照常分析这条路径。必须在物理上换源。
    //
    //   因此这里让分支在 MEM 级只取 ms_forward_data_alu（直接来自 es_to_ms_bus_r
    //   触发器，与 data_ram 无关），整个逻辑锥的起点由 BRAM 变成触发器，长路径被切断。
    //   正确性由 branch_load_stall 保证：分支绝不消费 MEM 级 load 的数据
    //   （此时 !ms_forward_is_load 为假、该路不被选中），而是多等一拍由 WB 级
    //   ws_forward（同样发自触发器）提供结果。
    wire ms_br_fwd_ok = ms_forward_valid && !ms_forward_is_load;

    wire [31:0] rj_br_value =
        (es_forward_valid && ds_use_rj && (es_forward_dest == rf_raddr1)) ? es_forward_data :
        (ms_br_fwd_ok     && ds_use_rj && (ms_forward_dest == rf_raddr1)) ? ms_forward_data_alu :
        (ws_forward_valid && ds_use_rj && (ws_forward_dest == rf_raddr1)) ? ws_forward_data :
                                                                           rf_rdata1;

    wire [31:0] rkd_br_value =
        (es_forward_valid && ds_use_rkd && (es_forward_dest == rf_raddr2)) ? es_forward_data :
        (ms_br_fwd_ok     && ds_use_rkd && (ms_forward_dest == rf_raddr2)) ? ms_forward_data_alu :
        (ws_forward_valid && ds_use_rkd && (ws_forward_dest == rf_raddr2)) ? ws_forward_data :
                                                                            rf_rdata2;

    // Load-Use 阻塞：EXE 级是 load（数据要到 MEM 级才就绪），
    // 且其目标寄存器正是本指令所需源寄存器时，阻塞 ID 级一拍。
    assign load_stall = es_is_load && (
        (ds_use_rj  && (rf_raddr1 != 5'd0) && (rf_raddr1 == es_forward_dest)) ||
        (ds_use_rkd && (rf_raddr2 != 5'd0) && (rf_raddr2 == es_forward_dest))
    );

    // 除法结果未就绪阻塞（第 5 章）：EXE 级是除/取模指令、且它要占用 EXE
    // 若干拍才有结果。若本指令正好要用它的结果，就阻塞 ID 直到结果就绪，
    // 否则会前递到一个尚未算出的值。处理方式与 Load-Use 完全同构。
    assign div_stall = es_is_div && !es_div_ready && (
        (ds_use_rj  && (rf_raddr1 != 5'd0) && (rf_raddr1 == es_forward_dest)) ||
        (ds_use_rkd && (rf_raddr2 != 5'd0) && (rf_raddr2 == es_forward_dest))
    );

    // 乘法结果阻塞（第 5 章·时序修复）：乘法器组合延迟过大，其结果不参与
    // EXE 级前递（见 EXE_stage.v 第 8 节说明）。因此当 EXE 级是一条乘法指令、
    // 且本指令的正源寄存器正好是它的目标寄存器时，阻塞 ID 一拍；下一拍该乘法
    // 已进入 MEM 级，由已寄存的 ms_forward 提供正确结果。与 Load-Use 同构。
    assign mul_stall = es_is_mul && (
        (ds_use_rj  && (rf_raddr1 != 5'd0) && (rf_raddr1 == es_forward_dest)) ||
        (ds_use_rkd && (rf_raddr2 != 5'd0) && (rf_raddr2 == es_forward_dest))
    );

    // 分支等待 load 进入 WB 的阻塞（第 5 章·时序修复）：
    // 分支不消费 MEM 级 load 的前递值（见上文 mem_fwd_ok），因此当 MEM 级是一条
    // load、且本分支的正源寄存器正好是它的目标寄存器时，再阻塞一拍；下一拍该 load
    // 已进入 WB 级，由 ws_forward 提供结果，组合路径从"data_ram 出发"变成"触发器出发"。
    assign branch_load_stall = ds_is_branch && ms_forward_valid && ms_forward_is_load && (
        (ds_use_rj  && (rf_raddr1 != 5'd0) && (rf_raddr1 == ms_forward_dest)) ||
        (ds_use_rkd && (rf_raddr2 != 5'd0) && (rf_raddr2 == ms_forward_dest))
    );

    // ---------------- 分支跳转控制 ----------------
    // 注：分支比较与转移目标一律使用 rj_br_value / rkd_br_value（不含 data_ram 通路），
    //     见上文"分支/跳转专用的前递通路"说明。
    assign rj_eq_rd  = (rj_br_value == rkd_br_value);
    wire   rj_lt_rd  = ($signed(rj_br_value) < $signed(rkd_br_value));
    wire   rj_ltu_rd = (rj_br_value < rkd_br_value);

    assign br_taken = (inst_beq  &&  rj_eq_rd
                    || inst_bne  && !rj_eq_rd
                    || inst_blt  &&  rj_lt_rd
                    || inst_bge  && !rj_lt_rd
                    || inst_bltu &&  rj_ltu_rd
                    || inst_bgeu && !rj_ltu_rd
                    || inst_jirl
                    || inst_bl
                    || inst_b
                    ) && ds_valid && ds_ready_go;

    wire [31:0] br_offs;
    wire [31:0] jirl_offs;

    // 转移偏移：26 位格式（b/bl）与 16 位格式（beq/bne/blt/bge/bltu/bgeu），均左移 2 位
    assign br_offs   = need_si26 ? {{ 4{i26[25]}}, i26[25:0], 2'b0} :
                       need_si16 ? {{14{i16[15]}}, i16[15:0], 2'b0} :
                                   32'b0;
    assign jirl_offs = {{14{i16[15]}}, i16[15:0], 2'b0};

    assign br_target = (inst_beq || inst_bne || inst_blt || inst_bge || inst_bltu || inst_bgeu || inst_bl || inst_b)
                     ? (ds_pc + br_offs)
                     : (rj_br_value + jirl_offs);

    assign br_bus = {br_taken, br_target};

    // ---------------- 打包输出给 EXE 级 ----------------
    // 位宽见 mycpu_h.v 的 DS_TO_ES_BUS_WD (=160)
    assign ds_to_es_bus = {
        1'b0,                             // 1 bit   保留（为第 6 章异常信息预留）
        alu_op,                           // 16 bit  ALU 操作码（独热，含乘除编码）
        ds_div_en,                        // 1 bit   是否除法/取模指令
        ds_div_signed,                    // 1 bit   除法是否有符号
        ds_div_rem,                       // 1 bit   取余数(1) / 取商(0)
        res_from_mem,                     // 1 bit   结果是否取自数据 RAM（load 类）
        src1_is_pc ? ds_pc : rj_value,    // 32 bit  ALU 源操作数 1
        src2_is_imm ? ds_imm : rkd_value, // 32 bit  ALU 源操作数 2
        gr_we,                            // 1 bit   通用寄存器写使能
        mem_we,                           // 1 bit   数据 RAM 写使能（store 类）
        ds_mem_size,                      // 3 bit   访存宽度：1=字节 2=半字 4=字
        ds_ld_signed,                     // 1 bit   load 结果是否符号扩展
        dest,                             // 5 bit   目标寄存器号
        rkd_value,                        // 32 bit  store 的写数据
        ds_pc                             // 32 bit  指令 PC（用于 trace）
    };

endmodule