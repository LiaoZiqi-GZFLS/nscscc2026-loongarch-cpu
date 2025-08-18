## 文件目录结构
- src/
    - mycpu/           【vivado支持的CPU IP完整源码】
        - xilinx_ip/   【CPU IP 内部使用到的 xilinx ip 】【可选】
            - IP名称    
                - *.xci\<x\>   
    - vivado_cannot/   【可选】
    - perf_clk_pll.xci 【性能测试时的pll】
- bit/                 【存放各项测试生成好的bit文件】
- show/                【决赛展示内容，要求myCPU与src/目录里完全一致】
- score.xlsx
- .gitlab-ci.yml CI/CD 【配置文件（禁止修改）】
- design.pdf           【设计文档】


## 注意事项
1. **master**分支是受保护的模板分支，请基于master分支建立自己的分支，进行设计文件的添加；如果master分支有变动，请及时合并master分支更新。  
2. **禁止修改** `.gitlab-ci.yml` 与 `tcl` 脚本。请严格按照脚本要求放置文件，否则可能导致无法生成工程与产物。
3. **Xilinx IP 使用规范**  
　　- 若调用了 Xilinx IP（例如 Block RAM IP），需将定制文件 `*.xci`（或 `*.xcix`）放置于 `src/mycpu/xilinx_ip/` 目录下。  
　　- 每个 IP 独立文件夹存放，且文件夹中**仅包含** `.xci` 或 `.xcix` 文件，不得包含综合生成的文件。  
4. **非 Vivado 支持语言**  
　　- 若使用 Vivado 无法直接综合的硬件描述语言（SpinalHDL、Chisel），需提供：  
　　　　- 完整源码  
　　　　- 编译说明  
5. **参考与借鉴声明**  
　　- 若 CPU 设计中参考了任何资料（如教材），需在文档中明确声明。 