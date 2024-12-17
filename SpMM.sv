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
    input   logic [`lgN:0]      start_idx,
    input   logic [`lgN:0]      end_idx,
    input   logic [`lgN-1:0]    out_idx[`N-1:0],
    output  data_t              out_data[`N-1:0],
    output  logic [`lgN:0]      out_start_idx,
    output  logic [`lgN:0]      out_end_idx,
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
    logic [`lgN:0] start_idx_data[`lgN:0];
    logic [`lgN:0] end_idx_data[`lgN:0];
    always_ff @(posedge clock) begin
        start_idx_data[0] <= start_idx;
        end_idx_data[0] <= end_idx;
    end
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
            always_ff @(posedge clock) begin
                start_idx_data[i+1] <= start_idx_data[i];
                end_idx_data[i+1] <= end_idx_data[i];
            end
        end
    endgenerate

    generate
        for(genvar i = 0; i < `N; i++) begin
            assign out_data[i] = PfxSum[`lgN][out_idx_data[`lgN][i]];
        end
    endgenerate
    assign out_start_idx = start_idx_data[`lgN];
    assign out_end_idx = end_idx_data[`lgN];
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
    assign delay = `lgN + 3;
    
    // cnt
    logic[`lgN:0] cnt;
    always_ff @(posedge clock) begin
        if(lhs_start || reset) begin
            cnt <= 0;
        end
        else begin
            cnt <= cnt + 1;
        end
    end

    // product generation
    data_t prod[`N-1:0];
    generate
        for(genvar i = 0; i < `N; i++) begin
            mul_ mul_inst(
                .clock(clock),
                .a(lhs_data[i]),
                .b(rhs[lhs_col[i]]),
                .out(prod[i])
            );
        end
    endgenerate
    data_t prod_latch[`N-1:0];
    always_ff @(posedge clock) begin
        for(int i = 0; i < `N; i++) begin
            prod_latch[i] <= prod[i];
        end
    end

    // ptr load & split generation
    logic [`dbLgN-1:0] ptr_latch[`N-1:0];
    logic split[`N*`N-1:0];
    always_ff @(posedge clock) begin
        if(lhs_start) begin
            for(int i = 0; i < `N; i++) begin
                ptr_latch[i] <= lhs_ptr[i];
            end
            for(int i = 0; i < `N * `N; i++) begin
                split[i] <= 0;
            end
            for(int i = 0; i < `N; i++) begin
                split[lhs_ptr[i]] <= 1;
            end
        end
    end
    logic split_col[`N-1:0];
    always_ff @(posedge clock) begin
        for(int i = 0; i < `N; i++) begin
            split_col[i] <= split[(cnt*`N)+i];
        end
    end

    // out_idx generation & blank row detection
    logic[`lgN-1:0] out_idx[`N-1:0], out_idx_latch[`N-1:0];
    logic[`lgN:0] cur_start_idx, cur_end_idx, cur_start_idx_latch, cur_end_idx_latch;
    logic blank_row[`N-1:0], blank_row_latch[`N-1:0];
    always_ff @(posedge clock) begin
        if(lhs_start) begin
            cur_start_idx <= 0;
        end
        else begin
            cur_start_idx <= cur_end_idx;
        end
    end
    always_comb begin
        for(integer i = 0; i < `N; i = i + 1) begin
            if(i < cur_start_idx) begin
                out_idx[i] = 0;
            end
            else if(ptr_latch[i] >= cnt*`N && ptr_latch[i] < (cnt+1)*`N) begin
                out_idx[i] = ptr_latch[i] - cnt*`N;
                cur_end_idx = i + 1;
            end
            else begin
                out_idx[i] = `N-1;
            end
        end
    end
    generate
        for(genvar i = 1; i < `N; i++) begin
            always_comb begin
                if(ptr_latch[i] == ptr_latch[i-1]) begin
                    blank_row[i] = 1;
                end
                else begin
                    blank_row[i] = 0;
                end
            end
        end
    endgenerate

    always_ff @(posedge clock) begin
        for(int i = 0; i < `N; i++) begin
            out_idx_latch[i] <= out_idx[i];
            blank_row_latch[i] <= blank_row[i];
        end
        cur_start_idx_latch <= cur_start_idx;
        cur_end_idx_latch <= cur_end_idx;
    end

    // RedUnit & HALO
    data_t ru_out[`N-1:0];
    logic[`lgN:0] out_start_idx, out_end_idx;
    data_t halo;
    logic halo_en;
    RedUnit RU_inst(
        .clock(clock),
        .reset(reset),
        .data(prod_latch),
        .split(split_col),
        .start_idx(cur_start_idx_latch),
        .end_idx(cur_end_idx_latch),
        .out_idx(out_idx_latch),
        .out_data(ru_out),
        .out_start_idx(out_start_idx),
        .out_end_idx(out_end_idx),
        .delay(),
        .num_el()
    );
    always_ff @(posedge clock) begin
        if(lhs_start) begin
            halo_en <= 0;
            halo.data <= 0;
        end
        else begin
            halo_en <= (ptr_latch[out_end_idx-1] % `N != `N-1);
            halo.data <= ru_out[`N-1];
        end
    end

    // output generation
    generate
        for(genvar i = 0; i < `N; i = i + 1) begin
            always_comb begin
                if(blank_row_latch[i]) begin
                    out[i] = 0;
                end
                else begin
                    if(i >= out_start_idx && i < out_end_idx) begin
                        if(i == out_start_idx) begin
                            out[i] = ((halo_en)?halo:0) + ru_out[i];
                        end
                        else begin
                            out[i] = ru_out[i];
                        end
                    end
                    else begin
                        out[i] = 0;
                    end
                end
            end
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
