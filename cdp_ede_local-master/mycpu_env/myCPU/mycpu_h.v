`ifndef MYCPU_H
`define MYCPU_H
    `define BR_BUS_WD         33   // {br_taken(1), br_target(32)}
    `define FS_TO_DS_BUS_WD   65   // {fs_adef(1), fs_inst(32), fs_pc(32)}   ← 第 6 章扩展档：+ADEF

    // ---------------------------------------------------------------
    // 第 6 章（异常与中断）为级间总线追加的字段
    //   DS -> ES ：原 160 位 + 19 位 = 179；扩展档再 +6（异常标志组）= 185
    //     新增 {ertn(1), ex_sys(1), csr_num(14), csr_re(1), csr_we(1), csr_xchg(1)}
    //     ex_sys  = 本指令会触发系统调用异常（syscall）
    //     csr_xchg= csrxchg（写掩码取 rj 值），为 0 时 csrwr 写掩码为全 1
    //   ES -> MS ：原 75 位 + {ertn(1), ex_sys(1)} = 77；扩展档 ex_sys→ex_flags(6) = 82
    //   MS -> WS ：原 70 位 + {ertn(1), ex_sys(1)} = 72；扩展档 = 77
    //
    // ★ 扩展档（EXP9）把原来 1 位的 ex_sys 换成 6 位的"异常标志组"：
    //     ex_flags[5:0] = {adef, ale, sys, brk, ine, int}
    //   多位并存、由写回级按优先级编码成 Ecode/EsubCode。
    //   这样每一级都不用知道"哪个异常优先"，只负责搬运。
    // ---------------------------------------------------------------
    `define DS_TO_ES_BUS_WD   184
    `define ES_TO_MS_BUS_WD   82
    `define MS_TO_WS_BUS_WD   77
    `define WS_TO_RF_BUS_WD   38   // {rf_we(1), rf_waddr(5), rf_wdata(32)}

    // ---------------------------------------------------------------
    // CSR 编号（指令中的 14 位立即数 csr_num 直接寻址）
    // ---------------------------------------------------------------
    `define CSR_CRMD    14'h000   // 当前模式信息
    `define CSR_PRMD    14'h001   // 例外前模式信息
    `define CSR_EUEN    14'h002   // 扩展部件使能（本设计无浮点，读 0）
    `define CSR_ECFG    14'h004   // 例外配置（局部中断使能 LIE）—— 汇编里叫 csr_ectl
    `define CSR_ESTAT   14'h005   // 例外状态
    `define CSR_ERA     14'h006   // 例外返回地址
    `define CSR_BADV    14'h007   // 出错虚地址
    `define CSR_EENTRY  14'h00c   // 例外入口地址
    `define CSR_SAVE0   14'h030   // 特权态软件暂存
    `define CSR_SAVE1   14'h031
    `define CSR_SAVE2   14'h032
    `define CSR_SAVE3   14'h033
    // 第 6 章扩展档（EXP9）：定时器与稳定计数器相关
    `define CSR_TID     14'h040   // 线程/处理器编号
    `define CSR_TCFG    14'h041   // 定时器配置：En[0] Periodic[1] InitVal[31:2]
    `define CSR_TVAL    14'h042   // 定时器当前计数值（只读）
    `define CSR_TICLR   14'h044   // 定时器中断清除（写 1 清 ESTAT.IS[11]，读恒 0）

    // ---------------------------------------------------------------
    // 异常代号 Ecode（手册表 7-7 例外编码表）
    // ---------------------------------------------------------------
    `define ECODE_INT   6'h00   // 中断
    `define ECODE_ADEF  6'h08   // 取指地址错
    `define ECODE_ALE   6'h09   // 地址非对齐
    `define ECODE_SYS   6'h0b   // 系统调用（syscall）
    `define ECODE_BRK   6'h0c   // 断点（break）
    `define ECODE_INE   6'h0d   // 指令不存在
    `define ECODE_IPE   6'h0e   // 指令特权等级错
`endif
