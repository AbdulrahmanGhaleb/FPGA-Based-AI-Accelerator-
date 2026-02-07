#include "cfs_hw.h"

cfs_rc_t cfs_wait_complete(uint32_t timeout_no_busy, uint32_t timeout_stuck_busy) {
  uint32_t s = 0;
  int saw_busy = 0;

  // Wait until BUSY is observed 
  for (uint32_t t = 0; t < timeout_no_busy; t++) {
    s = REG_STATUS;
    if (s & ST_BUSY_MASK) { saw_busy = 1; break; } 
  }
  if (!saw_busy) { 
    return CFS_TIMEOUT_NO_BUSY;
  }

  // Wait while BUSY remains high
  for (uint32_t t = 0; t < timeout_stuck_busy; t++) {
    s = REG_STATUS;
    if ((s & ST_BUSY_MASK) == 0) return CFS_OK; 
  }

  return CFS_TIMEOUT_STUCK_BUSY; 
}

cfs_rc_t accel_gemm_i16(const int16_t* A, int M, int K,
                        const int16_t* B, int N,
                        int32_t* C_out) {
  // Write A (MxK)
  for (int r = 0; r < M; r++) {
    for (int c = 0; c < K; c++) {
      int idx = r*K + c;
      cfs_write_i16(A_MEM_BASE, (uint32_t)idx, A[idx]);
    }
  }

  // Write B (KxN)
  for (int r = 0; r < K; r++) {
    for (int c = 0; c < N; c++) {
      int idx = r*N + c;
      cfs_write_i16(B_MEM_BASE, (uint32_t)idx, B[idx]);
    }
  }

  // Clear C 
  for (int i = 0; i < (M*N); i++) {
    ((volatile int32_t*)C_MEM_BASE)[i] = 0;
  }

  // Configure regs
  REG_BASE_A = 0;
  REG_BASE_B = 0;
  REG_BASE_C = 0;
  REG_DIM_M  = (uint32_t)M;
  REG_DIM_K  = (uint32_t)K;
  REG_DIM_N  = (uint32_t)N;

  // Start
  REG_CONTROL = 1;

  // Wait
  cfs_rc_t rc = cfs_wait_complete(100000u, 2000000u);
  if (rc != CFS_OK) return rc; //if accelerator fails, stop and propagate error upward

  // Read C (MxN)
  for (int r = 0; r < M; r++) {
    for (int c = 0; c < N; c++) {
      int idx = r*N + c;
      C_out[idx] = cfs_read_i32(C_MEM_BASE, (uint32_t)idx);
    }
  }

  return CFS_OK;
}
