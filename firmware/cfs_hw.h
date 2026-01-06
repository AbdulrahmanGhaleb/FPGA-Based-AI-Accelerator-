#pragma once //solves redefinition error 
#include <stdint.h>

// CFS MMIO map
#define CFS_BASE      (0xFFEB0000UL)

#define A_MEM_BASE    (CFS_BASE + 0x1000)
#define B_MEM_BASE    (CFS_BASE + 0x2000)
#define C_MEM_BASE    (CFS_BASE + 0x3000)

#define REG_CONTROL   (*(volatile uint32_t*)(CFS_BASE + 0x00))
#define REG_STATUS    (*(volatile uint32_t*)(CFS_BASE + 0x04))
#define REG_BASE_A    (*(volatile uint32_t*)(CFS_BASE + 0x08))
#define REG_BASE_B    (*(volatile uint32_t*)(CFS_BASE + 0x0C))
#define REG_BASE_C    (*(volatile uint32_t*)(CFS_BASE + 0x10))
#define REG_DIM_M     (*(volatile uint32_t*)(CFS_BASE + 0x14))
#define REG_DIM_K     (*(volatile uint32_t*)(CFS_BASE + 0x18))
#define REG_DIM_N     (*(volatile uint32_t*)(CFS_BASE + 0x1C))

// STATUS bits
#define ST_BUSY_MASK  (1u << 0)
#define ST_DONE_MASK  (1u << 1)

typedef enum {
  CFS_OK = 0, //BUSY was asserted, later deasserted, operation completed
  CFS_TIMEOUT_NO_BUSY = 1, //Software started the accelerator, but BUSY was never observed
  CFS_TIMEOUT_STUCK_BUSY = 2 //BUSY was asserted, but never cleared
} cfs_rc_t; //CFS return-code type

static inline void cfs_write_i16(uint32_t base, uint32_t idx, int16_t v) {
  ((volatile uint32_t*)base)[idx] = (uint32_t)(uint16_t)v; //(uint32_t)(uint16_t) is to extend the number and maintain their sign
}

static inline int32_t cfs_read_i32(uint32_t base, uint32_t idx) {
  return ((volatile int32_t*)base)[idx];
}


cfs_rc_t cfs_wait_complete(uint32_t timeout_no_busy, uint32_t timeout_stuck_busy);

// GEMM wrapper
cfs_rc_t accel_gemm_i16(const int16_t* A, int M, int K,
                        const int16_t* B, int N,
                        int32_t* C_out);
