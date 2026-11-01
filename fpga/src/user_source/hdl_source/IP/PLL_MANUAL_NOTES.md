# S24 PLL源码说明

本阶段以sys_pll.v、video_pll.v作为直接Verilog工程引用；两个历史IPC不再属于活动工程引用。原始IPC保留用于溯源，不能用其重新生成并覆盖本版手工包装。

实际改动为`FEEDBK_PATH=CLKC0_INT`，外部`fbclk=0`；NORMAL模式、所有VCO/分频/相位值保持。改动使用TD自带EG4原语公开支持的内部反馈路径，消除外部反馈绕过本地网络的不确定补偿。VHDL镜像也已同步，但未参与本工程综合。

sys PLL仍为SD100MHz、MEM与SDRAM同相83.333333MHz；video PLL仍25MHz/125MHz。SDRAM时钟通过SD/sdram.v中的EG_LOGIC_ODDR输出寄存器转发。SDC显式定义该物理转发时钟及全部PLL输出，不能因工具未自动识别ODDR转发而漏检DQ路径。

验证：公开PLL/ODDR功能模型、小工程真实布局布线；整机最终结果另见阶段manifest与docs测试记录。内部反馈不补偿板外走线，所有关联时钟、PAD和硬IP延迟仍在最终STA内检查。本说明不表示时序或板测已经通过。
