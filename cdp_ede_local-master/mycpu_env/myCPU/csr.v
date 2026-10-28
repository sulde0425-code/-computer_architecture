`include "mycpu_h.v"

// ============================================================================
// 控制状态寄存器（CSR）模块 —— 第 6 章
//
// 设计要点（指导书 6.4）：
//   1. 所有 CSR 集中在本模块实现，避免"又集中又分散"；
//   2. 端口分两类：
//        - 指令访问接口（csr_re / csr_num / csr_rvalue / csr_we / csr_wmask / csr_wvalue）
//        - 与处理器内部硬件直接交互的接口（ex_entry / era_pc / has_int /
//          ertn_flush / wb_ex / wb_ecode / wb_esubcode / wb_pc / wb_badv /
//          hw_int_in / ipi_int_in / counter / tid）
//   3. 写操作统一为逐位"掩码写入"：new = wmask & wvalue | ~wmask & old
//
// 已实现的 CSR：
//   基础档（EXP8）  CRMD / PRMD / ESTAT / ERA / EENTRY / SAVE0~3 / BADV
//   扩展档（EXP9）  ECFG(中断局部使能) / TID / TCFG / TVAL / TICLR
//                   + 核内定时器 timer_cnt + 64 位稳定计数器 counter
//
// TLB 相关 CSR 本版未实现（读返回 0、写被忽略），符合"访问未实现 CSR
// 读返回全 0、写不修改状态"的规定。
// ============================================================================
module csr(
    input  wire        clk,
    input  wire        reset,

    // ---------------- 指令访问接口 ----------------
    input  wire        csr_re,        // 读使能（csrrd/csrwr/csrxchg 都伴随读）
    input  wire [13:0] csr_num,       // CSR 寻址值（指令中的 14 位立即数）
    output wire [31:0] csr_rvalue,    // 读返回值（组合读出，未实现者返回 0）
    input  wire        csr_we,        // 写使能
    input  wire [31:0] csr_wmask,     // 写掩码（csrxchg 时为 rj 值，csrwr 时为全 1）
    input  wire [31:0] csr_wvalue,    // 写数据（rd 的旧值）

    // ---------------- 与处理器内部硬件交互的接口（输出） ----------------
    output wire [31:0] ex_entry,      // 异常处理入口地址（送 IF 级）
    output wire [31:0] era_pc,        // 异常返回地址（ERTN 时送 IF 级）
    output wire        has_int,       // 核内存在待处理中断（送 ID 级）
    output wire [63:0] counter,       // 64 位稳定计数器（rdcntvl/vh.w 用）
    output wire [31:0] tid,           // TID 当前值（rdcntid 用）

    // ---------------- 与处理器内部硬件交互的接口（输入） ----------------
    input  wire [ 7:0] hw_int_in,     // 8 个硬中断输入引脚（本 SoC 未接，恒 0）
    input  wire        ipi_int_in,    // 核间中断输入（单核，恒 0）

    input  wire        ertn_flush,    // ERTN 指令在写回级执行有效
    input  wire        wb_ex,         // 写回级指令触发异常
    input  wire [ 5:0] wb_ecode,      // 异常代号
    input  wire [ 8:0] wb_esubcode,   // 异常副代号
    input  wire [31:0] wb_pc,         // 触发异常指令的 PC
    input  wire [31:0] wb_badv        // 触发异常指令的出错虚地址
);

    // ========================================================================
    // 各 CSR 的域
    // ========================================================================
    // CRMD ：PLV[1:0]  IE[2]  DA[3]  PG[4]  DATF[5]  DATM[6]
    reg  [ 1:0] csr_crmd_plv;
    reg         csr_crmd_ie;
    reg         csr_crmd_da;
    reg         csr_crmd_pg;
    reg         csr_crmd_datf;
    reg         csr_crmd_datm;

    // PRMD ：PPLV[1:0]  PIE[2]
    reg  [ 1:0] csr_prmd_pplv;
    reg         csr_prmd_pie;

    // ESTAT ：IS[12:0]（中断状态）  Ecode[21:16]  EsubCode[30:22]
    //   IS[1:0]  ：2 个软中断，仅由 CSR 写指令更新
    //   IS[9:2]  ：8 个硬中断，采样硬件引脚
    //   IS[10]   ：未定义，恒 0
    //   IS[11]   ：定时器中断，由 timer_cnt 置起、由 TICLR.CLR 清 0
    //   IS[12]   ：核间中断，采样 ipi_int_in
    reg  [12:0] csr_estat_is;
    reg  [ 5:0] csr_estat_ecode;
    reg  [ 8:0] csr_estat_esubcode;

    // ECFG ：LIE[12:0] 局部中断使能（与 IS 的每一位一一对应）
    reg  [12:0] csr_ecfg_lie;

    // ERA / BADV / EENTRY / SAVE0~3 / TID
    reg  [31:0] csr_era_pc;
    reg  [31:0] csr_badv_vaddr;
    reg  [25:0] csr_eentry_va;      // EENTRY 的 VA 域，低 6 位恒 0
    reg  [31:0] csr_save0_data;
    reg  [31:0] csr_save1_data;
    reg  [31:0] csr_save2_data;
    reg  [31:0] csr_save3_data;
    reg  [31:0] csr_tid_tid;

    // 定时器：TCFG 的 En / Periodic / InitVal
    reg         csr_tcfg_en;
    reg         csr_tcfg_periodic;
    reg  [29:0] csr_tcfg_initval;
    reg  [31:0] timer_cnt;

    // 稳定计数器：每周期加 1，供 rdcntvl.w / rdcntvh.w 读取
    reg  [63:0] counter_r;

    // 写 TCFG 时"即将写入"的完整寄存器值（指导书 6.4.14）
    wire [31:0] tcfg_next_value = (csr_wmask[31:0] & csr_wvalue[31:0])
                                | (~csr_wmask[31:0] & {csr_tcfg_initval,
                                                       csr_tcfg_periodic,
                                                       csr_tcfg_en});

    // ========================================================================
    // CRMD
    //   触发异常：PLV <- 0（进入最高特权级）、IE <- 0（关中断）
    //   ERTN 返回：PLV <- PRMD.PPLV、IE <- PRMD.PIE
    //   复位：PLV=0、IE=0；DA=1、PG=0（仅支持直接地址翻译模式）
    // ========================================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_crmd_plv  <= 2'b0;
            csr_crmd_ie   <= 1'b0;
            csr_crmd_da   <= 1'b1;
            csr_crmd_pg   <= 1'b0;
            csr_crmd_datf <= 1'b0;
            csr_crmd_datm <= 1'b0;
        end else begin
            if (wb_ex) begin
                csr_crmd_plv <= 2'b0;
                csr_crmd_ie  <= 1'b0;
            end else if (ertn_flush) begin
                csr_crmd_plv <= csr_prmd_pplv;
                csr_crmd_ie  <= csr_prmd_pie;
            end else if (csr_we && csr_num == `CSR_CRMD) begin
                csr_crmd_plv  <= (csr_wmask[ 1: 0] & csr_wvalue[ 1: 0]) | (~csr_wmask[ 1: 0] & csr_crmd_plv);
                csr_crmd_ie   <= (csr_wmask[    2] & csr_wvalue[    2]) | (~csr_wmask[    2] & csr_crmd_ie);
                csr_crmd_da   <= (csr_wmask[    3] & csr_wvalue[    3]) | (~csr_wmask[    3] & csr_crmd_da);
                csr_crmd_pg   <= (csr_wmask[    4] & csr_wvalue[    4]) | (~csr_wmask[    4] & csr_crmd_pg);
                csr_crmd_datf <= (csr_wmask[    5] & csr_wvalue[    5]) | (~csr_wmask[    5] & csr_crmd_datf);
                csr_crmd_datm <= (csr_wmask[    6] & csr_wvalue[    6]) | (~csr_wmask[    6] & csr_crmd_datm);
            end
        end
    end

    // ========================================================================
    // PRMD ：触发异常时保存异常前的 PLV / IE；ERTN 时由 CRMD 读回
    // ========================================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_prmd_pplv <= 2'b0;
            csr_prmd_pie  <= 1'b0;
        end else if (wb_ex) begin
            csr_prmd_pplv <= csr_crmd_plv;
            csr_prmd_pie  <= csr_crmd_ie;
        end else if (csr_we && csr_num == `CSR_PRMD) begin
            csr_prmd_pplv <= (csr_wmask[1:0] & csr_wvalue[1:0]) | (~csr_wmask[1:0] & csr_prmd_pplv);
            csr_prmd_pie  <= (csr_wmask[  2] & csr_wvalue[  2]) | (~csr_wmask[  2] & csr_prmd_pie);
        end
    end

    // ========================================================================
    // ESTAT
    //   IS[1:0]      ：两个软中断，仅由 CSR 写指令更新
    //   IS[9:2]      ：8 个硬中断，采样引脚
    //   IS[10]       ：未定义，恒 0
    //   IS[11]       ：定时器中断（timer_cnt 到 0 置起；TICLR.CLR 写 1 清零）
    //   IS[12]       ：核间中断，采样引脚
    //   Ecode/Esub   ：触发异常时由硬件填入，软件只读
    // ========================================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_estat_is       <= 13'b0;
            csr_estat_ecode    <= 6'b0;
            csr_estat_esubcode <= 9'b0;
        end else begin
            if (wb_ex) begin
                csr_estat_ecode    <= wb_ecode;
                csr_estat_esubcode <= wb_esubcode;
            end
            // IS[1:0] 软中断：只由 CSR 写更新
            if (csr_we && csr_num == `CSR_ESTAT) begin
                csr_estat_is[1:0] <= (csr_wmask[1:0] & csr_wvalue[1:0])
                                   | (~csr_wmask[1:0] & csr_estat_is[1:0]);
            end
            // IS[9:2] 硬中断：直接采样引脚
            csr_estat_is[9:2] <= hw_int_in[7:0];
            // IS[10] 未定义，恒 0
            csr_estat_is[10]  <= 1'b0;
            // IS[11] 定时器中断
            if (timer_cnt[31:0] == 32'b0)
                csr_estat_is[11] <= 1'b1;
            else if (csr_we && csr_num == `CSR_TICLR && csr_wmask[0] && csr_wvalue[0])
                csr_estat_is[11] <= 1'b0;
            // IS[12] 核间中断
            csr_estat_is[12] <= ipi_int_in;
        end
    end

    // ========================================================================
    // ECFG ：局部中断使能，与 ESTAT.IS 逐位对应
    //   ⚠ bit10 对应的是 ESTAT.IS[10]（手册未定义），因此 LIE[10] 也不可写、恒为 0。
    //     （实测：软件写 ECFG=0x1fff 后再次 csrwr 读回的旧值是 0x1bff 而不是 0x1fff，
    //       差的正是 bit10 —— 黄金模型把它当作恒 0 位。）
    // ========================================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_ecfg_lie <= 13'b0;
        end else if (csr_we && csr_num == `CSR_ECFG) begin
            csr_ecfg_lie[ 9: 0] <= (csr_wmask[ 9: 0] & csr_wvalue[ 9: 0])
                                 | (~csr_wmask[ 9: 0] & csr_ecfg_lie[ 9: 0]);
            csr_ecfg_lie[   10] <= 1'b0;   // 未定义位，恒 0
            csr_ecfg_lie[12:11] <= (csr_wmask[12:11] & csr_wvalue[12:11])
                                 | (~csr_wmask[12:11] & csr_ecfg_lie[12:11]);
        end
    end

    // ========================================================================
    // ERA ：触发异常时记录该指令 PC（精确异常：写回级的 PC）
    // ========================================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_era_pc <= 32'b0;
        end else if (wb_ex) begin
            csr_era_pc <= wb_pc;
        end else if (csr_we && csr_num == `CSR_ERA) begin
            csr_era_pc <= (csr_wmask & csr_wvalue) | (~csr_wmask & csr_era_pc);
        end
    end

    // ========================================================================
    // BADV ：记录出错虚地址（ADEF 填出错 PC，ALE 填访存地址）
    //   ⚠ 只有"确实存在出错虚地址"的异常才更新 BADV。
    //     （实测：func 在 ADEF/ALE 之后会用一条 syscall 返回内核态再读 BADV 检查，
    //       若 syscall 也去更新 BADV=0，就会把刚才的地址冲掉，测试随即失败。）
    //     因此这里按 Ecode 判断：ADEF / ALE 才写，SYS / BRK / INE / INT 保持原值。
    // ========================================================================
    wire wb_badv_valid = (wb_ecode == `ECODE_ADEF) || (wb_ecode == `ECODE_ALE);
    always @(posedge clk) begin
        if (reset) begin
            csr_badv_vaddr <= 32'b0;
        end else if (wb_ex && wb_badv_valid) begin
            csr_badv_vaddr <= wb_badv;
        end else if (csr_we && csr_num == `CSR_BADV) begin
            csr_badv_vaddr <= (csr_wmask & csr_wvalue) | (~csr_wmask & csr_badv_vaddr);
        end
    end

    // ========================================================================
    // EENTRY ：异常入口地址，低 6 位恒 0
    // ========================================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_eentry_va <= 26'b0;
        end else if (csr_we && csr_num == `CSR_EENTRY) begin
            csr_eentry_va <= (csr_wmask[31:6] & csr_wvalue[31:6]) | (~csr_wmask[31:6] & csr_eentry_va);
        end
    end

    // ========================================================================
    // SAVE0~3 ：特权态软件临时存放数据
    // ========================================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_save0_data <= 32'b0;
            csr_save1_data <= 32'b0;
            csr_save2_data <= 32'b0;
            csr_save3_data <= 32'b0;
        end else begin
            if (csr_we && csr_num == `CSR_SAVE0)
                csr_save0_data <= (csr_wmask & csr_wvalue) | (~csr_wmask & csr_save0_data);
            if (csr_we && csr_num == `CSR_SAVE1)
                csr_save1_data <= (csr_wmask & csr_wvalue) | (~csr_wmask & csr_save1_data);
            if (csr_we && csr_num == `CSR_SAVE2)
                csr_save2_data <= (csr_wmask & csr_wvalue) | (~csr_wmask & csr_save2_data);
            if (csr_we && csr_num == `CSR_SAVE3)
                csr_save3_data <= (csr_wmask & csr_wvalue) | (~csr_wmask & csr_save3_data);
        end
    end

    // ========================================================================
    // TID ：软件可写，rdcntid 指令读出
    // ========================================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_tid_tid <= 32'b0;
        end else if (csr_we && csr_num == `CSR_TID) begin
            csr_tid_tid <= (csr_wmask & csr_wvalue) | (~csr_wmask & csr_tid_tid);
        end
    end

    // ========================================================================
    // 定时器：TCFG / timer_cnt / TVAL
    //   写 TCFG 且新值 En=1 时，用新写入的 InitVal 装载 timer_cnt；
    //   En=1 且 timer_cnt != 0xffffffff 时每周期减 1；
    //   减到 0 时：周期模式自动重载，非周期模式继续减成 0xffffffff 后停住
    //   （这正是示例代码里 timer_cnt != 32'hffffffff 这个条件的用意）
    //   注：减到 0 的那一拍会置起 ESTAT.IS[11]（见 ESTAT 节），
    //       这里 timer_cnt 本身在下一拍才变成 0xffffffff，不影响 IS。
    // ========================================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_tcfg_en       <= 1'b0;
            csr_tcfg_periodic <= 1'b0;
            csr_tcfg_initval  <= 30'b0;
        end else if (csr_we && csr_num == `CSR_TCFG) begin
            csr_tcfg_en       <= tcfg_next_value[0];
            csr_tcfg_periodic <= tcfg_next_value[1];
            csr_tcfg_initval  <= tcfg_next_value[31:2];
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            timer_cnt <= 32'hffffffff;
        end else if (csr_we && csr_num == `CSR_TCFG && tcfg_next_value[0]) begin
            // 软件开启定时器（新值 En=1）的同时装载计数初值
            timer_cnt <= {tcfg_next_value[31:2], 2'b0};
        end else if (csr_tcfg_en && timer_cnt != 32'hffffffff) begin
            if (timer_cnt[31:0] == 32'b0 && csr_tcfg_periodic)
                timer_cnt <= {csr_tcfg_initval, 2'b0};   // 周期模式：自动重载
            else
                timer_cnt <= timer_cnt - 1'b1;
        end
    end

    // ========================================================================
    // 稳定计数器：每周期加 1（rdcntvl.w / rdcntvh.w 读取）
    // ========================================================================
    always @(posedge clk) begin
        if (reset) counter_r <= 64'b0;
        else       counter_r <= counter_r + 1'b1;
    end

    // ========================================================================
    // 读出：每个 CSR 一个读出值，按 csr_num 选择
    // ========================================================================
    wire [31:0] csr_crmd_rvalue = {25'b0, csr_crmd_datm, csr_crmd_datf, csr_crmd_pg,
                                          csr_crmd_da,   csr_crmd_ie,   csr_crmd_plv};
    wire [31:0] csr_prmd_rvalue = {29'b0, csr_prmd_pie, csr_prmd_pplv};
    wire [31:0] csr_ecfg_rvalue = {19'b0, csr_ecfg_lie};
    // ESTAT 读出布局：bit31 保留、bit30:22 EsubCode、bit21:16 Ecode、
    //                 bit15:13 保留、bit12:0 IS
    wire [31:0] csr_estat_rvalue= {1'b0, csr_estat_esubcode, csr_estat_ecode, 3'b0,
                                   csr_estat_is};
    wire [31:0] csr_era_rvalue  = csr_era_pc;
    wire [31:0] csr_badv_rvalue = csr_badv_vaddr;
    wire [31:0] csr_eentry_rvalue = {csr_eentry_va, 6'b0};
    wire [31:0] csr_tval_rvalue = timer_cnt;      // TVAL 是只读的当前计数值
    wire [31:0] csr_ticlr_rvalue = 32'b0;         // TICLR 读恒 0

    assign csr_rvalue = {32{csr_num == `CSR_CRMD  }} & csr_crmd_rvalue
                      | {32{csr_num == `CSR_PRMD  }} & csr_prmd_rvalue
                      | {32{csr_num == `CSR_ECFG  }} & csr_ecfg_rvalue
                      | {32{csr_num == `CSR_ESTAT }} & csr_estat_rvalue
                      | {32{csr_num == `CSR_ERA   }} & csr_era_rvalue
                      | {32{csr_num == `CSR_BADV  }} & csr_badv_rvalue
                      | {32{csr_num == `CSR_EENTRY}} & csr_eentry_rvalue
                      | {32{csr_num == `CSR_SAVE0 }} & csr_save0_data
                      | {32{csr_num == `CSR_SAVE1 }} & csr_save1_data
                      | {32{csr_num == `CSR_SAVE2 }} & csr_save2_data
                      | {32{csr_num == `CSR_SAVE3 }} & csr_save3_data
                      | {32{csr_num == `CSR_TID   }} & csr_tid_tid
                      | {32{csr_num == `CSR_TCFG  }} & {csr_tcfg_initval,
                                                        csr_tcfg_periodic,
                                                        csr_tcfg_en}
                      | {32{csr_num == `CSR_TVAL  }} & csr_tval_rvalue
                      | {32{csr_num == `CSR_TICLR }} & csr_ticlr_rvalue;

    // ========================================================================
    // 送往其他流水级的硬件信号
    // ========================================================================
    assign ex_entry = {csr_eentry_va, 6'b0};   // 异常入口
    assign era_pc   = csr_era_pc;              // ERTN 返回地址
    assign counter  = counter_r;               // 稳定计数器
    assign tid      = csr_tid_tid;             // TID

    // 中断判定（指导书 6.2.1）：
    //   局部使能 ECFG.LIE 与中断状态 ESTAT.IS 逐位相与，只要有一位有效，
    //   且全局使能 CRMD.IE 打开，即认为核内有待处理中断。
    //   la32r 不考虑多个中断的优先级。
    assign has_int = ((csr_estat_is[12:0] & csr_ecfg_lie[12:0]) != 13'b0)
                     && (csr_crmd_ie == 1'b1);

endmodule
