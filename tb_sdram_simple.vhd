-- Released under the 3-Clause BSD License:
--
-- Copyright 2010-2019 Matthew Hagerty (matthew <at> dnotq <dot> io)
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
-- March 18, 2014
--
-- Testbench for Simple SDRAM Controller for Winbond W9812G6JH-75

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;


entity tb_sdram_simple is
end tb_sdram_simple;

architecture behavior of tb_sdram_simple is

   component sdram_simple
   generic
   -- Number of initialization clocks for SDRAM precharage.  Set low (2) for simulation.
   ( INIT_PRECHARGE_CLOCKS : integer := 20000      -- Default 200uS
   -- Register DOUT from SDRAM in cycle RAS1 or RAS2.
   ; REG_DOUT_IN_RAS1_RAS2 : integer := 2          -- 1 or 2, adjust if read is unstable.
   -- Any extra clocks needed between Precharge and Activate.
   ; EXTRA_CLOCKS_PER_MEMOP : integer := 0         -- 0 to n, adjust if needed.
   -- Clocks needed for an auto refresh cycle, not including idle and command overhead.
   ; CLOCKS_FOR_AUTO_REFRESH : integer := 6        -- 5 to n, adjust if needed.
   -- CAS Latency (CL), 1 to 3, typically 2 for slower clocks (i.e. 100MHz)
   ; CL : integer := 2                             -- 1 to 3. TODO implement use.
   );
   port
   -- Host
   ( clk_100m0_i     : in     std_logic
   ; reset_n_i       : in     std_logic
   ; refresh_i       : in     std_logic
   ; rw_i            : in     std_logic
   ; we_n_i          : in     std_logic
   ; addr_i          : in     std_logic_vector(23 downto 0)
   ; data_i          : in     std_logic_vector(15 downto 0)
   ; ub_i            : in     std_logic
   ; lb_i            : in     std_logic
   ; ready_o         : out    std_logic
   ; idle_o          : out    std_logic
   ; done_sb_o       : out    std_logic
   ; data_o          : out    std_logic_vector(15 downto 0)
   -- SDRAM interface
   ; sdr_cke_o       : out    std_logic
   ; sdr_cs_n_o      : out    std_logic
   ; sdr_ras_n_o     : out    std_logic
   ; sdr_cas_n_o     : out    std_logic
   ; sdr_we_n_o      : out    std_logic
   ; sdr_bs_o        : out    std_logic_vector( 1 downto 0)
   ; sdr_addr_o      : out    std_logic_vector(12 downto 0)
   ; sdr_data_io     : inout  std_logic_vector(15 downto 0)
   ; sdr_dqmu_o      : out    std_logic
   ; sdr_dqml_o      : out    std_logic
   );
   end component;


   -- Inputs
   signal clk_100m0_i      : std_logic := '0';
   signal reset_n_i        : std_logic := '0';
   signal refresh_i        : std_logic := '0';
   signal rw_i             : std_logic := '0';
   signal we_n_i           : std_logic := '1';
   signal addr_i           : std_logic_vector(23 downto 0) := (others => '0');
   signal data_i           : std_logic_vector(15 downto 0) := (others => '0');
   signal ub_i             : std_logic := '0';
   signal lb_i             : std_logic := '0';

	-- Tri-state
   signal sdr_data_io      : std_logic_vector(15 downto 0);

 	-- Outputs
   signal ready_o          : std_logic;
   signal idle_o           : std_logic;
   signal done_sb_o        : std_logic;
   signal data_o           : std_logic_vector(15 downto 0);
   signal sdr_cke_o        : std_logic;
   signal sdr_cs_n_o       : std_logic;
   signal sdr_ras_n_o      : std_logic;
   signal sdr_cas_n_o      : std_logic;
   signal sdr_we_n_o       : std_logic;
   signal sdr_bs_o         : std_logic_vector( 1 downto 0);
   signal sdr_addr_o       : std_logic_vector(12 downto 0);
   signal sdr_dqmu_o       : std_logic;
   signal sdr_dqml_o       : std_logic;

   -- Clock period definitions
   constant clk_100m0_i_period : time := 10 ns;

	type state_type is (ST_WAIT, ST_IDLE, ST_READ, ST_WRITE, ST_REFRESH);
	signal state_r, state_x : state_type := ST_WAIT;

   -- Access can be registered or combinatorial.

   -- Registered access.
   signal refresh_x        : std_logic;
   signal rw_x             : std_logic;

   -- Combinatorial access.
   signal rw_req_s         : std_logic := '0';
   signal refresh_req_s    : std_logic := '0';

begin

   -- Instantiate the Unit Under Test (UUT)
   uut: sdram_simple
   generic map
   ( G_INIT_PRECHARGE_CLOCKS => 8      -- initial precharge not needed for simulation.
   , G_REG_DOUT_IN_RAS1_RAS2 => 2      -- latch SDRAM data during RAS2.
   , G_EXTRA_CLOCKS_PER_MEMOP => 0     -- no extra clocks per memory operation needed.
   , G_CLOCKS_FOR_AUTO_REFRESH => 6    -- auto refresh clocks, not including cycle overhead.
   )
   port map
   ( clk_100m0_i        => clk_100m0_i
   , reset_n_i          => reset_n_i
   , refresh_i          => refresh_i
   , rw_i               => rw_i
   , we_n_i             => we_n_i
   , addr_i             => addr_i
   , data_i             => data_i
   , ub_i               => ub_i
   , lb_i               => lb_i
   , ready_o            => ready_o
   , done_sb_o          => done_sb_o
   , idle_o             => idle_o
   , data_o             => data_o
   -- SDRAM interface
   , sdr_cke_o          => sdr_cke_o
   , sdr_cs_n_o         => sdr_cs_n_o
   , sdr_ras_n_o        => sdr_ras_n_o
   , sdr_cas_n_o        => sdr_cas_n_o
   , sdr_we_n_o         => sdr_we_n_o
   , sdr_bs_o           => sdr_bs_o
   , sdr_addr_o         => sdr_addr_o
   , sdr_data_io        => sdr_data_io
   , sdr_dqmu_o         => sdr_dqmu_o
   , sdr_dqml_o         => sdr_dqml_o
   );


   -- Use the hacky SDRAM model so memory operations can be simulated.
   sdram_ext : entity work.tb_hacky_sdram_model
   port map
   ( clk_100m0_i        => clk_100m0_i
   , sdr_cke_i          => sdr_cke_o
   , sdr_cs_n_i         => sdr_cs_n_o
   , sdr_ras_n_i        => sdr_ras_n_o
   , sdr_cas_n_i        => sdr_cas_n_o
   , sdr_we_n_i         => sdr_we_n_o
   , sdr_bs_i           => sdr_bs_o
   , sdr_addr_i         => sdr_addr_o
   , sdr_data_io        => sdr_data_io
   , sdr_dqmu_i         => sdr_dqmu_o
   , sdr_dqml_i         => sdr_dqml_o
   );



   -- Clock process definitions
   clk_100m0_i_process :process
   begin
		clk_100m0_i <= '0';
		wait for clk_100m0_i_period/2;
		clk_100m0_i <= '1';
		wait for clk_100m0_i_period/2;
   end process;


   -- Sequence FSM
	process (clk_100m0_i)
	begin
		if rising_edge(clk_100m0_i) then
			state_r     <= state_x;
         -- Registered access.
--			rw_i        <= rw_x;
--			refresh_i   <= refresh_x;
		end if;
	end process;

   -- Combinatorial access.
   rw_i <= rw_req_s;
   refresh_i <= refresh_req_s;

	process ( state_r, ready_o, done_sb_o )
	begin

		state_x     <= state_r;
      refresh_x   <= '0'; -- strobe
		rw_x        <= '0'; -- strobe
		we_n_i      <= '1';
		ub_i        <= '0';
		lb_i        <= '0';

      rw_req_s <= '0';
      refresh_req_s <= '0';

      -- Step through a write, read, and refresh cycle.
		case ( state_r ) is

		when ST_WAIT =>
			if  ready_o = '1' then
				rw_x <= '1';
				state_x <= ST_WRITE;
			end if;

		when ST_WRITE =>
			if done_sb_o = '0' then
            rw_req_s <= '1';
				we_n_i <= '0';
				addr_i <= x"00_06_01";
				data_i <= x"abcd";
				ub_i <= '1';
				lb_i <= '0';
			else
				rw_x <= '1';
				state_x <= ST_READ;
			end if;

		when ST_READ =>
			if done_sb_o = '0' then
            rw_req_s <= '1';
				addr_i <= x"00_06_01";
			else
				refresh_x <= '1';
				state_x <= ST_REFRESH;
			end if;

		when ST_REFRESH =>
			if done_sb_o = '0' then
            refresh_req_s <= '1';
         else
				state_x <= ST_IDLE;
			end if;

		when ST_IDLE =>
			state_x <= ST_IDLE;

		end case;

   end process;

   -- Stimulus process
   stim_proc: process
   begin
		reset_n_i <= '0';
      wait for 20 ns;
		reset_n_i <= '1';
		wait;
	end process;

end;
