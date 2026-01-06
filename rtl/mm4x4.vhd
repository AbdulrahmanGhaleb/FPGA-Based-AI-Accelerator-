library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mm4x4 is 
    port (
        A_BUS : in  std_logic_vector(255 downto 0);
        B_BUS : in  std_logic_vector(255 downto 0);
        C_BUS : out std_logic_vector(511 downto 0)
    );
end entity mm4x4;

architecture rtl of mm4x4 is

    type signed_input_array  is array (0 to 3, 0 to 3) of signed(15 downto 0);
    type signed_output_array is array (0 to 3, 0 to 3) of signed(31 downto 0);
    type product_elements    is array (0 to 3, 0 to 3, 0 to 3) of signed(31 downto 0);
    type sum_elements        is array (0 to 3, 0 to 3, 0 to 1) of signed(31 downto 0);

    signal A : signed_input_array;
    signal B : signed_input_array;
    signal C : signed_output_array;
    signal P : product_elements;
    signal S : sum_elements;

begin

    ------------------------------------------------------------------------
    -- 1. UNPACK INPUTS
    ------------------------------------------------------------------------
    process(A_BUS, B_BUS)
        variable idx : integer;
    begin
        idx := 0;
        for r in 0 to 3 loop
            for c in 0 to 3 loop
                A(r,c) <= signed(A_BUS(idx*16+15 downto idx*16));
                B(r,c) <= signed(B_BUS(idx*16+15 downto idx*16));
                idx := idx + 1;
            end loop;
        end loop;
    end process;

    ------------------------------------------------------------------------
    -- 2. MULTIPLY + ADD
    ------------------------------------------------------------------------
    mult_rows : for i in 0 to 3 generate
        mult_cols : for j in 0 to 3 generate

            -- multipliers
            P(i,j,0) <= A(i,0) * B(0,j);
            P(i,j,1) <= A(i,1) * B(1,j);
            P(i,j,2) <= A(i,2) * B(2,j);
            P(i,j,3) <= A(i,3) * B(3,j);

            -- partial sums
            S(i,j,0) <= P(i,j,0) + P(i,j,1);
            S(i,j,1) <= P(i,j,2) + P(i,j,3);

            -- final output
            C(i,j)   <= S(i,j,0) + S(i,j,1);

        end generate;
    end generate;

    ------------------------------------------------------------------------
    -- 3. PACK OUTPUTS
    ------------------------------------------------------------------------
    pack_rows : for x in 0 to 3 generate
        pack_cols : for y in 0 to 3 generate

            C_BUS(((x*4 + y)*32 + 31) downto ((x*4 + y)*32))
                <= std_logic_vector(C(x,y));

        end generate;
    end generate;

end architecture rtl;
