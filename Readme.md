## 初赛提交要求

1. **截止时间**：北京时间 **2026 年 8 月 5 日 23 时 59 分 59 秒**。
2. **初赛评定指标**：初赛仅关注 `score.xlsx` 中的“系统计数器比值”和“功能分”。
3. **设计文档**：必须按照赛事要求在仓库根目录提交设计文档 `design.pdf`。
4. **成绩认定**：成绩以截止时间前由 CI 流水线实际测试得到的分数为准。超过截止
   时间后，参赛者不能再触发新的 CI 流水线。
5. **性能测试时序要求**：性能测试的 setup WNS 和 hold WNS 均不能为负，否则该
   次性能测试成绩无效。
6. **提交分支**：禁止直接向 `master` 分支上传或推送参赛代码。请基于 `master`
   新建分支，并在新分支中提交代码和触发 CI。
7. **Chiplab 版本**：比赛平台使用 Chiplab 的
   [`nscscc2026` 分支](https://gitee.com/loongson-edu/chiplab/tree/nscscc2026/)。

## 文件目录结构
- src/
    - mycpu/           【vivado支持的CPU IP完整源码】
        - xilinx_ip/   【CPU IP 内部使用到的 xilinx ip 】【可选】
            - IP名称    
                - *.xci\<x\>   
    - vivado_cannot/   【可选】
    - perf_clock.json  【性能测试CPU主频配置】
- bit/                 【存放各项测试生成好的bit文件】
- show/                【决赛展示内容，要求myCPU与src/目录里完全一致】
- score.xlsx
- .gitlab-ci.yml CI/CD 【配置文件（禁止修改）】
- design.pdf           【必须提交的设计文档】


## 注意事项
1. **master**分支是受保护的模板分支，请基于master分支建立自己的分支，进行设计文件的添加；如果master分支有变动，请及时合并master分支更新。  
2. **禁止修改** `.gitlab-ci.yml` 与 `tcl` 脚本。`.gitlab-ci.yml` 只引用赛事统一维护的外部 CI 模板；请严格按照模板要求放置文件，否则可能导致无法生成工程与产物。
3. **Xilinx IP 使用规范**  
　　- 若调用了 Xilinx IP（例如 Block RAM IP），需将定制文件 `*.xci`（或 `*.xcix`）放置于 `src/mycpu/xilinx_ip/` 目录下。  
　　- 每个 IP 独立文件夹存放，且文件夹中**仅包含** `.xci` 或 `.xcix` 文件，不得包含综合生成的文件。  
4. **性能测试 CPU 主频**
　　- 在 `src/perf_clock.json` 的 `cpu_clk_mhz` 字段中填写主频，允许范围为 10–200 MHz。
　　- 学生不再提交平台 PLL XCI；CI 根据该字段生成 Clock Wizard 配置，并固定系统时钟和 DDR 参考时钟。
5. **非 Vivado 支持语言**
　　- 若使用 Vivado 无法直接综合的硬件描述语言（SpinalHDL、Chisel），需提供：  
　　　　- 完整源码  
　　　　- 编译说明  
6. **参考与借鉴声明**
　　- 若 CPU 设计中参考了任何资料（如教材），需在文档中明确声明。
