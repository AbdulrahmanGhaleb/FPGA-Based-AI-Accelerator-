library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cfs_pkg.all;

entity tb_cfs_top is
end entity;

architecture sim of tb_cfs_top is

  -- DUT ports as signals
  signal clk_tb        : std_logic := '0';
  signal rstn_tb       : std_logic := '0';
  signal addr_tb       : std_logic_vector(7 downto 0);
  signal wdata_tb      : std_logic_vector(31 downto 0);
  signal rdata_tb      : std_logic_vector(31 downto 0);
  signal we_tb         : std_logic;
  signal re_tb         : std_logic;
  signal irq_tb        : std_logic;
  signal a_addr_tb     : u32;
  signal a_re_tb       : std_logic;
  signal a_rdata_tb    : s16;
  signal b_addr_tb     : u32;
  signal b_re_tb       : std_logic;
  signal b_rdata_tb    : s16;
  signal c_addr_tb     : u32;
  signal c_we_tb       : std_logic;
  signal c_wdata_tb    : s32;
  signal c_write_seen : std_logic := '0';


  -- Simulated BRAMs
  type s16_array is array (0 to LOCAL_BRAM_SIZE-1) of s16;
  type s32_array is array (0 to LOCAL_BRAM_SIZE-1) of s32;
  signal a_bram_sim : s16_array := (others => (others => '0'));
  signal b_bram_sim : s16_array := (others => (others => '0'));
  signal c_bram_sim : s32_array := (others => (others => '0'));

  -- Local 4x4-only types (to avoid illegal index constraint on s16_array)
  type s16_array_16 is array (0 to 15) of s16;
  type s32_array_16 is array (0 to 15) of s32;

begin

  --------------------------------
  -- Clock and Reset Generation
  --------------------------------
  clock_gen : process
  begin
    while true loop
      clk_tb <= '0'; wait for 5 ns;
      clk_tb <= '1'; wait for 5 ns;
    end loop;
  end process;

  reset_proc : process
  begin
    rstn_tb <= '0';
    wait for 20 ns;
    rstn_tb <= '1';
    wait;
  end process;

  --------------------------------
  -- Instantiate DUT
  --------------------------------
  dut_inst : entity work.cfs_top
    port map (
      clk_i            => clk_tb,
      rstn_i           => rstn_tb,
      addr_i           => addr_tb,
      wdata_i          => wdata_tb,
      rdata_o          => rdata_tb,
      we_i             => we_tb,
      re_i             => re_tb,
      irq_o            => irq_tb,
      a_mem_addr_o     => a_addr_tb,
      a_mem_re_o       => a_re_tb,
      a_mem_rdata_i    => a_rdata_tb,
      b_mem_addr_o     => b_addr_tb,
      b_mem_re_o       => b_re_tb,
      b_mem_rdata_i    => b_rdata_tb,
      c_mem_addr_o     => c_addr_tb,
      c_mem_we_o       => c_we_tb,
      c_mem_wdata_o    => c_wdata_tb
    );

  --------------------------------
  -- Simulated Local Memory
  --------------------------------
  a_mem_proc : process(clk_tb)
  begin
    if rising_edge(clk_tb) then
      if a_re_tb = '1' then
        a_rdata_tb <= a_bram_sim(to_integer(a_addr_tb));
      end if;
    end if;
  end process;

  b_mem_proc : process(clk_tb)
  begin
    if rising_edge(clk_tb) then
      if b_re_tb = '1' then
        b_rdata_tb <= b_bram_sim(to_integer(b_addr_tb));
      end if;
    end if;
  end process;

  c_mem_proc : process(clk_tb)
  begin
    if rising_edge(clk_tb) then
      if c_we_tb = '1' then
        c_bram_sim(to_integer(c_addr_tb)) <= c_wdata_tb;
		  c_write_seen <= '1';
      end if;
    end if;
  end process;

  --------------------------------
  -- Stimulus and Test Logic
  --------------------------------
  stim_proc : process
    variable a_tile : s16_array_16;
    variable b_tile : s16_array_16;
    variable expected_c : s32_array_16;
  begin
    wait until rstn_tb = '1';

    -- Initialize tiles
    for i in 0 to 15 loop
      a_tile(i) := to_signed(1, 16);
      if (i mod 5 = 0) then
        b_tile(i) := to_signed(1, 16); -- Identity matrix
      else
        b_tile(i) := to_signed(0, 16);
      end if;
      expected_c(i) := to_signed(1, 32);
    end loop;

    -- Write A
    for i in 0 to 15 loop
      a_bram_sim(i) <= a_tile(i);
    end loop;

    -- Write B
    for i in 0 to 15 loop
      b_bram_sim(i) <= b_tile(i);
    end loop;

    -- Write registers
    addr_tb   <= x"08"; wdata_tb <= x"00000000"; we_tb <= '1'; re_tb <= '0'; wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb   <= x"0C"; wdata_tb <= x"00000000"; we_tb <= '1'; wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb   <= x"10"; wdata_tb <= x"00000000"; we_tb <= '1'; wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb   <= x"14"; wdata_tb <= x"00000004"; we_tb <= '1'; wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb   <= x"18"; wdata_tb <= x"00000004"; we_tb <= '1'; wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb   <= x"1C"; wdata_tb <= x"00000004"; we_tb <= '1'; wait until rising_edge(clk_tb); we_tb <= '0';

    -- Start
    addr_tb   <= x"00"; wdata_tb <= x"00000001"; we_tb <= '1'; wait until rising_edge(clk_tb); we_tb <= '0';

    -- Wait for done
    wait until irq_tb = '1';
	 assert c_write_seen = '1'
	  report "ERROR: No C memory writes occurred during computation"
	  severity failure;

    -- Check output
    for i in 0 to 15 loop
      assert c_bram_sim(i) = expected_c(i)
        report "Mismatch at C[" & integer'image(i) & "]" severity error;
    end loop;

    report "Test passed" severity note;
    wait for 1000 ns;
    assert false report "Simulation ended cleanly." severity failure;
  end process;

end architecture sim;
