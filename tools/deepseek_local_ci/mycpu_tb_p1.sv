/*------------------------------------------------------------------------------
--------------------------------------------------------------------------------
Copyright (c) 2016, Loongson Technology Corporation Limited.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this 
list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, 
this list of conditions and the following disclaimer in the documentation and/or
other materials provided with the distribution.

3. Neither the name of Loongson Technology Corporation Limited nor the names of 
its contributors may be used to endorse or promote products derived from this 
software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND 
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED 
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE 
DISCLAIMED. IN NO EVENT SHALL LOONGSON TECHNOLOGY CORPORATION LIMITED BE LIABLE
TO ANY PARTY FOR DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE 
GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--------------------------------------------------------------------------------
------------------------------------------------------------------------------*/
`timescale 1ns / 1ps
`include "soc_config.vh"

`define CONFREG_NUM_REG         u_soc_top.u_confreg.num_data
`define CONFREG_OPEN_TRACE      1'b0
`define CONFREG_NUM_MONITOR     u_soc_top.u_confreg.num_monitor
`define UART_PSEL               u_soc_top.APB_DEV.uart0.PSEL
`define UART_PENBLE             u_soc_top.APB_DEV.uart0.PENABLE
`define UART_PWRITE             u_soc_top.APB_DEV.uart0.PWRITE
`define UART_WADDR              u_soc_top.APB_DEV.uart0.PADDR[7:0]
`define UART_WDATA              u_soc_top.APB_DEV.uart0.PWDATA[7:0]
`define MIG_AXI                 u_soc_top.ddr3.u_axi_wrap_ddr.mig_axi
`define END_PC 32'h1c000200



module tb_top( );
reg resetn;
reg clk;

//goio
wire [15:0] led;
wire [1 :0] led_rg0;
wire [1 :0] led_rg1;
wire [7 :0] num_csn;
wire [6 :0] num_a_g;
wire [7 :0] switch;
wire [3 :0] btn_key_col;
wire [3 :0] btn_key_row;
wire [1 :0] btn_step;
assign switch      = 8'hff;
assign btn_key_row = 4'd0;
assign btn_step    = 2'd3;

//ddr3
wire  [12:0]  ddr3_addr;
wire  [2 :0]  ddr3_ba;
wire  ddr3_ras_n;
wire  ddr3_cas_n;
wire  ddr3_we_n;
wire  ddr3_odt;
wire  ddr3_reset_n;
wire  ddr3_cke;
wire  [1:0]  ddr3_dm;
wire  ddr3_ck_p;
wire  ddr3_ck_n;
wire  [15:0]  ddr3_dq;
wire  [1:0]  ddr3_dqs_p;
wire  [1:0]  ddr3_dqs_n;

initial
begin
    clk = 1'b0;
    resetn = 1'b0;
    #2000;
    resetn = 1'b1;
end
always #5 clk=~clk;
soc_top #(.SIMULATION(1'b1)) u_soc_top
(
       .resetn_fpga (resetn     ), 
       .clk         (clk        ),

        //------gpio-------
        .num_csn    (num_csn    ),
        .num_a_g    (num_a_g    ),
        .led        (led        ),
        .led_rg0    (led_rg0    ),
        .led_rg1    (led_rg1    ),
        .switch_fpga(switch     ),
        .btn_key_col(btn_key_col),
        .btn_key_row(btn_key_row),
        .btn_step_fpga(btn_step   ),

        //------ddr3-------
        .ddr3_addr               ( ddr3_addr      ),
        .ddr3_ba                 ( ddr3_ba        ),
        .ddr3_ras_n              ( ddr3_ras_n     ),
        .ddr3_cas_n              ( ddr3_cas_n     ),
        .ddr3_we_n               ( ddr3_we_n      ),
        .ddr3_odt                ( ddr3_odt       ),
        .ddr3_reset_n            ( ddr3_reset_n   ),
        .ddr3_cke                ( ddr3_cke       ),
        .ddr3_dm                 ( ddr3_dm        ),
        .ddr3_ck_p               ( ddr3_ck_p      ),
        .ddr3_ck_n               ( ddr3_ck_n      ),
        .ddr3_dq                 ( ddr3_dq        ),
        .ddr3_dqs_p              ( ddr3_dqs_p     ),
        .ddr3_dqs_n              ( ddr3_dqs_n     )
    );   

//"cpu_clk" means cpu core clk
//"sys_clk" means system clk
//"wb" means write-back stage in pipeline
//"rf" means regfiles in cpu
//"w" in "wen/wnum/wdata" means writing
wire cpu_clk;
wire sys_clk;
wire [31:0] debug_wb_pc;
wire [3 :0] debug_wb_rf_wen;
wire [4 :0] debug_wb_rf_wnum;
wire [31:0] debug_wb_rf_wdata;
assign cpu_clk           = u_soc_top.cpu_clk;
assign sys_clk           = u_soc_top.sys_clk;
assign debug_wb_pc       = u_soc_top.debug_wb_pc;
assign debug_wb_rf_wen   = u_soc_top.debug_wb_rf_wen;
assign debug_wb_rf_wnum  = u_soc_top.debug_wb_rf_wnum;
assign debug_wb_rf_wdata = u_soc_top.debug_wb_rf_wdata;

//monitor numeric display
reg [7:0] err_count;
wire [31:0] confreg_num_reg = `CONFREG_NUM_REG;
reg  [31:0] confreg_num_reg_r;
always @(posedge sys_clk)
begin
    confreg_num_reg_r <= confreg_num_reg;
    if (!resetn)
    begin
        err_count <= 8'd0;
    end
    else if (confreg_num_reg_r != confreg_num_reg && `CONFREG_NUM_MONITOR)
    begin
        if(confreg_num_reg[7:0]!=confreg_num_reg_r[7:0]+1'b1)
        begin
            $display("--------------------------------------------------------------");
            $display("[%t] Error(%d)!!! Occurred in number 8'd%02d Functional Test Point!",$time, err_count, confreg_num_reg[31:24]);
            $display("--------------------------------------------------------------");
            err_count <= err_count + 1'b1;
        end
        else if(confreg_num_reg[31:24]!=confreg_num_reg_r[31:24]+1'b1)
        begin
            $display("--------------------------------------------------------------");
            $display("[%t] Error(%d)!!! Unknown, Functional Test Point numbers are unequal!",$time,err_count);
            $display("--------------------------------------------------------------");
            $display("==============================================================");
            err_count <= err_count + 1'b1;
        end
        else
        begin
            $display("----[%t] Number 8'd%02d Functional Test Point PASS!!!", $time, confreg_num_reg[31:24]);
        end
    end
end

//monitor test
initial
begin
    $timeformat(-9,0," ns",10);
    while(!resetn) #5;
    $display("==============================================================");
    $display("Test begin!");

    #10000;
    while(`CONFREG_NUM_MONITOR)
    begin
        #10000;
        $display ("        [%t] Test is running, debug_wb_pc = 0x%8h",$time, debug_wb_pc);
    end
end


// ==== P0 DBG probes v2 (completion-queue commit + fetch) ====
wire [4:0] dbg_pushPtr = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_robInfo_pushPtr;
wire [4:0] dbg_popPtr  = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_robInfo_popPtr;
wire [1:0] dbg_popCnt  = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_robInfo_popCount;
wire       dbg_flush   = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_flush;
wire dbg_p0_valid = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_0_valid;
wire dbg_p0_ready = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_0_ready;
wire dbg_p0_cmplt = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_0_payload_state_complete;
wire dbg_p0_excv  = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_0_payload_state_except_valid;
wire [31:0] dbg_p0_pc = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_0_payload_info_uop_pc;
wire dbg_p1_valid = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_1_valid;
wire dbg_p1_ready = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_1_ready;
wire dbg_p1_cmplt = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_1_payload_state_complete;
wire dbg_p1_excv  = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_1_payload_state_except_valid;
wire [31:0] dbg_p1_pc = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_1_payload_info_uop_pc;
wire dbg_p2_valid = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_2_valid;
wire dbg_p2_ready = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_2_ready;
wire dbg_p2_cmplt = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_2_payload_state_complete;
wire dbg_p2_excv  = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_2_payload_state_except_valid;
wire [31:0] dbg_p2_pc = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_2_payload_info_uop_pc;
wire        dbg_push0_v = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_push_0_valid;
wire        dbg_push0_r = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_push_0_ready;
wire        dbg_push0_c = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_push_0_payload_state_complete;
wire        dbg_push2_v = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_push_2_valid;
wire        dbg_push2_r = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_push_2_ready;
wire        dbg_push2_c = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_push_2_payload_state_complete;
wire        dbg_p2_isb = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_2_payload_info_uop_isBranch;
wire        dbg_p2_isj = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_2_payload_info_uop_isJump;
wire        dbg_p2_isl = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_2_payload_info_uop_isLoad;
wire        dbg_p2_iss = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ROBFIFOPlugin_debug_fifoIO_pop_2_payload_info_uop_isStore;
wire [31:0] dbg_fpc      = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.IF3_ICachePlugin_fetchPacket_pc;
wire [3:0]  dbg_foff     = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.IF3_ICachePlugin_pcWordOffset;
wire        dbg_fibusr   = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ICachePlugin_iBus_r_valid;
wire        dbg_freq     = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.IF3_ICachePlugin_reqValid;
wire        dbg_frefetch = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ICachePlugin_refetchValid;
wire        dbg_farvalid = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ICachePlugin_iBus_ar_valid;
wire        dbg_farready = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ICachePlugin_iBus_ar_ready;
wire [31:0] dbg_faraddr  = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ICachePlugin_iBus_ar_payload_addr;
wire        dbg_frvalid  = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ICachePlugin_iBus_r_valid;
wire [3:0]  dbg_frid     = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ICachePlugin_iBus_r_payload_id;
wire        dbg_frlast   = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.ICachePlugin_iBus_r_payload_last;
wire        dbg_fstart   = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.IF3_ICachePlugin_cacheRefillFSM_wantStart;
wire        dbg_fkill    = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.IF3_ICachePlugin_cacheRefillFSM_wantKill;
wire        dbg_fexit    = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.IF3_ICachePlugin_cacheRefillFSM_wantExit;
wire        dbg_darvalid = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.io_dBus_ar_valid;
wire        dbg_udarv    = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.io_udBus_ar_valid;
wire        dbg_udarr    = u_soc_top.u_cpu.u_nop_core.toplevel_crossbar_io_udBus_ar_ready;
wire        dbg_udrv     = u_soc_top.u_cpu.u_nop_core.toplevel_crossbar_io_udBus_r_valid;
wire        dbg_abarv    = u_soc_top.u_cpu.u_nop_core.toplevel_axiBuffer_io_out_axi_ar_valid;
wire        dbg_toparv   = u_soc_top.u_cpu.arvalid;
wire        dbg_toparr   = u_soc_top.u_cpu.arready;
wire        dbg_toprv    = u_soc_top.u_cpu.rvalid;
wire        dbg_ramarmask = u_soc_top.sim_ram.u_axi_ram.axi_arvalid_m_masked;
wire        dbg_ramarv    = u_soc_top.sim_ram.u_axi_ram.axi_arvalid;
wire        dbg_ramarr    = u_soc_top.sim_ram.u_axi_ram.axi_arready;
wire        dbg_ramrv     = u_soc_top.sim_ram.u_axi_ram.axi_rvalid;
wire        dbg_ramrlast  = u_soc_top.sim_ram.u_axi_ram.axi_rlast;
wire [4:0]  dbg_rampf     = u_soc_top.sim_ram.u_axi_ram.pf_r2r;
wire [2:0]  dbg_ramrs0    = u_soc_top.sim_ram.u_axi_ram.rstate[0];
wire [2:0]  dbg_ramrs1    = u_soc_top.sim_ram.u_axi_ram.rstate[1];
wire        dbg_arnomask  = u_soc_top.sim_ram.u_axi_ram.ar_nomask;
wire [4:0]  dbg_rmmask    = u_soc_top.sim_ram.u_axi_ram.ram_random_mask;
wire [31:0] dbg_rcount0   = u_soc_top.sim_ram.u_axi_ram.r_count[0];
wire [31:0] dbg_rcmp      = u_soc_top.sim_ram.u_axi_ram.r_countcmp;
wire        dbg_pfrand    = u_soc_top.sim_ram.u_axi_ram.pf_r_and;
wire        dbg_rvs       = u_soc_top.sim_ram.u_axi_ram.axi_rvalid_s_unmasked;
wire        dbg_rready_m  = u_soc_top.sim_ram.u_axi_ram.axi_rready_m_masked;
wire [3:0]  dbg_cpuarid   = u_soc_top.u_cpu.arid;
wire [3:0]  dbg_ramarid   = u_soc_top.ram_arid;
wire        dbg_ramarv2   = u_soc_top.ram_arvalid;
wire        dbg_ramarr2   = u_soc_top.ram_arready;
wire [3:0]  dbg_ramrid    = u_soc_top.ram_rid;
wire        dbg_ramrv2    = u_soc_top.ram_rvalid;
wire        dbg_ramrr2    = u_soc_top.ram_rready;
wire        dbg_ramrlast2 = u_soc_top.ram_rlast;
wire        dbg_a4rv      = u_soc_top.cpu_axi4_rvalid;
wire [3:0]  dbg_a4rid     = u_soc_top.cpu_axi4_rid;
wire        dbg_a4rlast   = u_soc_top.cpu_axi4_rlast;
wire        dbg_toprr    = u_soc_top.u_cpu.rready;
wire        dbg_drready  = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.io_dBus_r_ready;
wire        dbg_drvalid  = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.io_dBus_r_valid;
wire        dbg_finst0   = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.IF3_ICachePlugin_fetchPacket_insts_0_valid;
wire        dbg_finst1   = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.IF3_ICachePlugin_fetchPacket_insts_1_valid;
wire        dbg_finst2   = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.IF3_ICachePlugin_fetchPacket_insts_2_valid;
wire        dbg_finst3   = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.IF3_ICachePlugin_fetchPacket_insts_3_valid;
wire        dbg_fexcept  = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.IF3_ICachePlugin_fetchPacket_except_valid;
wire        dbg_fbpop0   = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.FetchBufferPlugin_bufferFIFO_io_pop_0_valid;
wire        dbg_fbpop1   = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.FetchBufferPlugin_bufferFIFO_io_pop_1_valid;
wire        dbg_fbpop2   = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.FetchBufferPlugin_bufferFIFO_io_pop_2_valid;
wire [31:0] dbg_fbpop0pc = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.FetchBufferPlugin_bufferFIFO_io_pop_0_payload_pc;
wire [31:0] dbg_fbpop1pc = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.FetchBufferPlugin_bufferFIFO_io_pop_1_payload_pc;
wire [31:0] dbg_fbpop2pc = u_soc_top.u_cpu.u_nop_core.toplevel_cpu.FetchBufferPlugin_bufferFIFO_io_pop_2_payload_pc;

reg [31:0]  p0dbg_last_sig = 0;
always @(negedge cpu_clk) begin
  if ($time >= 3784000 && $time <= 3809100) begin
    // 只在状态变化时打印(压缩日志)
    if ({dbg_pushPtr,dbg_popPtr,dbg_popCnt,dbg_flush,dbg_p0_valid,dbg_p0_ready,dbg_p0_cmplt,
         dbg_p1_valid,dbg_p1_ready,dbg_p1_cmplt,dbg_p2_valid,dbg_p2_ready,dbg_p2_cmplt,
         
         dbg_fpc,dbg_foff,dbg_fibusr,dbg_freq,dbg_frefetch,dbg_finst0,dbg_finst1,dbg_finst2,dbg_finst3,
         dbg_fbpop0,dbg_fbpop1,dbg_fbpop2} != p0dbg_last_sig) begin
      p0dbg_last_sig <= {dbg_pushPtr,dbg_popPtr,dbg_popCnt,dbg_flush,dbg_p0_valid,dbg_p0_ready,dbg_p0_cmplt,
         dbg_p1_valid,dbg_p1_ready,dbg_p1_cmplt,dbg_p2_valid,dbg_p2_ready,dbg_p2_cmplt,
         
         dbg_fpc,dbg_foff,dbg_fibusr,dbg_freq,dbg_frefetch,dbg_finst0,dbg_finst1,dbg_finst2,dbg_finst3,
         dbg_fbpop0,dbg_fbpop1,dbg_fbpop2};
      $display("[P0 %t] pp=%0d op=%0d pcnt=%0d flush=%0d | p v/r/c: %0b%0b%0b %0b%0b%0b %0b%0b%0b",
               $time, dbg_pushPtr, dbg_popPtr, dbg_popCnt, dbg_flush,
               dbg_p0_valid,dbg_p0_ready,dbg_p0_cmplt, dbg_p1_valid,dbg_p1_ready,dbg_p1_cmplt,
               dbg_p2_valid,dbg_p2_ready,dbg_p2_cmplt);
      $display("   p0pc=%08x p1pc=%08x p2pc=%08x", dbg_p0_pc, dbg_p1_pc, dbg_p2_pc);
      $display("   fpc=%08x off=%0d req=%0b ibusr=%0b refetch=%0b insts=%0b%0b%0b%0b except=%0b fbpop=%0b%0b%0b pc=%08x %08x %08x",
               dbg_fpc, dbg_foff, dbg_freq, dbg_fibusr, dbg_frefetch,
               dbg_finst0,dbg_finst1,dbg_finst2,dbg_finst3, dbg_fexcept,
               dbg_fbpop0,dbg_fbpop1,dbg_fbpop2, dbg_fbpop0pc, dbg_fbpop1pc, dbg_fbpop2pc);
      $display("   axi: arv=%0b arr=%0b araddr=%08x | rv=%0b rid=%0d rlast=%0b | start=%0b kill=%0b exit=%0b | darv=%0b drv=%0b drr=%0b",
               dbg_farvalid, dbg_farready, dbg_faraddr, dbg_frvalid, dbg_frid, dbg_frlast,
               dbg_fstart, dbg_fkill, dbg_fexit, dbg_darvalid, dbg_drvalid, dbg_drready);
      $display("   axi2: udarv=%0b udarr=%0b udrv=%0b abarv=%0b | top: arv=%0b arr=%0b rv=%0b rr=%0b",
               dbg_udarv, dbg_udarr, dbg_udrv, dbg_abarv, dbg_toparv, dbg_toparr, dbg_toprv, dbg_toprr);
      $display("   axi3: ram arv=%0b armask=%0b arr=%0b nomask=%0b | rv=%0b rlast=%0b pf=%0d rs0=%0d rs1=%0d",
               dbg_ramarv, dbg_ramarmask, dbg_ramarr, dbg_arnomask, dbg_ramrv, dbg_ramrlast, dbg_rampf, dbg_ramrs0, dbg_ramrs1);
      $display("   axi4: rmask=%0b rvs=%0b pfrand=%0b rrcnt=%0d rcmp=%0d rrdym=%0b",
               dbg_rmmask, dbg_rvs, dbg_pfrand, dbg_rcount0, dbg_rcmp, dbg_rready_m);
      $display("   axi5: cpuarid=%0d ramarid=%0d | ram arv=%0b arr=%0b rv=%0b rid=%0d rlast=%0b rr=%0b | a4 rv=%0b rid=%0d rlast=%0b",
               dbg_cpuarid, dbg_ramarid, dbg_ramarv2, dbg_ramarr2, dbg_ramrv2, dbg_ramrid, dbg_ramrlast2, dbg_ramrr2,
               dbg_a4rv, dbg_a4rid, dbg_a4rlast);
    end
  end
end

//模拟串口打印
wire uart_display;
wire [7:0] uart_data;
wire uart_wen;
assign uart_wen = (`UART_PSEL == 1'b1) &&  (`UART_PENBLE == 1'b1) && (`UART_PWRITE == 1'b1);
assign uart_display = (uart_wen == 1'b1) && (`UART_WADDR == 8'he0);
assign uart_data    = `UART_WDATA;

always @(posedge u_soc_top.sys_clk)
begin
    if(uart_display)
    begin
        if(uart_data==8'hff)
        begin
            ;//$finish;
        end
        else
        begin
            $write("%c",uart_data);
        end
    end
end

//test end
reg  debug_end;
wire global_err = err_count!=8'd0;
wire test_end = (debug_wb_pc==`END_PC) || (uart_display && uart_data==8'hff);
always @(posedge cpu_clk)
begin
    if (!resetn)
    begin
        debug_end <= 1'b0;
    end
    else if(test_end && !debug_end)
    begin
        debug_end <= 1'b1;
        $display("==============================================================");
        $display("Test end!");
        #40;
        // $fclose(trace_ref);
        if (global_err)
        begin
            $display("Fail!!!Total %d errors!",err_count);
        end
        else
        begin
            $display("----PASS!!!");
        end
	    $finish;
	end
end

generate if(`SIMU_USE_DDR==0) begin: sim_ram_tb

    integer software_bin;
    integer err,str;
    reg [31:0] instr;
    integer i;
    initial begin
        software_bin = $fopen("D:/code/Vivado/Loongarch_workspace/chiplab/fpga/nscscc-team/run_vivado/inst_data.bin","rb");
        err = $ferror(software_bin, str);
        if(!err) begin
            for(i=0;i<262144;i=i+1) begin
                if ($fread(instr,software_bin))begin
                    u_soc_top.sim_ram.u_axi_ram.u_fpga_sram.BRAM[i] <= {instr[7:0],instr[15:8],instr[23:16],instr[31:24]};
                end
                else begin
                    u_soc_top.sim_ram.u_axi_ram.u_fpga_sram.BRAM[i] <= 32'b0;
                end
            end
        end
        $fclose(software_bin);
    end

end
else begin: ddr3_tb

    // AXI4写数据任务
    task axi4_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            // 写地址通道
            @(posedge `MIG_AXI.ui_clk);
            force `MIG_AXI.s_axi_awid = 4'b0001;
            force `MIG_AXI.s_axi_awaddr = addr[26:0];
            force `MIG_AXI.s_axi_awlen   = 8'h00;
            force `MIG_AXI.s_axi_awsize  = 3'b010;
            force `MIG_AXI.s_axi_awburst = 2'b01;
            force `MIG_AXI.s_axi_awlock  = 1'b0;
            force `MIG_AXI.s_axi_awcache = 4'b0000;
            force `MIG_AXI.s_axi_awprot  = 3'b000;
            force `MIG_AXI.s_axi_awqos   = 4'b0000;
            force `MIG_AXI.s_axi_awvalid = 1'b1;
            
            // 等待握手完成
            wait(`MIG_AXI.s_axi_awready);
            @(posedge `MIG_AXI.ui_clk);
            force `MIG_AXI.s_axi_awvalid = 1'b0;
            
            // 写数据通道
            force `MIG_AXI.s_axi_wdata  = data;
            force `MIG_AXI.s_axi_wstrb  = 4'b1111;
            force `MIG_AXI.s_axi_wlast  = 1'b1;
            force `MIG_AXI.s_axi_wvalid = 1'b1;
            
            // 等待写数据握手完成
            wait(`MIG_AXI.s_axi_wready);
            @(posedge `MIG_AXI.ui_clk);
            force `MIG_AXI.s_axi_wvalid = 1'b0;
            
            // 等待写响应
            force `MIG_AXI.s_axi_bready = 1'b1;
            wait(`MIG_AXI.s_axi_bvalid);
            @(posedge `MIG_AXI.ui_clk);
            force `MIG_AXI.s_axi_bready = 1'b0;
        end
    endtask

    // 从文件写入AXI总线的任务
    task write_file;
        input [31:0] base_addr;  // 基地址
        input string filename;    // 文件名
        reg [31:0] data;         // 临时数据存储
        integer fd;              // 文件描述符
        integer bytes_read;      // 读取的字节数
        integer addr_offset;     // 地址偏移
        begin
            // 打开二进制文件
            fd = $fopen(filename, "rb");
            if (fd == 0) begin
                $display("Error: Unable to open file %s", filename);
                return;
            end
            
            addr_offset = 0;
            
            // 循环读取文件内容并写入AXI总线
            while (!$feof(fd)) begin
                bytes_read = $fread(data, fd);
                if (bytes_read > 0) begin
                    // 调用AXI写任务
                    axi4_write(
                        base_addr + addr_offset,  // 目标地址
                        {data[7:0],data[15:8],data[23:16],data[31:24]} // 写入数据
                    );
                    addr_offset = addr_offset + 4;
                end
            end
            
            // 关闭文件
            $fclose(fd);
            release `MIG_AXI.s_axi_awid;
            release `MIG_AXI.s_axi_awaddr;
            release `MIG_AXI.s_axi_awlen;
            release `MIG_AXI.s_axi_awsize;
            release `MIG_AXI.s_axi_awburst;
            release `MIG_AXI.s_axi_awlock;
            release `MIG_AXI.s_axi_awcache;
            release `MIG_AXI.s_axi_awprot;
            release `MIG_AXI.s_axi_awqos;
            release `MIG_AXI.s_axi_awvalid;
            release `MIG_AXI.s_axi_wdata ;
            release `MIG_AXI.s_axi_wstrb ;
            release `MIG_AXI.s_axi_wlast ;
            release `MIG_AXI.s_axi_wvalid;
            release `MIG_AXI.s_axi_bready;
            $display("File %s is written, and a total of %0d bytes are written", filename, addr_offset);
        end
    endtask

    initial begin
        force u_soc_top.ddr_data_init = 1'b0;
        wait(`MIG_AXI.init_calib_complete);
        write_file(32'h1c000000,"../../../../../inst_data.bin");
        @(posedge `MIG_AXI.ui_clk);
        force u_soc_top.ddr3.u_axi_wrap_ddr.u_Axi_CDC.axiOutRst = 1'b0;
        @(posedge `MIG_AXI.ui_clk);
        force u_soc_top.ddr3.u_axi_wrap_ddr.u_Axi_CDC.axiOutRst = 1'b1;
        force u_soc_top.ddr_data_init = 1'b1;
    end

    ddr3_model	u_ddr3_model (	
        .rst_n   		(resetn),	
        .ck      		(ddr3_ck_p),	
        .ck_n    		(ddr3_ck_n),	
        .cke     		(ddr3_cke),	
        .cs_n    		(1'b0),	
        .ras_n   		(ddr3_ras_n),	
        .cas_n   		(ddr3_cas_n),	
        .we_n    		(ddr3_we_n),	
        .dm_tdqs 		(ddr3_dm),	
        .ba      		(ddr3_ba),	
        .addr    		(ddr3_addr),	
        .dq      		(ddr3_dq),	
        .dqs     		(ddr3_dqs_p),	
        .dqs_n   		(ddr3_dqs_n),	
        .tdqs_n  		(),
        .odt     		(ddr3_odt)	
    );

end
endgenerate

/**************axi协议测试******************/
/*
reg [31:0] read_data [3:0];
initial begin
    wait(u_soc_top.cpu_resetn);
    force u_soc_top.u_cpu.awvalid = 1'b0;
    force u_soc_top.u_cpu.wvalid  = 1'b0;
    force u_soc_top.u_cpu.bready  = 1'b0;
    force u_soc_top.u_cpu.arvalid = 1'b0;
    force u_soc_top.u_cpu.rready  = 1'b0;
    // 写地址通道
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.awid = 4'h1;
    force u_soc_top.u_cpu.awaddr = 32'h1c000000;
    force u_soc_top.u_cpu.awlen   = 8'h00;
    force u_soc_top.u_cpu.awsize  = 3'b010;
    force u_soc_top.u_cpu.awburst = 2'b01;
    force u_soc_top.u_cpu.awlock  = 1'b0;
    force u_soc_top.u_cpu.awcache = 4'b0000;
    force u_soc_top.u_cpu.awprot  = 3'b000;
    force u_soc_top.u_cpu.awvalid = 1'b1;

    // 等待握手完成
    #1;
    wait(u_soc_top.u_cpu.awready);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.awid = 4'h2;
    force u_soc_top.u_cpu.awaddr = 32'h1c000004;
    force u_soc_top.u_cpu.awlen   = 8'h00;
    force u_soc_top.u_cpu.awsize  = 3'b010;
    force u_soc_top.u_cpu.awburst = 2'b01;
    force u_soc_top.u_cpu.awlock  = 1'b0;
    force u_soc_top.u_cpu.awcache = 4'b0000;
    force u_soc_top.u_cpu.awprot  = 3'b000;
    force u_soc_top.u_cpu.awvalid = 1'b1;

    // 等待握手完成
    #1;
    wait(u_soc_top.u_cpu.awready);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.awid = 4'h3;
    force u_soc_top.u_cpu.awaddr = 32'h1c000008;
    force u_soc_top.u_cpu.awlen   = 8'h00;
    force u_soc_top.u_cpu.awsize  = 3'b010;
    force u_soc_top.u_cpu.awburst = 2'b01;
    force u_soc_top.u_cpu.awlock  = 1'b0;
    force u_soc_top.u_cpu.awcache = 4'b0000;
    force u_soc_top.u_cpu.awprot  = 3'b000;
    force u_soc_top.u_cpu.awvalid = 1'b1;

    // 等待握手完成
    #1;
    wait(u_soc_top.u_cpu.awready);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.awid = 4'h4;
    force u_soc_top.u_cpu.awaddr = 32'h1c00000c;
    force u_soc_top.u_cpu.awlen   = 8'h00;
    force u_soc_top.u_cpu.awsize  = 3'b010;
    force u_soc_top.u_cpu.awburst = 2'b01;
    force u_soc_top.u_cpu.awlock  = 1'b0;
    force u_soc_top.u_cpu.awcache = 4'b0000;
    force u_soc_top.u_cpu.awprot  = 3'b000;
    force u_soc_top.u_cpu.awvalid = 1'b1;

    // 等待握手完成
    #1;
    wait(u_soc_top.u_cpu.awready);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.awvalid = 1'b0;

    // 写数据通道
    force u_soc_top.u_cpu.wid    = 4'h1;
    force u_soc_top.u_cpu.wdata  = 32'h1111_1111;
    force u_soc_top.u_cpu.wstrb  = 4'b1111;
    force u_soc_top.u_cpu.wlast  = 1'b1;
    force u_soc_top.u_cpu.wvalid = 1'b1;

    // 等待写数据握手完成
    #1;
    wait(u_soc_top.u_cpu.wready);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.wid    = 4'h4;
    force u_soc_top.u_cpu.wdata  = 32'h4444_4444;
    force u_soc_top.u_cpu.wstrb  = 4'b1111;
    force u_soc_top.u_cpu.wlast  = 1'b1;
    force u_soc_top.u_cpu.wvalid = 1'b1;

    // 等待写数据握手完成
    #1;
    wait(u_soc_top.u_cpu.wready);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.wid    = 4'h3;
    force u_soc_top.u_cpu.wdata  = 32'h3333_3333;
    force u_soc_top.u_cpu.wstrb  = 4'b1111;
    force u_soc_top.u_cpu.wlast  = 1'b1;
    force u_soc_top.u_cpu.wvalid = 1'b1;

    // 等待写数据握手完成
    #1;
    wait(u_soc_top.u_cpu.wready);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.wid    = 4'h2;
    force u_soc_top.u_cpu.wdata  = 32'h2222_2222;
    force u_soc_top.u_cpu.wstrb  = 4'b1111;
    force u_soc_top.u_cpu.wlast  = 1'b1;
    force u_soc_top.u_cpu.wvalid = 1'b1;

    // 等待写数据握手完成
    #1;
    wait(u_soc_top.u_cpu.wready);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.wvalid = 1'b0;

    // 等待写响应
    force u_soc_top.u_cpu.bready = 1'b1;
    wait(u_soc_top.u_cpu.bvalid);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.bready = 1'b0;
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.bready = 1'b1;
    wait(u_soc_top.u_cpu.bvalid);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.bready = 1'b0;
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.bready = 1'b1;
    wait(u_soc_top.u_cpu.bvalid);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.bready = 1'b0;
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.bready = 1'b1;
    wait(u_soc_top.u_cpu.bvalid);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.bready = 1'b0;

    // 读地址通道
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.arid    = 4'h1;
    force u_soc_top.u_cpu.araddr  = 32'h1c000000;
    force u_soc_top.u_cpu.arlen   = 8'h00;
    force u_soc_top.u_cpu.arsize  = 3'b010;
    force u_soc_top.u_cpu.arburst = 2'b01;
    force u_soc_top.u_cpu.arlock  = 1'b0;
    force u_soc_top.u_cpu.arcache = 4'b0000;
    force u_soc_top.u_cpu.arprot  = 3'b000;
    force u_soc_top.u_cpu.arvalid = 1'b1;
    
    // 等待读地址握手完成
    #1;
    wait(u_soc_top.u_cpu.arready);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.arid    = 4'h2;
    force u_soc_top.u_cpu.araddr  = 32'h1c000004;
    force u_soc_top.u_cpu.arlen   = 8'h00;
    force u_soc_top.u_cpu.arsize  = 3'b010;
    force u_soc_top.u_cpu.arburst = 2'b01;
    force u_soc_top.u_cpu.arlock  = 1'b0;
    force u_soc_top.u_cpu.arcache = 4'b0000;
    force u_soc_top.u_cpu.arprot  = 3'b000;
    force u_soc_top.u_cpu.arvalid = 1'b1;

    // 等待读地址握手完成
    #1;
    wait(u_soc_top.u_cpu.arready);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.arid    = 4'h3;
    force u_soc_top.u_cpu.araddr  = 32'h1c000008;
    force u_soc_top.u_cpu.arlen   = 8'h00;
    force u_soc_top.u_cpu.arsize  = 3'b010;
    force u_soc_top.u_cpu.arburst = 2'b01;
    force u_soc_top.u_cpu.arlock  = 1'b0;
    force u_soc_top.u_cpu.arcache = 4'b0000;
    force u_soc_top.u_cpu.arprot  = 3'b000;
    force u_soc_top.u_cpu.arvalid = 1'b1;

    // 等待读地址握手完成
    #1;
    wait(u_soc_top.u_cpu.arready);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.arid    = 4'h4;
    force u_soc_top.u_cpu.araddr  = 32'h1c00000c;
    force u_soc_top.u_cpu.arlen   = 8'h00;
    force u_soc_top.u_cpu.arsize  = 3'b010;
    force u_soc_top.u_cpu.arburst = 2'b01;
    force u_soc_top.u_cpu.arlock  = 1'b0;
    force u_soc_top.u_cpu.arcache = 4'b0000;
    force u_soc_top.u_cpu.arprot  = 3'b000;
    force u_soc_top.u_cpu.arvalid = 1'b1;

    // 等待读地址握手完成
    #1;
    wait(u_soc_top.u_cpu.arready);
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.arvalid = 1'b0;
    
    // 读数据通道
    force u_soc_top.u_cpu.rready = 1'b1;
    
    // 等待读数据有效
    #1;
    wait(u_soc_top.u_cpu.rvalid);
    read_data[0] = u_soc_top.u_cpu.rdata;
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.rready = 1'b0;
    @(posedge u_soc_top.u_cpu.aclk);

    force u_soc_top.u_cpu.rready = 1'b1;
    #1;
    wait(u_soc_top.u_cpu.rvalid);
    read_data[1] = u_soc_top.u_cpu.rdata;
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.rready = 1'b0;
    @(posedge u_soc_top.u_cpu.aclk);

    force u_soc_top.u_cpu.rready = 1'b1;
    #1;
    wait(u_soc_top.u_cpu.rvalid);
    read_data[2] = u_soc_top.u_cpu.rdata;
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.rready = 1'b0;
    @(posedge u_soc_top.u_cpu.aclk);

    force u_soc_top.u_cpu.rready = 1'b1;
    #1;
    wait(u_soc_top.u_cpu.rvalid);
    read_data[3] = u_soc_top.u_cpu.rdata;
    @(posedge u_soc_top.u_cpu.aclk);
    force u_soc_top.u_cpu.rready = 1'b0;
    @(posedge u_soc_top.u_cpu.aclk);

    $finish;
end
*/
endmodule
