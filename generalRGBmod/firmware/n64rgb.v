//////////////////////////////////////////////////////////////////////////////////
// Company: Circuit-Board.de
// Engineer: borti4938
// (initial design file by Ikari_01)
//
// Module Name:    n64rgb
// Project Name:   n64rgb
// Target Devices: several MaxII & MaxV devices
// Tool versions:  Altera Quartus Prime
// Description:
//
// Dependencies: n64igr.v (Rev. 2.5)
//
// Revision: 2.5
// Features: BUFFERED version (no color shifting around edges)
//           deblur (with heuristic) and 15bit mode (5bit for each color)
//             - heuristic deblur:   on (default)                               | off (set pin 1 to GND / short pin 1 & 2)
//             - deblur default:     on (default)                               | off (set pin 91 to GND / short pin 91 & 90)
//               (deblur deafult only comes into account if heuristic is switched off)
//             - 15bit mode default: on (set pin 36 to GND / short pin 36 & 37) | off (default)
//           controller input detection for switching de-blur and 15bit mode
//           resetting N64 using the controller
//           defaults of de-blur and 15bit mode are set on power cycle
//           if de-blur heuristic is overridden by user, it is reset on each power cycle and on each reset
//
///////////////////////////////////////////////////////////////////////////////////////////

//`define DEBUG

// Only uncomment one of the following `define macros!
//`define USE_EPM240T100C5
//`define USE_EPM570T100C5
//`define USE_5M240ZT100C4
`define USE_5M570ZT100C4

//`define OPTION_INVLPF

module n64rgb (
  input nCLK,
  input nDSYNC,
  input [6:0] D_i,

  input CTRL_i,

  input Default_nForceDeBlur,
  input Default_DeBlur,
  input Default_n15bit_mode,

  output reg nVSYNC,
  output reg nCLAMP,
  output reg nHSYNC,
  output reg nCSYNC,

  output reg [6:0] R_o,     // red data vector
  output reg [6:0] G_o,     // green data vector
  output reg [6:0] B_o,     // blue data vector

  inout nRST,

  input  nTHS7374_LPF_Bypass_i,
  output THS7374_LPF_Bypass_o,

  // dummies: some I/O pins are tied to Vcc/GND
  `ifdef USE_EPM240T100C5
    input [6:0] dummy
  `endif
  `ifdef USE_EPM570T100C5
    input [2:0] dummy
  `endif
  `ifdef USE_5M240ZT100C4
    input [5:0] dummy
  `endif
  `ifdef USE_5M570ZT100C4
    input dummy
  `endif
);


`ifndef DEBUG
  reg [3:0] S_DBr[0:1];        // sync data vector buffer: {nVSYNC, nCLAMP, nHSYNC, nCSYNC}
`else
  reg [3:0] S_DBr[0:5];
`endif
reg [6:0] R_DBr, G_DBr, B_DBr; // red, green and blue data buffer

initial begin
  S_DBr[1] = 4'b1111;
  S_DBr[0] = 4'b1111;
`ifdef DEBUG
  S_DBr[5] = 4'b1111;
  S_DBr[4] = 4'b1111;
  S_DBr[3] = 4'b1111;
  S_DBr[2] = 4'b1111;
`endif
  {nVSYNC, nCLAMP, nHSYNC, nCSYNC} = 4'b1111;
  R_DBr = 7'b0000000;
  G_DBr = 7'b0000000;
  B_DBr = 7'b0000000;
  R_o = 7'b0000000;
  G_o = 7'b0000000;
  B_o = 7'b0000000;
end


// Part 1: connect IGR module
// ==========================

wire nForceDeBlur, nDeBlur, n15bit_mode;
`ifdef OPTION_INVLPF
  wire InvLPF;
`endif

n64igr igr(
  .nCLK(nCLK),
  .nRST(nRST),
  .CTRL(CTRL_i),
  .Default_nForceDeBlur(Default_nForceDeBlur),
  .Default_DeBlur(Default_DeBlur),
  .Default_n15bit_mode(Default_n15bit_mode),
  .nForceDeBlur(nForceDeBlur),
  .nDeBlur(nDeBlur),
  .n15bit_mode(n15bit_mode)
`ifdef OPTION_INVLPF
  ,
  .InvLPF(InvLPF)
`endif
);


// Part 2 - 4: RGB Demux with De-Blur Add-On
// =========================================
//
// short description of N64s RGB and sync data demux
// -------------------------------------------------
//
// pulse shapes and their realtion to each other:
// nCLK (~50MHz, Numbers representing negedge count)
// ---. 3 .---. 0 .---. 1 .---. 2 .---. 3 .---
//    |___|   |___|   |___|   |___|   |___|
// nDSYNC (~12.5MHz)                           .....
// -------.       .-------------------.
//        |_______|                   |_______
//
// more info: http://members.optusnet.com.au/eviltim/n64rgb/n64rgb.html
//


// Part 2.1: data counter for heuristic and de-mux
// ===============================================

reg [1:0] data_cnt = 2'b00;

always @(negedge nCLK) begin // data register management
  if (~nDSYNC)
    data_cnt <= 2'b01;  // reset data counter
  else
    data_cnt <= data_cnt + 1'b1;  // increment data counter
end


// Part 2.2: estimation of 240p/288p
// =================================

reg [2:0] serr_cnt = 3'b000; // 240p: 3 hsync pulses during vsync pulse ; 480i: 6 serrated hsync per vsync
reg       n64_480i = 1'b1;

always @(negedge nCLK) begin // estimation of blur effect
  if (~nDSYNC) begin
    if(&{~S_DBr[0][3],~S_DBr[0][0],D_i[0]}) // nVSYNC low and posedge at nCSYNC
      serr_cnt <= serr_cnt + 1'b1;          // count up hsync pulses during vsync pulse
                                            // serr_cnt[2]==1 means a value >=4 -> 480i mode detected

    if(~S_DBr[0][3] & D_i[3]) begin // posedge at nVSYNC detected - set n64_480i and reset serr_cnt
      n64_480i <= serr_cnt[2];
      serr_cnt <= 3'b000;
    end
  end
end


// Part 2.3: determine vmode
// =========================

reg [1:0] line_cnt;       // PAL: line_cnt[1:0] == 01 ; NTSC: line_cnt[1:0] = 11
reg       vmode;          // PAL: vmode == 1          ; NTSC: vmode == 0
reg       blur_pixel_pos; // indicates position of a potential blurry pixel
                          // blur_pixel_pos == 0 -> pixel at D_i
                          // blur_pixel_pos == 1 -> pixel at #_DBr

always @(negedge nCLK) begin
  if (~nDSYNC) begin
    if(~S_DBr[0][3] & D_i[3]) begin // posedge at nVSYNC detected - reset line_cnt and set vmode
      line_cnt <= 2'b00;
      vmode    <= ~line_cnt[1];
    end

    if(~S_DBr[0][1] & D_i[1]) // posedge nHSYNC -> increase line_cnt
      line_cnt <= line_cnt + 1'b1;

    if(~n64_480i) begin // 240p
      if(~S_DBr[0][0] & D_i[0]) // posedge nCSYNC -> reset blanking
        blur_pixel_pos <= ~vmode;
      else
        blur_pixel_pos <= ~blur_pixel_pos;
    end else
      blur_pixel_pos <= 1'b1;
  end
end


// Part 3.1: heuristic guess in 240p/288p if blur is used by the N64
// =================================================================

`ifdef DEBUG
  parameter init_cnt = 4'hd;            // initial counter value for nblur_est_cnt
  parameter hold_off = 4'h3;            // hold off estimation for x pairs of (non-blur,'blur') pixels
  reg [3:0] nblur_est_cnt  = init_cnt;  // register to estimate whether blur is used or not by the N64
                                        // (if counter saturates, a non-blurred picture is detected)
  reg [3:0] nblur_est_holdoff = 4'h0;   // Holf Off the nblur_est_cnt (removes ripples e.g. due to light effects)
`endif

`define CMP_RANGE 6:5 // evaluate gradients in this range (shall include the MSB)

`define TREND_RANGE    8:0      // width of the trend filter
`define NBLUR_TH_BIT   8        // MSB
parameter init_trend = 9'h100;  // initial value (shall have MSB set, zero else)

`ifndef DEBUG
  reg [1:0] nblur_est_cnt     = 2'b00;  // register to estimate whether blur is used or not by the N64
  reg [1:0] nblur_est_holdoff = 2'b00;  // Holf Off the nblur_est_cnt (removes ripples e.g. due to light effects)
`endif

reg [2:0] run_estimation = 3'b000;    // run counter or not (run_estimation[2] decides); do not use pixels at border

reg [1:0] gradient[2:0];  // shows the (sharp) gradient direction between neighbored pixels
                          // gradient[x][1]   = 1 -> decreasing intensity
                          // gradient[x][0]   = 1 -> increasing intensity
                          // else                 -> constant
reg [1:0] gradient_changes = 2'b00;

reg [`TREND_RANGE] nblur_n64_trend = init_trend;  // trend shows if the algorithm tends to estimate more blur enabled rather than disabled
                                                  // this acts as like as a very simple mean filter
reg nblur_n64 = 1'b1;                             // blur effect is estimated to be off within the N64 if value is 1'b1

always @(negedge nCLK) begin // estimation of blur effect
  if (~nDSYNC) begin

    if(~blur_pixel_pos) begin  // incomming (potential) blurry pixel
                               // (blur_pixel_pos changes on next @(negedge nCLK))

      run_estimation[2:1] <= run_estimation[1:0]; // deblur estimation counter is
      run_estimation[0]   <= 1'b1;                // starts a bit delayed in each line

`ifdef DEBUG
      if (|nblur_est_holdoff) // hold_off? if yes, decrement it
        nblur_est_holdoff <= nblur_est_holdoff - 1'b1;
`else
      if (|nblur_est_holdoff) // hold_off? if yes, increment it until overflow back to zero
        nblur_est_holdoff <= nblur_est_holdoff + 1'b1;
`endif


      if (&gradient_changes) begin  // evaluate gradients: &gradient_changes == all color components changed the gradient
`ifdef DEBUG
        if (~|{&nblur_est_cnt,|nblur_est_holdoff})
          nblur_est_cnt <= nblur_est_cnt +1'b1;
        nblur_est_holdoff <= hold_off;
`else
        if (~nblur_est_cnt[1] & ~|nblur_est_holdoff)
          nblur_est_cnt <= nblur_est_cnt +1'b1;
        nblur_est_holdoff <= 2'b01;
`endif
      end

      gradient_changes    <= 2'b00; // reset
    end

    if(~S_DBr[0][0] & D_i[0]) begin // negedge at CSYNC detected - new line
      run_estimation    <= 3'b000;
`ifdef DEBUG
      nblur_est_holdoff <= 4'h0;
`else
      nblur_est_holdoff <= 2'b00;
`endif
    end

    if(S_DBr[0][3] & ~D_i[3]) begin // negedge at nVSYNC detected - new frame
`ifdef DEBUG
      if(&nblur_est_cnt) begin // add to weight
`else
      if(nblur_est_cnt[1]) begin // add to weight
`endif
        if(~&nblur_n64_trend)
          nblur_n64_trend <= nblur_n64_trend + 1'b1;
      end else begin// subtract
        if(|nblur_n64_trend)
          nblur_n64_trend <= nblur_n64_trend - 1'b1;
      end

      nblur_n64 <= nblur_n64_trend[`NBLUR_TH_BIT];
//      nblur_n64 <= &nblur_est_cnt;

`ifdef DEBUG
      nblur_est_cnt <= init_cnt;
`else
      nblur_est_cnt <= 2'b00;
`endif
    end

  end else if (&{S_DBr[1][3],S_DBr[1][1],S_DBr[0][3],S_DBr[0][1]}) begin
    if (blur_pixel_pos) begin
      case(data_cnt)
          2'b01: gradient[2] <= {R_DBr[`CMP_RANGE] < D_i[`CMP_RANGE],
                                 R_DBr[`CMP_RANGE] > D_i[`CMP_RANGE]};
          2'b10: gradient[1] <= {G_DBr[`CMP_RANGE] < D_i[`CMP_RANGE],
                                 G_DBr[`CMP_RANGE] > D_i[`CMP_RANGE]};
          2'b11: gradient[0] <= {B_DBr[`CMP_RANGE] < D_i[`CMP_RANGE],
                                 B_DBr[`CMP_RANGE] > D_i[`CMP_RANGE]};
      endcase
    end else if (run_estimation[2]) begin
      case(data_cnt)
          2'b01: if (&(gradient[2] ^ {R_DBr[`CMP_RANGE] < D_i[`CMP_RANGE],
                                      R_DBr[`CMP_RANGE] > D_i[`CMP_RANGE]}))
                   gradient_changes <= 2'b01;
          2'b10: if (&(gradient[1] ^ {G_DBr[`CMP_RANGE] < D_i[`CMP_RANGE],
                                      G_DBr[`CMP_RANGE] > D_i[`CMP_RANGE]}))
                   gradient_changes <= gradient_changes + 1'b1;
          2'b11: if (&(gradient[0] ^ {B_DBr[`CMP_RANGE] < D_i[`CMP_RANGE],
                                      B_DBr[`CMP_RANGE] > D_i[`CMP_RANGE]}))
                   gradient_changes <= gradient_changes + 1'b1;
      endcase
    end
  end else begin
    run_estimation  <= 3'b0;
    gradient[2]     <= 2'b0;
    gradient[1]     <= 2'b0;
    gradient[0]     <= 2'b0;
  end
  if (~nRST | n64_480i) begin
    nblur_n64_trend <= init_trend;
    nblur_n64       <= 1'b1;
  end
end


// Part 3.2: blanking management
// =============================

wire ndo_deblur = ~nForceDeBlur ?  (n64_480i | nDeBlur) : (n64_480i | nblur_n64); // force de-blur option for 240p? -> yes: enable it if user wants to | no: enable de-blur depending on estimation

reg  nblank_rgb;  // blanking of RGB pixels for de-blur

always @(negedge nCLK) begin
  if (~nDSYNC)
    if(ndo_deblur)
      nblank_rgb <= 1'b1;
    else begin 
      if(~S_DBr[0][0] & D_i[0]) // posedge nCSYNC -> reset blanking
        nblank_rgb <= vmode;
      else
        nblank_rgb <= ~nblank_rgb;
    end
end


// Part 4: data demux
// ==================

always @(negedge nCLK) begin // data register management
  if (~nDSYNC) begin
    // shift data to output registers
`ifndef DEBUG
    {nVSYNC, nCLAMP, nHSYNC, nCSYNC} <= ndo_deblur ? S_DBr[0] : S_DBr[1];
`else // DEBUG: make a large jump between deblur on and off to see occasional estimation switches
    {nVSYNC, nCLAMP, nHSYNC, nCSYNC} <= ndo_deblur ? D_i[3:0] : S_DBr[5];
    S_DBr[5] <= S_DBr[4];
    S_DBr[4] <= S_DBr[3];
    S_DBr[3] <= S_DBr[2];
    S_DBr[2] <= S_DBr[1];
`endif
    S_DBr[1] <= S_DBr[0];
    if (nblank_rgb) begin // pass RGB only if not blanked
      R_o <= R_DBr;
      G_o <= G_DBr;
      B_o <= B_DBr;
    end

    // get new sync data
    S_DBr[0] <= D_i[3:0];
  end else begin
    // demux of RGB
    case(data_cnt)
      2'b01: R_DBr <= n15bit_mode ? D_i : {D_i[6:2], 2'b00};
      2'b10: G_DBr <= n15bit_mode ? D_i : {D_i[6:2], 2'b00};
      2'b11: B_DBr <= n15bit_mode ? D_i : {D_i[6:2], 2'b00};
    endcase
  end
end


`ifdef OPTION_INVLPF
  assign THS7374_LPF_Bypass_o = ~nTHS7374_LPF_Bypass_i ^ InvLPF;
`else
  assign THS7374_LPF_Bypass_o = ~nTHS7374_LPF_Bypass_i;
`endif

endmodule
