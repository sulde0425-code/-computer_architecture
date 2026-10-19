`ifndef MYCPU_H
`define MYCPU_H
    `define BR_BUS_WD         33   // {br_taken(1), br_target(32)}
    `define FS_TO_DS_BUS_WD   64   // {fs_inst(32), fs_pc(32)}
    // {spare(1), alu_op(16), div_en(1), div_signed(1), div_rem(1), res_from_mem(1),
    //  alu_src1(32), alu_src2(32), gr_we(1), mem_we(1), mem_size(3), ld_signed(1),
    //  dest(5), rkd_value(32), ds_pc(32)}  = 1+16+3+1+32+32+1+1+3+1+5+32+32 = 160
    `define DS_TO_ES_BUS_WD   160
    `define ES_TO_MS_BUS_WD   75   // {res_from_mem(1), gr_we(1), mem_size(3), ld_signed(1), dest(5), alu_result(32), pc(32)}
    `define MS_TO_WS_BUS_WD   70   // {gr_we(1), dest(5), final_result(32), pc(32)}
    `define WS_TO_RF_BUS_WD   38   // {rf_we(1), rf_waddr(5), rf_wdata(32)}
`endif
