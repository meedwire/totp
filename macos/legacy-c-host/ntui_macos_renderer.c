#include "ntui_macos_renderer.h"

#include <ctype.h>
#include <dlfcn.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define NTUI_VALUE_NULL 0x0aU
#define NTUI_VALUE_NAN 0x22U
#define NTUI_VALUE_POS_INFINITY 0x2aU
#define NTUI_VALUE_NEG_INFINITY 0x32U
#define NTUI_VALUE_TAG_MASK 0x7U
#define NTUI_VALUE_INT_TAG 0x1U
#define NTUI_VALUE_REF_TAG 0x0U
#define NTUI_HEAP_KIND_NUMBER 6U

typedef uintptr_t NtuiValue;
typedef void (*NtuiMainFn)(void);
typedef NtuiValue (*NtuiFn0)(NtuiValue env);
typedef NtuiValue (*NtuiFn1)(NtuiValue env, NtuiValue arg0);
typedef NtuiValue (*NtuiFn2)(NtuiValue env, NtuiValue arg0, NtuiValue arg1);
typedef NtuiValue (*NtuiFn3)(NtuiValue env, NtuiValue arg0, NtuiValue arg1, NtuiValue arg2);
typedef NtuiValue (*NtuiFn5)(
    NtuiValue env,
    NtuiValue arg0,
    NtuiValue arg1,
    NtuiValue arg2,
    NtuiValue arg3,
    NtuiValue arg4);
typedef uint64_t (*NtuiGcCollectFn)(void);
typedef uint64_t (*NtuiGcCollectAutoFn)(const char *reason);

int ntui_macos_metal_register_font_asset(
    const char *resource_path,
    const char *family,
    const char *asset_path,
    int weight,
    const char *style);

typedef struct NtuiMacosTextRenderOptions {
  int line_index;
  int run_index;
  double letter_spacing;
  double word_spacing;
  double text_decoration_thickness;
  double text_underline_offset;
  double text_indent;
  const char *text_decoration_line;
  const char *text_decoration_style;
  const char *text_decoration_color;
  const char *text_underline_position;
  const char *text_shadow;
  const char *direction;
  const char *writing_mode;
} NtuiMacosTextRenderOptions;

typedef struct NtuiNumberObject {
  uint64_t kind;
  uint64_t flags;
  uint64_t shape;
  uint64_t slots;
  double value;
} NtuiNumberObject;

typedef struct NtuiMacosRuntime {
  void *handle;
  int main_called;
  int initialized;
  NtuiMainFn main_fn;
  NtuiFn0 init;
  NtuiFn3 render_frame;
  NtuiFn5 handle_touch;
  NtuiFn1 command_kind;
  NtuiFn1 command_x;
  NtuiFn1 command_y;
  NtuiFn1 command_width;
  NtuiFn1 command_height;
  NtuiFn1 command_font_size;
  NtuiFn1 command_baseline_offset;
  NtuiFn1 command_box_width;
  NtuiFn1 command_line_height;
  NtuiFn1 command_font_weight;
  NtuiFn1 command_border_width;
  NtuiFn1 command_border_radius;
  NtuiFn1 command_opacity;
  NtuiFn0 font_asset_count;
  NtuiFn1 font_asset_weight;
  NtuiFn1 font_asset_family_length;
  NtuiFn2 font_asset_family_char_code;
  NtuiFn1 font_asset_path_length;
  NtuiFn2 font_asset_path_char_code;
  NtuiFn1 font_asset_style_length;
  NtuiFn2 font_asset_style_char_code;
  NtuiFn0 command_text_transport_version;
  NtuiFn1 command_line_index;
  NtuiFn1 command_run_index;
  NtuiFn1 command_letter_spacing;
  NtuiFn1 command_word_spacing;
  NtuiFn1 command_text_decoration_thickness;
  NtuiFn1 command_text_underline_offset;
  NtuiFn1 command_text_indent;
  NtuiFn1 command_color_length;
  NtuiFn2 command_color_char_code;
  NtuiFn1 command_text_length;
  NtuiFn2 command_text_char_code;
  NtuiFn1 command_text_align_length;
  NtuiFn2 command_text_align_char_code;
  NtuiFn1 command_font_family_length;
  NtuiFn2 command_font_family_char_code;
  NtuiFn1 command_font_style_length;
  NtuiFn2 command_font_style_char_code;
  NtuiFn1 command_text_decoration_line_length;
  NtuiFn2 command_text_decoration_line_char_code;
  NtuiFn1 command_text_decoration_style_length;
  NtuiFn2 command_text_decoration_style_char_code;
  NtuiFn1 command_text_decoration_color_length;
  NtuiFn2 command_text_decoration_color_char_code;
  NtuiFn1 command_text_underline_position_length;
  NtuiFn2 command_text_underline_position_char_code;
  NtuiFn1 command_text_shadow_length;
  NtuiFn2 command_text_shadow_char_code;
  NtuiFn1 command_direction_length;
  NtuiFn2 command_direction_char_code;
  NtuiFn1 command_writing_mode_length;
  NtuiFn2 command_writing_mode_char_code;
  NtuiFn1 command_border_color_length;
  NtuiFn2 command_border_color_char_code;
  NtuiGcCollectFn gc_collect;
  NtuiGcCollectAutoFn gc_collect_auto_if_needed;
  const uint64_t *memory_snapshot_allocations;
  const uint64_t *memory_snapshot_bytes;
  const uint64_t *memory_snapshot_live_allocations;
  const uint64_t *memory_snapshot_live_bytes;
  const uint64_t *memory_snapshot_heap_allocations;
  const uint64_t *memory_snapshot_heap_bytes;
  const uint64_t *memory_snapshot_raw_allocations;
  const uint64_t *memory_snapshot_raw_bytes;
  const uint64_t *gc_cycles;
  const uint64_t *gc_collected_bytes;
} NtuiMacosRuntime;

int ntui_macos_metal_begin_frame(NtuiMacosView *view, int drawable_width, int drawable_height);
int ntui_macos_metal_draw_rect(double x, double y, double width, double height, NtuiMacosColor color);
int ntui_macos_metal_draw_box(
    double x,
    double y,
    double width,
    double height,
    double border_width,
    double border_radius,
    NtuiMacosColor fill_color,
    NtuiMacosColor border_color);
int ntui_macos_metal_draw_text(
    const char *text,
    double x,
    double baseline_y,
    double box_width,
    double font_size,
    double line_height,
    double baseline_offset,
    int font_weight,
    const char *text_align,
    const char *font_family,
    const char *font_style,
    NtuiMacosColor color,
    const NtuiMacosTextRenderOptions *options);
int ntui_macos_metal_end_frame(void);
void ntui_macos_metal_log_renderer_memory(void);

static NtuiMacosRuntime g_ntui_runtime;
static char g_ntui_library_path[PATH_MAX];
static char g_ntui_resource_path[PATH_MAX];
static char g_ntui_last_error[512];
static double g_ntui_opacity_stack[32];
static int g_ntui_opacity_stack_size = 0;
static double g_ntui_current_opacity = 1.0;

static int ntui_macos_hex_digit(char ch) {
  if (ch >= '0' && ch <= '9') return ch - '0';
  if (ch >= 'a' && ch <= 'f') return 10 + ch - 'a';
  if (ch >= 'A' && ch <= 'F') return 10 + ch - 'A';
  return -1;
}

static int ntui_macos_hex_pair(const char *text) {
  const int hi = ntui_macos_hex_digit(text[0]);
  const int lo = ntui_macos_hex_digit(text[1]);
  if (hi < 0 || lo < 0) return -1;
  return (hi << 4) | lo;
}

static int ntui_macos_hex_single(char ch) {
  const int value = ntui_macos_hex_digit(ch);
  if (value < 0) return -1;
  return (value << 4) | value;
}

NtuiMacosColor ntui_macos_parse_color(const char *text, NtuiMacosColor fallback) {
  if (text == NULL) return fallback;
  while (isspace((unsigned char)*text)) text += 1;
  if (strcmp(text, "transparent") == 0) {
    return (NtuiMacosColor){.r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0};
  }
  if (strcmp(text, "white") == 0) {
    return (NtuiMacosColor){.r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0};
  }
  if (strcmp(text, "black") == 0) {
    return (NtuiMacosColor){.r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0};
  }
  if (*text != '#') return fallback;
  text += 1;

  const size_t length = strlen(text);
  int r = -1;
  int g = -1;
  int b = -1;
  int a = 255;

  if (length == 3 || length == 4) {
    r = ntui_macos_hex_single(text[0]);
    g = ntui_macos_hex_single(text[1]);
    b = ntui_macos_hex_single(text[2]);
    if (length == 4) a = ntui_macos_hex_single(text[3]);
  } else if (length == 6 || length == 8) {
    r = ntui_macos_hex_pair(text);
    g = ntui_macos_hex_pair(text + 2);
    b = ntui_macos_hex_pair(text + 4);
    if (length == 8) a = ntui_macos_hex_pair(text + 6);
  }

  if (r < 0 || g < 0 || b < 0 || a < 0) return fallback;
  NtuiMacosColor out = {
      .r = (double)r / 255.0,
      .g = (double)g / 255.0,
      .b = (double)b / 255.0,
      .a = (double)a / 255.0,
  };
  return out;
}

static int ntui_macos_env_logs_enabled(const char *name) {
  const char *value = getenv(name);
  return value != NULL && value[0] != 0 && strcmp(value, "0") != 0;
}

static int ntui_macos_render_logs_enabled(void) {
  return ntui_macos_env_logs_enabled("NTUI_MACOS_RENDER_LOGS");
}

static int ntui_macos_memory_logs_enabled(void) {
  return ntui_macos_env_logs_enabled("NTUI_MACOS_MEMORY_LOGS");
}

static int ntui_macos_memory_or_render_logs_enabled(void) {
  return ntui_macos_memory_logs_enabled() || ntui_macos_render_logs_enabled();
}

static uint64_t ntui_macos_read_counter(const uint64_t *counter) {
  return counter == NULL ? 0U : *counter;
}

static void ntui_macos_log_ts_memory_counters(const char *reason) {
  if (!ntui_macos_memory_or_render_logs_enabled()) return;
  fprintf(
      stderr,
      "ts_heap_memory platform=macos reason=%s allocations=%llu bytes=%llu liveAllocations=%llu liveBytes=%llu heapAllocations=%llu heapBytes=%llu rawAllocations=%llu rawBytes=%llu gcCycles=%llu gcCollectedBytes=%llu\n",
      reason == NULL ? "unknown" : reason,
      (unsigned long long)ntui_macos_read_counter(g_ntui_runtime.memory_snapshot_allocations),
      (unsigned long long)ntui_macos_read_counter(g_ntui_runtime.memory_snapshot_bytes),
      (unsigned long long)ntui_macos_read_counter(g_ntui_runtime.memory_snapshot_live_allocations),
      (unsigned long long)ntui_macos_read_counter(g_ntui_runtime.memory_snapshot_live_bytes),
      (unsigned long long)ntui_macos_read_counter(g_ntui_runtime.memory_snapshot_heap_allocations),
      (unsigned long long)ntui_macos_read_counter(g_ntui_runtime.memory_snapshot_heap_bytes),
      (unsigned long long)ntui_macos_read_counter(g_ntui_runtime.memory_snapshot_raw_allocations),
      (unsigned long long)ntui_macos_read_counter(g_ntui_runtime.memory_snapshot_raw_bytes),
      (unsigned long long)ntui_macos_read_counter(g_ntui_runtime.gc_cycles),
      (unsigned long long)ntui_macos_read_counter(g_ntui_runtime.gc_collected_bytes));
}

static void ntui_macos_collect_ts_gc_auto(const char *reason) {
  if (g_ntui_runtime.gc_collect_auto_if_needed == NULL) return;
  const int has_live_bytes = g_ntui_runtime.memory_snapshot_live_bytes != NULL;
  const uint64_t live_before = ntui_macos_read_counter(g_ntui_runtime.memory_snapshot_live_bytes);
  const uint64_t collected = g_ntui_runtime.gc_collect_auto_if_needed(reason);
  const uint64_t live_after = ntui_macos_read_counter(g_ntui_runtime.memory_snapshot_live_bytes);
  if (has_live_bytes && ntui_macos_memory_or_render_logs_enabled()) {
    fprintf(
        stderr,
        "ts_gc_auto platform=macos reason=%s collectedBytes=%llu liveBytesBefore=%llu liveBytesAfter=%llu\n",
        reason == NULL ? "unknown" : reason,
        (unsigned long long)collected,
        (unsigned long long)live_before,
        (unsigned long long)live_after);
  }
}

static double ntui_macos_clamp_opacity(double value) {
  if (!isfinite(value)) return 1.0;
  if (value <= 0.0) return 0.0;
  if (value >= 1.0) return 1.0;
  return value;
}

static void ntui_macos_reset_opacity_stack(void) {
  g_ntui_opacity_stack_size = 0;
  g_ntui_current_opacity = 1.0;
}

static NtuiMacosColor ntui_macos_apply_current_opacity(NtuiMacosColor color) {
  color.a *= ntui_macos_clamp_opacity(g_ntui_current_opacity);
  return color;
}

static int ntui_macos_begin_opacity_layer(
    double x,
    double y,
    double width,
    double height,
    double opacity) {
  if (g_ntui_opacity_stack_size >= 32) return 0;
  const double clamped = ntui_macos_clamp_opacity(opacity);
  g_ntui_opacity_stack[g_ntui_opacity_stack_size] = g_ntui_current_opacity;
  g_ntui_opacity_stack_size += 1;
  g_ntui_current_opacity = ntui_macos_clamp_opacity(g_ntui_current_opacity * clamped);
  if (ntui_macos_render_logs_enabled()) {
    fprintf(
        stderr,
        "ntui_macos_renderer: opacity_layer begin x=%.2f y=%.2f width=%.2f height=%.2f opacity=%.3f effective=%.3f depth=%d\n",
        x,
        y,
        width,
        height,
        clamped,
        g_ntui_current_opacity,
        g_ntui_opacity_stack_size);
  }
  return 1;
}

static int ntui_macos_end_opacity_layer(void) {
  if (g_ntui_opacity_stack_size <= 0) {
    g_ntui_current_opacity = 1.0;
    if (ntui_macos_render_logs_enabled()) {
      fprintf(stderr, "ntui_macos_renderer: opacity_layer end underflow\n");
    }
    return 1;
  }
  g_ntui_opacity_stack_size -= 1;
  g_ntui_current_opacity = g_ntui_opacity_stack[g_ntui_opacity_stack_size];
  if (ntui_macos_render_logs_enabled()) {
    fprintf(
        stderr,
        "ntui_macos_renderer: opacity_layer end effective=%.3f depth=%d\n",
        g_ntui_current_opacity,
        g_ntui_opacity_stack_size);
  }
  return 1;
}

static void ntui_macos_set_error(const char *message) {
  if (message == NULL) message = "unknown renderer error";
  snprintf(g_ntui_last_error, sizeof(g_ntui_last_error), "%s", message);
}

static void ntui_macos_set_dlopen_error(const char *symbol) {
  const char *error = dlerror();
  if (error == NULL) error = "missing symbol";
  snprintf(
      g_ntui_last_error,
      sizeof(g_ntui_last_error),
      "%s: %s",
      symbol == NULL ? "runtime" : symbol,
      error);
}

static NtuiValue ntui_macos_box_int(int value) {
  return (((NtuiValue)(intptr_t)value) << 3U) | NTUI_VALUE_INT_TAG;
}

static int ntui_macos_value_is_int(NtuiValue value) {
  return (value & NTUI_VALUE_TAG_MASK) == NTUI_VALUE_INT_TAG;
}

static int ntui_macos_value_is_ref(NtuiValue value) {
  return value != 0U && (value & NTUI_VALUE_TAG_MASK) == NTUI_VALUE_REF_TAG;
}

static double ntui_macos_value_to_double(NtuiValue value) {
  if (ntui_macos_value_is_int(value)) {
    return (double)(((intptr_t)value) >> 3U);
  }
  if (ntui_macos_value_is_ref(value)) {
    const NtuiNumberObject *number = (const NtuiNumberObject *)(uintptr_t)value;
    if (number->kind == NTUI_HEAP_KIND_NUMBER) return number->value;
  }
  if (value == NTUI_VALUE_POS_INFINITY) return INFINITY;
  if (value == NTUI_VALUE_NEG_INFINITY) return -INFINITY;
  return NAN;
}

static int ntui_macos_value_to_int(NtuiValue value) {
  const double number = ntui_macos_value_to_double(value);
  if (!isfinite(number)) return 0;
  if (number > (double)INT_MAX) return INT_MAX;
  if (number < (double)INT_MIN) return INT_MIN;
  return (int)llround(number);
}

static void *ntui_macos_symbol(void *handle, const char *name) {
  dlerror();
  void *symbol = dlsym(handle, name);
  const char *error = dlerror();
  if (error != NULL || symbol == NULL) {
    ntui_macos_set_dlopen_error(name);
    return NULL;
  }
  return symbol;
}

static int ntui_macos_load_required_symbols(NtuiMacosRuntime *runtime) {
#define NTUI_LOAD_SYMBOL(field, type, symbol_name)             \
  do {                                                         \
    runtime->field = (type)ntui_macos_symbol(runtime->handle, symbol_name); \
    if (runtime->field == NULL) return 0;                      \
  } while (0)
#define NTUI_LOAD_OPTIONAL_SYMBOL(field, type, symbol_name) \
  do {                                                      \
    dlerror();                                              \
    runtime->field = (type)dlsym(runtime->handle, symbol_name); \
    dlerror();                                              \
  } while (0)
#define NTUI_LOAD_OPTIONAL_COUNTER(field, symbol_name)          \
  do {                                                          \
    dlerror();                                                  \
    runtime->field = (const uint64_t *)dlsym(runtime->handle, symbol_name); \
    if (runtime->field == NULL && (symbol_name)[0] == '_') {    \
      runtime->field = (const uint64_t *)dlsym(runtime->handle, (symbol_name) + 1); \
    }                                                           \
    dlerror();                                                  \
  } while (0)

  NTUI_LOAD_SYMBOL(main_fn, NtuiMainFn, "main");
  NTUI_LOAD_SYMBOL(init, NtuiFn0, "ntui_init");
  NTUI_LOAD_SYMBOL(render_frame, NtuiFn3, "ntui_render_frame");
  NTUI_LOAD_SYMBOL(handle_touch, NtuiFn5, "ntui_handle_touch");
  NTUI_LOAD_SYMBOL(command_kind, NtuiFn1, "ntui_command_kind");
  NTUI_LOAD_SYMBOL(command_x, NtuiFn1, "ntui_command_x");
  NTUI_LOAD_SYMBOL(command_y, NtuiFn1, "ntui_command_y");
  NTUI_LOAD_SYMBOL(command_width, NtuiFn1, "ntui_command_width");
  NTUI_LOAD_SYMBOL(command_height, NtuiFn1, "ntui_command_height");
  NTUI_LOAD_SYMBOL(command_font_size, NtuiFn1, "ntui_command_font_size");
  NTUI_LOAD_SYMBOL(command_baseline_offset, NtuiFn1, "ntui_command_baseline_offset");
  NTUI_LOAD_SYMBOL(command_box_width, NtuiFn1, "ntui_command_box_width");
  NTUI_LOAD_SYMBOL(command_line_height, NtuiFn1, "ntui_command_line_height");
  NTUI_LOAD_SYMBOL(command_font_weight, NtuiFn1, "ntui_command_font_weight");
  NTUI_LOAD_SYMBOL(command_border_width, NtuiFn1, "ntui_command_border_width");
  NTUI_LOAD_SYMBOL(command_border_radius, NtuiFn1, "ntui_command_border_radius");
  NTUI_LOAD_SYMBOL(command_opacity, NtuiFn1, "ntui_command_opacity");
  NTUI_LOAD_SYMBOL(command_color_length, NtuiFn1, "ntui_command_color_length");
  NTUI_LOAD_SYMBOL(command_color_char_code, NtuiFn2, "ntui_command_color_char_code");
  NTUI_LOAD_SYMBOL(command_text_length, NtuiFn1, "ntui_command_text_length");
  NTUI_LOAD_SYMBOL(command_text_char_code, NtuiFn2, "ntui_command_text_char_code");
  NTUI_LOAD_SYMBOL(command_text_align_length, NtuiFn1, "ntui_command_text_align_length");
  NTUI_LOAD_SYMBOL(command_text_align_char_code, NtuiFn2, "ntui_command_text_align_char_code");
  NTUI_LOAD_SYMBOL(command_font_family_length, NtuiFn1, "ntui_command_font_family_length");
  NTUI_LOAD_SYMBOL(command_font_family_char_code, NtuiFn2, "ntui_command_font_family_char_code");
  NTUI_LOAD_SYMBOL(command_font_style_length, NtuiFn1, "ntui_command_font_style_length");
  NTUI_LOAD_SYMBOL(command_font_style_char_code, NtuiFn2, "ntui_command_font_style_char_code");
  NTUI_LOAD_SYMBOL(command_border_color_length, NtuiFn1, "ntui_command_border_color_length");
  NTUI_LOAD_SYMBOL(command_border_color_char_code, NtuiFn2, "ntui_command_border_color_char_code");
  NTUI_LOAD_OPTIONAL_SYMBOL(font_asset_count, NtuiFn0, "ntui_font_asset_count");
  NTUI_LOAD_OPTIONAL_SYMBOL(font_asset_weight, NtuiFn1, "ntui_font_asset_weight");
  NTUI_LOAD_OPTIONAL_SYMBOL(font_asset_family_length, NtuiFn1, "ntui_font_asset_family_length");
  NTUI_LOAD_OPTIONAL_SYMBOL(font_asset_family_char_code, NtuiFn2, "ntui_font_asset_family_char_code");
  NTUI_LOAD_OPTIONAL_SYMBOL(font_asset_path_length, NtuiFn1, "ntui_font_asset_path_length");
  NTUI_LOAD_OPTIONAL_SYMBOL(font_asset_path_char_code, NtuiFn2, "ntui_font_asset_path_char_code");
  NTUI_LOAD_OPTIONAL_SYMBOL(font_asset_style_length, NtuiFn1, "ntui_font_asset_style_length");
  NTUI_LOAD_OPTIONAL_SYMBOL(font_asset_style_char_code, NtuiFn2, "ntui_font_asset_style_char_code");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_transport_version, NtuiFn0, "ntui_command_text_transport_version");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_line_index, NtuiFn1, "ntui_command_line_index");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_run_index, NtuiFn1, "ntui_command_run_index");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_letter_spacing, NtuiFn1, "ntui_command_letter_spacing");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_word_spacing, NtuiFn1, "ntui_command_word_spacing");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_decoration_thickness, NtuiFn1, "ntui_command_text_decoration_thickness");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_underline_offset, NtuiFn1, "ntui_command_text_underline_offset");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_indent, NtuiFn1, "ntui_command_text_indent");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_decoration_line_length, NtuiFn1, "ntui_command_text_decoration_line_length");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_decoration_line_char_code, NtuiFn2, "ntui_command_text_decoration_line_char_code");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_decoration_style_length, NtuiFn1, "ntui_command_text_decoration_style_length");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_decoration_style_char_code, NtuiFn2, "ntui_command_text_decoration_style_char_code");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_decoration_color_length, NtuiFn1, "ntui_command_text_decoration_color_length");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_decoration_color_char_code, NtuiFn2, "ntui_command_text_decoration_color_char_code");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_underline_position_length, NtuiFn1, "ntui_command_text_underline_position_length");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_underline_position_char_code, NtuiFn2, "ntui_command_text_underline_position_char_code");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_shadow_length, NtuiFn1, "ntui_command_text_shadow_length");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_text_shadow_char_code, NtuiFn2, "ntui_command_text_shadow_char_code");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_direction_length, NtuiFn1, "ntui_command_direction_length");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_direction_char_code, NtuiFn2, "ntui_command_direction_char_code");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_writing_mode_length, NtuiFn1, "ntui_command_writing_mode_length");
  NTUI_LOAD_OPTIONAL_SYMBOL(command_writing_mode_char_code, NtuiFn2, "ntui_command_writing_mode_char_code");
  NTUI_LOAD_OPTIONAL_SYMBOL(gc_collect, NtuiGcCollectFn, "ntsc_gc_collect");
  NTUI_LOAD_OPTIONAL_SYMBOL(gc_collect_auto_if_needed, NtuiGcCollectAutoFn, "ntsc_gc_collect_auto_if_needed");
  NTUI_LOAD_OPTIONAL_COUNTER(memory_snapshot_allocations, "_ntsc_memory_snapshot_allocations");
  NTUI_LOAD_OPTIONAL_COUNTER(memory_snapshot_bytes, "_ntsc_memory_snapshot_bytes");
  NTUI_LOAD_OPTIONAL_COUNTER(memory_snapshot_live_allocations, "_ntsc_memory_snapshot_live_allocations");
  NTUI_LOAD_OPTIONAL_COUNTER(memory_snapshot_live_bytes, "_ntsc_memory_snapshot_live_bytes");
  NTUI_LOAD_OPTIONAL_COUNTER(memory_snapshot_heap_allocations, "_ntsc_memory_snapshot_heap_allocations");
  NTUI_LOAD_OPTIONAL_COUNTER(memory_snapshot_heap_bytes, "_ntsc_memory_snapshot_heap_bytes");
  NTUI_LOAD_OPTIONAL_COUNTER(memory_snapshot_raw_allocations, "_ntsc_memory_snapshot_raw_allocations");
  NTUI_LOAD_OPTIONAL_COUNTER(memory_snapshot_raw_bytes, "_ntsc_memory_snapshot_raw_bytes");
  NTUI_LOAD_OPTIONAL_COUNTER(gc_cycles, "_ntsc_gc_cycles");
  NTUI_LOAD_OPTIONAL_COUNTER(gc_collected_bytes, "_ntsc_gc_collected_bytes");

#undef NTUI_LOAD_OPTIONAL_COUNTER
#undef NTUI_LOAD_OPTIONAL_SYMBOL
#undef NTUI_LOAD_SYMBOL
  return 1;
}

static char *ntui_macos_read_string(NtuiFn1 length_fn, NtuiFn2 char_code_fn, NtuiValue index);

static void ntui_macos_register_font_assets(void) {
  if (g_ntui_runtime.font_asset_count == NULL ||
      g_ntui_runtime.font_asset_weight == NULL ||
      g_ntui_runtime.font_asset_family_length == NULL ||
      g_ntui_runtime.font_asset_family_char_code == NULL ||
      g_ntui_runtime.font_asset_path_length == NULL ||
      g_ntui_runtime.font_asset_path_char_code == NULL ||
      g_ntui_runtime.font_asset_style_length == NULL ||
      g_ntui_runtime.font_asset_style_char_code == NULL) {
    return;
  }

  const int count = ntui_macos_value_to_int(g_ntui_runtime.font_asset_count((NtuiValue)NTUI_VALUE_NULL));
  for (int asset_index = 0; asset_index < count; asset_index += 1) {
    const NtuiValue index = ntui_macos_box_int(asset_index);
    char *family = ntui_macos_read_string(
        g_ntui_runtime.font_asset_family_length,
        g_ntui_runtime.font_asset_family_char_code,
        index);
    char *path = ntui_macos_read_string(
        g_ntui_runtime.font_asset_path_length,
        g_ntui_runtime.font_asset_path_char_code,
        index);
    char *style = ntui_macos_read_string(
        g_ntui_runtime.font_asset_style_length,
        g_ntui_runtime.font_asset_style_char_code,
        index);
    const int weight = ntui_macos_value_to_int(
        g_ntui_runtime.font_asset_weight((NtuiValue)NTUI_VALUE_NULL, index));
    ntui_macos_metal_register_font_asset(g_ntui_resource_path, family, path, weight, style);
    free(family);
    free(path);
    free(style);
  }
}

static int ntui_macos_ensure_runtime(void) {
  if (g_ntui_runtime.initialized) return 1;
  if (g_ntui_runtime.handle == NULL) {
    if (g_ntui_library_path[0] == 0) {
      ntui_macos_set_error("runtime library path is not configured");
      return 0;
    }
    g_ntui_runtime.handle = dlopen(g_ntui_library_path, RTLD_NOW | RTLD_LOCAL);
    if (g_ntui_runtime.handle == NULL) {
      ntui_macos_set_dlopen_error(g_ntui_library_path);
      return 0;
    }
    if (!ntui_macos_load_required_symbols(&g_ntui_runtime)) return 0;
  }
  if (!g_ntui_runtime.main_called) {
    g_ntui_runtime.main_fn();
    g_ntui_runtime.main_called = 1;
  }
  g_ntui_runtime.init((NtuiValue)NTUI_VALUE_NULL);
  ntui_macos_register_font_assets();
  g_ntui_runtime.initialized = 1;
  return 1;
}

typedef struct NtuiUtf8Builder {
  char *data;
  size_t length;
  size_t capacity;
  uint32_t pending_high_surrogate;
} NtuiUtf8Builder;

static int ntui_macos_utf16_is_high_surrogate(uint32_t code_unit) {
  return code_unit >= 0xd800U && code_unit <= 0xdbffU;
}

static int ntui_macos_utf16_is_low_surrogate(uint32_t code_unit) {
  return code_unit >= 0xdc00U && code_unit <= 0xdfffU;
}

static uint32_t ntui_macos_utf16_surrogate_pair_to_codepoint(uint32_t high, uint32_t low) {
  return 0x10000U + (((high - 0xd800U) << 10U) | (low - 0xdc00U));
}

static int ntui_macos_utf8_append_codepoint(NtuiUtf8Builder *builder, uint32_t codepoint) {
  if (builder == NULL || builder->data == NULL) return 0;
  if (codepoint > 0x10ffffU || (codepoint >= 0xd800U && codepoint <= 0xdfffU)) {
    codepoint = 0xfffdU;
  }

  char bytes[4];
  size_t count = 0;
  if (codepoint <= 0x7fU) {
    bytes[count++] = (char)codepoint;
  } else if (codepoint <= 0x7ffU) {
    bytes[count++] = (char)(0xc0U | ((codepoint >> 6U) & 0x1fU));
    bytes[count++] = (char)(0x80U | (codepoint & 0x3fU));
  } else if (codepoint <= 0xffffU) {
    bytes[count++] = (char)(0xe0U | ((codepoint >> 12U) & 0x0fU));
    bytes[count++] = (char)(0x80U | ((codepoint >> 6U) & 0x3fU));
    bytes[count++] = (char)(0x80U | (codepoint & 0x3fU));
  } else {
    bytes[count++] = (char)(0xf0U | ((codepoint >> 18U) & 0x07U));
    bytes[count++] = (char)(0x80U | ((codepoint >> 12U) & 0x3fU));
    bytes[count++] = (char)(0x80U | ((codepoint >> 6U) & 0x3fU));
    bytes[count++] = (char)(0x80U | (codepoint & 0x3fU));
  }

  if (builder->length + count + 1U > builder->capacity) return 0;
  memcpy(builder->data + builder->length, bytes, count);
  builder->length += count;
  return 1;
}

static int ntui_macos_utf8_flush_surrogate(NtuiUtf8Builder *builder) {
  if (builder == NULL || builder->pending_high_surrogate == 0U) return 1;
  builder->pending_high_surrogate = 0U;
  return ntui_macos_utf8_append_codepoint(builder, 0xfffdU);
}

static int ntui_macos_utf8_append_code_unit(NtuiUtf8Builder *builder, int code_unit) {
  if (builder == NULL || code_unit < 0 || code_unit > 0xffff) {
    return ntui_macos_utf8_flush_surrogate(builder) &&
           ntui_macos_utf8_append_codepoint(builder, 0xfffdU);
  }

  const uint32_t unit = (uint32_t)code_unit;
  if (unit <= 0xffU) {
    if (!ntui_macos_utf8_flush_surrogate(builder)) return 0;
    if (builder->length + 2U > builder->capacity) return 0;
    builder->data[builder->length++] = (char)unit;
    builder->data[builder->length] = 0;
    return 1;
  }

  if (builder->pending_high_surrogate != 0U) {
    const uint32_t high = builder->pending_high_surrogate;
    if (ntui_macos_utf16_is_low_surrogate(unit)) {
      builder->pending_high_surrogate = 0U;
      return ntui_macos_utf8_append_codepoint(
          builder,
          ntui_macos_utf16_surrogate_pair_to_codepoint(high, unit));
    }
    if (!ntui_macos_utf8_append_codepoint(builder, 0xfffdU)) return 0;
    builder->pending_high_surrogate = 0U;
  }

  if (ntui_macos_utf16_is_high_surrogate(unit)) {
    builder->pending_high_surrogate = unit;
    return 1;
  }
  if (ntui_macos_utf16_is_low_surrogate(unit)) {
    return ntui_macos_utf8_append_codepoint(builder, 0xfffdU);
  }
  return ntui_macos_utf8_append_codepoint(builder, unit);
}

static char *ntui_macos_read_string(
    NtuiFn1 length_fn,
    NtuiFn2 char_code_fn,
    NtuiValue index) {
  if (length_fn == NULL || char_code_fn == NULL) return NULL;
  const int utf16_length = ntui_macos_value_to_int(length_fn((NtuiValue)NTUI_VALUE_NULL, index));
  if (utf16_length <= 0) {
    char *empty = (char *)malloc(1U);
    if (empty != NULL) empty[0] = 0;
    return empty;
  }

  NtuiUtf8Builder builder = {
      .data = (char *)malloc(((size_t)utf16_length * 4U) + 1U),
      .length = 0U,
      .capacity = ((size_t)utf16_length * 4U) + 1U,
      .pending_high_surrogate = 0U,
  };
  if (builder.data == NULL) return NULL;
  builder.data[0] = 0;

  for (int offset = 0; offset < utf16_length; offset += 1) {
    const NtuiValue code_value = char_code_fn(
        (NtuiValue)NTUI_VALUE_NULL,
        index,
        ntui_macos_box_int(offset));
    if (!ntui_macos_utf8_append_code_unit(&builder, ntui_macos_value_to_int(code_value))) {
      free(builder.data);
      return NULL;
    }
  }
  if (!ntui_macos_utf8_flush_surrogate(&builder)) {
    free(builder.data);
    return NULL;
  }
  builder.data[builder.length] = 0;
  return builder.data;
}

static int ntui_macos_read_optional_int(NtuiFn1 fn, NtuiValue index, int fallback) {
  if (fn == NULL) return fallback;
  return ntui_macos_value_to_int(fn((NtuiValue)NTUI_VALUE_NULL, index));
}

static double ntui_macos_read_optional_double(NtuiFn1 fn, NtuiValue index, double fallback) {
  if (fn == NULL) return fallback;
  const double value = ntui_macos_value_to_double(fn((NtuiValue)NTUI_VALUE_NULL, index));
  return isfinite(value) ? value : fallback;
}

static char *ntui_macos_read_optional_string(
    NtuiFn1 length_fn,
    NtuiFn2 char_code_fn,
    NtuiValue index,
    const char *fallback) {
  if (length_fn == NULL || char_code_fn == NULL) {
    const char *safe = fallback == NULL ? "" : fallback;
    char *copy = (char *)malloc(strlen(safe) + 1U);
    if (copy != NULL) strcpy(copy, safe);
    return copy;
  }
  return ntui_macos_read_string(length_fn, char_code_fn, index);
}

static int ntui_macos_normalize_scale_millis(int scale_millis) {
  if (scale_millis < 500 || scale_millis > 8500) return 1000;
  return scale_millis;
}

static double ntui_macos_scale_px(double value, double scale) {
  if (!isfinite(value)) return 0.0;
  return value * scale;
}

static int ntui_macos_is_valid_rect(double x, double y, double width, double height) {
  return isfinite(x) && isfinite(y) && isfinite(width) && isfinite(height) &&
         width > 0.0 && height > 0.0;
}

void ntui_macos_renderer_set_library_path(const char *path) {
  if (path == NULL) {
    g_ntui_library_path[0] = 0;
    return;
  }
  snprintf(g_ntui_library_path, sizeof(g_ntui_library_path), "%s", path);
}

void ntui_macos_renderer_set_resource_path(const char *path) {
  if (path == NULL) {
    g_ntui_resource_path[0] = 0;
    return;
  }
  snprintf(g_ntui_resource_path, sizeof(g_ntui_resource_path), "%s", path);
  ntui_macos_metal_register_font_asset(g_ntui_resource_path, "Roboto", "fonts/Roboto-Regular.ttf", 400, "normal");
}

const char *ntui_macos_renderer_last_error(void) {
  return g_ntui_last_error[0] == 0 ? NULL : g_ntui_last_error;
}

int ntui_macos_renderer_render(
    NtuiMacosView *view,
    int drawable_width,
    int drawable_height,
    int scale_millis) {
  if (view == NULL || drawable_width <= 0 || drawable_height <= 0) return 0;
  if (!ntui_macos_ensure_runtime()) return 0;

  const int normalized_scale_millis = ntui_macos_normalize_scale_millis(scale_millis);
  const double scale = (double)normalized_scale_millis / 1000.0;
  const int layout_width = (int)fmax(1.0, floor(((double)drawable_width / scale) + 0.5));
  const int layout_height = (int)fmax(1.0, floor(((double)drawable_height / scale) + 0.5));
  const int count = ntui_macos_value_to_int(g_ntui_runtime.render_frame(
      (NtuiValue)NTUI_VALUE_NULL,
      ntui_macos_box_int(layout_width),
      ntui_macos_box_int(layout_height),
      ntui_macos_box_int(1)));

  if (!ntui_macos_metal_begin_frame(view, drawable_width, drawable_height)) return 0;
  ntui_macos_reset_opacity_stack();

  for (int command_index = 0; command_index < count; command_index += 1) {
    const NtuiValue index = ntui_macos_box_int(command_index);
    const int kind = ntui_macos_value_to_int(g_ntui_runtime.command_kind((NtuiValue)NTUI_VALUE_NULL, index));
    const double x = ntui_macos_scale_px(
        ntui_macos_value_to_double(g_ntui_runtime.command_x((NtuiValue)NTUI_VALUE_NULL, index)),
        scale);
    const double y = ntui_macos_scale_px(
        ntui_macos_value_to_double(g_ntui_runtime.command_y((NtuiValue)NTUI_VALUE_NULL, index)),
        scale);
    const double width = ntui_macos_scale_px(
        ntui_macos_value_to_double(g_ntui_runtime.command_width((NtuiValue)NTUI_VALUE_NULL, index)),
        scale);
    const double height = ntui_macos_scale_px(
        ntui_macos_value_to_double(g_ntui_runtime.command_height((NtuiValue)NTUI_VALUE_NULL, index)),
        scale);

    if (kind == 9) {
      const double opacity = ntui_macos_value_to_double(
          g_ntui_runtime.command_opacity((NtuiValue)NTUI_VALUE_NULL, index));
      ntui_macos_begin_opacity_layer(x, y, width, height, opacity);
      continue;
    }

    if (kind == 10) {
      ntui_macos_end_opacity_layer();
      continue;
    }

    if (kind == 1) {
      char *color_text = ntui_macos_read_string(
          g_ntui_runtime.command_color_length,
          g_ntui_runtime.command_color_char_code,
          index);
      const NtuiMacosColor color = ntui_macos_apply_current_opacity(ntui_macos_parse_color(
          color_text,
          (NtuiMacosColor){.r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0}));
      if (ntui_macos_is_valid_rect(x, y, width, height)) {
        ntui_macos_metal_draw_rect(x, y, width, height, color);
      }
      free(color_text);
      continue;
    }

    if (kind == 3) {
      char *color_text = ntui_macos_read_string(
          g_ntui_runtime.command_color_length,
          g_ntui_runtime.command_color_char_code,
          index);
      char *border_color_text = ntui_macos_read_string(
          g_ntui_runtime.command_border_color_length,
          g_ntui_runtime.command_border_color_char_code,
          index);
      const NtuiMacosColor fill_color = ntui_macos_apply_current_opacity(ntui_macos_parse_color(
          color_text,
          (NtuiMacosColor){.r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0}));
      const NtuiMacosColor border_color = ntui_macos_apply_current_opacity(ntui_macos_parse_color(
          border_color_text,
          (NtuiMacosColor){.r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0}));
      const double border_width = ntui_macos_scale_px(
          ntui_macos_value_to_double(g_ntui_runtime.command_border_width((NtuiValue)NTUI_VALUE_NULL, index)),
          scale);
      const double border_radius = ntui_macos_scale_px(
          ntui_macos_value_to_double(g_ntui_runtime.command_border_radius((NtuiValue)NTUI_VALUE_NULL, index)),
          scale);
      if (ntui_macos_is_valid_rect(x, y, width, height)) {
        ntui_macos_metal_draw_box(
            x,
            y,
            width,
            height,
            border_width,
            border_radius,
            fill_color,
            border_color);
      }
      free(color_text);
      free(border_color_text);
      continue;
    }

    if (kind == 2) {
      char *text = ntui_macos_read_string(
          g_ntui_runtime.command_text_length,
          g_ntui_runtime.command_text_char_code,
          index);
      char *text_align = ntui_macos_read_string(
          g_ntui_runtime.command_text_align_length,
          g_ntui_runtime.command_text_align_char_code,
          index);
      char *color_text = ntui_macos_read_string(
          g_ntui_runtime.command_color_length,
          g_ntui_runtime.command_color_char_code,
          index);
      char *font_family = ntui_macos_read_string(
          g_ntui_runtime.command_font_family_length,
          g_ntui_runtime.command_font_family_char_code,
          index);
      char *font_style = ntui_macos_read_string(
          g_ntui_runtime.command_font_style_length,
          g_ntui_runtime.command_font_style_char_code,
          index);
      char *text_decoration_line = ntui_macos_read_optional_string(
          g_ntui_runtime.command_text_decoration_line_length,
          g_ntui_runtime.command_text_decoration_line_char_code,
          index,
          "none");
      char *text_decoration_style = ntui_macos_read_optional_string(
          g_ntui_runtime.command_text_decoration_style_length,
          g_ntui_runtime.command_text_decoration_style_char_code,
          index,
          "solid");
      char *text_decoration_color = ntui_macos_read_optional_string(
          g_ntui_runtime.command_text_decoration_color_length,
          g_ntui_runtime.command_text_decoration_color_char_code,
          index,
          color_text == NULL ? "" : color_text);
      char *text_underline_position = ntui_macos_read_optional_string(
          g_ntui_runtime.command_text_underline_position_length,
          g_ntui_runtime.command_text_underline_position_char_code,
          index,
          "auto");
      char *text_shadow = ntui_macos_read_optional_string(
          g_ntui_runtime.command_text_shadow_length,
          g_ntui_runtime.command_text_shadow_char_code,
          index,
          "");
      char *direction = ntui_macos_read_optional_string(
          g_ntui_runtime.command_direction_length,
          g_ntui_runtime.command_direction_char_code,
          index,
          "ltr");
      char *writing_mode = ntui_macos_read_optional_string(
          g_ntui_runtime.command_writing_mode_length,
          g_ntui_runtime.command_writing_mode_char_code,
          index,
          "horizontal-tb");
      const double box_width = ntui_macos_scale_px(
          ntui_macos_value_to_double(g_ntui_runtime.command_box_width((NtuiValue)NTUI_VALUE_NULL, index)),
          scale);
      const double font_size = ntui_macos_scale_px(
          ntui_macos_value_to_double(g_ntui_runtime.command_font_size((NtuiValue)NTUI_VALUE_NULL, index)),
          scale);
      const double line_height = ntui_macos_scale_px(
          ntui_macos_value_to_double(g_ntui_runtime.command_line_height((NtuiValue)NTUI_VALUE_NULL, index)),
          scale);
      const double baseline_offset = ntui_macos_scale_px(
          ntui_macos_value_to_double(g_ntui_runtime.command_baseline_offset((NtuiValue)NTUI_VALUE_NULL, index)),
          scale);
      const int font_weight = ntui_macos_value_to_int(
          g_ntui_runtime.command_font_weight((NtuiValue)NTUI_VALUE_NULL, index));
      const NtuiMacosTextRenderOptions text_options = {
          .line_index = ntui_macos_read_optional_int(g_ntui_runtime.command_line_index, index, -1),
          .run_index = ntui_macos_read_optional_int(g_ntui_runtime.command_run_index, index, -1),
          .letter_spacing = ntui_macos_scale_px(ntui_macos_read_optional_double(g_ntui_runtime.command_letter_spacing, index, 0.0), scale),
          .word_spacing = ntui_macos_scale_px(ntui_macos_read_optional_double(g_ntui_runtime.command_word_spacing, index, 0.0), scale),
          .text_decoration_thickness = ntui_macos_scale_px(ntui_macos_read_optional_double(g_ntui_runtime.command_text_decoration_thickness, index, 0.0), scale),
          .text_underline_offset = ntui_macos_scale_px(ntui_macos_read_optional_double(g_ntui_runtime.command_text_underline_offset, index, 0.0), scale),
          .text_indent = ntui_macos_scale_px(ntui_macos_read_optional_double(g_ntui_runtime.command_text_indent, index, 0.0), scale),
          .text_decoration_line = text_decoration_line,
          .text_decoration_style = text_decoration_style,
          .text_decoration_color = text_decoration_color,
          .text_underline_position = text_underline_position,
          .text_shadow = text_shadow,
          .direction = direction,
          .writing_mode = writing_mode,
      };
      const NtuiMacosColor color = ntui_macos_apply_current_opacity(ntui_macos_parse_color(
          color_text,
          (NtuiMacosColor){.r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0}));
      if (text != NULL && text[0] != 0 && isfinite(x) && isfinite(y) && box_width > 0.0 && font_size > 0.0) {
        ntui_macos_metal_draw_text(
            text,
            x,
            y,
            box_width,
            font_size,
            line_height,
            baseline_offset,
            font_weight,
            text_align,
            font_family,
            font_style,
            color,
            &text_options);
      }
      free(text);
      free(text_align);
      free(color_text);
      free(font_family);
      free(font_style);
      free(text_decoration_line);
      free(text_decoration_style);
      free(text_decoration_color);
      free(text_underline_position);
      free(text_shadow);
      free(direction);
      free(writing_mode);
    }
  }
  ntui_macos_reset_opacity_stack();

  if (!ntui_macos_metal_end_frame()) return 0;
  ntui_macos_collect_ts_gc_auto("finish_frame");
  ntui_macos_log_ts_memory_counters("finish_frame");
  ntui_macos_metal_log_renderer_memory();
  return count;
}

int ntui_macos_renderer_touch(float x, float y, int phase, int scale_millis) {
  if (!ntui_macos_ensure_runtime()) return 0;
  const int normalized_scale_millis = ntui_macos_normalize_scale_millis(scale_millis);
  const double scale = (double)normalized_scale_millis / 1000.0;
  const int logical_x = (int)llround((double)x);
  const int logical_y = (int)llround((double)y);
  const int physical_x = (int)llround((double)x * scale);
  const int physical_y = (int)llround((double)y * scale);
  return ntui_macos_value_to_int(g_ntui_runtime.handle_touch(
      (NtuiValue)NTUI_VALUE_NULL,
      ntui_macos_box_int(physical_x),
      ntui_macos_box_int(physical_y),
      ntui_macos_box_int(logical_x),
      ntui_macos_box_int(logical_y),
      ntui_macos_box_int(phase)));
}
