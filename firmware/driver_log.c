#include "driver_log.h"

int32_t float_to_scaled_int(float x, float scale) {
  if (x >= 0.0f) return (int32_t)(x * scale + 0.5f);
  else           return (int32_t)(x * scale - 0.5f);
}

void print_f_scaled(const char* name, float x, int32_t scale, const char* scale_tag) {
  int32_t xs = float_to_scaled_int(x, (float)scale);
  neorv32_uart0_printf("%s=%d (%s)\n", name, (int)xs, scale_tag);
}

void print_vec_i16_as_float_scaled(const char* name,
                                  const int16_t* v, int n, int max_print,
                                  float a_s,
                                  int32_t scale, const char* scale_tag) {
  neorv32_uart0_printf("%s (%s): [", name, scale_tag);
  int m = (n < max_print) ? n : max_print;
  for (int i = 0; i < m; i++) {
    float f = (float)v[i] * a_s;
    int32_t fs = float_to_scaled_int(f, (float)scale);
    neorv32_uart0_printf("%d", (int)fs);
    if (i != m-1) neorv32_uart0_printf(", ");
  }
  if (n > m) neorv32_uart0_printf(", ...");
  neorv32_uart0_printf("]\n");
}

void print_vec_i32_as_float_scaled(const char* name,
                                  const int32_t* v, int n, int max_print,
                                  float z_s,
                                  int32_t scale, const char* scale_tag) {
  neorv32_uart0_printf("%s (%s): [", name, scale_tag);
  int m = (n < max_print) ? n : max_print;
  for (int i = 0; i < m; i++) {
    float f = (float)v[i] * z_s;
    int32_t fs = float_to_scaled_int(f, (float)scale);
    neorv32_uart0_printf("%d", (int)fs);
    if (i != m-1) neorv32_uart0_printf(", ");
  }
  if (n > m) neorv32_uart0_printf(", ...");
  neorv32_uart0_printf("]\n");
}
