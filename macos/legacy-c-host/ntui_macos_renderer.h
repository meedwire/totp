#ifndef NTUI_MACOS_RENDERER_H
#define NTUI_MACOS_RENDERER_H

#ifdef __OBJC__
@class MTKView;
typedef MTKView NtuiMacosView;
#else
typedef void NtuiMacosView;
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NtuiMacosColor {
  double r;
  double g;
  double b;
  double a;
} NtuiMacosColor;

NtuiMacosColor ntui_macos_parse_color(const char *text, NtuiMacosColor fallback);

void ntui_macos_renderer_set_library_path(const char *path);
void ntui_macos_renderer_set_resource_path(const char *path);
const char *ntui_macos_renderer_last_error(void);
int ntui_macos_renderer_render(NtuiMacosView *view, int drawable_width, int drawable_height, int scale_millis);
int ntui_macos_renderer_touch(float x, float y, int phase, int scale_millis);

#ifdef __cplusplus
}
#endif

#endif
