`include "mycpu_h.v"

module IF_stage(
 input wire clk,
 input wire reset,
 input wire ds_allowin,
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

 //if向id传 递 的bus
 assign fs_to_ds_bus = {fs_inst,fs_pc};

 //pre-if stage
 assign to_fs_valid = ~reset;
 assign seq_pc = fs_pc + 3'h4; //顺 序
 assign next_pc = (br_taken == 1 ) ? br_target :seq_pc;

 //IF stage
 assign fs_ready_go = 1'b1; //可 以 传 输
 assign fs_allowin = !fs_valid || fs_ready_go && ds_allowin; //允 许 进 入，
 // 分支/跳转被采取时，IF 级中已预取的那条错误路径指令必须被取消(flush)。
 // 这里组合地门控 fs_to_ds_valid：br_taken=1 时禁止其进入 ID 级。
 assign fs_to_ds_valid = fs_valid && fs_ready_go && ~br_taken;
 always@(posedge clk)begin
 if(reset)begin
 fs_valid <= 1'b0;
 end else if(fs_allowin)begin
 fs_valid <= to_fs_valid;
 end
end

 always@(posedge clk)begin
 if(reset)begin
 fs_pc <= 32'h1bfffffc;
 end else if(to_fs_valid && fs_allowin)begin
    fs_pc <= next_pc;
 end
 end

 assign inst_sram_en = to_fs_valid && fs_allowin; //
 assign inst_sram_we = 4'h0; //写
 assign inst_sram_addr =next_pc;
 assign inst_sram_wdata = 32'b0;

 assign fs_inst = inst_sram_rdata;

endmodule