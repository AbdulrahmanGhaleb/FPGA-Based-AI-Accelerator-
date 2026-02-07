#include <neorv32.h>

#include "driver_log.h"
#include "nn_fixed.h"
#include "comfort_test_set.h"


static inline uint32_t rdcycle(void) {
  return neorv32_cpu_csr_read(CSR_MCYCLE);
}

#define TEST_INPUT_Q_SCALE (1 << 8)

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
// Multi-run (accuracy + perf) configuration
// ------------------------------
#ifndef NN_ACCURACY_TEST
#define NN_ACCURACY_TEST 1
#endif


static void print_run_header(void) {
  LOGD("NN Inference\n");
#if (LOG_LEVEL >= LOG_DEBUG)
  LOGD("Log level: DEBUG\n");
#else
  LOGD("Log level: INFO\n");
#endif
}

int main(void) {
  neorv32_uart0_setup(19200, 0);
  neorv32_uart0_printf("\n");

  print_run_header();

  nn_stats_t st;
  nn_stats_init(&st);

#if NN_ACCURACY_TEST

  LOGD("MULTI-RUN: accuracy + performance, samples=%d\n", (int)TEST_SET_SIZE);
  int TP = 0, TN = 0, FP = 0, FN = 0;
  int correct = 0;

  for (int i = 0; i < TEST_SET_SIZE; i++) {
    float T = (float)test_T_q[i] / (float)TEST_INPUT_Q_SCALE;
    float H = (float)test_H_q[i] / (float)TEST_INPUT_Q_SCALE;

    float prob = 0.0f;
    int cls = 0;

    int rc = nn_infer_fixed_accel(T, H, &prob, &cls, &st);
    if (rc != 0) {
      LOGE("ACC TEST failed at i=%d (timeouts=%d)\n",
           i, (int)st.accel_timeouts);
      break;
    }

    if (cls == test_label[i]) {
      correct++;
    }
    if (cls == 1 && test_label[i] == 1) TP++;
    else if (cls == 0 && test_label[i] == 0) TN++;
    else if (cls == 1 && test_label[i] == 0) FP++;
    else if (cls == 0 && test_label[i] == 1) FN++;
    /*LOGI("CONFUSION: TP=%d TN=%d FP=%d FN=%d\n", TP, TN, FP, FN);*/
  }

  // Final accuracy report
  LOGI("NN ENGINE REPORT\n");
  LOGI("NUMBER OF ITERATIONS:  %d\n", (int)PERF_ITERS);
  LOGI("Saturation counts: a1=%d a2=%d a3=%d\n",(int)st.a1_sat, (int)st.a2_sat, (int)st.a3_sat);
  int accuracy_x100 = (correct * 10000) / TEST_SET_SIZE;
  LOGI("ACCURACY RESULT: %d / %d correct\n",
       correct, (int)TEST_SET_SIZE);
  LOGI("ACCURACY: %d.%d\n",
       accuracy_x100 / 100,
       accuracy_x100 % 100);
  LOGI("CONFUSION: TP=%d TN=%d FP=%d FN=%d\n", TP, TN, FP, FN);
  if (st.max_abs_diff_l2 == 0 && st.max_abs_diff_l3 == 0 && st.max_abs_diff_l4 == 0) {
  LOGI("CPU and NN Engine match: maxdiff(L2/L3/L4)=%d/%d/%d (cpu vs accel)\n", (int)st.max_abs_diff_l2, (int)st.max_abs_diff_l3, (int)st.max_abs_diff_l4);
  }


#if PERF_ENABLE
  uint32_t accel_total_cycles = 0;
  uint32_t accel_cycles_per_iter = 0;
  uint32_t cpu_total_cycles = 0;
  uint32_t cpu_cycles_per_iter = 0;

  float perf_prob = 0.0f;
  int perf_cls = 0;
  int rc_perf = 0;

  uint32_t t0 = rdcycle();
  for (int i = 0; i < TEST_SET_SIZE; i++) {
    float T = (float)test_T_q[i] / (float)TEST_INPUT_Q_SCALE;
    float H = (float)test_H_q[i] / (float)TEST_INPUT_Q_SCALE;
    rc_perf = nn_infer_fixed_accel_perf(T, H, &perf_prob, &perf_cls, NULL);
    if (rc_perf != 0) break;
  }
  uint32_t t1 = rdcycle();

  if (rc_perf == 0) {
    accel_total_cycles = t1 - t0;
    accel_cycles_per_iter = accel_total_cycles / TEST_SET_SIZE;
  } else {
    LOGE("PERF accel failed (rc=%d)\n", rc_perf);
  }

  t0 = rdcycle();
  for (int i = 0; i < TEST_SET_SIZE; i++) {
    float T = (float)test_T_q[i] / (float)TEST_INPUT_Q_SCALE;
    float H = (float)test_H_q[i] / (float)TEST_INPUT_Q_SCALE;
    rc_perf = nn_infer_fixed_cpu_perf(T, H, &perf_prob, &perf_cls, NULL);
    if (rc_perf != 0) break;
  }
  t1 = rdcycle();

  if (rc_perf == 0) {
    cpu_total_cycles = t1 - t0;
    cpu_cycles_per_iter = cpu_total_cycles / TEST_SET_SIZE;
  } else {
    LOGE("PERF cpu failed (rc=%d)\n", rc_perf);
  }

  if (accel_cycles_per_iter > 0 && cpu_cycles_per_iter > 0) {
    int32_t accel_cyc_per_mac_x100 = (int32_t)((accel_cycles_per_iter * 100u) / MACS_PER_INFER);
    int32_t cpu_cyc_per_mac_x100 = (int32_t)((cpu_cycles_per_iter * 100u) / MACS_PER_INFER);
    int32_t speedup_x100 = (int32_t)((cpu_cycles_per_iter * 100u) / accel_cycles_per_iter);

    
    LOGI("Total cycles (NN ENGINE): %u\n", (unsigned)accel_total_cycles);
    LOGI("Cycles / inference (NN ENGINE): %u\n", (unsigned)accel_cycles_per_iter);
    LOGI("Cycles / MAC (NN ENGINE): %d(x1e-2)\n", (int)accel_cyc_per_mac_x100);

    LOGI("Total cycles (CPU): %u\n", (unsigned)cpu_total_cycles);
    LOGI("Cycles / inference (CPU): %u\n", (unsigned)cpu_cycles_per_iter);
    LOGI("Cycles / MAC (CPU): %d(x1e-2)\n", (int)cpu_cyc_per_mac_x100);

    LOGI("Achieved Speedup: %d(x1e-2)x\n", (int)speedup_x100);

  }
#endif

#endif




  float T = 35.9f;
  float H = 90.0f;

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

    if (st.max_abs_diff_l2 == 0 && st.max_abs_diff_l3 == 0 && st.max_abs_diff_l4 == 0) {
      LOGI("PROOF: no difference between CPU and accelerator intermediate values\n");
    } else {
      LOGI("PROOF: maxdiff(L2/L3/L4)=%d/%d/%d (cpu vs accel)\n",
           (int)st.max_abs_diff_l2, (int)st.max_abs_diff_l3, (int)st.max_abs_diff_l4);
    }
  }


  while (1) { ; }
  return 0;
}
