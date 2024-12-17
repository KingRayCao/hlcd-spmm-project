`ifndef N
`define N              16
`endif
`define W               8
`define lgN     ($clog2(`N))
`define dbLgN (2*$clog2(`N))

typedef struct packed { logic [`W-1:0] data; } data_t;

module add_(
    input   logic   clock,
    input   data_t  a,
    input   data_t  b,
    output  data_t  out
);
    always_ff @(posedge clock) begin
        out.data <= a.data + b.data;
    end
endmodule

module mul_(
    input   logic   clock,
    input   data_t  a,
    input   data_t  b,
    output  data_t out
);
    always_ff @(posedge clock) begin
        out.data <= a.data * b.data;
    end
endmodule

module RedUnit(
    input   logic               clock,
                                reset,
    input   data_t              data[`N-1:0],
    input   logic               split[`N-1:0],
    input   logic [`lgN-1:0]    out_idx[`N-1:0],
    output  data_t              out_data[`N-1:0],
    output  int                 delay,
    output  int                 num_el
);
    // num_el 总是赋值为 N
    assign num_el = `N;
    // delay 你需要自己为其赋值，表示电路的延迟
    assign delay = `lgN + 1;

    data_t PfxSum[`lgN:0][`N-1:0];
    logic [`lgN-1:0] out_idx_data[`lgN:0][`N-1:0];
    logic pfx_enb[`lgN:0][`N-1:0];
    generate
        for(genvar i = 0; i < `N; i++) begin
            always_ff @(posedge clock) begin
                PfxSum[0][i] <= data[i];
                out_idx_data[0][i] <= out_idx[i];
                if(i >= 1) begin
                    pfx_enb[0][i] <= split[i-1];
                end
                else begin
                    pfx_enb[0][i] <= 0;
                end
            end
        end
    endgenerate

    //PfxSum
    generate
        for(genvar i = 0; i < `lgN; i++) begin
            for(genvar j = 0; j < `N; j++) begin
                if(j >= (1 << i)) begin
                    add_ add_inst(
                        .clock(clock),
                        .a(PfxSum[i][j]),
                        .b((pfx_enb[i][j])?0:PfxSum[i][j - (1 << i)]),
                        .out(PfxSum[i+1][j])
                    );
                end
                else begin
                    always_ff @(posedge clock) begin
                        PfxSum[i+1][j] <= PfxSum[i][j];
                    end
                end
                always_ff @(posedge clock) begin
                    out_idx_data[i+1][j] <= out_idx_data[i][j];
                    if(j >= (1<<i)) begin
                            pfx_enb[i+1][j] <= pfx_enb[i][j-(1<<i)]|pfx_enb[i][j];
                    end
                    else begin
                            pfx_enb[i+1][j] <= pfx_enb[i][j];
                    end
                end
            end
        end
    endgenerate

    generate
        for(genvar i = 0; i < `N; i++) begin
            assign out_data[i] = PfxSum[`lgN][out_idx_data[`lgN][i]];
        end
    endgenerate
endmodule

module PE(
    input   logic               clock,
                                reset,
    input   logic               lhs_start,
    input   logic [`dbLgN-1:0]  lhs_ptr [`N-1:0],
    input   logic [`lgN-1:0]    lhs_col [`N-1:0],
    input   data_t              lhs_data[`N-1:0],
    input   data_t              rhs[`N-1:0],
    output  data_t              out[`N-1:0],
    output  int                 delay,
    output  int                 num_el
);
    // num_el 总是赋值为 N
    assign num_el = `N;
    // delay 你需要自己为其赋值，表示电路的延迟
    assign delay = 0;

    generate
        for(genvar i = 0; i < `N; i++) begin
            assign out[i] = 0;
        end
    endgenerate
endmodule

module SpMM(
    input   logic               clock,
                                reset,
    /* 输入在各种情况下是否 ready */
    output  logic               lhs_ready_ns,
                                lhs_ready_ws,
                                lhs_ready_os,
                                lhs_ready_wos,
    input   logic               lhs_start,
    /* 如果是 weight-stationary, 这次使用的 rhs 将保留到下一次 */
                                lhs_ws,
    /* 如果是 output-stationary, 将这次的结果加到上次的 output 里 */
                                lhs_os,
    input   logic [`dbLgN-1:0]  lhs_ptr [`N-1:0],
    input   logic [`lgN-1:0]    lhs_col [`N-1:0],
    input   data_t              lhs_data[`N-1:0],
    output  logic               rhs_ready,
    input   logic               rhs_start,
    input   data_t              rhs_data [3:0][`N-1:0],
    output  logic               out_ready,
    input   logic               out_start,
    output  data_t              out_data [3:0][`N-1:0],
    output  int                 num_el
);
    // num_el 总是赋值为 N
    assign num_el = `N;

    assign lhs_ready_ns = 0;
    assign lhs_ready_ws = 0;
    assign lhs_ready_os = 0;
    assign lhs_ready_wos = 0;
    assign rhs_ready = 0;
    assign out_ready = 0;
endmodule
