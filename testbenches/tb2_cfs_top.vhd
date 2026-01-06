library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cfs_pkg.all;

entity tb2_cfs_top is
end entity;

architecture sim of tb2_cfs_top is

  -- DUT ports as signals
  signal clk_tb        : std_logic := '0';
  signal rstn_tb       : std_logic := '0';
  signal addr_tb       : std_logic_vector(7 downto 0) := (others => '0');
  signal wdata_tb      : std_logic_vector(31 downto 0) := (others => '0');
  signal rdata_tb      : std_logic_vector(31 downto 0);
  signal we_tb         : std_logic := '0';
  signal re_tb         : std_logic := '0';
  signal irq_tb        : std_logic;

  signal a_addr_tb     : u32;
  signal a_re_tb       : std_logic;
  signal a_rdata_tb    : s16 := (others => '0');

  signal b_addr_tb     : u32;
  signal b_re_tb       : std_logic;
  signal b_rdata_tb    : s16 := (others => '0');

  signal c_addr_tb     : u32;
  signal c_we_tb       : std_logic;
  signal c_wdata_tb    : s32;

  -- Count observed C writes 
  signal c_write_count : integer := 0;

  constant M_TB : integer := 8;
  constant K_TB : integer := 4;
  constant N_TB : integer := 8;

  constant A_ELEMS : integer := M_TB * K_TB; -- 32
  constant B_ELEMS : integer := K_TB * N_TB; -- 32
  constant C_ELEMS : integer := M_TB * N_TB; -- 64

  -- Simulated BRAMs 
  type s16_array is array (0 to LOCAL_BRAM_SIZE-1) of s16;
  type s32_array is array (0 to LOCAL_BRAM_SIZE-1) of s32;
  signal a_bram_sim : s16_array := (others => (others => '0'));
  signal b_bram_sim : s16_array := (others => (others => '0'));
  signal c_bram_sim : s32_array := (others => (others => '0'));

  -- Local 64 element expected array
  type s32_array_64 is array (0 to 63) of s32;

  
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
  -- Simulated Local Memory (A/B reads)
  --------------------------------
  a_mem_proc : process(clk_tb)
    variable idx_v : integer;
  begin
    if rising_edge(clk_tb) then
      if a_re_tb = '1' then

        assert not has_unknown(std_logic_vector(a_addr_tb))
          report "TB ERROR: A read with UNKNOWN address bits"
          severity failure;

        idx_v := to_integer(a_addr_tb);

        assert (idx_v >= 0) and (idx_v < LOCAL_BRAM_SIZE)
          report "TB ERROR: A read address OUT OF RANGE. idx=" & integer'image(idx_v)
          severity failure;

        a_rdata_tb <= a_bram_sim(idx_v);
      end if;
    end if;
  end process;

  b_mem_proc : process(clk_tb)
    variable idx_v : integer;
  begin
    if rising_edge(clk_tb) then
      if b_re_tb = '1' then

        assert not has_unknown(std_logic_vector(b_addr_tb))
          report "TB ERROR: B read with UNKNOWN address bits"
          severity failure;

        idx_v := to_integer(b_addr_tb);

        assert (idx_v >= 0) and (idx_v < LOCAL_BRAM_SIZE)
          report "TB ERROR: B read address OUT OF RANGE. idx=" & integer'image(idx_v)
          severity failure;

        b_rdata_tb <= b_bram_sim(idx_v);
      end if;
    end if;
  end process;

  --------------------------------
  -- Simulated Local Memory (C writes)
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

      else
        if c_we_tb = '1' then

          assert not has_unknown(std_logic_vector(c_addr_tb))
            report "TB ERROR: C write with UNKNOWN address bits"
            severity failure;

          idx_v := to_integer(c_addr_tb);

          assert (idx_v >= 0) and (idx_v < LOCAL_BRAM_SIZE)
            report "TB ERROR: C write address OUT OF RANGE. idx=" & integer'image(idx_v)
            severity failure;

          c_bram_sim(idx_v) <= c_wdata_tb;
          c_write_count <= c_write_count + 1;

        end if;
      end if;
    end if;
  end process;

  --------------------------------
  -- Stimulus and Test Logic
  --------------------------------
  stim_proc : process
    variable expected_c64 : s32_array_64;
    variable idx          : integer;
    variable got_i        : integer;
    variable exp_i        : integer;
  begin
    wait until rstn_tb = '1';

    -- clear A/B only 
    for i in 0 to (A_ELEMS-1) loop
      a_bram_sim(i) <= (others => '0');
    end loop;

    for i in 0 to (B_ELEMS-1) loop
      b_bram_sim(i) <= (others => '0');
    end loop;

    -- filling A BRAM directly
    for row in 0 to (M_TB-1) loop
      for k in 0 to (K_TB-1) loop
        if row < 4 then
          a_bram_sim(row*K_TB + k) <= to_signed(1, 16);
        else
          a_bram_sim(row*K_TB + k) <= to_signed(2, 16);
        end if;
      end loop;
    end loop;

    -- filling B BRAM directly
    for k in 0 to (K_TB-1) loop
      for col in 0 to (N_TB-1) loop
        if col = k then
          b_bram_sim(k*N_TB + col) <= to_signed(1, 16);
        else
          b_bram_sim(k*N_TB + col) <= to_signed(0, 16);
        end if;
      end loop;
    end loop;

    wait until rising_edge(clk_tb);

    -- Write registers
    addr_tb <= x"08"; wdata_tb <= x"00000000"; we_tb <= '1'; re_tb <= '0'; wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb <= x"0C"; wdata_tb <= x"00000000"; we_tb <= '1';              wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb <= x"10"; wdata_tb <= x"00000000"; we_tb <= '1';              wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb <= x"14"; wdata_tb <= x"00000008"; we_tb <= '1';              wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb <= x"18"; wdata_tb <= x"00000004"; we_tb <= '1';              wait until rising_edge(clk_tb); we_tb <= '0';
    addr_tb <= x"1C"; wdata_tb <= x"00000008"; we_tb <= '1';              wait until rising_edge(clk_tb); we_tb <= '0';

    wait until rising_edge(clk_tb);

    -- Start
    addr_tb <= x"00"; wdata_tb <= x"00000001"; we_tb <= '1';
    wait until rising_edge(clk_tb);
    we_tb <= '0';

    -- Wait for done
    wait until irq_tb = '1';
    wait until rising_edge(clk_tb);

    assert c_write_count > 0
      report "ERROR: No C memory writes occurred during computation"
      severity failure;

    wait until rising_edge(clk_tb);

    -- Check output
    for row in 0 to (M_TB-1) loop
      for col in 0 to (N_TB-1) loop

        -- expected values
        if col < 4 then
          if row < 4 then
            expected_c64(row*N_TB + col) := to_signed(1, 32);
          else
            expected_c64(row*N_TB + col) := to_signed(2, 32);
          end if;
        else
          expected_c64(row*N_TB + col) := to_signed(0, 32);
        end if;

        idx := row*N_TB + col;

        
        assert not has_unknown(std_logic_vector(c_bram_sim(idx)))
          report "TB ERROR: C BRAM read is UNKNOWN at idx="
                 & integer'image(idx) & " (row=" & integer'image(row)
                 & ", col=" & integer'image(col) & ")"
          severity failure;

        got_i := to_integer(signed(c_bram_sim(idx)));
        exp_i := to_integer(signed(expected_c64(idx)));

        assert c_bram_sim(idx) = expected_c64(idx)
          report "Mismatch at C[" & integer'image(row) & "][" & integer'image(col) & "]: got "
                 & integer'image(got_i) & ", expected "
                 & integer'image(exp_i)
          severity error;

      end loop;
    end loop;

    report "Test passed" severity note;
    wait for 1000 ns;
    assert false report "Simulation ended cleanly." severity failure;
  end process;

end architecture sim;
