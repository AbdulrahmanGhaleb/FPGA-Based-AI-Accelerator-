#include <neorv32.h>

#include "driver_log.h"
#include "nn_fixed.h"

static inline uint32_t rdcycle(void) {
  return neorv32_cpu_csr_read(CSR_MCYCLE);
}

// ------------------------------
// Performance configuration
// ------------------------------
#ifndef PERF_ENABLE
#define PERF_ENABLE 1
#endif

#ifndef PERF_ITERS
#define PERF_ITERS 1000
#endif

//padded
#define MACS_L1 (4u * 4u * 16u)
#define MACS_L2 (4u * 16u * 16u)
#define MACS_L3 (4u * 16u * 8u)
#define MACS_L4 (4u * 8u * 4u)
#define MACS_PER_INFER (MACS_L1 + MACS_L2 + MACS_L3 + MACS_L4)


// ------------------------------
// Stress test configuration
// ------------------------------
#ifndef NN_STRESS
#define NN_STRESS 0
#endif

#ifndef STRESS_ITERS
#define STRESS_ITERS 200
#endif

// LCG for input randomizer for stress test
static uint32_t lcg_state = 0x12345678u;
static uint32_t lcg_u32(void) {
  lcg_state = lcg_state * 1664525u + 1013904223u;
  return lcg_state;
}
static float lcg_range(float lo, float hi) {
  uint32_t r = lcg_u32();
  // Use top 16 bits as [0..1)
  float u = (float)((r >> 16) & 0xFFFFu) / 65536.0f;
  return lo + (hi - lo) * u;
}

static void print_run_header(void) {
  LOGI("NN Inference (Fixed-Point + Accel) dims: 2-16-16-8-1  tile:4x4  pad:ON\n");
#if (LOG_LEVEL >= LOG_DEBUG)
  LOGI("Log level: DEBUG\n");
#else
  LOGI("Log level: INFO\n");
#endif
}

int main(void) {
  neorv32_uart0_setup(19200, 0);
  neorv32_uart0_printf("\n");

  print_run_header();

  nn_stats_t st;
  nn_stats_init(&st);

#if NN_STRESS
  LOGI("STRESS mode: iters=%d\n", (int)STRESS_ITERS);

  for (int it = 0; it < STRESS_ITERS; it++) {
    
    float T = lcg_range(15.0f, 40.0f);
    float H = lcg_range(10.0f, 95.0f);

    float prob = 0.0f;
    int cls = 0;

    int rc = nn_infer_fixed_accel(T, H, &prob, &cls, &st);
    if (rc != 0) {
      LOGE("Inference failed at iter=%d (timeouts=%d)\n", it, (int)st.accel_timeouts);
      break;
    }

    // Print checkpoint lines 
    if ((it % 50) == 0) {
      LOGI("iter=%d T=%d(x1e-2) H=%d(x1e-2) prob=%d(x1e-5) cls=%d\n",
           it,
           (int)float_to_scaled_int(T, 100.0f),
           (int)float_to_scaled_int(H, 100.0f),
           (int)float_to_scaled_int(prob, 100000.0f),
           cls);
    }
  }

  LOGI("STRESS DONE runs=%d timeouts=%d maxdiff(L2/L3/L4)=%d/%d/%d\n",
       (int)st.runs, (int)st.accel_timeouts,
       (int)st.max_abs_diff_l2, (int)st.max_abs_diff_l3, (int)st.max_abs_diff_l4);

  LOGI("Activation ranges (raw i16): a1[%d..%d] a2[%d..%d] a3[%d..%d]\n",
       (int)st.a1_min, (int)st.a1_max,
       (int)st.a2_min, (int)st.a2_max,
       (int)st.a3_min, (int)st.a3_max);

  LOGI("Saturation counts: a1=%d a2=%d a3=%d\n",
       (int)st.a1_sat, (int)st.a2_sat, (int)st.a3_sat);

#else
  // Single demo run 
  float T = 30.9f;
  float H = 50.0f;

  LOGI("Input: T=%d(x1e-2)  H=%d(x1e-2)\n",
       (int)float_to_scaled_int(T, 100.0f),
       (int)float_to_scaled_int(H, 100.0f));

  
  float x0 = T / 35.0f;
  float x1 = H / 100.0f;
  LOGI("x_norm (x1e-5): [%d, %d]\n",
       (int)float_to_scaled_int(x0, 100000.0f),
       (int)float_to_scaled_int(x1, 100000.0f));

  float prob = 0.0f;
  int cls = 0;

  //this run is the original run 
  int rc = nn_infer_fixed_accel(T, H, &prob, &cls, &st);
  if (rc != 0) {
    LOGE("Inference failed (timeouts=%d)\n", (int)st.accel_timeouts);
  } else {
    LOGI("Output: prob=%d(x1e-5)  class=%d (%s)\n",
         (int)float_to_scaled_int(prob, 100000.0f),
         cls,
         (cls ? "COMFORTABLE" : "NOT COMFORTABLE"));

  
    LOGI("PROOF: maxdiff(L2/L3/L4)=%d/%d/%d  timeouts=%d\n",
         (int)st.max_abs_diff_l2, (int)st.max_abs_diff_l3, (int)st.max_abs_diff_l4,
         (int)st.accel_timeouts);
  }

#if PERF_ENABLE
  uint32_t accel_total_cycles = 0;
  uint32_t accel_cycles_per_iter = 0;
  uint32_t cpu_total_cycles = 0;
  uint32_t cpu_cycles_per_iter = 0;

  float perf_prob = 0.0f;
  int perf_cls = 0;
  int rc_perf = 0;

  //this run is for performance metrics measurement purely
  uint32_t t0 = rdcycle();
  for (int i = 0; i < PERF_ITERS; i++) {
    rc_perf = nn_infer_fixed_accel_perf(T, H, &perf_prob, &perf_cls, NULL);
    if (rc_perf != 0) break;
  }
  uint32_t t1 = rdcycle();

  if (rc_perf == 0) {
    accel_total_cycles = t1 - t0;
    accel_cycles_per_iter = accel_total_cycles / PERF_ITERS;
  } else {
    LOGE("PERF accel failed (rc=%d)\n", rc_perf);
  }

  //this run is for performance metrics measurement purely
  t0 = rdcycle();
  for (int i = 0; i < PERF_ITERS; i++) {
    rc_perf = nn_infer_fixed_cpu_perf(T, H, &perf_prob, &perf_cls, NULL);
    if (rc_perf != 0) break;
  }
  t1 = rdcycle();

  if (rc_perf == 0) {
    cpu_total_cycles = t1 - t0;
    cpu_cycles_per_iter = cpu_total_cycles / PERF_ITERS;
  } else {
    LOGE("PERF cpu failed (rc=%d)\n", rc_perf);
  }

  if (accel_cycles_per_iter > 0 && cpu_cycles_per_iter > 0) {
    int32_t accel_cyc_per_mac_x100 = (int32_t)((accel_cycles_per_iter * 100u) / MACS_PER_INFER);
    int32_t cpu_cyc_per_mac_x100 = (int32_t)((cpu_cycles_per_iter * 100u) / MACS_PER_INFER);
    int32_t speedup_x100 = (int32_t)((cpu_cycles_per_iter * 100u) / accel_cycles_per_iter);

    LOGP("Mode: ACCEL\n");
    LOGP("Iterations: %d\n", (int)PERF_ITERS);
    LOGP("Total cycles: %d\n", (unsigned long)accel_total_cycles);
    LOGP("Cycles / inference: %d\n", (unsigned long)accel_cycles_per_iter);
    LOGP("Cycles / MAC: %d(x1e-2)\n", (int)accel_cyc_per_mac_x100);

    LOGP("Mode: CPU\n");
    LOGP("Iterations: %d\n", (int)PERF_ITERS);
    LOGP("Total cycles: %d\n", (unsigned long)cpu_total_cycles);
    LOGP("Cycles / inference: %d\n", (unsigned long)cpu_cycles_per_iter);
    LOGP("Cycles / MAC: %d(x1e-2)\n", (int)cpu_cyc_per_mac_x100);

    LOGP("Speedup: %d(x1e-2)x\n", (int)speedup_x100);
  }
#endif
#endif

  while (1) { ; }
  return 0;
}
