# 测试用例介绍

| obj*n* | 对应测试                     |
| ------ | --------------------------------- |
| ex1_obj  | 不考虑相关引发的冲突的单发射五级流水 CPU |
| ex2_obj  | 使用阻塞的方法，加入适当的逻辑处理寄存器写后读数据相关引发的流水线冲突       |
| ex3_obj  | 使用前递的方法，加入适当的逻辑处理寄存器写后读数据相关引发的流水线冲突 |
| ex4_obj   |  添加算术逻辑运算类指令 slti、sltui、andi、ori、xori、sll、srl、sra、pcaddu12i                          |
| ex5_obj   | 添加转移指令 blt、bge、bltu、bgeu                          |
| ex6_obj   | 添加访存指令 ld.b、ld.h、ld.bu、ld.hu、st.b、sth                               |
| ex7_obj   | 添加乘除运算类指令 mul.w、mulh.w、mulh.wu、div.w、mod.w、div.wu、mod.wu                 |
| ex8_obj   | 异常中断支持                |
| ex9_obj   | 异常中断支持增量开发                 |

