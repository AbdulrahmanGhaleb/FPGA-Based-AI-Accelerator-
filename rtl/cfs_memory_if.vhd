
--Reads full matrices from local BRAM
--Writes full tiles back to local BRAM
--Sends tile elements to tile buffer one element at a time
--Controls which element goes into which tile cell using the WE bits
-- It does NOT store matrices, It only moves data between BRAM ↔ tile buffer.


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cfs_pkg.all;

entity cfs_memory_if is
    port(
        --CLOCK AND RESET
        clk_i : in std_logic;
        rstn_i : in std_logic;

        --FROM CFS CORE
        start_i : in std_logic;
        op_i : in std_logic_vector(1 downto 0); --01 = load A, 10 = load B, 11 = store C

        tile_row_i : in u32;
        tile_col_i : in u32;
        tile_k_i : in u32;

        dim_m_i : in u32;
        dim_k_i : in u32;
        dim_n_i : in u32;

        base_addr_a_i : in u32;
        base_addr_b_i : in u32;
        base_addr_c_i : in u32;

        busy_o : out std_logic;
        done_o : out std_logic;

        --TO TILE BUFFER
        --A TILE LOAD:
        we_a_o : out std_logic_vector(15 downto 0);
        a_data_o : out s16;
        --B TILE LOAD:
        we_b_o : out std_logic_vector(15 downto 0);
        b_data_o : out s16;
        --C TILE WRITE-BACK:
        c_acc_tile_i : in tile4x4_int32;

        --LOCAL MEMORIES FOR A,B,C
        a_mem_addr_o : out u32;
        a_mem_re_o : out std_logic;
        a_mem_rdata_i : in s16;

        b_mem_addr_o : out u32;
        b_mem_re_o : out std_logic;
        b_mem_rdata_i : in s16;

        c_mem_addr_o : out u32;
        c_mem_we_o : out std_logic;
        c_mem_wdata_o : out s32
    );

end entity cfs_memory_if;

architecture rtl of cfs_memory_if is
    --FSM STATES FOR MEMORY IF
    type mem_state_t is(
        MS_IDLE, --waits for FSM to assert start_i
        MS_LOAD_A_REQ, --compute next A address, assert read enable(a_mem_re_o)
        MS_LOAD_A_WAIT, --wait 1 cycle for synchronous BRAM read latency
        MS_LOAD_A_LATCH, --latch A BRAM read data and push into tile buffer
        MS_LOAD_B_REQ, 
        MS_LOAD_B_WAIT, --wait 1 cycle for synchronous BRAM read latency
        MS_LOAD_B_LATCH, --latch B BRAM read data and push into tile buffer
        MS_WRITE_C --write each of 16 accumulated C values back to local BRAM
    );

    signal state : mem_state_t := MS_IDLE;
    signal current_op : std_logic_vector(1 downto 0) := (others => '0');

    -- element index within the 4x4 tile: 0..15
    signal elem_idx : integer range 0 to 15 := 0; 

    -- REGISTERED OUTPUTS
    signal we_a_reg    : std_logic_vector(15 downto 0) := (others => '0');
    signal we_b_reg    : std_logic_vector(15 downto 0) := (others => '0');
    signal a_data_reg  : s16 := (others => '0');
    signal b_data_reg  : s16 := (others => '0');

    signal a_addr_reg  : u32 := (others => '0');
    signal a_re_reg    : std_logic := '0';
    signal b_addr_reg  : u32 := (others => '0');
    signal b_re_reg    : std_logic := '0';
    signal c_addr_reg  : u32 := (others => '0');
    signal c_we_reg    : std_logic := '0';
    signal c_wdata_reg : s32 := (others => '0');

    signal busy_reg    : std_logic := '0';
    signal done_reg    : std_logic := '0';

begin
    --OUTPUT ASSIGNMENTS
    we_a_o <= we_a_reg;
    we_b_o <= we_b_reg;
    a_data_o <= a_data_reg;
    b_data_o <= b_data_reg;
    
    a_mem_addr_o <= a_addr_reg;
    a_mem_re_o <= a_re_reg;
    b_mem_addr_o <= b_addr_reg;
    b_mem_re_o <= b_re_reg;
    c_mem_addr_o <= c_addr_reg;
    c_mem_we_o <= c_we_reg;
    c_mem_wdata_o <= c_wdata_reg;

    busy_o <= busy_reg;
    done_o <= done_reg;

    --MAIN SEQUENCE
    process(clk_i, rstn_i)
        --local variables for address calculation
        variable M, K, N : integer;
        variable tile_row_int, tile_col_int, tile_k_int : integer;
        variable base_a_int, base_b_int, base_c_int : integer;

        variable r, c : integer;
        variable idx : integer;
        variable global_row, global_col, global_k : integer;
        variable element_index : integer;
    begin
        if rstn_i = '0' then
            state <= MS_IDLE;
            current_op <= (others=>'0');
            elem_idx <= 0;

            we_a_reg <= (others => '0');
            we_b_reg <= (others => '0');
            a_data_reg <= (others => '0');
            b_data_reg <= (others => '0');
            a_addr_reg <= (others => '0');
            a_re_reg <= '0';
            b_addr_reg <= (others => '0');
            b_re_reg <= '0';
            c_addr_reg <= (others => '0');
            c_we_reg <= '0';
            c_wdata_reg <= (others => '0');

            busy_reg <= '0';
            done_reg <= '0';
        elsif rising_edge(clk_i) then
            --DEFAULTS
            we_a_reg <= (others => '0');
            we_b_reg <= (others => '0');
            a_re_reg <= '0';
            b_re_reg <= '0';
            c_we_reg <= '0';
            done_reg <= '0';

            --CONVERT DIMENSIONS AND TILE INDICES TO INTEGERS fOR ARITHMETICS
            M := to_integer(dim_m_i);
            K := to_integer(dim_k_i);  
            N := to_integer(dim_n_i);
            tile_row_int := to_integer(tile_row_i);
            tile_col_int := to_integer(tile_col_i);
            tile_k_int := to_integer(tile_k_i);
            base_a_int := to_integer(base_addr_a_i);
            base_b_int := to_integer(base_addr_b_i);
            base_c_int := to_integer(base_addr_c_i);

            case state is
                when MS_IDLE =>
                    busy_reg <='0';

                    if start_i = '1' then 
                        busy_reg <= '1';
                        elem_idx <= 0;
                        current_op <= op_i;

                        if op_i = "01" then --LOAD A TILE
                            state <= MS_LOAD_A_REQ;
                        elsif op_i = "10" then -- LOAD B TILE
                            state <= MS_LOAD_B_REQ;
                        elsif op_i = "11" then -- WRITE BACK C TILE
                            state <= MS_WRITE_C;
                        else
                            --unknown operation, stay in IDLE
                            busy_reg <= '0';
                            state <= MS_IDLE;
                        end if;
                    end if;
                when MS_LOAD_A_REQ =>
                    --element indices inside the 4x4 tile
                    idx := elem_idx; --Determine which of the 16 elements of the 4Ã4 tile it is about to load
                    r := idx / 4; --convert that element to row and column within the tile
                    c := idx mod 4;
                    --calculate global row and column in FULL matrix A (not tile)
                    global_row := tile_row_int * 4 +r;
                    global_k := tile_k_int * 4 + c;

                    --linear index within matrix A
                    element_index := base_a_int + global_row*K + global_k;

                    --issue memory read for A element
                    a_addr_reg <= to_unsigned(element_index, a_addr_reg'length);
                    a_re_reg <= '1';
                    state <= MS_LOAD_A_WAIT;
                when MS_LOAD_A_WAIT =>
                    -- synchronous BRAM updates read-data after the clock edge; wait one more cycle before latching
                    state <= MS_LOAD_A_LATCH;
                when MS_LOAD_A_LATCH =>
                    --latch A read data and push into tile buffer
                    a_data_reg <= a_mem_rdata_i;
                    --generate one-hot WE for the element being loaded
                    idx := elem_idx;
                    we_a_reg(idx) <= '1';
                    --move to next element
                    if elem_idx = 15 then --finished all 16 elements
                        elem_idx <= 0;
                        done_reg <= '1';
                        busy_reg <= '0';
                        state <= MS_IDLE;
                    else
                        elem_idx <= elem_idx + 1;
                        state <= MS_LOAD_A_REQ;
                    end if;
                when MS_LOAD_B_REQ =>
                    idx := elem_idx;
                    r   := idx / 4;
                    c   := idx mod 4;

                    -- global coordinates in B: (K x N)
                    global_k := tile_k_int   * 4 + r; -- row index in B
                    global_col := tile_col_int * 4 + c; -- column index in B

                    element_index := base_b_int + global_k * N + global_col;

                    b_addr_reg <= to_unsigned(element_index, b_addr_reg'length);
                    b_re_reg <= '1';

                    state <= MS_LOAD_B_WAIT;

                when MS_LOAD_B_WAIT =>
                    -- synchronous BRAM updates read-data after the clock edge; wait one more cycle before latching
                    state <= MS_LOAD_B_LATCH;
                when MS_LOAD_B_LATCH =>
                    b_data_reg <= b_mem_rdata_i;

                    idx := elem_idx;
                    we_b_reg(idx) <= '1';

                    if elem_idx = 15 then
                        elem_idx <= 0;
                        done_reg <= '1';
                        busy_reg <= '0';
                        state <= MS_IDLE;
                    else
                        elem_idx <= elem_idx + 1;
                        state <= MS_LOAD_B_REQ;
                    end if;
                when MS_WRITE_C =>
                    idx := elem_idx;
                    r := idx/4;
                    c := idx mod 4;
                    global_row := tile_row_int * 4 + r;
                    global_col := tile_col_int * 4 + c;
                    element_index := base_c_int + global_row * N + global_col;
                    c_addr_reg <= to_unsigned(element_index, c_addr_reg'length);
                    c_wdata_reg <= c_acc_tile_i(r,c);
                    c_we_reg <= '1';
                    if elem_idx = 15 then
                        elem_idx <= 0;
                        done_reg <= '1';
                        busy_reg <= '0';
                        state <= MS_IDLE;
                    else
                        elem_idx <= elem_idx + 1;
                        state <= MS_WRITE_C;
                    end if;
                end case;
        end if;
    end process;
end architecture rtl;