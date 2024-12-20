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
    output  logic               in_over,
    output  logic               out_start,
    output  logic               out_over,
    output  int                 delay,
    output  int                 num_el
);
    // num_el 总是赋值为 N
    assign num_el = `N;
    // delay 你需要自己为其赋值，表示电路的延迟
    assign delay = `lgN + 3;

    localparam  S_IDLE  = 0,
                S_BUSY  = 1;    
    logic[1:0] state;
    // state control
    always_ff @(posedge clock) begin
        if(reset) begin
            state <= S_IDLE;
        end
        else begin
            case(state)
                S_IDLE: begin
                    if(lhs_start) begin
                        state <= S_BUSY;
                    end
                end
                S_BUSY: begin
                    if(out_over) begin
                        state <= S_IDLE;
                    end
                end
                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end
    // cnt
    logic[`lgN:0] cnt;
    always_ff @(posedge clock) begin
        if(lhs_start || reset || state == S_IDLE) begin
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
    logic[`lgN-1:0] out_idx_latch[`N-1:0];
    logic[`lgN:0] cur_start_idx_latch, cur_end_idx_latch;
    logic blank_row[`N-1:0], blank_row_latch[`N-1:0];
    always_ff @(posedge clock) begin
        if(lhs_start || reset || state == S_IDLE) begin
            cur_start_idx_latch <= 0;
        end
        else begin
            cur_start_idx_latch <= cur_end_idx_latch;
        end
    end
    always_ff @(posedge clock) begin
        for(int i = 0; i < `N; i = i + 1) begin
            if(i < cur_start_idx_latch) begin
                out_idx_latch[i] <= 0;
            end
            else if(ptr_latch[i] >= cnt*`N && ptr_latch[i] < (cnt+1)*`N) begin
                out_idx_latch[i] <= ptr_latch[i] - cnt*`N;
            end
            else begin
                out_idx_latch[i] <= `N-1;
            end
        end
    end
    always_ff @(posedge clock) begin
        if(lhs_start) begin
            cur_end_idx_latch <= 0;
        end
        else begin
            for(int i = 0; i < `N; i = i + 1) begin
                if(ptr_latch[i] >= cnt*`N && ptr_latch[i] < (cnt+1)*`N) begin
                    cur_end_idx_latch <= i+1;
                end
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
            blank_row_latch[i] <= blank_row[i];
        end
    end


    // io start/over communication
    logic[`lgN:0] final_in_cnt;
    logic in_ended;
    always_ff @(posedge clock) begin
        if(reset || lhs_start) begin
            final_in_cnt <= 0;
            in_ended <= 0;
        end
        else if(in_over) begin
            final_in_cnt <= cnt;
            in_ended <= 1;
        end
    end
    always_comb begin
        in_over = state == S_BUSY && ptr_latch[`N-1] >= cnt*`N && ptr_latch[`N-1] < (cnt+1)*`N;
        out_start = state == S_BUSY && cnt == ru_delay + 1;
        out_over = state == S_BUSY && in_ended && cnt == ru_delay + 1 + final_in_cnt;
    end

    // RedUnit & HALO
    data_t ru_out[`N-1:0];
    logic[`lgN:0] out_start_idx, out_end_idx;
    data_t halo;
    logic halo_en;
    logic[`lgN:0] ru_delay;
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
        .delay(ru_delay),
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

    // FIXME: RHS logic
    localparam  S_RHS_BUF_IDLE  = 0, // the buffer is idle and ready to be written
                S_RHS_BUF_BUSY  = 1, // the buffer is being written
                S_RHS_BUF_READY = 2; // the buffer is written and needed for later use
    localparam  S_RHS_IDLE      = 0, // the rhs is idle
                S_RHS_BUSY      = 1; // the rhs is being written
    data_t rhs_buf [1:0][`N-1:0][`N-1:0];
    logic rhs_buf_read_n, rhs_buf_calc_n; // indicate which buffer is being written and read
    logic [`lgN:0] rhs_cnt;
    logic[1:0] rhs_state;
    logic[2:0] rhs_buf_state[1:0];
    logic rhs_release;
    // rhs_cnt
    always_ff @(posedge clock) begin
        if(reset) begin
            rhs_cnt <= 0;
        end
        else if(rhs_start || rhs_state == S_RHS_BUSY) begin
            rhs_cnt <= rhs_cnt + 1;
        end
        else begin
            rhs_cnt <= 0;
        end
    end
    // rhs_state
    always_ff @(posedge clock) begin
        if(reset) begin
            rhs_state <= S_RHS_IDLE;
        end
        else begin
            case(rhs_state)
                S_RHS_IDLE: begin
                    if(rhs_start) begin
                        rhs_state <= S_RHS_BUSY;
                    end
                end
                S_RHS_BUSY: begin
                    if(rhs_cnt == `N/4-1) begin
                        rhs_state <= S_RHS_IDLE;
                    end
                end
                default: begin
                    rhs_state <= S_RHS_IDLE;
                end
            endcase
        end
    end
    // rhs_buf_state
    always_ff @(posedge clock) begin
        if(reset) begin
            rhs_buf_state[0] <= S_RHS_BUF_IDLE;
            rhs_buf_state[1] <= S_RHS_BUF_IDLE;
        end
        else begin
            case(rhs_buf_state[0])
                S_RHS_BUF_IDLE: begin
                    if(rhs_start) begin
                        rhs_buf_state[0] <= S_RHS_BUF_BUSY;
                    end
                end
                S_RHS_BUF_BUSY: begin
                    if(rhs_cnt == `N/4-1) begin
                        rhs_buf_state[0] <= S_RHS_BUF_READY;
                    end
                end
                S_RHS_BUF_READY: begin
                    // TODO: release buffer
                end
                default: begin
                    rhs_buf_state[0] <= S_RHS_BUF_IDLE;
                end
            endcase
            case(rhs_buf_state[1])
                S_RHS_BUF_IDLE: begin
                    if(rhs_start && rhs_buf_state[0] != S_RHS_BUF_IDLE) begin
                        rhs_buf_state[1] <= S_RHS_BUF_BUSY;
                    end
                end
                S_RHS_BUF_BUSY: begin
                    if(rhs_cnt == `N/4-1) begin
                        rhs_buf_state[1] <= S_RHS_BUF_READY;
                    end
                end
                S_RHS_BUF_READY: begin
                    // TODO: release buffer
                end
                default: begin
                    rhs_buf_state[1] <= S_RHS_BUF_IDLE;       
                end
            endcase
        end
    end
    assign rhs_ready = (rhs_state == S_RHS_IDLE) && (rhs_buf_state[0] == S_RHS_BUF_IDLE || rhs_buf_state[1] == S_RHS_BUF_IDLE);
    assign rhs_buf_read_n = (rhs_buf_state[0] == S_RHS_BUF_READY)?1:0;

    // TODO: rhs_calc_n logic
    assign rhs_buf_calc_n = 0;
    // read rhs
    always_ff @(posedge clock) begin
        if(reset) begin
            for(int i = 0; i < 2; i++) begin
                for(int j = 0; j < `N; j++) begin
                    for(int k = 0; k < `N; k++) begin
                        rhs_buf[i][j][k].data <= 0;
                    end
                end
            end
        end
        else if(rhs_start || (rhs_state == S_RHS_BUSY && rhs_cnt < `N/4)) begin
            for(int j = 0; j < 4; j = j + 1) begin
                    for(int k = 0; k < `N; k = k + 1) begin
                        rhs_buf[rhs_buf_read_n][`N-4+j][k].data <= rhs_data[j][k].data;
                    end
                end
            for(int i = 0; i < `N - 4; i = i + 4) begin
                for(int j = 0; j < 4; j++) begin
                    for(int k = 0; k < `N; k++) begin
                        rhs_buf[rhs_buf_read_n][i+j][k].data <= rhs_buf[rhs_buf_read_n][i+4+j][k].data;
                    end
                end
            end
        end
    end

    // FIXME: LHS logic

    // FIXME: PE generation
    logic pe_lhs_start = lhs_start;
    data_t pe_out[`N-1:0][`N-1:0];

    logic pe_in_over, pe_out_start, pe_out_over;
    int pe_delay;
    PE PE_inst(
        .clock(clock),
        .reset(reset),
        .lhs_start(pe_lhs_start),
        .lhs_ptr(lhs_ptr),
        .lhs_col(lhs_col),
        .lhs_data(lhs_data),
        .rhs(rhs_buf[rhs_buf_calc_n][`N-1:0][0]),
        .out(pe_out[0]),
        .in_over(pe_in_over),
        .out_start(pe_out_start),
        .out_over(pe_out_over),
        .delay(pe_delay),
        .num_el()
    );
    generate
        for(genvar i = 1; i < `N; i = i + 1) begin
            PE PE_inst(
                .clock(clock),
                .reset(reset),
                .lhs_start(pe_lhs_start),
                .lhs_ptr(lhs_ptr),
                .lhs_col(lhs_col),
                .lhs_data(lhs_data),
                .rhs(rhs_buf[rhs_buf_calc_n][`N-1:0][i]),
                .out(pe_out[i]),
                .in_over(pe_in_over),
                .out_start(pe_out_start),
                .out_over(pe_out_over),
                .delay(),
                .num_el()
            );
        end
    endgenerate

    // FIXME: OUTPUT buffer
    localparam  S_OUT_BUF_IDLE      = 0,
                S_OUT_BUF_BUSY      = 1,
                S_OUT_BUF_READY     = 2;
    localparam  S_OUT_RECEIVE_IDLE  = 0,
                S_OUT_RECEIVE_BUSY  = 1;
    data_t out_buf [1:0][`N-1:0][`N-1:0];
    logic[1:0] out_buf_state[1:0];
    logic[1:0] out_buf_receive_state;
    logic out_buf_receive_n, out_buf_write_n;
    logic[`lgN:0] out_buf_receive_cnt;
    // TODO: out_buf_receive_start
    logic out_buf_receive_ready, out_buf_receive_start;
    // out buffer receive cnt
    always_ff @(posedge clock) begin
        if(reset) begin
            out_buf_receive_cnt <= 0;
        end
        else if(out_start || out_buf_receive_state == S_OUT_RECEIVE_BUSY) begin
            out_buf_receive_cnt <= out_buf_receive_cnt + 1;
        end
        else begin
            out_buf_receive_cnt <= 0;
        end
    end
    // out buffer receive state
    always_ff @(posedge clock) begin
        if(reset) begin
            out_buf_receive_state <= S_OUT_RECEIVE_IDLE;
        end
        else begin
            case(out_buf_receive_state)
                S_OUT_RECEIVE_IDLE: begin
                    if(out_buf_receive_start) begin
                        out_buf_receive_state <= S_OUT_RECEIVE_BUSY;
                    end
                end
                S_OUT_RECEIVE_BUSY: begin
                    if(out_buf_receive_cnt == `N/4-1) begin
                        out_buf_receive_state <= S_OUT_RECEIVE_IDLE;
                    end
                end
                default: begin
                    out_buf_receive_state <= S_OUT_RECEIVE_IDLE;
                end
            endcase
        end
    end

    // out buffer state
    always_ff @(posedge clock) begin
        if(reset) begin
            out_buf_state[0] <= S_OUT_BUF_IDLE;
            out_buf_state[1] <= S_OUT_BUF_IDLE;
        end
        else begin
            case(out_buf_state[0])
                S_OUT_BUF_IDLE: begin
                    if(out_buf_receive_start) begin
                        out_buf_state[0] <= S_OUT_BUF_BUSY;
                    end
                end
                S_OUT_BUF_BUSY: begin
                    if(out_buf_receive_cnt == `N/4-1) begin
                        out_buf_state[0] <= S_OUT_BUF_READY;
                    end
                end
                S_OUT_BUF_READY: begin
                    // TODO: release buffer
                end
                default: begin
                    out_buf_state[0] <= S_OUT_BUF_IDLE;
                end
            endcase
            case(out_buf_state[1])
                S_OUT_BUF_IDLE: begin
                    if(out_buf_receive_start && out_buf_state[0] != S_OUT_BUF_IDLE) begin
                        out_buf_state[1] <= S_OUT_BUF_BUSY;
                    end
                end
                S_OUT_BUF_BUSY: begin
                    if(out_buf_receive_cnt == `N/4-1) begin
                        out_buf_state[1] <= S_OUT_BUF_READY;
                    end
                end
                S_OUT_BUF_READY: begin
                    //TODO: release buffer
                end
                default: begin
                    out_buf_state[1] <= S_OUT_BUF_IDLE;
                end
            endcase
        end
    end

    generate
        for(genvar i = 0; i < `N; i = i + 1) begin
            for(genvar j = 0; j < `N; j = j + 1) begin
                // TODO: out_buf adder control
                data_t adder0, adder1;
                assign adder0 = reset?0:out_buf[out_buf_receive_n][i][j];
                assign adder1 = pe_out[i][j];
                add_ add_inst(
                    .clock(clock),
                    .a(adder0),
                    .b(adder1),
                    .out(out_buf[out_buf_receive_n][i][j])
                );
            end
        end
    endgenerate

    // FIXME: OUTPUT logic
    localparam  S_OUT_IDLE  = 0,
                S_OUT_READY = 1,
                S_OUT_BUSY  = 2;
    logic[1:0] out_state;
    logic [`lgN:0] out_cnt;
    always_ff @(posedge clock) begin
        if(reset) begin
            out_cnt <= 0;
        end
        else if(out_start || out_state == S_OUT_BUSY) begin
            out_cnt <= out_cnt + 1;
        end
        else begin
            out_cnt <= 0;
        end
    end
    always_ff @(posedge clock) begin
        if(reset) begin
            out_state <= S_OUT_IDLE;
        end
        else begin
            case(out_state)
                S_OUT_IDLE: begin
                    // TODO: judge whether out is ready for output
                end
                S_OUT_READY: begin
                    if(out_start) begin
                        out_state <= S_OUT_BUSY;
                    end
                end
                S_OUT_BUSY: begin
                    if(out_cnt == `N/4-1) begin
                        out_state <= S_OUT_IDLE;
                    end
                end
                default: begin
                    out_state <= S_OUT_IDLE;
                end
            endcase
        end
    end
    assign out_ready = (out_state == S_OUT_READY);
    generate
        for(genvar i = 0; i < 4; i = i + 1) begin
            for(genvar j = 0; j < `N; j = j + 1) begin
                always_comb begin
                    if(out_state == S_OUT_BUSY) begin
                        out_data[i][j].data = out_buf[out_buf_write_n][out_cnt*4+i][j].data;
                    end
                    else begin
                        out_data[i][j].data = 0;
                    end
                end
            end
        end
    endgenerate
endmodule
