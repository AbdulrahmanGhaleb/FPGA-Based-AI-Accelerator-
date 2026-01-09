#pragma once
#include <stdint.h>
#include <neorv32.h>

typedef enum {
  LOG_ERROR = 0, //Something is wrong and likely prevents correct operation.
  LOG_WARN  = 1, //Something unusual happened but the program can continue.
  LOG_INFO  = 2, //Normal high-level messages 
  LOG_DEBUG = 3 //Very detailed internal information for development only.
} log_level_t;

// Compile-time default
#ifndef LOG_LEVEL 
#define LOG_LEVEL LOG_INFO 
#endif

#define LOG_PRINTF(lvl, fmt, ...) do { \
  if ((lvl) <= LOG_LEVEL) neorv32_uart0_printf(fmt, ##__VA_ARGS__); \
} while (0)

#define LOGE(fmt, ...) LOG_PRINTF(LOG_ERROR, "[ERR] " fmt, ##__VA_ARGS__)
#define LOGW(fmt, ...) LOG_PRINTF(LOG_WARN,  "[WRN] " fmt, ##__VA_ARGS__)
#define LOGI(fmt, ...) LOG_PRINTF(LOG_INFO,  "[INF] " fmt, ##__VA_ARGS__)
#define LOGD(fmt, ...) LOG_PRINTF(LOG_DEBUG, "[DBG] " fmt, ##__VA_ARGS__)

#ifndef LOG_PERF
#define LOG_PERF 1
#endif

#define LOGP(fmt, ...) do { \
  if (LOG_PERF) neorv32_uart0_printf("[PERF] " fmt, ##__VA_ARGS__); \
} while (0)

//scaled-print helpers 
int32_t float_to_scaled_int(float x, float scale);
void    print_f_scaled(const char* name, float x, int32_t scale, const char* scale_tag);

void print_vec_i16_as_float_scaled(const char* name,
                                  const int16_t* v, int n, int max_print,
                                  float a_s,
                                  int32_t scale, const char* scale_tag);

void print_vec_i32_as_float_scaled(const char* name,
                                  const int32_t* v, int n, int max_print,
                                  float z_s,
                                  int32_t scale, const char* scale_tag);
