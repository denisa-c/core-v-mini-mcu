// Copyright 2022 OpenHW Group
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

module cpu_subsystem
  import obi_pkg::*;
  import core_v_mini_mcu_pkg::*;
#(
    parameter BOOT_ADDR = 'h180,
    parameter PULP_XPULP    =  0,                   // PULP ISA Extension (incl. custom CSRs and hardware loop, excl. p.elw)
    parameter FPU = 0,  // Floating Point Unit (interfaced via APU interface)
    parameter PULP_ZFINX = 0,  // Float-in-General Purpose registers
    parameter NUM_MHPMCOUNTERS = 1,
    parameter DM_HALTADDRESS = '0,
    parameter core_v_mini_mcu_pkg::cpu_type_e CPU_TYPE = core_v_mini_mcu_pkg::CpuType
) (
    // Clock and Reset
    input logic clk_i,
    input logic rst_ni,

    // Instruction memory interface
    output obi_req_t  core_instr_req_o,
    input  obi_resp_t core_instr_resp_i,

    // Data memory interface
    output obi_req_t  core_data_req_o,
    input  obi_resp_t core_data_resp_i,

    // Interrupt inputs
    input  logic [31:0] irq_i,      // CLINT interrupts + CLINT extension interrupts
    output logic        irq_ack_o,
    output logic [ 4:0] irq_id_o,

    // Debug Interface
    input logic debug_req_i,

    // CPU Control Signals
    input logic fetch_enable_i
);

  assign core_instr_req_o.wdata = '0;
  assign core_instr_req_o.we    = '0;
  assign core_instr_req_o.be    = 4'b1111;

  if (CPU_TYPE == cv32e20) begin : gen_cv32e20

    logic [4:0] rf_raddr_a, rf_raddr_b, rf_waddr_wb;
    logic [31:0] rf_rdata_a, rf_rdata_b, rf_wdata_wb;
    logic rf_we_wb;

    import ibex_pkg::*;

    ibex_core #(
        .DmHaltAddr(DM_HALTADDRESS),
        .DmExceptionAddr(32'h0)
    ) cv32e20_i (
        .clk_i (clk_i),
        .rst_ni(rst_ni),

        .hart_id_i  (32'h0),
        .boot_addr_i(BOOT_ADDR - 'h80),


        .instr_addr_o  (core_instr_req_o.addr),
        .instr_req_o   (core_instr_req_o.req),
        .instr_rdata_i (core_instr_resp_i.rdata),
        .instr_gnt_i   (core_instr_resp_i.gnt),
        .instr_rvalid_i(core_instr_resp_i.rvalid),
        .instr_err_i   (1'b0),

        .data_addr_o  (core_data_req_o.addr),
        .data_wdata_o (core_data_req_o.wdata),
        .data_we_o    (core_data_req_o.we),
        .data_req_o   (core_data_req_o.req),
        .data_be_o    (core_data_req_o.be),
        .data_rdata_i (core_data_resp_i.rdata),
        .data_gnt_i   (core_data_resp_i.gnt),
        .data_rvalid_i(core_data_resp_i.rvalid),
        .data_err_i   (1'b0),

        .dummy_instr_id_o (),
        .rf_raddr_a_o     (rf_raddr_a),
        .rf_raddr_b_o     (rf_raddr_b),
        .rf_waddr_wb_o    (rf_waddr_wb),
        .rf_we_wb_o       (rf_we_wb),
        .rf_wdata_wb_ecc_o(rf_wdata_wb),
        .rf_rdata_a_ecc_i (rf_rdata_a),
        .rf_rdata_b_ecc_i (rf_rdata_b),

        .ic_tag_req_o      (),
        .ic_tag_write_o    (),
        .ic_tag_addr_o     (),
        .ic_tag_wdata_o    (),
        .ic_tag_rdata_i    (),
        .ic_data_req_o     (),
        .ic_data_write_o   (),
        .ic_data_addr_o    (),
        .ic_data_wdata_o   (),
        .ic_data_rdata_i   (),
        .ic_scr_key_valid_i(),

        .irq_software_i(irq_i[3]),
        .irq_timer_i   (irq_i[7]),
        .irq_external_i(irq_i[11]),
        .irq_fast_i    (irq_i[30:16]),
        .irq_nm_i      (irq_i[31]),
        .irq_pending_o (),

        .debug_req_i(debug_req_i),
        .crash_dump_o(),
        .double_fault_seen_o(),

        .fetch_enable_i({3'b0, fetch_enable_i}),
        .alert_minor_o(),
        .alert_major_o(),
        .icache_inval_o(),
        .core_busy_o()
    );

    cv32e40p_register_file #(
        .ADDR_WIDTH(6)
    ) cv32e20_register_file_i (
        // Clock and Reset
        .clk  (clk_i),
        .rst_n(rst_ni),

        .scan_cg_en_i(1'b0),

        //Read port R1
        .raddr_a_i({1'b0, rf_raddr_a}),
        .rdata_a_o(rf_rdata_a),

        //Read port R2
        .raddr_b_i({1'b0, rf_raddr_b}),
        .rdata_b_o(rf_rdata_b),

        //Read port R3
        .raddr_c_i('0),
        .rdata_c_o(),

        // Write port W1
        .waddr_a_i({1'b0, rf_waddr_wb}),
        .wdata_a_i(rf_wdata_wb),
        .we_a_i(rf_we_wb),

        // Write port W2
        .waddr_b_i('0),
        .wdata_b_i('0),
        .we_b_i('0)
    );



    assign irq_ack_o = '0;
    assign irq_id_o  = '0;

  end else begin : gen_cv32e40p
    import cv32e40p_apu_core_pkg::*;
    // APU Core to FP Wrapper
    logic                              apu_req;
    logic [   APU_NARGS_CPU-1:0][31:0] apu_operands;
    logic [     APU_WOP_CPU-1:0]       apu_op;
    logic [APU_NDSFLAGS_CPU-1:0]       apu_flags;


    // APU FP Wrapper to Core
    logic                              apu_gnt;
    logic                              apu_rvalid;
    logic [                31:0]       apu_rdata;
    logic [APU_NUSFLAGS_CPU-1:0]       apu_rflags;

    // instantiate the core
    cv32e40p_wrapper #(
        .PULP_XPULP      (PULP_XPULP),
        .PULP_CLUSTER    (0),
        .FPU             (FPU),
        .PULP_ZFINX      (PULP_ZFINX),
        .NUM_MHPMCOUNTERS(NUM_MHPMCOUNTERS)
    ) cv32e40p_wrapper_i (
        .clk_i (clk_i),
        .rst_ni(rst_ni),

        .pulp_clock_en_i(1'b1),
        .scan_cg_en_i   (1'b0),

        .boot_addr_i        (BOOT_ADDR),
        .mtvec_addr_i       (32'h0),
        .dm_halt_addr_i     (DM_HALTADDRESS),
        .hart_id_i          (32'h0),
        .dm_exception_addr_i(32'h0),

        .instr_addr_o  (core_instr_req_o.addr),
        .instr_req_o   (core_instr_req_o.req),
        .instr_rdata_i (core_instr_resp_i.rdata),
        .instr_gnt_i   (core_instr_resp_i.gnt),
        .instr_rvalid_i(core_instr_resp_i.rvalid),

        .data_addr_o  (core_data_req_o.addr),
        .data_wdata_o (core_data_req_o.wdata),
        .data_we_o    (core_data_req_o.we),
        .data_req_o   (core_data_req_o.req),
        .data_be_o    (core_data_req_o.be),
        .data_rdata_i (core_data_resp_i.rdata),
        .data_gnt_i   (core_data_resp_i.gnt),
        .data_rvalid_i(core_data_resp_i.rvalid),

        .apu_req_o     (apu_req),
        .apu_gnt_i     (apu_gnt),
        .apu_operands_o(apu_operands),
        .apu_op_o      (apu_op),
        .apu_flags_o   (apu_flags),
        .apu_rvalid_i  (apu_rvalid),
        .apu_result_i  (apu_rdata),
        .apu_flags_i   (apu_rflags),

        .irq_i    (irq_i),
        .irq_ack_o(irq_ack_o),
        .irq_id_o (irq_id_o),

        .debug_req_i      (debug_req_i),
        .debug_havereset_o(),
        .debug_running_o  (),
        .debug_halted_o   (),

        .fetch_enable_i(fetch_enable_i),
        .core_sleep_o  ()
    );

    if (FPU) begin
      cv32e40p_fp_wrapper fp_wrapper_i (
          .clk_i         (clk_i),
          .rst_ni        (rst_ni),
          .apu_req_i     (apu_req),
          .apu_gnt_o     (apu_gnt),
          .apu_operands_i(apu_operands),
          .apu_op_i      (apu_op),
          .apu_flags_i   (apu_flags),
          .apu_rvalid_o  (apu_rvalid),
          .apu_rdata_o   (apu_rdata),
          .apu_rflags_o  (apu_rflags)
      );
    end else begin
      assign apu_gnt    = '0;
      assign apu_rvalid = '0;
      assign apu_rdata  = '0;
      assign apu_rflags = '0;
    end

  end

endmodule
