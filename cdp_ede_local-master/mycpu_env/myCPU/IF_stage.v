`include "mycpu_h.v"

module IF_stage(
 input wire clk,
 input wire reset,
 input wire ds_allowin,
 input wire flush,            // 第 6 章：写回级报异常 / ERTN，清空流水线并改指
 input wire [31:0] flush_pc,  // 第 6 章：异常入口地址 或 ERTN 返回地址（ERA）
 input wire [`BR_BUS_WD -1 :0] br_bus,
 output wire fs_to_ds_valid,
 output wire [`FS_TO_DS_BUS_WD-1 :0] fs_to_ds_bus,
 // inst sram interface
 output wire inst_sram_en,
 output wire [3:0] inst_sram_we,
 output wire [31:0] inst_sram_addr,
 output wire [31:0] inst_sram_wdata,
 input wire [31:0] inst_sram_rdata
 );
 //if级 握 手 信 号
 reg fs_valid;
 wire fs_ready_go;
 wire fs_allowin;
 wire to_fs_valid;

 wire [31:0] seq_pc; //顺 序 的 地 址
 wire [31:0] next_pc; //下 一 个 执 行 的 地 址， 可 能 会 跳 转

 wire br_taken; //跳 转 信 号
 wire [31:0] br_target;//跳 转 地 址

 assign {br_taken,br_target} = br_bus; //跳 转 信 号 传 递

 wire [31:0] fs_inst; //fs阶 段 的inst和pc,往 后 传 递
 reg [31:0] fs_pc;

 // 第 6 章扩展档（EXP9）：取指地址错异常 ADEF
 //   LoongArch 要求所有指令的 PC 都是字对齐的，地址最低两位不为 0 即触发 ADEF。
 //   判定放在 pre-IF（next_pc 生成之后、真正发起取指之前），
 //   这样"不该发生的取指"根本不会发出去（指导书 6.2.3 的强烈建议）。
 reg fs_adef;
 // 组合判定：本拍准备去取的这个 PC 是否非对齐
 //   （声明必须在使用之前，否则综合器报 used before declaration）
 //   注意 flush 那一拍的 flush_pc 由软件保证对齐，不参与 ADEF 判定
 wire adef_now = (next_pc[1:0] != 2'b00);
 always @(posedge clk) begin
     if (reset)                          fs_adef <= 1'b0;
     // ★ flush 这一拍同样要判定：ERTN 返回地址是软件用 csrwr 写进 ERA 的，
     //   可以是任意值（func 专门用非对齐的 ERA 来测 ADEF）。
     //   若在这里无条件清零，PC 会先被改成那个非对齐地址、下一拍再 +4，
     //   于是报出来的出错 PC 比真实地址大 4，BADV 也就跟着错。
     else if (flush)                     fs_adef <= (flush_pc[1:0] != 2'b00);
     else if (to_fs_valid && fs_allowin) fs_adef <= adef_now;
 end

 //if向id传 递 的bus（第 6 章扩展档：多带 1 位 ADEF 标志）
 assign fs_to_ds_bus = {fs_adef, fs_inst, fs_pc};

 //pre-if stage
 assign to_fs_valid = ~reset;
 assign seq_pc = fs_pc + 3'h4; //顺 序
 // 第 6 章：flush 的优先级高于分支 —— 异常入口 / ERTN 返回地址直接覆盖取指 PC
 assign next_pc = flush        ? flush_pc :
                  (br_taken == 1 ) ? br_target :seq_pc;

 //IF stage
 assign fs_ready_go = 1'b1; //可 以 传 输
 assign fs_allowin = !fs_valid || fs_ready_go && ds_allowin; //允 许 进 入，
 // 分支/跳转被采取时，IF 级中已预取的那条错误路径指令必须被取消(flush)。
 // 这里组合地门控 fs_to_ds_valid：br_taken=1 时禁止其进入 ID 级。
 assign fs_to_ds_valid = fs_valid && fs_ready_go && ~br_taken && ~flush;
 always@(posedge clk)begin
 if(reset)begin
 fs_valid <= 1'b0;
 end else if(fs_allowin)begin
 fs_valid <= to_fs_valid;
 end
end

 // 第 6 章：flush（异常入口 / ERTN 返回）时必须无条件改写 PC。
 //   不能只依赖 to_fs_valid && fs_allowin —— 当后级反压导致 fs_allowin=0 时，
 //   fs_pc 会停在旧地址，取指地址虽然已经发出去了，但 fs_pc 与随后送进 ID 的
 //   指令配不上，程序就会沿着异常处理程序一路跑飞。
 always@(posedge clk)begin
 if(reset)begin
 fs_pc <= 32'h1bfffffc;
 end else if(flush)begin
    fs_pc <= flush_pc;
 end else if(to_fs_valid && fs_allowin)begin
    fs_pc <= next_pc;
 end
 end

 // 第 6 章：flush（异常入口 / ERTN 返回）时必须强制发出一次取指。
 //   原来只写 (to_fs_valid && fs_allowin)，而 flush 那一拍后级反压可能让
 //   fs_allowin=0，于是这一拍根本没去读指令 RAM；但 fs_pc 已经被改写成
 //   flush_pc 了，下一拍 fs_inst 拿到的仍是上一次的旧读数据 —— 指令与 PC
 //   配不上，异常返回后程序会沿着错误的数据一路跑飞。
 // 第 6 章扩展档：出现 ADEF 的地址一律不去取指。
 //   这个 PC 本身已经不对了，用它访存的后果不可预期，最坏会死机。
 assign inst_sram_en = (flush || (to_fs_valid && fs_allowin)) & ~adef_now;
 assign inst_sram_we = 4'h0; //写
 assign inst_sram_addr =next_pc;
 assign inst_sram_wdata = 32'b0;

 assign fs_inst = inst_sram_rdata;

endmodule