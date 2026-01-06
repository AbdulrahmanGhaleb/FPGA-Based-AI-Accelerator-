#pragma once
#include <stdint.h>

typedef struct { //statistics that are used in debugging
  uint32_t runs; //how many times inference was execcuted
  uint32_t accel_timeouts; //how many times accelerator failed to complete (incremented when BUSY never appears or BUSY gets stuck)

  int32_t max_abs_diff_l2; //The maximum absolute difference between accelerator output and CPU reference output.
  int32_t max_abs_diff_l3;
  int32_t max_abs_diff_l4;

  int16_t a1_min, a1_max; //activation ranges, smallest and largest, used to detect when saturation happens
  int16_t a2_min, a2_max;
  int16_t a3_min, a3_max;

  uint32_t a1_sat; //counts how many times range was reached (quantization effects)
  uint32_t a2_sat;
  uint32_t a3_sat;
} nn_stats_t;

void nn_stats_init(nn_stats_t* st);

int nn_infer_fixed_accel(float T, float H, float* out_prob, int* out_cls, nn_stats_t* st); //*out_prob → sigmoid output (0–1), *out_cls → final classification (0 or 1)
