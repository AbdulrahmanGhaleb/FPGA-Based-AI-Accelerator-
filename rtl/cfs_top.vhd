library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cfs_pkg.all;

entity cfs_top is 
    port(
        clk_i : in std_logic;
        rstn_i : in std_logic;

        --CPU INTERFACE; will be driven by neorv32_cfs
        addr_i : in std_logic_vector(7 downto 0); --local CFS byte offset
        wdata_i : in std_logic_vector(31 downto 0); --The 32-bit value CPU wants to write to a register.
        rdata_o : out std_logic_vector(31 downto 0); --The 32-bit value returned to CPU when it performs a load.
        we_i : in std_logic; --write enable from CPU
        re_i : in std_logic; --read enable from CPU
        irq_o : out std_logic; --interrupt request to CPU

        --LOCAL BRAM MEMORIES FOR A,B,C; these connect to BRAM
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
end entity cfs_top;

architecture rtl of cfs_top is
    --SIGNALS BETWEEN CFS_REGS AND CFS_FSM
    signal start_s : std_logic;
    signal clear_acc_reg_s : std_logic;

    signal dim_m_s : u32;
    signal dim_k_s : u32;
    signal dim_n_s : u32;

    signal addr_a_base_s : u32;
    signal addr_b_base_s : u32;
    signal addr_c_base_s : u32;

    signal busy_s : std_logic;
    signal done_s : std_logic;

    --SIGNALS BETWEEN CFS_FSM AND CFS_MEMORY_IF
    signal mem_start_s : std_logic;
    signal mem_op_s    : std_logic_vector(1 downto 0);

    signal mem_tile_row_s : u32;
    signal mem_tile_col_s : u32;
    signal mem_tile_k_s   : u32;

    signal mem_dim_m_s : u32;
    signal mem_dim_k_s : u32;
    signal mem_dim_n_s : u32;

    signal mem_base_addr_a_s : u32;
    signal mem_base_addr_b_s : u32;
    signal mem_base_addr_c_s : u32;

    signal mem_busy_s : std_logic;
    signal mem_done_s : std_logic;

    --SIGNALS BETWEEN CFS_MEMORY_IF AND CFS_TILE_BUFFER
    signal we_a_s    : std_logic_vector(15 downto 0);
    signal a_data_s  : s16;

    signal we_b_s    : std_logic_vector(15 downto 0);
    signal b_data_s  : s16;

    signal c_acc_tile_s : tile4x4_int32;

    --SIGNALS BETWEEN CFS_FSM AND CFS_TILE_BUFFER
    signal clear_acc_fsm_s : std_logic;
    signal clear_acc_to_tile_s : std_logic;

    signal we_c_acc_s    : std_logic_vector(15 downto 0);
    signal c_acc_data_s  : s32;

    --TILE BUFFER OUTPUTS TO MM4X4 AND BACK TO FSM/MEMORY_IF
    signal a_tile_s : tile4x4_int16;
    signal b_tile_s : tile4x4_int16;

    --MM4X4 INTERFACE SIGNALS
    signal A_BUS_s : std_logic_vector(255 downto 0);
    signal B_BUS_s : std_logic_vector(255 downto 0);
    signal C_BUS_s : std_logic_vector(511 downto 0);
    
    signal mm_c_tile_s : tile4x4_int32;
begin
    irq_o <= done_s;
    clear_acc_to_tile_s <= clear_acc_reg_s or clear_acc_fsm_s;

    regs_inst : entity work.cfs_regs
        port map(
            clk_i => clk_i,
            rstn_i => rstn_i,
            addr_i => addr_i,
            wdata_i => wdata_i,
            rdata_o => rdata_o,
            we_i => we_i,
            re_i => re_i,
            start_o => start_s,
            clear_acc_o => clear_acc_reg_s,
            addr_a_base_o => addr_a_base_s,
            addr_b_base_o => addr_b_base_s,
            addr_c_base_o => addr_c_base_s,
            dim_o_m => dim_m_s,
            dim_o_k => dim_k_s,
            dim_o_n => dim_n_s,
            busy_i => busy_s,
            done_i => done_s
        );
    tile_buffer_inst : entity work.cfs_tile_buffer
        port map(
            clk_i => clk_i,
            rstn_i => rstn_i,
            clear_acc_i => clear_acc_to_tile_s,
            we_a_i => we_a_s,
            a_data_i => a_data_s,
            we_b_i => we_b_s,
            b_data_i => b_data_s,
            we_c_acc_i => we_c_acc_s,
            c_acc_data_i => c_acc_data_s,
            a_tile_o => a_tile_s,
            b_tile_o => b_tile_s,
            c_acc_tile_o => c_acc_tile_s
        );
    mm4x4_inst : entity work.mm4x4
        port map(
            A_BUS => A_BUS_s,
            B_BUS => B_BUS_s,
            C_BUS => C_BUS_s
        );
    pack_inputs_to_mm4x4 : process(a_tile_s, b_tile_s)
        variable idx : integer;
    begin
        idx := 0;
        for r in 0 to 3 loop
            for c in 0 to 3 loop
                A_BUS_s(idx*16+15 downto idx*16) <= std_logic_vector(a_tile_s(r,c));
                B_BUS_s(idx*16+15 downto idx*16) <= std_logic_vector(b_tile_s(r,c));
                idx := idx + 1;
            end loop;
        end loop;
    end process;
    unpack_mm4x4_output : process(C_BUS_s)
        variable idx : integer;
    begin
        idx := 0;
        for r in 0 to 3 loop
            for c in 0 to 3 loop
                mm_c_tile_s(r,c) <= signed(C_BUS_s(idx*32+31 downto idx*32));
                idx := idx + 1;
            end loop;
        end loop;
    end process;

    --loads tiles from local BRAMs and writes C tiles back
    mem_if_inst : entity work.cfs_memory_if
        port map(
            clk_i => clk_i,
            rstn_i => rstn_i,
            start_i => mem_start_s,
            op_i => mem_op_s,
            tile_row_i => mem_tile_row_s,
            tile_col_i => mem_tile_col_s,
            tile_k_i => mem_tile_k_s,
            dim_m_i => mem_dim_m_s,
            dim_k_i => mem_dim_k_s,
            dim_n_i => mem_dim_n_s,
            base_addr_a_i => mem_base_addr_a_s,
            base_addr_b_i => mem_base_addr_b_s,
            base_addr_c_i => mem_base_addr_c_s,
            busy_o => mem_busy_s,
            done_o => mem_done_s,
            a_mem_addr_o => a_mem_addr_o,
            a_mem_re_o => a_mem_re_o,
            a_mem_rdata_i => a_mem_rdata_i,
            b_mem_addr_o => b_mem_addr_o,
            b_mem_re_o => b_mem_re_o,
            b_mem_rdata_i => b_mem_rdata_i,
            c_mem_addr_o => c_mem_addr_o,
            c_mem_we_o => c_mem_we_o,
            c_mem_wdata_o => c_mem_wdata_o,
            we_a_o => we_a_s,
            a_data_o => a_data_s,
            we_b_o => we_b_s,
            b_data_o => b_data_s,
            c_acc_tile_i => c_acc_tile_s
        );
    --fsm : main controller, tiling loops, accumulation, and coordination
    fsm_inst : entity work.cfs_fsm
        port map(
        clk_i => clk_i,
        rstn_i => rstn_i,
        start_i => start_s,
        clear_acc_o => clear_acc_fsm_s,

        dim_m_i => dim_m_s,
        dim_k_i => dim_k_s,
        dim_n_i => dim_n_s,

        addr_a_base_i => addr_a_base_s,
        addr_b_base_i => addr_b_base_s,
        addr_c_base_i => addr_c_base_s,

        busy_o => busy_s,
        done_o => done_s,

        mem_start_o => mem_start_s,
        mem_op_o => mem_op_s,
        mem_tile_row_o => mem_tile_row_s,
        mem_tile_col_o => mem_tile_col_s,
        mem_tile_k_o => mem_tile_k_s,

        mem_dim_m_o => mem_dim_m_s,
        mem_dim_k_o => mem_dim_k_s,
        mem_dim_n_o => mem_dim_n_s,

        mem_base_addr_a_o => mem_base_addr_a_s,
        mem_base_addr_b_o => mem_base_addr_b_s,
        mem_base_addr_c_o => mem_base_addr_c_s,

        mem_busy_i => mem_busy_s,
        mem_done_i => mem_done_s,

        mm_c_tile_i => mm_c_tile_s,
        we_c_acc_o  => we_c_acc_s,
        c_acc_data_o => c_acc_data_s,


        c_acc_tile_i => c_acc_tile_s
    );

end architecture rtl;
