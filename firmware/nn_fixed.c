#include <math.h>
#include "nn_fixed.h"
#include "cfs_hw.h"
#include "driver_log.h"

#include "nn_weights_quantized.h"

// NN dims
#define IN_DIM   2
#define L1_DIM  16
#define L2_DIM  16
#define L3_DIM   8
#define OUT_DIM  1

static inline int round_up4(int x) { return (x + 3) & ~3; } //Bitwise AND clears the lowest 2 bits forcing number to become multiple of 4



// used in quantization and requantization
static const float A0_S = 1.0f / 32768.0f; // Q15 input
static const float A1_S = 1.0f / 8192.0f;  // Q13
static const float A2_S = 1.0f / 8192.0f;  // Q13
static const float A3_S = 1.0f / 8192.0f;  // Q13

static inline int16_t sat_i16(int32_t x) {
  if (x >  32767) return  32767;
  if (x < -32768) return -32768;
  return (int16_t)x;
}

static inline int16_t quant_f_to_i16(float x, float a_s) {
  float qf = x / a_s;
  int32_t qi = (qf >= 0.0f) ? (int32_t)(qf + 0.5f) : (int32_t)(qf - 0.5f);
  return sat_i16(qi);
}

static inline int32_t relu_i32(int32_t x) { return (x > 0) ? x : 0; }

static float sigmoid_f(float x) {
  if (x >  10.0f) x = 10.0f;
  if (x < -10.0f) x = -10.0f;
  return 1.0f / (1.0f + expf(-x));
}

static void pad_vec_i16(const int16_t* src, int len, int16_t* dst, int plen) {
  for (int i = 0; i < plen; i++) dst[i] = (i < len) ? src[i] : 0;
}

static void pad_mat_i16(const int16_t* W, int in_dim, int out_dim,
                        int16_t* Wp, int pin, int pout) {
  for (int i = 0; i < pin; i++) {
    for (int j = 0; j < pout; j++) {
      if (i < in_dim && j < out_dim) Wp[i*pout + j] = W[i*out_dim + j];
      else  Wp[i*pout + j] = 0;
    }
  }
}

static inline int32_t bias_f_to_i32(float b, float a_in_s, float w_s) {
  float denom = a_in_s * w_s;
  float qf = b / denom;
  return (qf >= 0.0f) ? (int32_t)(qf + 0.5f) : (int32_t)(qf - 0.5f);
}

static inline int16_t requant_i32_to_i16(int32_t zq, float a_in_s, float w_s, float a_out_s) {
  float mult = (a_in_s * w_s) / a_out_s;
  float qf = (float)zq * mult;
  int32_t qi = (qf >= 0.0f) ? (int32_t)(qf + 0.5f) : (int32_t)(qf - 0.5f);
  return sat_i16(qi);
}

static inline int32_t i32_abs(int32_t x) { return (x < 0) ? -x : x; }

static void vec_minmax_i16(const int16_t* v, int n, int16_t* out_min, int16_t* out_max) {
  int16_t mn = v[0], mx = v[0];
  for (int i = 1; i < n; i++) {
    if (v[i] < mn) mn = v[i];
    if (v[i] > mx) mx = v[i];
  }
  *out_min = mn; *out_max = mx;
}

void nn_stats_init(nn_stats_t* st) {
  st->runs = 0;
  st->accel_timeouts = 0;
  st->max_abs_diff_l2 = 0;
  st->max_abs_diff_l3 = 0;
  st->max_abs_diff_l4 = 0;

  st->a1_min = 0; st->a1_max = 0;
  st->a2_min = 0; st->a2_max = 0;
  st->a3_min = 0; st->a3_max = 0;

  st->a1_sat = 0;
  st->a2_sat = 0;
  st->a3_sat = 0;
}

// Enable/disable CPU cross-check at compile time
#ifndef NN_ENABLE_CPU_CHECK
#define NN_ENABLE_CPU_CHECK 1
#endif

// Verbose vector prints at DEBUG
#ifndef NN_VERBOSE_VECTORS
#define NN_VERBOSE_VECTORS 1
#endif

int nn_infer_fixed_accel(float T, float H, float* out_prob, int* out_cls, nn_stats_t* st) {


  float x0_f[IN_DIM];
  x0_f[0] = T / 35.0f;
  x0_f[1] = H / 100.0f;

  // Quantize input ; float to int
  int16_t x0_q[IN_DIM];
  for (int i = 0; i < IN_DIM; i++) x0_q[i] = quant_f_to_i16(x0_f[i], A0_S);

  // -------------------------------
  // Layer 1 (2->16) with input pad 2->4
  // -------------------------------
  const int L1_IN_PAD = round_up4(IN_DIM); // 4

  int16_t x0_q_pad[4];
  pad_vec_i16(x0_q, IN_DIM, x0_q_pad, L1_IN_PAD);

  int16_t W1_q_pad[4 * 16];
  pad_mat_i16(W1_q, IN_DIM, L1_DIM, W1_q_pad, L1_IN_PAD, L1_DIM);

  // A1 is 4x4: row0 = x0_q_pad
  int16_t A1[4 * 4] = {0};
  for (int c = 0; c < 4; c++) A1[0*4 + c] = x0_q_pad[c];

  int32_t C1[4 * 16];
  cfs_rc_t rc = accel_gemm_i16(A1, 4, 4, W1_q_pad, 16, C1);
  if (rc != CFS_OK) { if (st) st->accel_timeouts++; return -1; }

  int32_t z1_q[16];
  for (int j = 0; j < 16; j++) z1_q[j] = C1[0*16 + j];

  LOGI("L1 GEMM: M=4 K=4 N=16 (x padded 2->4)\n");
  LOGD("L1 z1_q sample (first 8):\n");
  for (int j = 0; j < 8; j++) LOGD("  z1_q[%d]=%d\n", j, (long)z1_q[j]);

  int16_t a1_q[16];
  for (int j = 0; j < L1_DIM; j++) {
    int32_t bq = bias_f_to_i32(b1[j], A0_S, s1);
    int32_t zq = z1_q[j] + bq;
    zq = relu_i32(zq);
    int16_t out = requant_i32_to_i16(zq, A0_S, s1, A1_S);
    a1_q[j] = out;
    if (st && (out == 32767 || out == -32768)) st->a1_sat++;
  }

  // -------------------------------
  // Layer 2 (16->16)
  // -------------------------------
  int16_t A2[4 * 16] = {0};
  for (int c = 0; c < 16; c++) A2[0*16 + c] = a1_q[c];

  int32_t C2[4 * 16];
  rc = accel_gemm_i16(A2, 4, 16, W2_q, 16, C2);
  if (rc != CFS_OK) { if (st) st->accel_timeouts++; return -1; }

  int32_t z2_q[16];
  for (int j = 0; j < 16; j++) z2_q[j] = C2[0*16 + j];

  int32_t max_abs_diff2 = 0;
#if NN_ENABLE_CPU_CHECK
  for (int j = 0; j < 16; j++) {
    int32_t acc_cpu = 0;
    for (int i = 0; i < 16; i++) {
      acc_cpu += (int32_t)a1_q[i] * (int32_t)W2_q[i*16 + j];
    }
    int32_t diff = z2_q[j] - acc_cpu;
    int32_t ad = i32_abs(diff);
    if (ad > max_abs_diff2) max_abs_diff2 = ad;

    if (j < 3 && LOG_LEVEL >= LOG_DEBUG) {
      LOGD("L2 j=%d accel=%d cpu=%d diff=%d\n", j, (long)z2_q[j], (long)acc_cpu, (long)diff);
    }
  }
#endif

  if (st && max_abs_diff2 > st->max_abs_diff_l2) st->max_abs_diff_l2 = max_abs_diff2;
  LOGI("L2 GEMM: M=4 K=16 N=16  accel-vs-cpu MAX|diff|=%d\n", (long)max_abs_diff2);

  int16_t a2_q[16];
  for (int j = 0; j < L2_DIM; j++) {
    int32_t bq = bias_f_to_i32(b2[j], A1_S, s2);
    int32_t zq = z2_q[j] + bq;
    zq = relu_i32(zq);
    int16_t out = requant_i32_to_i16(zq, A1_S, s2, A2_S);
    a2_q[j] = out;
    if (st && (out == 32767 || out == -32768)) st->a2_sat++;
  }

  // -------------------------------
  // Layer 3 (16->8)
  // -------------------------------
  int16_t A3[4 * 16] = {0};
  for (int c = 0; c < 16; c++) A3[0*16 + c] = a2_q[c];

  int32_t C3[4 * 8];
  rc = accel_gemm_i16(A3, 4, 16, W3_q, 8, C3);
  if (rc != CFS_OK) { if (st) st->accel_timeouts++; return -1; }

  int32_t z3_q[8];
  for (int j = 0; j < 8; j++) z3_q[j] = C3[0*8 + j];

  int32_t max_abs_diff3 = 0;
#if NN_ENABLE_CPU_CHECK
  for (int j = 0; j < 8; j++) {
    int32_t acc_cpu = 0;
    for (int i = 0; i < 16; i++) {
      acc_cpu += (int32_t)a2_q[i] * (int32_t)W3_q[i*8 + j];
    }
    int32_t diff = z3_q[j] - acc_cpu;
    int32_t ad = i32_abs(diff);
    if (ad > max_abs_diff3) max_abs_diff3 = ad;

    if (LOG_LEVEL >= LOG_DEBUG) {
      LOGD("L3 j=%d accel=%d cpu=%d diff=%d\n", j, (long)z3_q[j], (long)acc_cpu, (long)diff);
    }
  }
#endif

  if (st && max_abs_diff3 > st->max_abs_diff_l3) st->max_abs_diff_l3 = max_abs_diff3;
  LOGI("L3 GEMM: M=4 K=16 N=8   accel-vs-cpu MAX|diff|=%d\n", (long)max_abs_diff3);

  int16_t a3_q[8];
  for (int j = 0; j < L3_DIM; j++) {
    int32_t bq = bias_f_to_i32(b3[j], A2_S, s3);
    int32_t zq = z3_q[j] + bq;
    zq = relu_i32(zq);
    int16_t out = requant_i32_to_i16(zq, A2_S, s3, A3_S);
    a3_q[j] = out;
    if (st && (out == 32767 || out == -32768)) st->a3_sat++;
  }

  // -------------------------------
  // Layer 4 (8->1) with output pad 1->4
  // -------------------------------
  const int L4_OUT_PAD = round_up4(OUT_DIM); // 4
  int16_t W4_q_pad[8 * 4];
  pad_mat_i16(W4_q, 8, 1, W4_q_pad, 8, 4);

  int16_t A4[4 * 8] = {0};
  for (int c = 0; c < 8; c++) A4[0*8 + c] = a3_q[c];

  int32_t C4[4 * 4];
  rc = accel_gemm_i16(A4, 4, 8, W4_q_pad, 4, C4);
  if (rc != CFS_OK) { if (st) st->accel_timeouts++; return -1; }

  int32_t z4_q_pad0 = C4[0*4 + 0];

  int32_t max_abs_diff4 = 0;
#if NN_ENABLE_CPU_CHECK
  int32_t acc4_cpu0 = 0;
  for (int i = 0; i < 8; i++) {
    acc4_cpu0 += (int32_t)a3_q[i] * (int32_t)W4_q_pad[i*4 + 0];
  }
  int32_t diff4 = z4_q_pad0 - acc4_cpu0;
  max_abs_diff4 = i32_abs(diff4);
  if (LOG_LEVEL >= LOG_DEBUG) {
    LOGD("L4 z4[0] accel=%d cpu=%d diff=%d\n", (long)z4_q_pad0, (long)acc4_cpu0, (long)diff4);
  }
#endif

  if (st && max_abs_diff4 > st->max_abs_diff_l4) st->max_abs_diff_l4 = max_abs_diff4;
  LOGI("L4 GEMM: M=4 K=8 N=4    accel-vs-cpu |diff(z4[0])|=%d\n", (long)max_abs_diff4);

  // Add bias then sigmoid
  int32_t b4q0 = bias_f_to_i32(b4[0], A3_S, s4);
  int32_t z4q0 = z4_q_pad0 + b4q0;

  float z4_f = (float)z4q0 * (A3_S * s4);
  float y0   = sigmoid_f(z4_f);

  // Update stats min/max
  if (st) {
    int16_t mn, mx;

    vec_minmax_i16(a1_q, 16, &mn, &mx);
    if (st->runs == 0) { st->a1_min = mn; st->a1_max = mx; }
    else { if (mn < st->a1_min) st->a1_min = mn; if (mx > st->a1_max) st->a1_max = mx; }

    vec_minmax_i16(a2_q, 16, &mn, &mx);
    if (st->runs == 0) { st->a2_min = mn; st->a2_max = mx; }
    else { if (mn < st->a2_min) st->a2_min = mn; if (mx > st->a2_max) st->a2_max = mx; }

    vec_minmax_i16(a3_q, 8, &mn, &mx);
    if (st->runs == 0) { st->a3_min = mn; st->a3_max = mx; }
    else { if (mn < st->a3_min) st->a3_min = mn; if (mx > st->a3_max) st->a3_max = mx; }

    st->runs++;
  }


#if NN_VERBOSE_VECTORS
  if (LOG_LEVEL >= LOG_DEBUG) {
    LOGD("Activations (scaled like Phase0/1):\n");
    print_vec_i16_as_float_scaled("a1", a1_q, 16, 6, A1_S, 10000, "x1e-4");
    print_vec_i16_as_float_scaled("a2", a2_q, 16, 6, A2_S, 10000, "x1e-4");
    print_vec_i16_as_float_scaled("a3", a3_q,  8, 8, A3_S, 10000, "x1e-4");
    print_f_scaled("z4", z4_f, 10000, "x1e-4");
    print_f_scaled("sigmoid(z4)", y0, 100000, "x1e-5");
  }
#endif

  int cls = (y0 >= 0.5f) ? 1 : 0;
  *out_prob = y0;
  *out_cls  = cls;

  return 0;
}
