--Holds ONE 4×4 tile of A (16 × s16)
--Holds ONE 4×4 tile of B (16 × s16)
--Holds ONE 4×4 tile of accumulated C (16 × s32)
--Provides data to the mm4x4 core
--Receives accumulation results
--It ONLY stores 48 values (16 A + 16 B + 16 Cacc).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cfs_pkg.all;

entity cfs_tile_buffer is
    port(
        --CLOCK AND RESET
        clk_i : in std_logic;
        rstn_i : in std_logic;

        --CONTROL SIGNALS
        clear_acc_i : in std_logic;

        --WRITE ENABLES
        we_a_i : in std_logic_vector(15 downto 0);
        a_data_i : in s16;
        we_b_i : in std_logic_vector(15 downto 0);  
        b_data_i : in s16;
        we_c_acc_i : in std_logic_vector(15 downto 0);
        c_acc_data_i : in s32;

        --OUTPUT PORTS
        a_tile_o : out tile4x4_int16;
        b_tile_o : out tile4x4_int16;
        c_acc_tile_o : out tile4x4_int32

    );
end entity cfs_tile_buffer;

architecture rtl of cfs_tile_buffer is
    --INTERNAL STORAGE
    signal A_tile : tile4x4_int16 := (others => (others => (others => '0')));
    signal B_tile : tile4x4_int16 := (others => (others => (others => '0')));
    signal C_acc_tile : tile4x4_int32 := (others => (others => (others => '0')));
begin
    --ASSIGN OUTPUTS
    a_tile_o <= A_tile;
    b_tile_o <= B_tile;
    c_acc_tile_o <= C_acc_tile;

    --TILE WRITE AND CLEAR LOGIC
    process(clk_i, rstn_i)
        variable index : integer;
        variable r: integer;
        variable c: integer;
    begin
        if rstn_i = '0' then
            for r in 0 to 3 loop
                for c in 0 to 3 loop
                    A_tile(r,c) <= (others => '0');
                    B_tile(r,c) <= (others => '0');
                    C_acc_tile(r,c) <= (others => '0');
                end loop;
            end loop;
        elsif rising_edge(clk_i) then
            --CLEAR ACCUMULATION TILE
            if clear_acc_i = '1' then
                for r in 0 to 3 loop
                    for c in 0 to 3 loop
                        C_acc_tile(r,c) <= (others => '0');
                    end loop;
                end loop;
            end if;
            --WRITE TO A TILE
            for r in 0 to 3 loop
                for c in 0 to 3 loop
                    index := r*4+c;
                    if we_a_i(index) = '1' then
                        A_tile(r,c) <= a_data_i;
                    end if;
                end loop;
            end loop;
            --WRITE TO B TILE
            for r in 0 to 3 loop
                for c in 0 to 3 loop
                    index := r*4+c;
                    if we_b_i(index) = '1' then
                        B_tile(r,c) <= b_data_i;
                    end if;
                end loop;
            end loop;
            --WRITE TO C ACCUM TILE
            for r in 0 to 3 loop
                for c in 0 to 3 loop
                    index := r*4+c;
                    if we_c_acc_i(index) = '1' then
                        C_acc_tile(r,c) <= c_acc_data_i;
                    end if;
                end loop;
            end loop;
        end if;
    end process;
end architecture rtl;
