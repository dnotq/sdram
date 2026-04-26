-- Released under the 3-Clause BSD License:
--
-- Copyright 2026 Matthew Hagerty (matthew <at> dnotq <dot> io)
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
-- 1. Redistributions of source code must retain the above copyright notice,
-- this list of conditions and the following disclaimer.
--
-- 2. Redistributions in binary form must reproduce the above copyright
-- notice, this list of conditions and the following disclaimer in the
-- documentation and/or other materials provided with the distribution.
--
-- 3. Neither the name of the copyright holder nor the names of its
-- contributors may be used to endorse or promote products derived from this
-- software without specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
-- ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.

-- Matthew Hagerty
-- April 18, 2026
--
-- This is a very hacky model of an SDRAM chip designed to provide functional
-- memory for the simple SDRAM techbench.
--
-- There is no actual timing considered, only cycles, and the response is based
-- collectively on the datasheets for three different 16Mx16 SDRAM parts.
--
-- Only the activate, read, and write commands are implemented.
-- Assume CL=2
-- The memory is 2Mx16.
--

-- Suffix naming convention:
--    _i   input, from register
--    _ci  input, from combinatorial logic
--    _i   output, registered
--    _co  output, combinatorial
--    _io  tri-state I/O, top-level
--    _r   register
--    _x   next state signal/wire for registers
--    _s   signal/wire, combinatorial
--    _sb  single-cycle strobe
--    _n   active-low signal
--


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_hacky_sdram_model is
port
( clk_100m0_i     : in     std_logic
; sdr_cke_i       : in     std_logic
; sdr_cs_n_i      : in     std_logic
; sdr_ras_n_i     : in     std_logic
; sdr_cas_n_i     : in     std_logic
; sdr_we_n_i      : in     std_logic
; sdr_bs_i        : in     std_logic_vector( 1 downto 0)
; sdr_addr_i      : in     std_logic_vector(12 downto 0)
; sdr_data_io     : inout  std_logic_vector(15 downto 0)
; sdr_dqmu_i      : in     std_logic
; sdr_dqml_i      : in     std_logic
);
end tb_hacky_sdram_model;

architecture behavior of tb_hacky_sdram_model is

   subtype cmd_type is std_logic_vector(3 downto 0);
   constant CMD_ACTIVATE         : cmd_type := "0011";
   constant CMD_WRITE            : cmd_type := "0100";
   constant CMD_READ             : cmd_type := "0101";

   -- 2MB SDRAM
   type sdram_t is array (0 to 1048576) of std_logic_vector(7 downto 0);
   signal sdram_ub : sdram_t := ((others=> (others=>'0')));
   signal sdram_lb : sdram_t := ((others=> (others=>'0')));

   type sd_st_type is (SD_IDLE, SD_RCD, SD_RW, SD_WRITE, SD_RAS1, SD_RAS2);
   signal sd_state_r       : sd_st_type := SD_IDLE;
   signal sd_state_x       : sd_st_type;

   signal sd_addr_s        : std_logic_vector(19 downto 0);
   signal sd_cmd_s         : std_logic_vector( 3 downto 0);

   signal sd_row_r         : std_logic_vector( 6 downto 0) := (others => '0');
   signal sd_row_x         : std_logic_vector( 6 downto 0);
   signal sd_col_r         : std_logic_vector(12 downto 0) := (others => '0');
   signal sd_col_x         : std_logic_vector(12 downto 0);

   signal sd_data_ub_r     : std_logic_vector( 7 downto 0) := (others => '0');
   signal sd_data_ub_x     : std_logic_vector( 7 downto 0);
   signal sd_data_lb_r     : std_logic_vector( 7 downto 0) := (others => '0');
   signal sd_data_lb_x     : std_logic_vector( 7 downto 0);

   signal sd_ub_r          : std_logic := '0';
   signal sd_ub_x          : std_logic;
   signal sd_lb_r          : std_logic := '0';
   signal sd_lb_x          : std_logic;

   signal sd_ub_en_sb      : std_logic;
   signal sd_lb_en_sb      : std_logic;
   signal sd_rd_en_sb      : std_logic;

begin

   -- SDRAM
   process
   ( sdr_cs_n_i, sdr_ras_n_i, sdr_cas_n_i, sdr_we_n_i
   , sdr_addr_i, sdr_data_io, sdr_dqmu_i, sdr_dqml_i
   , sd_state_r, sd_row_r, sd_col_r
   , sd_data_ub_r, sd_data_lb_r, sd_ub_r, sd_lb_r
   , sd_cmd_s, sd_rd_en_sb
   ) begin

      sd_cmd_s    <= (sdr_cs_n_i & sdr_ras_n_i & sdr_cas_n_i & sdr_we_n_i);
      sd_addr_s   <= sd_row_r & sd_col_r;
      sd_state_x  <= sd_state_r;
      sd_row_x    <= sd_row_r;
      sd_col_x    <= sd_col_r;

      sd_data_ub_x <= sd_data_ub_r;
      sd_data_lb_x <= sd_data_lb_r;

      sd_ub_x     <= sd_ub_r;
      sd_lb_x     <= sd_lb_r;
      sd_ub_en_sb <= '1';
      sd_lb_en_sb <= '1';

      sd_rd_en_sb <= '1';

      case ( sd_state_r ) is
      when SD_IDLE =>
         sd_ub_x <= '1';
         sd_lb_x <= '1';

         if sd_cmd_s = CMD_ACTIVATE then
            sd_row_x <= sdr_addr_i(6 downto 0);
            sd_state_x <= SD_RCD;
         end if;

      when SD_RCD =>
         -- Expect CL=2
         sd_state_x <= SD_RW;

      when SD_RW =>
         sd_col_x <= sdr_addr_i;

         if sd_cmd_s = CMD_READ then
            sd_state_x <= SD_RAS1;

         elsif sd_cmd_s = CMD_WRITE then
            sd_ub_x <= sdr_dqmu_i;
            sd_lb_x <= sdr_dqml_i;
            sd_data_ub_x <= sdr_data_io(15 downto 8);
            sd_data_lb_x <= sdr_data_io( 7 downto 0);
            sd_state_x <= SD_WRITE;
         else
            sd_state_x <= SD_IDLE;
         end if;

      when SD_WRITE =>
         sd_ub_en_sb <= sd_ub_r;
         sd_lb_en_sb <= sd_lb_r;
         sd_state_x <= SD_IDLE;

      when SD_RAS1 =>
         sd_state_x <= SD_RAS2;
         sd_rd_en_sb <= '0';

      when SD_RAS2 =>
         sd_state_x <= SD_IDLE;

      end case;
   end process;


   process (clk_100m0_i) begin
   if rising_edge(clk_100m0_i) then
      sd_state_r  <= sd_state_x;
      sd_row_r    <= sd_row_x;
      sd_col_r    <= sd_col_x;
      sd_ub_r     <= sd_ub_x;
      sd_lb_r     <= sd_lb_x;

      sd_data_ub_r <= sd_data_ub_x;
      sd_data_lb_r <= sd_data_lb_x;

      if sd_ub_en_sb = '0' then
         sdram_ub(to_integer(unsigned(sd_addr_s))) <= sd_data_ub_r;
      end if;

      if sd_lb_en_sb = '0' then
         sdram_lb(to_integer(unsigned(sd_addr_s))) <= sd_data_lb_r;
      end if;

      if sd_rd_en_sb = '0' then
         -- Drive the output tri-state when reading.
         -- The memory is directly connected to the output (not registered in
         -- this model). Assume in a real SDRAM this is also the case, however
         -- it would be the active-row that is connected to the output via bus
         -- driver transistors.
         sdr_data_io(15 downto 8) <= sdram_ub(to_integer(unsigned(sd_addr_s)));
         sdr_data_io( 7 downto 0) <= sdram_lb(to_integer(unsigned(sd_addr_s)));
      else
         sdr_data_io <= (others => 'Z');
      end if;

   end if;
   end process;

end;
