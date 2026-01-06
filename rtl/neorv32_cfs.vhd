-- ================================================================================ --
-- NEORV32 SoC - Custom Functions Subsystem (CFS)                                   --
--                                                                                 --
-- This version integrates a tiled 4x4 matrix-multiply accelerator via cfs_top.    --
-- ================================================================================ --

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;

library work;
use work.cfs_pkg.all;  -- for s16, s32, u32, LOCAL_BRAM_SIZE

entity neorv32_cfs is
  port (
    -- global control --
    clk_i     : in  std_ulogic; -- global clock line
    rstn_i    : in  std_ulogic; -- global reset line, low-active, async
    -- CPU access --
    bus_req_i : in  bus_req_t;  -- bus request
    bus_rsp_o : out bus_rsp_t;  -- bus response
    -- CPU interrupt --
    irq_o     : out std_ulogic; -- interrupt request
    -- external IO --
    cfs_in_i  : in  std_ulogic_vector(255 downto 0); -- custom inputs conduit (unused)
    cfs_out_o : out std_ulogic_vector(255 downto 0)  -- custom outputs conduit (unused)
  );
end neorv32_cfs;

architecture neorv32_cfs_rtl of neorv32_cfs is
  constant A_WIN_BASE       : integer := 16#1000#;
  constant B_WIN_BASE       : integer := 16#2000#;
  constant C_WIN_BASE       : integer := 16#3000#;
  constant BRAM_WINDOW_BYTES: integer := LOCAL_BRAM_SIZE * 4; -- each element is exposed as a 32-bit slot

  ------------------------------------------------------------------------------
  -- Signals between NEORV32 bus and cfs_top
  ------------------------------------------------------------------------------
  signal cfs_addr_s  : std_logic_vector(7 downto 0);
  signal cfs_wdata_s : std_logic_vector(31 downto 0);
  signal cfs_rdata_s : std_logic_vector(31 downto 0);
  signal cfs_we_s    : std_logic;
  signal cfs_re_s    : std_logic;
  signal cfs_irq_s   : std_logic;

  ------------------------------------------------------------------------------
  -- Local BRAMs for A, B, C matrices (inside CFS)
  -- Depth = LOCAL_BRAM_SIZE (e.g. 16x16 = 256 elements)
  ------------------------------------------------------------------------------
  type a_bram_t is array (0 to LOCAL_BRAM_SIZE-1) of s16;
  type b_bram_t is array (0 to LOCAL_BRAM_SIZE-1) of s16;
  type c_bram_t is array (0 to LOCAL_BRAM_SIZE-1) of s32;

  signal a_bram : a_bram_t;
  signal b_bram : b_bram_t;
  signal c_bram : c_bram_t;

  -- Ports between cfs_top and BRAMs
  -- used during load A
  signal a_mem_addr_s  : u32;
  signal a_mem_re_s    : std_logic;
  signal a_mem_rdata_s : s16;
 
-- used during load B
  signal b_mem_addr_s  : u32;
  signal b_mem_re_s    : std_logic;
  signal b_mem_rdata_s : s16;

--used during write back
  signal c_mem_addr_s  : u32;
  signal c_mem_we_s    : std_logic;
  signal c_mem_wdata_s : s32;

  -- CPU-side BRAM write strobes (for preloading / inspection)
  signal cpu_a_we_s    : std_logic := '0';
  signal cpu_a_addr_s  : integer range 0 to LOCAL_BRAM_SIZE-1 := 0;
  signal cpu_a_wdata_s : s16 := (others => '0');

  signal cpu_b_we_s    : std_logic := '0';
  signal cpu_b_addr_s  : integer range 0 to LOCAL_BRAM_SIZE-1 := 0;
  signal cpu_b_wdata_s : s16 := (others => '0');

  signal cpu_c_we_s    : std_logic := '0';
  signal cpu_c_addr_s  : integer range 0 to LOCAL_BRAM_SIZE-1 := 0;
  signal cpu_c_wdata_s : s32 := (others => '0');

  -- Register read pipeline flag (register block reads require an extra cycle to return valid data)
  signal reg_read_inflight_s : std_logic := '0';

begin

  ------------------------------------------------------------------------------
  -- CFS external IOs (not used in this accelerator)
  ------------------------------------------------------------------------------
  cfs_out_o <= (others => '0');
  -- cfs_in_i is unused

  ------------------------------------------------------------------------------
  -- Instantiate your accelerator top-level: cfs_top
  ------------------------------------------------------------------------------
  cfs_top_inst : entity work.cfs_top
    port map (
      clk_i  => std_logic(clk_i),
      rstn_i => std_logic(rstn_i),

      -- CPU / register interface
      addr_i  => cfs_addr_s,
      wdata_i => cfs_wdata_s,
      rdata_o => cfs_rdata_s,
      we_i    => cfs_we_s,
      re_i    => cfs_re_s,
      irq_o   => cfs_irq_s,

      -- Local A / B / C memories
      a_mem_addr_o  => a_mem_addr_s,
      a_mem_re_o    => a_mem_re_s,
      a_mem_rdata_i => a_mem_rdata_s,

      b_mem_addr_o  => b_mem_addr_s,
      b_mem_re_o    => b_mem_re_s,
      b_mem_rdata_i => b_mem_rdata_s,

      c_mem_addr_o  => c_mem_addr_s,
      c_mem_we_o    => c_mem_we_s,
      c_mem_wdata_o => c_mem_wdata_s
    );

  ------------------------------------------------------------------------------
  -- Connect accelerator IRQ to CPU
  ------------------------------------------------------------------------------
  irq_o <= std_ulogic(cfs_irq_s);

  ------------------------------------------------------------------------------
  -- Local BRAM implementation for A, B, C
  -- Simple synchronous memories with:
  --  - 1-cycle read latency for A and B (gated by *_mem_re_s)
  --  - write-only interface for C (gated by c_mem_we_s)
  ------------------------------------------------------------------------------
  bram_proc : process(clk_i, rstn_i)
    variable a_idx, b_idx, c_idx : integer;
  begin
    if rstn_i = '0' then
      a_mem_rdata_s <= (others => '0');
      b_mem_rdata_s <= (others => '0');
      -- c_bram contents left undefined or zero-initialized as you prefer
    elsif rising_edge(clk_i) then
      -- A memory read
      if a_mem_re_s = '1' then
        a_idx := to_integer(a_mem_addr_s);
        if (a_idx >= 0) and (a_idx < LOCAL_BRAM_SIZE) then
          a_mem_rdata_s <= a_bram(a_idx);
        else
          a_mem_rdata_s <= (others => '0');
        end if;
      end if;

      -- B memory read
      if b_mem_re_s = '1' then
        b_idx := to_integer(b_mem_addr_s);
        if (b_idx >= 0) and (b_idx < LOCAL_BRAM_SIZE) then
          b_mem_rdata_s <= b_bram(b_idx);
        else
          b_mem_rdata_s <= (others => '0');
        end if;
      end if;

      -- CPU preload writes into A/B (used before START)
      if cpu_a_we_s = '1' then
        a_bram(cpu_a_addr_s) <= cpu_a_wdata_s;
      end if;
      if cpu_b_we_s = '1' then
        b_bram(cpu_b_addr_s) <= cpu_b_wdata_s;
      end if;

      -- C memory write
      if c_mem_we_s = '1' then
        c_idx := to_integer(c_mem_addr_s);
        if (c_idx >= 0) and (c_idx < LOCAL_BRAM_SIZE) then
          c_bram(c_idx) <= c_mem_wdata_s;
        end if;
      elsif cpu_c_we_s = '1' then
        c_bram(cpu_c_addr_s) <= cpu_c_wdata_s;
      end if;
    end if;
  end process bram_proc;

  ------------------------------------------------------------------------------
  -- Bus Read/Write Access: connect NEORV32 bus to cfs_top's register interface
  --
  -- - CFS address space is 64kB (16-bit byte address)
  -- - We only use the lowest 8 bits as local byte offset into our register map:
  --       0x00 CONTROL, 0x04 STATUS, 0x08 A_ADDR, 0x0C B_ADDR,
  --       0x10 C_ADDR, 0x14 DIM_M, 0x18 DIM_K, 0x1C DIM_N
  -- - Only full-word writes (ben = "1111") are forwarded.
  -- - All accesses are acknowledged in the next cycle.
  ------------------------------------------------------------------------------
  bus_access : process(rstn_i, clk_i)
    variable addr_int  : integer;
    variable elem_idx  : integer;
  begin
    if (rstn_i = '0') then
      -- reset bus response and CFS control signals
      bus_rsp_o       <= rsp_terminate_c;
      cfs_addr_s      <= (others => '0');
      cfs_wdata_s     <= (others => '0');
      cfs_we_s        <= '0';
      cfs_re_s        <= '0';
      cpu_a_we_s      <= '0';
      cpu_b_we_s      <= '0';
      cpu_c_we_s      <= '0';
      reg_read_inflight_s <= '0';
    elsif rising_edge(clk_i) then
      -- default outputs
      bus_rsp_o.ack  <= bus_req_i.stb; -- acknowledge one cycle later
      bus_rsp_o.err  <= '0';
      bus_rsp_o.data <= (others => '0');

      -- default: no register access unless we see STB
      cfs_we_s <= '0';
      cfs_re_s <= '0';
      cpu_a_we_s <= '0';
      cpu_b_we_s <= '0';
      cpu_c_we_s <= '0';

      -- complete pending register-block read (data becomes valid one cycle after asserting cfs_re_s)
      if reg_read_inflight_s = '1' then
        bus_rsp_o.ack  <= '1';
        bus_rsp_o.data <= std_ulogic_vector(cfs_rdata_s);
        reg_read_inflight_s <= '0';
      end if;

      if (bus_req_i.stb = '1') then  -- valid access
        -- use lower 16 bits as byte offset within CFS window
        addr_int := to_integer(unsigned(bus_req_i.addr(15 downto 0)));

        -- Register block (0x00..0xFF)
        if addr_int < 16#0100# then
          cfs_addr_s  <= std_logic_vector(bus_req_i.addr(7 downto 0));
          cfs_wdata_s <= std_logic_vector(bus_req_i.data);

          if (bus_req_i.rw = '1') then
            if (bus_req_i.ben = "1111") then
              cfs_we_s <= '1';
            end if;
          else
            cfs_re_s <= '1';
            -- stall ACK for one extra cycle so cfs_rdata_s can become valid
            bus_rsp_o.ack <= '0';
            reg_read_inflight_s <= '1';
          end if;

        -- A window: 0x1000 .. 0x1000 + BRAM_WINDOW_BYTES
        elsif (addr_int >= A_WIN_BASE) and (addr_int < A_WIN_BASE + BRAM_WINDOW_BYTES) then
          elem_idx := (addr_int - A_WIN_BASE) / 4;
          if (elem_idx >= 0) and (elem_idx < LOCAL_BRAM_SIZE) then
            if bus_req_i.rw = '1' then
              if (bus_req_i.ben = "1111") then
                cpu_a_we_s    <= '1';
                cpu_a_addr_s  <= elem_idx;
                cpu_a_wdata_s <= signed(bus_req_i.data(15 downto 0));
              else
                bus_rsp_o.err <= '1';
              end if;
            else
              bus_rsp_o.data <= std_ulogic_vector(std_logic_vector(resize(a_bram(elem_idx), bus_rsp_o.data'length)));
            end if;
          else
            bus_rsp_o.err <= '1';
          end if;

        -- B window: 0x2000 .. 0x2000 + BRAM_WINDOW_BYTES
        elsif (addr_int >= B_WIN_BASE) and (addr_int < B_WIN_BASE + BRAM_WINDOW_BYTES) then
          elem_idx := (addr_int - B_WIN_BASE) / 4;
          if (elem_idx >= 0) and (elem_idx < LOCAL_BRAM_SIZE) then
            if bus_req_i.rw = '1' then
              if (bus_req_i.ben = "1111") then
                cpu_b_we_s    <= '1';
                cpu_b_addr_s  <= elem_idx;
                cpu_b_wdata_s <= signed(bus_req_i.data(15 downto 0));
              else
                bus_rsp_o.err <= '1';
              end if;
            else
              bus_rsp_o.data <= std_ulogic_vector(std_logic_vector(resize(b_bram(elem_idx), bus_rsp_o.data'length)));
            end if;
          else
            bus_rsp_o.err <= '1';
          end if;

        -- C window: 0x3000 .. 0x3000 + BRAM_WINDOW_BYTES
        elsif (addr_int >= C_WIN_BASE) and (addr_int < C_WIN_BASE + BRAM_WINDOW_BYTES) then
          elem_idx := (addr_int - C_WIN_BASE) / 4;
          if (elem_idx >= 0) and (elem_idx < LOCAL_BRAM_SIZE) then
            if bus_req_i.rw = '1' then
              if (bus_req_i.ben = "1111") then
                cpu_c_we_s    <= '1';
                cpu_c_addr_s  <= elem_idx;
                cpu_c_wdata_s <= signed(bus_req_i.data);
              else
                bus_rsp_o.err <= '1';
              end if;
            else
              bus_rsp_o.data <= std_ulogic_vector(std_logic_vector(c_bram(elem_idx)));
            end if;
          else
            bus_rsp_o.err <= '1';
          end if;

        else
          -- Unknown offset inside CFS space
          bus_rsp_o.err <= '1';
        end if;
      end if;
    end if;
  end process bus_access;

end neorv32_cfs_rtl;
