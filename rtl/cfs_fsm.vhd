library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cfs_pkg.all;

entity cfs_fsm is 
    port(
        -- Clock and Resetclock and restest
        clk_i : in std_logic;
        rstn_i : in std_logic;

        --FROM CFS_REGS
        start_i : in std_logic;
        dim_m_i : in u32;
        dim_k_i : in u32;
        dim_n_i : in u32;
        addr_a_base_i : in u32;
        addr_b_base_i : in u32;
        addr_c_base_i : in u32;

        --STATUS BACK TO CFS_REGS
        busy_o : out std_logic;
        done_o : out std_logic;

        --TO CFS_MEMORY_IF
        mem_start_o        : out std_logic;
        mem_op_o           : out std_logic_vector(1 downto 0); -- 01: load A, 10: load B, 11: store C
        mem_tile_row_o     : out u32;
        mem_tile_col_o     : out u32;
        mem_tile_k_o       : out u32;
        mem_dim_m_o        : out u32;
        mem_dim_k_o        : out u32;
        mem_dim_n_o        : out u32;
        mem_base_addr_a_o  : out u32;
        mem_base_addr_b_o  : out u32;
        mem_base_addr_c_o  : out u32;
        mem_busy_i         : in std_logic;
        mem_done_i         : in std_logic;

        --TO TILE BUFFER
        clear_acc_o : out std_logic;
        we_c_acc_o : out std_logic_vector(15 downto 0);
        c_acc_data_o : out s32;

        --FROM TILE BUFFER AND MM4X4 RESULT
        c_acc_tile_i : in tile4x4_int32;
        mm_c_tile_i : in tile4x4_int32       
    );
end entity cfs_fsm;

architecture rtl of cfs_fsm is 
    ---------------------------------
    --INTERNAL REGISTERS AND SIGNALS
    ---------------------------------
    signal state: fsm_states := IDLE;

    --LATCHED CONFIGURATION (DIM AND BASE ADDRS)
    signal dim_m_reg : u32 := (others => '0');
    signal dim_k_reg : u32 := (others => '0');
    signal dim_n_reg : u32 := (others => '0');

    signal addr_a_base_reg : u32 := (others => '0');
    signal addr_b_base_reg : u32 := (others => '0');
    signal addr_c_base_reg : u32 := (others => '0');

    --TILE COUNTERS
    signal tile_row : integer range 0 to MAX_DIM-1 := 0;
    signal tile_col : integer range 0 to MAX_DIM-1 := 0;
    signal tile_k : integer range 0 to MAX_DIM-1 := 0;
    
    --NUMBER OF TILES ALONG EACH DIMENSION
    signal m_tiles : integer range 0 to MAX_DIM/TILE_SIZE :=0;
    signal n_tiles : integer range 0 to MAX_DIM/TILE_SIZE :=0;
    signal k_tiles : integer range 0 to MAX_DIM/TILE_SIZE :=0;

    --ACCUMULATION INDEX INSIDE 4X4 TILE
    signal acc_idx : integer range 0 to 15 := 0;
    
    --STATUS
    signal busy_reg : std_logic := '0';
    signal done_reg : std_logic := '0';

    ---MEMORY INTERFACE CONTROL
    signal mem_start_reg : std_logic := '0';
    signal mem_op_reg : std_logic_vector(1 downto 0) := (others => '0');
    signal mem_req_active : std_logic := '0';

    --TILE BUFFER ACCUMULATOR CONTROL
    signal clear_acc_reg : std_logic := '0';
    signal we_c_acc_reg : std_logic_vector(15 downto 0) := (others => '0');
    signal c_acc_data_reg : s32 := (others => '0');
begin
    -----------------
    --OUTPUT MAPPINGS
    -----------------
    busy_o <= busy_reg;
    done_o <= done_reg;

    mem_start_o <= mem_start_reg;
    mem_op_o    <= mem_op_reg;

    mem_dim_m_o <= dim_m_reg;
    mem_dim_k_o <= dim_k_reg;
    mem_dim_n_o <= dim_n_reg;

    mem_base_addr_a_o <= addr_a_base_reg;
    mem_base_addr_b_o <= addr_b_base_reg;
    mem_base_addr_c_o <= addr_c_base_reg;

    -- Convert tile indices (integer) to u32
    mem_tile_row_o <= to_unsigned(tile_row, mem_tile_row_o'length);
    mem_tile_col_o <= to_unsigned(tile_col, mem_tile_col_o'length);
    mem_tile_k_o   <= to_unsigned(tile_k,   mem_tile_k_o'length);

    clear_acc_o  <= clear_acc_reg;
    we_c_acc_o   <= we_c_acc_reg;
    c_acc_data_o <= c_acc_data_reg;

    -----------
    --MAIN FSM
    -----------
    process(clk_i, rstn_i)
        variable m_int, k_int, n_int : integer;
        variable r,c : integer;
        variable sum : s32;
    begin
        if rstn_i = '0' then 

            ----------------
            -- ASYNC RESET
            ----------------
            state <= IDLE;
            dim_m_reg <= (others => '0');
            dim_k_reg <= (others => '0');
            dim_n_reg <= (others => '0');
            addr_a_base_reg <= (others => '0');
            addr_b_base_reg <= (others => '0');
            addr_c_base_reg <= (others => '0');

            tile_row <= 0;
            tile_col <= 0;
            tile_k <= 0;
            m_tiles <=0;
            n_tiles <=0;
            k_tiles <=0;
            acc_idx <= 0;

            busy_reg <= '0';
            done_reg <= '0';
            mem_start_reg <= '0';
            mem_op_reg <= (others => '0');
            mem_req_active <= '0';
            clear_acc_reg <= '0';
            we_c_acc_reg <= (others => '0');
            c_acc_data_reg <= (others => '0');
        elsif rising_edge(clk_i) then
            --------------------------------
            --DEFAULTS FOR ONE CYCLE STROBS
            --------------------------------
            mem_start_reg  <= '0';
            done_reg  <= '0';
            clear_acc_reg <= '0';
            we_c_acc_reg <= (others => '0');

            case state is
                when IDLE => 
                    busy_reg <= '0';
                    mem_req_active<= '0';
                    if start_i = '1' then 
                        --LATCH CONFRIGURATION
                        dim_m_reg <= dim_m_i;
                        dim_k_reg <= dim_k_i;
                        dim_n_reg <= dim_n_i;
                        addr_a_base_reg <= addr_a_base_i;
                        addr_b_base_reg <= addr_b_base_i;
                        addr_c_base_reg <= addr_c_base_i;
                        --CONVERT DIMENSIONS TO INTEGER
                        m_int := to_integer(dim_m_i);
                        k_int := to_integer(dim_k_i);
                        n_int := to_integer(dim_n_i);

                        m_tiles <= m_int / TILE_SIZE;
                        k_tiles <= k_int / TILE_SIZE;
                        n_tiles <= n_int / TILE_SIZE;

                        
                        tile_row <= 0;
                        tile_col <= 0;
                        tile_k <= 0;
                        acc_idx <= 0;
                        busy_reg <= '1';

                        --GO TO LOAD A STATE
                        state <= LOAD_A;
                    else
                        state <= IDLE;
                    end if;

                when LOAD_A => 
                    if mem_req_active = '0' then 
                        mem_op_reg <= "01";
                        mem_start_reg <= '1';
                        mem_req_active <= '1';
                        --During k = 0, accumulator must be cleared.
                        --For k = 1, 2, ..., accumulator must retain previous partial sums.
                        if tile_k = 0 then 
                            clear_acc_reg <= '1';
                        end if;
                    else
                        --WAIT FOR MEMORY INTERFACE TO COMPLETE
                        if mem_done_i = '1' then
                            mem_req_active <= '0';
                            state <= LOAD_B;
                        end if;
                    end if;
                when LOAD_B =>
                    if mem_req_active = '0' then
                        mem_op_reg      <= "10";      -- load B
                        mem_start_reg   <= '1';       -- one-cycle pulse
                        mem_req_active  <= '1';
                    else
                        if mem_done_i = '1' then
                        mem_req_active <= '0';
                        state <= START_MM;
                        end if;
                    end if;
                ----------------------------------------------------------------------
                -- START_MM: In a pipelined design we might assert a start here.
                -- For a purely combinational mm4x4, this can simply move to WAIT_MM.
                -- No explicit handshake with mm4x4 is needed; data is combinational.
                -- We can transition immediately to WAIT_MM or even directly to ACCUM.
                ----------------------------------------------------------------------
                when START_MM =>
                    state <= WAIT_MM;
                when WAIT_MM =>
                    --In combinational design, mm4x4 result is ready immediately.
                    --This state allows for pipelining if extended later. Can transition directly to ACCUM state.
                    acc_idx <= 0;
                    state <= ACCUM;
                when ACCUM =>
                    r := acc_idx / 4;
                    c := acc_idx mod 4;
                    sum := c_acc_tile_i(r,c) + mm_c_tile_i(r,c); --old + partial
                    c_acc_data_reg <= sum;
                    we_c_acc_reg(acc_idx) <= '1';
                    if acc_idx = 15 then
                        acc_idx <= 0;
                        state <= NEXT_K;
                    else
                        acc_idx <= acc_idx + 1;
                        state <= ACCUM;
                    end if;
                when NEXT_K =>
                    if tile_k < (k_tiles - 1) then
                        tile_k <= tile_k + 1;
                        state <= LOAD_A;
                    else
                        tile_k <= 0;
                        state <= WRITE_BACK;
                    end if;
                when WRITE_BACK =>
                    if mem_req_active = '0' then
                        mem_op_reg <= "11";      -- store C
                        mem_start_reg <= '1';    -- one-cycle pulse
                        mem_req_active <= '1';
                    else
                        if mem_done_i = '1' then
                            mem_req_active <= '0';
                            state <= NEXT_COL;
                        end if;
                    end if;
                when NEXT_COL =>
                    if tile_col < (n_tiles - 1) then
                        tile_col <= tile_col + 1;
                        tile_k <= 0;
                        state <= LOAD_A;
                    else
                        tile_col <= 0;
                        tile_k <= 0;
                        state <= NEXT_ROW;
                    end if;
                when NEXT_ROW =>
                    if tile_row < (m_tiles - 1) then
                        tile_row <= tile_row + 1;
                        tile_col <= 0;
                        tile_k   <= 0;
                        state    <= LOAD_A;
                    else
                        -- All tile rows, columns, and K tiles are done
                        state    <= DONE;
                    end if;
                when DONE =>
                    done_reg <= '1';
                    busy_reg <= '0';
                    state <= IDLE;
            end case;
        end if;
    end process;
end architecture rtl; 

