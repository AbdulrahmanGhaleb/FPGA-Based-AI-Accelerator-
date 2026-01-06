library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Memory used for CFS is local to it, meaning it doesnt go through CPU's bus
-- Inside CFS, CPU communicates through offsets, no absolute addresses
-- CFS base address is 0xffeb0000, already specified by default in neorv32_package

package cfs_pkg is
    -- GLOBAL CONSTANTS
    constant MAX_DIM : integer := 16;
    constant TILE_SIZE : integer := 4;
    constant LOCAL_BRAM_SIZE : integer := MAX_DIM * MAX_DIM;


    -- TYPE DEFINITIONS
    type tile4x4_int16 is array (0 to 3, 0 to 3) of signed(15 downto 0);
    type tile4x4_int32 is array (0 to 3, 0 to 3) of signed(31 downto 0);

    -- FSM STATE ENUMERATIONS
    type fsm_states is (
        IDLE,
        LOAD_A,
        LOAD_B,
        START_MM,
        WAIT_MM,
        ACCUM,
        NEXT_K,
        NEXT_COL,
        NEXT_ROW,
        WRITE_BACK,
        DONE
    );

    -- REGSITER MAP (8 registers, 4 bytes (32 bits) each)
    constant REG_CONTROL : natural := 16#00#;
    constant REG_STATUS : natural := 16#04#;
    constant REG_A_ADDR : natural := 16#08#;
    constant REG_B_ADDR : natural := 16#0C#;
    constant REG_C_ADDR : natural := 16#10#;
    constant REG_DIM_M : natural := 16#14#;
    constant REG_DIM_K : natural := 16#18#;
    constant REG_DIM_N : natural := 16#1C#;

    -- SUBTYPES FOR INDICES AND DIMENSIONS
    subtype bram_index_t is integer range 0 to (MAX_DIM * MAX_DIM -1 );
    subtype dim_t is integer range 0 to MAX_DIM;

    -- DATA WIDTH SUBTYPES
    subtype s16 is signed (15 downto 0);
    subtype s32 is signed (31 downto 0);
    subtype u32 is unsigned (31 downto 0);

    -- TILE INDEXING HELPER
    function index_2d_to_1d(row, col, row_width : integer) return bram_index_t;
    
end package cfs_pkg;

package body cfs_pkg is
    function index_2d_to_1d(row, col, row_width : integer) return bram_index_t is
    begin
        return (row * row_width) + col;
    end function;
end package body cfs_pkg;




