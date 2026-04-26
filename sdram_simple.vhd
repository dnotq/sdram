-- Released under the 3-Clause BSD License:
--
-- Copyright 2014-2026 Matthew Hagerty (matthew <at> dnotq <dot> com)
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

-- Simple SDRAM Controller
--
-- Access time of 70ns for any read or write.
-- Typical refresh cycle time of 80ns.
-- Input clock is expected to be 100MHz.
-- Expect CL=2.
-- A refresh cycle must be issued at least once every 7us.
-- Defaults set for a Winbond W9812G6JH-75.
--
--
-- Notes for: Winbond W9812G6JH-75:
--
-- During testing and adjustment it was found that the refresh cycles needs to
-- 80ns to prevent SDRAM corruption.  Also, the read data needs to be registered
-- in the RAS2 cycle.  The read and write cycles remain reliable at 70ns.
--
-- Generics were added to help ajust these values for other SDRAM chips that
-- may have slight variations in these timings.
--
--
-- Change Log:
--
-- Apr 18, 2026
--    Added generic to adjust the RAS1/2 cycle for registering SDRAM data out.
--    Added generic for SDRAM init precharge cycles.
--    Added generic to adjust any needed extra cycles per memory operation.
--    Added generic to set clocks needed for an auto refresh cycle.
--    Registered done_sb_o output.
--    Added idle_o helper signal (in case done_sb_o is missed).
--    Updated testbench to include a hacky SDRAM model.
--    Updated readme.
--
-- Nov 19, 2025
--    Incorporated refresh correction (thanks tomcircuit).
--    Changed we_i to we_n_i since it is active low.
--    Changed reset to active low.
--    Renamed SDRAM signals.
--    Tidy up formatting.
--
-- Apr 20, 2023
--    Corrected REFRESH operation timer assignment to yield 70ns duration.
--    [tomcircuit at gmail dot com]
--
-- Dec 14, 2019
--    Changed SDRAM input data setup to ST_RAS1 so it will be correctly
--    registered during ST_RAS2.
--    Comment cleanup.
--
-- Jan 28, 2016
--    Changed to use positive clock edge.
--    Buffered output (read) data, sampled during RAS2.
--    Removed unused signals for features that were not implemented.
--    Changed tabs to space.
--
-- March 19, 2014
--    Initial implementation.
--
--
-- Suffix naming convention:
--    _i   input, from register
--    _ci  input, from combinatorial logic
--    _o   output, registered
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
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity sdram_simple is
generic
-- Number of initialization clocks for SDRAM precharage.  Set low (2) for simulation.
( G_INIT_PRECHARGE_CLOCKS : integer := 20000    -- Default 200uS
-- Register DOUT from SDRAM in cycle RAS1 or RAS2.
; G_REG_DOUT_IN_RAS1_RAS2 : integer := 2        -- 1 or 2, adjust if read is unstable.
-- Any extra clocks needed between Precharge and Activate.
; G_EXTRA_CLOCKS_PER_MEMOP : integer := 0       -- 0 to n, adjust if needed.
-- Clocks needed for an auto refresh cycle, not including idle and command overhead.
; G_CLOCKS_FOR_AUTO_REFRESH : integer := 6      -- 5 to n, adjust if needed.
-- CAS Latency (CL), 1 to 3, typically 2 for slower clocks (i.e. 100MHz)
; G_CL : integer := 2                           -- 1 to 3. TODO implement use.
);
port
-- Host interface
( clk_100m0_i     : in     std_logic                     -- Master clock
; reset_n_i       : in     std_logic := '0'              -- Reset, active low
; refresh_i       : in     std_logic := '0'              -- Initiate a refresh cycle, active high
; rw_i            : in     std_logic := '0'              -- Initiate a read or write operation, active high
; we_n_i          : in     std_logic := '0'              -- Write enable, active low
; addr_i          : in     std_logic_vector(23 downto 0) -- Address from host to SDRAM
; data_i          : in     std_logic_vector(15 downto 0) -- Data from host to SDRAM
; ub_i            : in     std_logic                     -- Data upper byte write-enable (active low)
; lb_i            : in     std_logic                     -- Data lower byte write-enable (active low)
; ready_o         : out    std_logic := '0'              -- Set to '1' when the memory is ready
; idle_o          : out    std_logic := '0'              -- Set to '1' when ready and idle
; done_sb_o       : out    std_logic := '0'              -- Read, write, or refresh, operation done strobe
; data_o          : out    std_logic_vector(15 downto 0) -- Data from SDRAM to host

-- SDRAM interface
; sdr_cke_o       : out    std_logic                     -- Clock-enable to SDRAM
; sdr_cs_n_o      : out    std_logic                     -- Chip-select to SDRAM
; sdr_ras_n_o     : out    std_logic                     -- SDRAM row address strobe
; sdr_cas_n_o     : out    std_logic                     -- SDRAM column address strobe
; sdr_we_n_o      : out    std_logic                     -- SDRAM write enable
; sdr_bs_o        : out    std_logic_vector( 1 downto 0) -- SDRAM bank address
; sdr_addr_o      : out    std_logic_vector(12 downto 0) -- SDRAM row/column address
; sdr_data_io     : inout  std_logic_vector(15 downto 0) -- Data to/from SDRAM
; sdr_dqmu_o      : out    std_logic                     -- Upper-byte mask for SDRAM data bus
; sdr_dqml_o      : out    std_logic                     -- Lower-byte mask for SDRAM data bus
);
end entity;

architecture rtl of sdram_simple is

   -- SDRAM controller states.
   type fsm_state_type is (
   ST_INIT_WAIT, ST_INIT_PRECHARGE, ST_INIT_REFRESH1, ST_INIT_MODE, ST_INIT_REFRESH2,
   ST_IDLE, ST_REFRESH, ST_ACTIVATE, ST_RCD, ST_RW, ST_RAS1, ST_RAS2, ST_PRECHARGE);
   signal state_r, state_x : fsm_state_type := ST_INIT_WAIT;


   -- SDRAM mode register data sent on the address bus.
   --
   -- | A12-A10 |    A9    | A8  A7 | A6 A5 A4 |    A3   | A2 A1 A0 |
   -- | reserved| wr burst |reserved| CAS Ltncy|addr mode| burst len|
   --   0  0  0      0       0   0    0  1  0       0      0  0  0
   constant MODE_REG : std_logic_vector(12 downto 0) := "000" & "0" & "00" & "010" & "0" & "000";

   -- SDRAM commands combine SDRAM inputs: cs_n, ras_n, cas_n, we_n.
   subtype cmd_type is std_logic_vector(3 downto 0);
   constant CMD_ACTIVATE         : cmd_type := "0011";
   constant CMD_PRECHARGE        : cmd_type := "0010";
   constant CMD_WRITE            : cmd_type := "0100";
   constant CMD_READ             : cmd_type := "0101";
   constant CMD_MODE             : cmd_type := "0000";
   constant CMD_NOP              : cmd_type := "0111";
   constant CMD_REFRESH          : cmd_type := "0001";

   signal cmd_r                  : cmd_type := CMD_NOP;
   signal cmd_x                  : cmd_type;

   signal bank_s                 : std_logic_vector( 1 downto 0);
   signal row_s                  : std_logic_vector(12 downto 0);
   signal col_s                  : std_logic_vector( 8 downto 0);
   signal addr_r                 : std_logic_vector(12 downto 0);
   signal addr_x                 : std_logic_vector(12 downto 0);    -- SDRAM row/column address.
   signal sd_dout_r              : std_logic_vector(15 downto 0);
   signal sd_dout_x              : std_logic_vector(15 downto 0);
   signal sd_busdir_r            : std_logic := '0';
   signal sd_busdir_x            : std_logic;
   signal done_sb_r, done_sb_x   : std_logic := '0';
   signal idle_r, idle_x         : std_logic := '0';
   signal timer_r, timer_x       : natural range 0 to 20000 := 0;
   signal refcnt_r, refcnt_x     : natural range 0 to 8 := 0;

   signal bank_r, bank_x         : std_logic_vector(1 downto 0);
   signal cke_r, cke_x           : std_logic := '0';
   signal ub_r, ub_x             : std_logic := '0';
   signal lb_r, lb_x             : std_logic := '0';
   signal ready_r, ready_x       : std_logic := '0';

   -- Data buffer for SDRAM to Host.
   signal buf_dout_r, buf_dout_x : std_logic_vector(15 downto 0) := (others => '0');

begin

   -- All signals to SDRAM buffered.

   (sdr_cs_n_o, sdr_ras_n_o, sdr_cas_n_o, sdr_we_n_o) <= cmd_r; -- SDRAM operation control bits
   sdr_cke_o   <= cke_r;      -- SDRAM clock enable
   sdr_bs_o    <= bank_r;     -- SDRAM bank address
   sdr_addr_o  <= addr_r;     -- SDRAM address
   sdr_data_io <= sd_dout_r when sd_busdir_r = '1' else (others => 'Z'); -- SDRAM data bus.
   sdr_dqmu_o  <= ub_r;       -- SDRAM upper data byte write-enable (active low) or read-enable (active high)
   sdr_dqml_o  <= lb_r;       -- SDRAM lower date byte write-enable (active low) or read-enable (active high)

   -- Signals back to host.
   ready_o     <= ready_r;
   idle_o      <= idle_r;
   done_sb_o   <= done_sb_r;
   data_o      <= buf_dout_r;

   -- 23  22  | 21 20 19 18 17 16 15 14 13 12 11 10 09 | 08 07 06 05 04 03 02 01 00 |
   -- BS0 BS1 |        ROW (A12-A0)  8192 rows         |   COL (A8-A0)  512 cols    |
   bank_s <= addr_i(23 downto 22);
   row_s  <= addr_i(21 downto 9);
   col_s  <= addr_i( 8 downto 0);


   process
   ( state_r, timer_r, refcnt_r, cke_r, addr_r, sd_dout_r, sd_busdir_r, ready_r
   , ub_r, lb_r
   , bank_r, bank_s, row_s, col_s
   , rw_i, refresh_i, addr_i, data_i, we_n_i, ub_i, lb_i
   , buf_dout_r, sdr_data_io
   ) begin

      state_x     <= state_r;       -- Stay in the same state unless changed.
      timer_x     <= timer_r;       -- Hold the cycle timer by default.
      refcnt_x    <= refcnt_r;      -- Hold the refresh timer by default.
      cke_x       <= cke_r;         -- Stay in the same clock mode unless changed.
      cmd_x       <= CMD_NOP;       -- Default to NOP unless changed.
      bank_x      <= bank_r;        -- Register the SDRAM bank.
      addr_x      <= addr_r;        -- Register the SDRAM address.
      sd_dout_x   <= sd_dout_r;     -- Register the SDRAM write data.
      sd_busdir_x <= sd_busdir_r;   -- Register the SDRAM bus tristate control.
      ub_x        <= ub_r;
      lb_x        <= lb_r;
      buf_dout_x  <= buf_dout_r;    -- SDRAM to host data buffer.

      ready_x     <= ready_r;       -- Always ready unless performing initialization.
      done_sb_x   <= '0';           -- Done strobe, single cycle.
      idle_x      <= '0';           -- Only set in idle state.

      if timer_r /= 0 then
         timer_x <= timer_r - 1;
         if timer_r = 1 and ready_r = '1' then
            -- Done strobe for refresh cycles.
            done_sb_x <= '1';
         end if;
      else

         cke_x    <= '1';
         bank_x   <= bank_s;
         -- A10 low for rd/wr commands to suppress auto-precharge.
         addr_x   <= "0000" & col_s;
         ub_x     <= '0';
         lb_x     <= '0';

         case state_r is

         when ST_INIT_WAIT =>

            -- 1. Wait 200us with DQM signals high, cmd NOP.
            -- 2. Precharge all banks.
            -- 3. Eight refresh cycles.
            -- 4. Set mode register.
            -- 5. Eight refresh cycles.

            state_x <= ST_INIT_PRECHARGE;
            -- Wait N microseconds, adjust generic according to datasheet.
            timer_x <= G_INIT_PRECHARGE_CLOCKS;
            ub_x <= '1';
            lb_x <= '1';

         when ST_INIT_PRECHARGE =>

            state_x <= ST_INIT_REFRESH1;
            -- Do 8 refresh cycles in the next state.
            refcnt_x <= 8;
            cmd_x <= CMD_PRECHARGE;
            -- Wait 2 cycles plus state overhead for 20ns Trp.
            timer_x <= 2;
            bank_x <= "00";
            -- Precharge all banks.
            addr_x(10) <= '1';

         when ST_INIT_REFRESH1 =>

            if refcnt_r = 0 then
               state_x <= ST_INIT_MODE;
            else
               refcnt_x <= refcnt_r - 1;
               cmd_x <= CMD_REFRESH;
               -- Add one additional count to match the operational cycle time.
               timer_x <= G_CLOCKS_FOR_AUTO_REFRESH + 1;
            end if;

         when ST_INIT_MODE =>

            state_x <= ST_INIT_REFRESH2;
            -- Do 8 refresh cycles in the next state.
            refcnt_x <= 8;
            bank_x <= "00";
            addr_x <= MODE_REG;
            cmd_x <= CMD_MODE;
            -- Trsc == 2 cycles after issuing MODE command.
            timer_x <= 2;

         when ST_INIT_REFRESH2 =>

            if refcnt_r = 0 then
               state_x <= ST_IDLE;
               ready_x <= '1';
            else
               refcnt_x <= refcnt_r - 1;
               cmd_x <= CMD_REFRESH;
               -- Add one additional count to match the operational cycle time.
               timer_x <= G_CLOCKS_FOR_AUTO_REFRESH + 1;
            end if;

      --
      -- Normal Operation
      --
         -- CL=2
         -- Tcas - 2clk - Read/write to data out.
         -- Trc  - 70ns - Activate to activate command.
         -- Trcd - 20ns - Activate to read/write command.
         -- Tras - 50ns - Activate to precharge command.
         -- Trp  - 20ns - Precharge to activate command.
         --
         --          |<-----------       Trc      ------------>|
         --          |<----------- Tras ---------->|
         --          |<- Trcd  ->|<- Tcas  ->|     |<-  Trp  ->|
         --   T0__  T1__  T2__  T3__  T4__  T5__  T6__  T0__  T1__
         --  __/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__
         --  IDLE  ACTVT  NOP  RD/WR  NOP   NOP  PRECG IDLE  ACTVT
         --               RCD         RAS1  RAS2
         --      ---<Row>-------------------------------------<Row>--
         --                  ---<Col>---
         --                  ---<A10>-------------<A10>---
         --                                    ---<Bank>---
         --                  ---<DQM>---
         --                  ---<Din>---
         --                        ---<///Dout///>---
         --                                     --<DATA_o>---
         --  -<ADDR_i                  >---
         --  -------<DATA_i>---
         --  -------------<UB  >---
         --  -------------<LB  >---
         --  -------------<WE_n>---
         --  _/RW_i \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\____
         --                                    ___/DONE\___
         --
         --   T0__  T1__  T2__  T3__  T4__  T5__  T6__  T7__  T0__
         --  __/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__
         --  IDLE  REFSH  NOP   NOP   NOP   NOP   NOP   NOP  IDLE
         --  _/REFSH\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\____
         --                                          ___/DONE\___
         --
         -- A10 during rd/wr : 0 = disable auto-precharge, 1 = enable auto-precharge.
         -- A10 during precharge: 0 = single bank, 1 = all banks.
         -- Registering Dout in RAS1 or RAS2 will vary between memory chips, the
         -- signal routing in the FPGA, and the circuit board routing.  Use the
         -- generic G_REG_DOUT_IN_RAS1_RAS2 to set the state to register Dout.

         -- Next State vs Current State Guide
         --
         --  T0__  T1__  T2__  T3__  T4__  T5__  T6__  T0__  T1__  T2__
         -- __/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__/  \__
         -- IDLE  ACTVT  NOP  RD/WR  NOP   NOP  PRECG IDLE  ACTVT
         --       IDLE  ACTVT  NOP  RD/WR  NOP   NOP  PRECG IDLE  ACTVT

         when ST_IDLE =>
            -- 60ns since activate when coming from PRECHARGE state.
            -- 10ns since PRECHARGE.  Trp == 20ns min.
            if rw_i = '1' then
               state_x <= ST_ACTIVATE;
               cmd_x <= CMD_ACTIVATE;
               -- Set bank select and row on activate command.
               addr_x <= row_s;

            elsif refresh_i = '1' then
               state_x <= ST_REFRESH;
               cmd_x <= CMD_REFRESH;
               -- Wait N cycles plus state overhead for auto refresh cycle.
               timer_x <= G_CLOCKS_FOR_AUTO_REFRESH;

            else
               idle_x <= '1';
            end if;

         when ST_REFRESH =>
            state_x <= ST_IDLE;

         when ST_ACTIVATE =>
            -- Trc (Active to Active Command Period) is 65ns min.
            -- 70ns since activate when coming from PRECHARGE -> IDLE states.
            -- 20ns since PRECHARGE.
            -- ACTIVATE command is presented to the SDRAM.  The command out of this
            -- state will be NOP for one cycle.
            state_x <= ST_RCD;
            -- Register any write data, even if not used.
            sd_dout_x <= data_i;

         when ST_RCD =>
            -- 10ns since activate.
            -- Trcd == 20ns min.  The clock is 10ns, so the time requirement
            -- should be satisfied by the end of this state.
            -- READ or WRITE command will be active in the next cycle.
            state_x <= ST_RW;

            if we_n_i = '0' then
               cmd_x <= CMD_WRITE;
               -- The SDRAM latches the input data with the command.
               sd_busdir_x <= '1';
               ub_x <= ub_i;
               lb_x <= lb_i;
            else
               cmd_x <= CMD_READ;
            end if;

         when ST_RW =>
            -- 20ns since activate.
            -- READ or WRITE command presented to SDRAM.
            state_x <= ST_RAS1;
            sd_busdir_x <= '0';

         when ST_RAS1 =>
            -- 30ns since activate.
            state_x <= ST_RAS2;
            if G_REG_DOUT_IN_RAS1_RAS2 = 1 then
               -- Register data from SDRAM.
               buf_dout_x <= sdr_data_io;
            end if;

         when ST_RAS2 =>
            -- 40ns since activate.
            -- Tras (Active to precharge Command Period) 45ns min.
            -- PRECHARGE command will be active in the next cycle.
            state_x <= ST_PRECHARGE;
            cmd_x <= CMD_PRECHARGE;
            -- Precharge all banks.
            addr_x(10) <= '1';
            if G_REG_DOUT_IN_RAS1_RAS2 = 2 then
               -- Register data from SDRAM.
               buf_dout_x <= sdr_data_io;
            end if;

            if G_EXTRA_CLOCKS_PER_MEMOP = 0 then
               -- Read data is ready and should be latched by the host in the
               -- precharge state.  If extra clocks are needed, the done is
               -- delayed util the last extra clock. (see timer_r)
               done_sb_x <= '1';
            end if;

            -- Extend by any required clock cycles.
            timer_x <= G_EXTRA_CLOCKS_PER_MEMOP;

         when ST_PRECHARGE =>
            -- 50ns since activate.
            -- PRECHARGE presented to SDRAM.
            state_x <= ST_IDLE;

         end case;
      end if;
   end process;

   process (clk_100m0_i)
   begin
      if rising_edge(clk_100m0_i) then
      if reset_n_i = '0' then
         state_r  <= ST_INIT_WAIT;
         timer_r  <= 0;
         cmd_r    <= CMD_NOP;
         cke_r    <= '0';
         ready_r  <= '0';
         idle_r   <= '0';
      else
         state_r     <= state_x;
         timer_r     <= timer_x;
         refcnt_r    <= refcnt_x;
         cke_r       <= cke_x;         -- CKE to SDRAM.
         cmd_r       <= cmd_x;         -- Command to SDRAM.
         bank_r      <= bank_x;        -- Bank to SDRAM.
         addr_r      <= addr_x;        -- Address to SDRAM.
         sd_dout_r   <= sd_dout_x;     -- Data to SDRAM.
         sd_busdir_r <= sd_busdir_x;   -- SDRAM bus direction.
         ub_r        <= ub_x;          -- Upper byte enable to SDRAM.
         lb_r        <= lb_x;          -- Lower byte enable to SDRAM.
         ready_r     <= ready_x;
         done_sb_r   <= done_sb_x;
         idle_r      <= idle_x;
         buf_dout_r  <= buf_dout_x;

      end if;
      end if;
   end process;

end architecture;
