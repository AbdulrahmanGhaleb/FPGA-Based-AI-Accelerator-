--This module is the bridge between CPU (C CODE) and accelerator hardware (fsm, engine and other modules)
--FSM uses the outputs of this module to operate
--All registers inside cfs_regs update on rising edge of clk_i 


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cfs_pkg.all;

entity cfs_regs is
    port(
        --CLOCK AND RESET
        clk_i : in std_logic;
        rstn_i : in std_logic;

        --FROM CPU INTERFACE
        addr_i : in std_logic_vector(7 downto 0); --local CFS byte offset
        wdata_i : in std_logic_vector(31 downto 0); --The 32-bit value CPU wants to write to a register.
        rdata_o : out std_logic_vector(31 downto 0); --The 32-bit value returned to CPU when it performs a load.
        we_i : in std_logic; --write enable from CPU
        re_i : in std_logic; --read enable from CPU

        --TO CFS CORE
        start_o : out std_logic; --One-cycle pulse generated when CPU writes CONTROL bit 0 = 1, tells the FSM: “start processing now”
        clear_acc_o : out std_logic; --One-cycle pulse generated when CPU writes CONTROL bit 1 = 1, tells the FSM to clear accumulation registers

        --to cfs_fsm
        --BASE ADDRESSES; Base address (or base index) where the first element of A, B, or C tile begins.
        addr_a_base_o : out u32;
        addr_b_base_o : out u32;
        addr_c_base_o : out u32;

        --to cfs_fsm
        --DIMENSIONS; provide the sizes of the matrices to be multiplied
        dim_o_m : out u32;
        dim_o_k : out u32;
        dim_o_n : out u32;

        --from cfs_fsm
        --STATUS INPUTS FROM FSM; fsm drives these values, CPU polls these values to know when accelerator is done
        busy_i : in std_logic;
        done_i : in std_logic   
    );
end entity cfs_regs;

architecture rtl of cfs_regs is
    --INTERNAL REGISTERS
    signal reg_control_q : u32 := (others=>'0'); -- CPU writes to CONTROL are stored in reg_control

    signal reg_addr_a_q : u32 := (others=>'0'); -- CPU writes to A_ADDR are stored in reg_addr_a
    signal reg_addr_b_q : u32 := (others=>'0');
    signal reg_addr_c_q : u32 := (others=>'0');

    signal reg_dim_m_q : u32 := (others=>'0');
    signal reg_dim_k_q : u32 := (others=>'0');
    signal reg_dim_n_q : u32 := (others=>'0');

    --START / CLEAR
    signal start_pulse : std_logic := '0';
    signal clear_acc_pulse : std_logic := '0';
    
begin
    --OUTPUT MAPPINGS; assigning registers to ports
    addr_a_base_o <= reg_addr_a_q;
    addr_b_base_o <=reg_addr_b_q;
    addr_c_base_o <= reg_addr_c_q;

    dim_o_m <= reg_dim_m_q;
    dim_o_k <= reg_dim_k_q;
    dim_o_n <= reg_dim_n_q;

    start_o <= start_pulse;
    clear_acc_o <= clear_acc_pulse;

    --WRITE LOGIC (CPU TO REGISTERS - SEQUENTIAL)
    process(clk_i, rstn_i)
        variable addr_u : unsigned(addr_i'range);
        variable wdata_u : u32;
    begin
        if rstn_i = '0' then
            --ASYNC RESET
            reg_control_q <= (others=>'0');
            reg_addr_a_q <= (others=>'0');
            reg_addr_b_q  <= (others=>'0');
            reg_addr_c_q  <= (others=>'0');
            reg_dim_m_q  <= (others=>'0');
            reg_dim_k_q  <= (others=>'0');
            reg_dim_n_q  <= (others=>'0');
            start_pulse <= '0';
            clear_acc_pulse <= '0';
        elsif rising_edge(clk_i) then 
            --CLEAR PULSES
            start_pulse <= '0';
            clear_acc_pulse <= '0';
            addr_u := unsigned(addr_i);
            wdata_u := unsigned(wdata_i);

            if we_i = '1' then
                --DECDOE ADDRESS BASED ON BYTE OFFSET
                if addr_u = to_unsigned(REG_CONTROL, addr_u'length) then
                    reg_control_q <= wdata_u;
                    --GENERATE PULSES BASED ON CONTROL BITS
                    if wdata_u(0) = '1' then
                        start_pulse <= '1';
                    end if;
                    if wdata_u(1) = '1' then
                        clear_acc_pulse <= '1';
                    end if;
                elsif addr_u = to_unsigned(REG_A_ADDR, addr_u'length) then
                    reg_addr_a_q <= wdata_u;
                elsif addr_u = to_unsigned(REG_B_ADDR, addr_u'length) then
                    reg_addr_b_q <= wdata_u;
                elsif addr_u = to_unsigned(REG_C_ADDR, addr_u'length) then
                    reg_addr_c_q <= wdata_u;
                elsif addr_u = to_unsigned(REG_DIM_M, addr_u'length) then
                    reg_dim_m_q <= wdata_u;
                elsif addr_u = to_unsigned(REG_DIM_K, addr_u'length) then
                    reg_dim_k_q <= wdata_u;
                elsif addr_u = to_unsigned(REG_DIM_N, addr_u'length) then
                    reg_dim_n_q <= wdata_u;
                else 
                    --INVALID ADDRESS, DO NOTHING
                    null;
                end if;
            end if;
        end if;
    end process;

    --READ LOGIC (REGISTERS TO CPU - COMBINATIONAL)
    process(addr_i, re_i, reg_control_q, reg_addr_a_q, reg_addr_b_q, reg_addr_c_q, reg_dim_m_q, reg_dim_k_q, reg_dim_n_q, busy_i, done_i)
        variable addr_u : unsigned(addr_i'range);
        variable rdata_v : u32;
    begin
        rdata_v := (others=>'0');
        addr_u := unsigned(addr_i);

        if re_i = '1' then
            --DECODE ADDRESS BASED ON BYTE OFFSET
            if addr_u = to_unsigned(REG_CONTROL, addr_u'length) then
                rdata_v := reg_control_q;
				elsif addr_u = to_unsigned(REG_STATUS, addr_u'length) then
					 rdata_v := (others => '0');
					 if busy_i = '1' then
						  rdata_v(0) := '1';
					 else
						  rdata_v(0) := '0';
					 end if;
					 if done_i = '1' then
						  rdata_v(1) := '1';
					 else
						  rdata_v(1) := '0';
					 end if;
            elsif addr_u = to_unsigned(REG_A_ADDR, addr_u'length) then
                rdata_v := reg_addr_a_q;
            elsif addr_u = to_unsigned(REG_B_ADDR, addr_u'length) then
                rdata_v := reg_addr_b_q;
            elsif addr_u = to_unsigned(REG_C_ADDR, addr_u'length) then
                rdata_v := reg_addr_c_q;
            elsif addr_u = to_unsigned(REG_DIM_M, addr_u'length) then
                rdata_v := reg_dim_m_q;
            elsif addr_u = to_unsigned(REG_DIM_K, addr_u'length) then
                rdata_v := reg_dim_k_q;
            elsif addr_u = to_unsigned(REG_DIM_N, addr_u'length) then
                rdata_v := reg_dim_n_q;
            else 
                --INVALID ADDRESS, RETURN ZERO
                rdata_v := (others=>'0');
            end if;
        else
            rdata_v := (others=>'0');
        end if;
        rdata_o <= std_logic_vector(rdata_v);
    end process;
end architecture rtl;
        