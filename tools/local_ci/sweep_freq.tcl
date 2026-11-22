# 频率可行性扫描:Clock Wizard 在哪些请求频率下能同时满足
# sys=100±0.001 与 ddr=200±0.001,cpu 误差≤1%(与 CI 门禁一致)
create_project -in_memory -part xc7a200tfbg676-2
set xci D:/code/Vivado/Loongarch_workspace/chiplab/chip/soc_demo/nscscc-team/xilinx_ip/clk_pll/clk_pll.xci
file delete -force [file dirname $xci]/gen
read_ip $xci
set ip [get_ips clk_pll]
proc actual_freq {ip row} {
    set s [get_property CONFIG.C_OUTCLK_SUM_ROW$row $ip]
    if {![regexp {__([0-9]+[.][0-9]+)__} $s _ f]} { return -1.0 }
    return [expr {double($f)}]
}
puts "SWEEP_START"
for {set f 100.0} {$f <= 160.0} {set f [expr {$f + 1.0}]} {
    set_property -dict [list \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ [format %.6f $f] \
        CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {100.000000} \
        CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {200.000000} \
        CONFIG.CLK_OUT1_PORT {cpu_clk} \
        CONFIG.CLK_OUT2_PORT {sys_clk} \
        CONFIG.CLK_OUT3_PORT {ddr_clk} \
    ] $ip
    generate_target all $ip
    set cpu [actual_freq $ip 1]
    set sys [actual_freq $ip 2]
    set ddr [actual_freq $ip 3]
    set cpu_ok [expr {abs($cpu - $f) <= [expr {max(0.001, $f * 0.01)}]}]
    set sys_ok [expr {abs($sys - 100.0) <= 0.001}]
    set ddr_ok [expr {abs($ddr - 200.0) <= 0.001}]
    puts [format "req=%.1f cpu=%.6f sys=%.6f ddr=%.6f cpu_ok=%d sys_ok=%d ddr_ok=%d" \
        $f $cpu $sys $ddr $cpu_ok $sys_ok $ddr_ok]
}
puts "SWEEP_END"
