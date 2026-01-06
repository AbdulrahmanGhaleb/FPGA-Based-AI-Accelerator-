library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cfs_pkg.all;

entity tb3_cfs_top is
end entity;

architecture sim of tb3_cfs_top is

  -- DUT ports
  signal clk_tb   : std_logic := '0';
  signal rstn_tb  : std_logic := '0';
  signal addr_tb  : std_logic_vector(7 downto 0) := (others => '0');
  signal wdata_tb : std_logic_vector(31 downto 0) := (others => '0');
  signal rdata_tb : std_logic_vector(31 downto 0);
  signal we_tb    : std_logic := '0';
  signal re_tb    : std_logic := '0';
  signal irq_tb   : std_logic;

  signal a_addr_tb  : u32;
  signal a_re_tb    : std_logic;
  signal a_rdata_tb : s16 := (others => '0');

  signal b_addr_tb  : u32;
  signal b_re_tb    : std_logic;
  signal b_rdata_tb : s16 := (others => '0');

  signal c_addr_tb  : u32;
  signal c_we_tb    : std_logic;
  signal c_wdata_tb : s32;

  signal c_write_count : integer := 0;

  constant M_TB : integer := 4;
  constant K_TB : integer := 8;
  constant N_TB : integer := 4;

  constant A_ELEMS : integer := M_TB * K_TB; -- 32
  constant B_ELEMS : integer := K_TB * N_TB; -- 32
  constant C_ELEMS : integer := M_TB * N_TB; -- 16

  type s16_array is array (0 to LOCAL_BRAM_SIZE-1) of s16;
  type s32_array is array (0 to LOCAL_BRAM_SIZE-1) of s32;

  signal a_bram_sim : s16_array := (others => (others => '0'));
  signal b_bram_sim : s16_array := (others => (others => '0'));
  signal c_bram_sim : s32_array := (others => (others => '0'));

  type s32_array_16 is array (0 to 15) of s32;

  function has_unknown(slv : std_logic_vector) return boolean is
  begin
    for i in slv'range loop
      if not (slv(i) = '0' or slv(i) = '1') then
        return true;
      end if;
    end loop;
    return false;
  end function;

begin

  --------------------------------
  -- Clock
  --------------------------------
  clock_gen : process
  begin
    while true loop
      clk_tb <= '0'; wait for 5 ns;
      clk_tb <= '1'; wait for 5 ns;
    end loop;
  end process;

  --------------------------------
  -- Reset
  --------------------------------
  reset_proc : process
  begin
    rstn_tb <= '0';
    wait for 20 ns;
    rstn_tb <= '1';
    wait;
  end process;

  --------------------------------
  -- DUT
  --------------------------------
  dut_inst : entity work.cfs_top
    port map (
      clk_i         => clk_tb,
      rstn_i        => rstn_tb,
      addr_i        => addr_tb,
      wdata_i       => wdata_tb,
      rdata_o       => rdata_tb,
      we_i          => we_tb,
      re_i          => re_tb,
      irq_o         => irq_tb,
      a_mem_addr_o  => a_addr_tb,
      a_mem_re_o    => a_re_tb,
      a_mem_rdata_i => a_rdata_tb,
      b_mem_addr_o  => b_addr_tb,
      b_mem_re_o    => b_re_tb,
      b_mem_rdata_i => b_rdata_tb,
      c_mem_addr_o  => c_addr_tb,
      c_mem_we_o    => c_we_tb,
      c_mem_wdata_o => c_wdata_tb
    );

  --------------------------------
  -- A memory
  --------------------------------
  a_mem_proc : process(clk_tb)
    variable idx_v : integer;
  begin
    if rising_edge(clk_tb) then
      if a_re_tb = '1' then
        idx_v := to_integer(a_addr_tb);
        a_rdata_tb <= a_bram_sim(idx_v);
      end if;
    end if;
  end process;

  --------------------------------
  -- B memory
  --------------------------------
  b_mem_proc : process(clk_tb)
    variable idx_v : integer;
  begin
    if rising_edge(clk_tb) then
      if b_re_tb = '1' then
        idx_v := to_integer(b_addr_tb);
        b_rdata_tb <= b_bram_sim(idx_v);
      end if;
    end if;
  end process;

  --------------------------------
  -- C memory
  --------------------------------
  c_mem_proc : process(clk_tb)
    variable idx_v : integer;
  begin
    if rising_edge(clk_tb) then
      if rstn_tb = '0' then
        for i in 0 to LOCAL_BRAM_SIZE-1 loop
          c_bram_sim(i) <= (others => '0');
        end loop;
        c_write_count <= 0;
      elsif c_we_tb = '1' then
        idx_v := to_integer(c_addr_tb);
        c_bram_sim(idx_v) <= c_wdata_tb;
        c_write_count <= c_write_count + 1;
      end if;
    end if;
  end process;

  --------------------------------
  -- Stimulus
  --------------------------------
  stim_proc : process
    variable expected_c16 : s32_array_16;
    variable idx  : integer;
    variable got  : integer;
    variable exp  : integer;
  begin
    wait until rstn_tb = '1';

    -- A = all ones (4x8)
    for row in 0 to M_TB-1 loop
      for k in 0 to K_TB-1 loop
        a_bram_sim(row*K_TB + k) <= to_signed(1, 16);
      end loop;
    end loop;

    -- B = two stacked I4 tiles
    for k in 0 to K_TB-1 loop
      for col in 0 to N_TB-1 loop
        if col = (k mod 4) then
          b_bram_sim(k*N_TB + col) <= to_signed(1, 16);
        else
          b_bram_sim(k*N_TB + col) <= to_signed(0, 16);
        end if;
      end loop;
    end loop;

    wait until rising_edge(clk_tb);

    -- Registers
    addr_tb <= x"08"; wdata_tb <= x"00000000"; we_tb <= '1'; wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb <= x"0C"; wdata_tb <= x"00000000"; we_tb <= '1'; wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb <= x"10"; wdata_tb <= x"00000000"; we_tb <= '1'; wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb <= x"14"; wdata_tb <= x"00000004"; we_tb <= '1'; wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb <= x"18"; wdata_tb <= x"00000008"; we_tb <= '1'; wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb <= x"1C"; wdata_tb <= x"00000004"; we_tb <= '1'; wait until rising_edge(clk_tb); we_tb <= '0';

    wait until rising_edge(clk_tb);

    -- Start
    addr_tb <= x"00"; wdata_tb <= x"00000001"; we_tb <= '1';
    wait until rising_edge(clk_tb);
    we_tb <= '0';

    wait until irq_tb = '1';
    wait until rising_edge(clk_tb);

    -- Expected = 2 everywhere
    for i in 0 to 15 loop
      expected_c16(i) := to_signed(2, 32);
    end loop;

    -- Check
    for row in 0 to M_TB-1 loop
      for col in 0 to N_TB-1 loop
        idx := row*N_TB + col;
        got := to_integer(signed(c_bram_sim(idx)));
        exp := to_integer(signed(expected_c16(idx)));

        assert c_bram_sim(idx) = expected_c16(idx)
          report "Mismatch at C(" & integer'image(row) & "," & integer'image(col)
                 & ") got=" & integer'image(got)
                 & " exp=" & integer'image(exp)
          severity error;
      end loop;
    end loop;

    report "TB3 PASSED: multi-K accumulation verified" severity note;
    wait for 1000 ns;
    assert false report "Simulation ended cleanly." severity failure;
  end process;

end architecture sim;
