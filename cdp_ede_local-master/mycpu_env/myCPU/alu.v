// alu.v —— 独热操作码 ALU（16 位操作码，但本模块只实现 0~11 的运算）
//
//   ★ 乘法不放在这里（第 5 章）★
//   原因：乘法器在 Artix-7 上由 DSP48 级联 + 进位链构成，组合延迟很大。
//   若把乘法结果并进下面这条"或树"多路选择，mul 的结果就会成为 alu_result
//   逻辑锥的一部分 —— 而 alu_result 是所有指令的 EXE->ID 前递数据来源。
//   综合器无法把乘法器从锥里剪掉（op_mul 是运行期信号、不是常量），
//   于是乘法器随前递一路串到 ID 分支比较 -> IF 取指地址，形成跨三级的长路径
//   （实测 22ns，@50MHz 要求 20ns，时序不收敛，上板必错）。
//   因此乘法器移到 EXE_stage.v 中单独实现，结果只送 es_to_ms_bus，
//   不进入 es_forward_data（乘法结果改由 MEM 级前递，见 mul_stall）。
//
//   除法（div/mod）也不在本模块内完成，由 EXE 级例化的 divider.v 多拍算出。
module ALU(
    input  wire [15:0] alu_op,
    input  wire [31:0] alu_src1,
    input  wire [31:0] alu_src2,
    output wire [31:0] alu_result
);

    wire op_add  = alu_op[ 0];
    wire op_sub  = alu_op[ 1];
    wire op_slt  = alu_op[ 2];
    wire op_sltu = alu_op[ 3];
    wire op_and  = alu_op[ 4];
    wire op_nor  = alu_op[ 5];
    wire op_or   = alu_op[ 6];
    wire op_xor  = alu_op[ 7];
    wire op_sll  = alu_op[ 8];
    wire op_srl  = alu_op[ 9];
    wire op_sra  = alu_op[10];
    wire op_lui  = alu_op[11];
    // alu_op[12..14] = mul.w / mulh.w / mulh.wu，由 EXE_stage 的乘法器处理，此处不使用

    // 加减法部件 (共享加法器)
    wire [31:0] add_sub_b = (op_sub | op_slt | op_sltu) ? ~alu_src2 : alu_src2;
    wire        cin       = (op_sub | op_slt | op_sltu) ? 1'b1      : 1'b0;
    wire [32:0] adder_res = {1'b0, alu_src1} + {1'b0, add_sub_b} + cin;
    wire [31:0] add_sub_res = adder_res[31:0];

    // 比较逻辑 (SLT / SLTU)
    // 符号溢出判断
    wire adder_ovf = (alu_src1[31] == add_sub_b[31]) && (add_sub_res[31] != alu_src1[31]);
    wire slt_res   = adder_ovf ^ add_sub_res[31];
    wire sltu_res  = ~adder_res[32]; // 进位借位标志

    // 移位运算 (低 5 位作为有效移位数)
    wire [ 4:0] shift_amt = alu_src2[4:0];
    wire [31:0] sll_res   = alu_src1 << shift_amt;
    wire [31:0] srl_res   = alu_src1 >> shift_amt;
    wire [31:0] sra_res   = ($signed(alu_src1)) >>> shift_amt;

    // 逻辑运算
    wire [31:0] and_res = alu_src1 & alu_src2;
    wire [31:0] nor_res = ~(alu_src1 | alu_src2);
    wire [31:0] or_res  = alu_src1 | alu_src2;
    wire [31:0] xor_res = alu_src1 ^ alu_src2;
    wire [31:0] lui_res = alu_src2;

    // 结果多路选择输出（不含乘法：乘法在 EXE_stage 中单独实现）
    assign alu_result = ({32{op_add | op_sub}} & add_sub_res)
                      | ({32{op_slt}}          & {31'b0, slt_res})
                      | ({32{op_sltu}}         & {31'b0, sltu_res})
                      | ({32{op_and}}          & and_res)
                      | ({32{op_nor}}          & nor_res)
                      | ({32{op_or}}           & or_res)
                      | ({32{op_xor}}          & xor_res)
                      | ({32{op_sll}}          & sll_res)
                      | ({32{op_srl}}          & srl_res)
                      | ({32{op_sra}}          & sra_res)
                      | ({32{op_lui}}          & lui_res);

endmodule
