#import "ntui_macos_renderer.h"

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <MetalKit/MetalKit.h>

#include "font_manager.h"
#include "text_layout.h"

#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NTUI_MACOS_ATLAS_FIRST 32
#define NTUI_MACOS_ATLAS_LAST 126
#define NTUI_MACOS_ATLAS_COUNT (NTUI_MACOS_ATLAS_LAST - NTUI_MACOS_ATLAS_FIRST + 1)

typedef struct NtuiMacosVertex {
  float position[2];
  float color[4];
  float tex_coord[2];
} NtuiMacosVertex;

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

typedef struct NtuiMacosGlyph {
  float u0;
  float v0;
  float u1;
  float v1;
  float advance;
  float offset_x;
  float offset_y;
  float width;
  float height;
} NtuiMacosGlyph;

typedef struct NtuiMacosGlyphAtlas {
  char family[64];
  char style[16];
  int weight;
  int size_px;
  int width;
  int height;
  float ascent;
  id<MTLTexture> texture;
  NtuiMacosGlyph glyphs[NTUI_MACOS_ATLAS_COUNT];
} NtuiMacosGlyphAtlas;

static id<MTLDevice> g_ntui_device;
static id<MTLCommandQueue> g_ntui_command_queue;
static id<MTLRenderPipelineState> g_ntui_solid_pipeline;
static id<MTLRenderPipelineState> g_ntui_box_pipeline;
static id<MTLRenderPipelineState> g_ntui_texture_pipeline;
static id<MTLRenderPipelineState> g_ntui_text_pipeline;
static MTKTextureLoader *g_ntui_texture_loader;
static id<MTLCommandBuffer> g_ntui_command_buffer;
static id<MTLRenderCommandEncoder> g_ntui_encoder;
static id<CAMetalDrawable> g_ntui_drawable;
static int g_ntui_drawable_width;
static int g_ntui_drawable_height;
static NtuiMacosGlyphAtlas g_ntui_text_atlas;
static NtuiFontManager g_ntui_font_manager;
static int g_ntui_font_manager_ready;
static uint64_t g_ntui_frames_submitted;
static uint64_t g_ntui_font_texture_count;
static uint64_t g_ntui_font_texture_bytes;
static uint64_t g_ntui_appkit_fallback_texture_count;
static uint64_t g_ntui_appkit_fallback_texture_bytes;

typedef struct NtuiMacosFontTexture {
  NtuiFontAtlas *font;
  id<MTLTexture> texture;
} NtuiMacosFontTexture;

static NtuiMacosFontTexture g_ntui_font_textures[NTUI_FONT_MANAGER_CAPACITY];

static int ntui_macos_metal_env_logs_enabled(const char *name) {
  const char *value = getenv(name);
  return value != NULL && value[0] != 0 && strcmp(value, "0") != 0;
}

static int ntui_macos_metal_memory_or_render_logs_enabled(void) {
  return ntui_macos_metal_env_logs_enabled("NTUI_MACOS_MEMORY_LOGS") ||
         ntui_macos_metal_env_logs_enabled("NTUI_MACOS_RENDER_LOGS");
}

void ntui_macos_metal_log_renderer_memory(void) {
  if (!ntui_macos_metal_memory_or_render_logs_enabled()) return;
  fprintf(
      stderr,
      "macos_renderer_memory frame=%llu fontTextures=%llu fontTextureBytes=%llu appkitFallbackTextures=%llu appkitFallbackBytes=%llu\n",
      (unsigned long long)g_ntui_frames_submitted,
      (unsigned long long)g_ntui_font_texture_count,
      (unsigned long long)g_ntui_font_texture_bytes,
      (unsigned long long)g_ntui_appkit_fallback_texture_count,
      (unsigned long long)g_ntui_appkit_fallback_texture_bytes);
}

static NSString *const kNtuiMacosShaderSource =
@"#include <metal_stdlib>\n"
 "using namespace metal;\n"
 "struct NtuiVertex {\n"
 "  packed_float2 position;\n"
 "  packed_float4 color;\n"
 "  packed_float2 texCoord;\n"
 "};\n"
 "struct NtuiRaster {\n"
 "  float4 position [[position]];\n"
 "  float4 color;\n"
 "  float2 texCoord;\n"
 "};\n"
 "vertex NtuiRaster ntui_vertex(uint vertexID [[vertex_id]], constant NtuiVertex *vertices [[buffer(0)]]) {\n"
 "  NtuiVertex inputVertex = vertices[vertexID];\n"
 "  NtuiRaster out;\n"
 "  out.position = float4(inputVertex.position, 0.0, 1.0);\n"
 "  out.color = inputVertex.color;\n"
 "  out.texCoord = inputVertex.texCoord;\n"
 "  return out;\n"
 "}\n"
 "fragment float4 ntui_solid_fragment(NtuiRaster in [[stage_in]]) {\n"
 "  return in.color;\n"
 "}\n"
 "float ntui_rounded_rect_sdf(float2 p, float2 halfSize, float radius) {\n"
 "  float2 q = abs(p) - (halfSize - float2(radius));\n"
 "  return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;\n"
 "}\n"
 "fragment float4 ntui_box_fragment(NtuiRaster in [[stage_in]], constant float4 *box [[buffer(0)]]) {\n"
 "  float2 size = max(box[0].xy, float2(0.0));\n"
 "  float2 halfSize = size * 0.5;\n"
 "  float radius = clamp(box[0].z, 0.0, min(halfSize.x, halfSize.y));\n"
 "  float borderWidth = clamp(box[0].w, 0.0, min(halfSize.x, halfSize.y));\n"
 "  float2 local = (in.texCoord * size) - halfSize;\n"
 "  float outer = ntui_rounded_rect_sdf(local, halfSize, radius);\n"
 "  float outerAlpha = 1.0 - smoothstep(0.0, 1.0, outer);\n"
 "  if (outerAlpha <= 0.0) discard_fragment();\n"
 "  float innerAlpha = 1.0;\n"
 "  if (borderWidth > 0.0) {\n"
 "    float2 innerHalf = max(halfSize - float2(borderWidth), float2(0.0));\n"
 "    float innerRadius = max(radius - borderWidth, 0.0);\n"
 "    innerAlpha = 0.0;\n"
 "    if (innerHalf.x > 0.0 && innerHalf.y > 0.0) {\n"
 "      float inner = ntui_rounded_rect_sdf(local, innerHalf, innerRadius);\n"
 "      innerAlpha = 1.0 - smoothstep(0.0, 1.0, inner);\n"
 "    }\n"
 "  }\n"
 "  float4 color = mix(box[2], box[1], innerAlpha);\n"
 "  color.a *= outerAlpha;\n"
 "  return color;\n"
 "}\n"
 "fragment float4 ntui_texture_fragment(NtuiRaster in [[stage_in]], texture2d<float> texture [[texture(0)]]) {\n"
 "  constexpr sampler textSampler(address::clamp_to_edge, filter::linear);\n"
 "  return texture.sample(textSampler, in.texCoord) * in.color;\n"
 "}\n"
 "fragment float4 ntui_text_fragment(NtuiRaster in [[stage_in]], texture2d<float> texture [[texture(0)]]) {\n"
 "  constexpr sampler textSampler(address::clamp_to_edge, filter::linear);\n"
 "  float alpha = in.texCoord.x < -0.5 ? 1.0 : texture.sample(textSampler, in.texCoord).r;\n"
 "  return float4(in.color.rgb, in.color.a * alpha);\n"
 "}\n";

static double ntui_macos_clamp(double value, double minimum, double maximum) {
  return fmin(fmax(value, minimum), maximum);
}

static int ntui_macos_rect_is_visible(double x, double y, double width, double height) {
  return isfinite(x) && isfinite(y) && isfinite(width) && isfinite(height) &&
         width > 0.0 && height > 0.0 && g_ntui_encoder != nil;
}

static void ntui_macos_write_vertex(
    NtuiMacosVertex *vertex,
    double x,
    double y,
    double u,
    double v,
    NtuiMacosColor color) {
  const double ndc_x = (x / (double)g_ntui_drawable_width) * 2.0 - 1.0;
  const double ndc_y = 1.0 - (y / (double)g_ntui_drawable_height) * 2.0;
  vertex->position[0] = (float)ndc_x;
  vertex->position[1] = (float)ndc_y;
  vertex->color[0] = (float)ntui_macos_clamp(color.r, 0.0, 1.0);
  vertex->color[1] = (float)ntui_macos_clamp(color.g, 0.0, 1.0);
  vertex->color[2] = (float)ntui_macos_clamp(color.b, 0.0, 1.0);
  vertex->color[3] = (float)ntui_macos_clamp(color.a, 0.0, 1.0);
  vertex->tex_coord[0] = (float)u;
  vertex->tex_coord[1] = (float)v;
}

static void ntui_macos_make_quad(
    NtuiMacosVertex vertices[6],
    double x,
    double y,
    double width,
    double height,
    NtuiMacosColor color) {
  const double x0 = x;
  const double y0 = y;
  const double x1 = x + width;
  const double y1 = y + height;
  ntui_macos_write_vertex(&vertices[0], x0, y0, 0.0, 0.0, color);
  ntui_macos_write_vertex(&vertices[1], x1, y0, 1.0, 0.0, color);
  ntui_macos_write_vertex(&vertices[2], x1, y1, 1.0, 1.0, color);
  ntui_macos_write_vertex(&vertices[3], x0, y0, 0.0, 0.0, color);
  ntui_macos_write_vertex(&vertices[4], x1, y1, 1.0, 1.0, color);
  ntui_macos_write_vertex(&vertices[5], x0, y1, 0.0, 1.0, color);
}

static void ntui_macos_flip_quad_texture_y(NtuiMacosVertex vertices[6]) {
  for (int index = 0; index < 6; index += 1) {
    vertices[index].tex_coord[1] = 1.0f - vertices[index].tex_coord[1];
  }
}

static int ntui_macos_text_is_ascii_atlas_supported(const char *text) {
  if (text == NULL) return 0;
  for (const unsigned char *cursor = (const unsigned char *)text; *cursor != 0; cursor += 1) {
    if (*cursor != '\n' && (*cursor < NTUI_MACOS_ATLAS_FIRST || *cursor > NTUI_MACOS_ATLAS_LAST)) {
      return 0;
    }
  }
  return 1;
}

static int ntui_macos_should_use_appkit_text_fallback(
    const char *text,
    const NtuiMacosTextRenderOptions *options) {
  (void)text;
  if (options == NULL) return 0;
  if (options->text_shadow != NULL && options->text_shadow[0] != 0) return 1;
  if (options->writing_mode != NULL &&
      options->writing_mode[0] != 0 &&
      strcmp(options->writing_mode, "horizontal-tb") != 0) {
    return 1;
  }
  return 0;
}

static int ntui_macos_compile_pipelines(MTLPixelFormat pixel_format) {
  if (
      g_ntui_solid_pipeline != nil &&
      g_ntui_box_pipeline != nil &&
      g_ntui_texture_pipeline != nil &&
      g_ntui_text_pipeline != nil) return 1;
  NSError *error = nil;
  id<MTLLibrary> library = [g_ntui_device newLibraryWithSource:kNtuiMacosShaderSource options:nil error:&error];
  if (library == nil) {
    NSLog(@"ntui_macos_renderer: failed to compile Metal library: %@", error);
    return 0;
  }

  id<MTLFunction> vertex = [library newFunctionWithName:@"ntui_vertex"];
  id<MTLFunction> solid_fragment = [library newFunctionWithName:@"ntui_solid_fragment"];
  id<MTLFunction> box_fragment = [library newFunctionWithName:@"ntui_box_fragment"];
  id<MTLFunction> texture_fragment = [library newFunctionWithName:@"ntui_texture_fragment"];
  id<MTLFunction> text_fragment = [library newFunctionWithName:@"ntui_text_fragment"];
  if (vertex == nil || solid_fragment == nil || box_fragment == nil || texture_fragment == nil || text_fragment == nil) return 0;

  MTLRenderPipelineDescriptor *solid_descriptor = [[MTLRenderPipelineDescriptor alloc] init];
  solid_descriptor.vertexFunction = vertex;
  solid_descriptor.fragmentFunction = solid_fragment;
  solid_descriptor.colorAttachments[0].pixelFormat = pixel_format;
  solid_descriptor.colorAttachments[0].blendingEnabled = YES;
  solid_descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  solid_descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  solid_descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
  solid_descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  g_ntui_solid_pipeline = [g_ntui_device newRenderPipelineStateWithDescriptor:solid_descriptor error:&error];
  if (g_ntui_solid_pipeline == nil) {
    NSLog(@"ntui_macos_renderer: failed to compile solid pipeline: %@", error);
    return 0;
  }

  MTLRenderPipelineDescriptor *box_descriptor = [[MTLRenderPipelineDescriptor alloc] init];
  box_descriptor.vertexFunction = vertex;
  box_descriptor.fragmentFunction = box_fragment;
  box_descriptor.colorAttachments[0].pixelFormat = pixel_format;
  box_descriptor.colorAttachments[0].blendingEnabled = YES;
  box_descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  box_descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  box_descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
  box_descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  g_ntui_box_pipeline = [g_ntui_device newRenderPipelineStateWithDescriptor:box_descriptor error:&error];
  if (g_ntui_box_pipeline == nil) {
    NSLog(@"ntui_macos_renderer: failed to compile box pipeline: %@", error);
    return 0;
  }

  MTLRenderPipelineDescriptor *texture_descriptor = [[MTLRenderPipelineDescriptor alloc] init];
  texture_descriptor.vertexFunction = vertex;
  texture_descriptor.fragmentFunction = texture_fragment;
  texture_descriptor.colorAttachments[0].pixelFormat = pixel_format;
  texture_descriptor.colorAttachments[0].blendingEnabled = YES;
  texture_descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  texture_descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  texture_descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
  texture_descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  g_ntui_texture_pipeline = [g_ntui_device newRenderPipelineStateWithDescriptor:texture_descriptor error:&error];
  if (g_ntui_texture_pipeline == nil) {
    NSLog(@"ntui_macos_renderer: failed to compile texture pipeline: %@", error);
    return 0;
  }

  MTLRenderPipelineDescriptor *text_descriptor = [[MTLRenderPipelineDescriptor alloc] init];
  text_descriptor.vertexFunction = vertex;
  text_descriptor.fragmentFunction = text_fragment;
  text_descriptor.colorAttachments[0].pixelFormat = pixel_format;
  text_descriptor.colorAttachments[0].blendingEnabled = YES;
  text_descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  text_descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  text_descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
  text_descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  g_ntui_text_pipeline = [g_ntui_device newRenderPipelineStateWithDescriptor:text_descriptor error:&error];
  if (g_ntui_text_pipeline == nil) {
    NSLog(@"ntui_macos_renderer: failed to compile text pipeline: %@", error);
    return 0;
  }

  return 1;
}

static int ntui_macos_prepare_device(MTKView *view) {
  if (view == nil) return 0;
  if (g_ntui_device == nil) {
    g_ntui_device = view.device ?: MTLCreateSystemDefaultDevice();
  }
  if (g_ntui_device == nil) return 0;
  if (view.device == nil) view.device = g_ntui_device;
  view.framebufferOnly = NO;
  if (view.colorPixelFormat == MTLPixelFormatInvalid) {
    view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
  }
  if (g_ntui_command_queue == nil) {
    g_ntui_command_queue = [g_ntui_device newCommandQueue];
  }
  if (g_ntui_texture_loader == nil) {
    g_ntui_texture_loader = [[MTKTextureLoader alloc] initWithDevice:g_ntui_device];
  }
  return g_ntui_command_queue != nil && ntui_macos_compile_pipelines(view.colorPixelFormat);
}

static void ntui_macos_ensure_font_manager(void) {
  if (g_ntui_font_manager_ready) return;
  ntui_font_manager_init(&g_ntui_font_manager);
  g_ntui_font_manager_ready = 1;
}

static void ntui_macos_reset_font_textures(void) {
  for (int index = 0; index < NTUI_FONT_MANAGER_CAPACITY; index += 1) {
    g_ntui_font_textures[index].font = NULL;
    g_ntui_font_textures[index].texture = nil;
  }
  ntui_font_manager_reset_textures(&g_ntui_font_manager);
}

static id<MTLTexture> ntui_macos_texture_for_font(NtuiFontAtlas *font) {
  if (font == NULL || font->bitmap == NULL || font->width <= 0 || font->height <= 0 || g_ntui_device == nil) {
    return nil;
  }
  int empty_slot = -1;
  for (int index = 0; index < NTUI_FONT_MANAGER_CAPACITY; index += 1) {
    if (g_ntui_font_textures[index].font == font && g_ntui_font_textures[index].texture != nil) {
      return g_ntui_font_textures[index].texture;
    }
    if (empty_slot < 0 && g_ntui_font_textures[index].font == NULL) empty_slot = index;
  }

  const int slot = empty_slot >= 0 ? empty_slot : 0;
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                        width:(NSUInteger)font->width
                                                                                       height:(NSUInteger)font->height
                                                                                    mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> texture = [g_ntui_device newTextureWithDescriptor:descriptor];
  if (texture == nil) return nil;
  [texture replaceRegion:MTLRegionMake2D(0, 0, font->width, font->height)
             mipmapLevel:0
               withBytes:font->bitmap
             bytesPerRow:(NSUInteger)font->width];
  g_ntui_font_textures[slot].font = font;
  g_ntui_font_textures[slot].texture = texture;
  font->texture_id = (unsigned int)(slot + 1);
  g_ntui_font_texture_count += 1;
  g_ntui_font_texture_bytes += (uint64_t)((size_t)font->width * (size_t)font->height);
  return texture;
}

static int ntui_macos_floor_to_int(double value) {
  const int truncated = (int)value;
  return (double)truncated > value ? truncated - 1 : truncated;
}

static int ntui_macos_ceil_to_int(double value) {
  const int truncated = (int)value;
  return (double)truncated < value ? truncated + 1 : truncated;
}

static int ntui_macos_set_text_scissor(double x, double y, double width, double height) {
  if (g_ntui_encoder == nil || g_ntui_drawable_width <= 0 || g_ntui_drawable_height <= 0) return 0;
  if (!isfinite(x) || !isfinite(y) || !isfinite(width) || !isfinite(height) || width <= 0.0 || height <= 0.0) return 0;
  double left_f = x;
  double top_f = y;
  double right_f = x + width;
  double bottom_f = y + height;
  if (right_f <= 0.0 || bottom_f <= 0.0) return 0;
  if (left_f >= (double)g_ntui_drawable_width || top_f >= (double)g_ntui_drawable_height) return 0;
  if (left_f < 0.0) left_f = 0.0;
  if (top_f < 0.0) top_f = 0.0;
  if (right_f > (double)g_ntui_drawable_width) right_f = (double)g_ntui_drawable_width;
  if (bottom_f > (double)g_ntui_drawable_height) bottom_f = (double)g_ntui_drawable_height;

  const int left = ntui_macos_floor_to_int(left_f);
  const int top = ntui_macos_floor_to_int(top_f);
  const int right = ntui_macos_ceil_to_int(right_f);
  const int bottom = ntui_macos_ceil_to_int(bottom_f);
  if (right <= left || bottom <= top) return 0;
  MTLScissorRect rect = {
      .x = (NSUInteger)left,
      .y = (NSUInteger)top,
      .width = (NSUInteger)(right - left),
      .height = (NSUInteger)(bottom - top),
  };
  [g_ntui_encoder setScissorRect:rect];
  return 1;
}

static void ntui_macos_reset_scissor(void) {
  if (g_ntui_encoder == nil || g_ntui_drawable_width <= 0 || g_ntui_drawable_height <= 0) return;
  MTLScissorRect rect = {
      .x = 0,
      .y = 0,
      .width = (NSUInteger)g_ntui_drawable_width,
      .height = (NSUInteger)g_ntui_drawable_height,
  };
  [g_ntui_encoder setScissorRect:rect];
}

int ntui_macos_metal_begin_frame(NtuiMacosView *raw_view, int drawable_width, int drawable_height) {
  MTKView *view = (MTKView *)raw_view;
  if (!ntui_macos_prepare_device(view)) return 0;
  if (drawable_width <= 0 || drawable_height <= 0) return 0;

  g_ntui_drawable_width = drawable_width;
  g_ntui_drawable_height = drawable_height;

  MTLRenderPassDescriptor *pass_descriptor = view.currentRenderPassDescriptor;
  g_ntui_drawable = view.currentDrawable;
  if (pass_descriptor == nil || g_ntui_drawable == nil) return 0;

  pass_descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.063, 0.075, 0.090, 1.0);
  pass_descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass_descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

  g_ntui_command_buffer = [g_ntui_command_queue commandBuffer];
  g_ntui_encoder = [g_ntui_command_buffer renderCommandEncoderWithDescriptor:pass_descriptor];
  return g_ntui_encoder != nil;
}

int ntui_macos_metal_draw_rect(double x, double y, double width, double height, NtuiMacosColor color) {
  if (!ntui_macos_rect_is_visible(x, y, width, height) || color.a <= 0.0) return 1;
  NtuiMacosVertex vertices[6];
  ntui_macos_make_quad(vertices, x, y, width, height, color);
  [g_ntui_encoder setRenderPipelineState:g_ntui_solid_pipeline];
  [g_ntui_encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
  [g_ntui_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  return 1;
}

int ntui_macos_metal_draw_box(
    double x,
    double y,
    double width,
    double height,
    double border_width,
    double border_radius,
    NtuiMacosColor fill_color,
    NtuiMacosColor border_color) {
  if (!ntui_macos_rect_is_visible(x, y, width, height)) return 1;
  const double border = ntui_macos_clamp(border_width, 0.0, fmin(width, height) * 0.5);
  const double radius = ntui_macos_clamp(border_radius, 0.0, fmin(width, height) * 0.5);
  if (fill_color.a <= 0.0 && (border <= 0.0 || border_color.a <= 0.0)) return 1;
  if (radius <= 0.0 && border <= 0.0) {
    return ntui_macos_metal_draw_rect(x, y, width, height, fill_color);
  }

  NtuiMacosVertex vertices[6];
  ntui_macos_make_quad(vertices, x, y, width, height, fill_color);
  const float box_uniforms[] = {
      (float)width,
      (float)height,
      (float)radius,
      (float)border,
      (float)ntui_macos_clamp(fill_color.r, 0.0, 1.0),
      (float)ntui_macos_clamp(fill_color.g, 0.0, 1.0),
      (float)ntui_macos_clamp(fill_color.b, 0.0, 1.0),
      (float)ntui_macos_clamp(fill_color.a, 0.0, 1.0),
      (float)ntui_macos_clamp(border_color.r, 0.0, 1.0),
      (float)ntui_macos_clamp(border_color.g, 0.0, 1.0),
      (float)ntui_macos_clamp(border_color.b, 0.0, 1.0),
      (float)ntui_macos_clamp(border_color.a, 0.0, 1.0),
  };
  [g_ntui_encoder setRenderPipelineState:g_ntui_box_pipeline];
  [g_ntui_encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
  [g_ntui_encoder setFragmentBytes:box_uniforms length:sizeof(box_uniforms) atIndex:0];
  [g_ntui_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  return 1;
}

static NSFontWeight ntui_macos_system_weight(int font_weight) {
  if (font_weight >= 900) return NSFontWeightBlack;
  if (font_weight >= 800) return NSFontWeightHeavy;
  if (font_weight >= 700) return NSFontWeightBold;
  if (font_weight >= 600) return NSFontWeightSemibold;
  if (font_weight >= 500) return NSFontWeightMedium;
  if (font_weight <= 300) return NSFontWeightLight;
  return NSFontWeightRegular;
}

static CGFloat ntui_macos_font_weight_trait(int font_weight) {
  if (font_weight >= 900) return 0.62;
  if (font_weight >= 800) return 0.56;
  if (font_weight >= 700) return 0.40;
  if (font_weight >= 600) return 0.30;
  if (font_weight >= 500) return 0.23;
  if (font_weight <= 300) return -0.40;
  return 0.0;
}

static void ntui_macos_ensure_font_manager(void);
static void ntui_macos_reset_font_textures(void);

int ntui_macos_metal_register_font_asset(
    const char *resource_path,
    const char *family,
    const char *asset_path,
    int weight,
    const char *style) {
  (void)family;
  (void)weight;
  (void)style;
  if (asset_path == NULL || asset_path[0] == 0) return 0;
  ntui_macos_ensure_font_manager();

  NSString *path = [NSString stringWithUTF8String:asset_path] ?: @"";
  if (![path isAbsolutePath] && resource_path != NULL && resource_path[0] != 0) {
    NSString *root = [NSString stringWithUTF8String:resource_path] ?: @"";
    path = [root stringByAppendingPathComponent:path];
  }

  NSURL *url = [NSURL fileURLWithPath:path];
  if (url == nil) return 0;
  CFErrorRef error = NULL;
  const bool registered = CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error);
  if (!registered && error != NULL) {
    CFRelease(error);
  }
  const int atlas_registered = ntui_font_manager_register_path(
      &g_ntui_font_manager,
      family,
      path.fileSystemRepresentation,
      weight,
      style);
  ntui_macos_reset_font_textures();
  g_ntui_text_atlas.texture = nil;
  return registered || atlas_registered ? 1 : 0;
}

static NSFont *ntui_macos_resolve_font(
    const char *font_family,
    const char *font_style,
    double font_size,
    int font_weight) {
  const CGFloat size = (CGFloat)fmax(font_size, 1.0);
  NSFont *font = nil;
  if (font_family != NULL && font_family[0] != 0) {
    NSString *family = [NSString stringWithUTF8String:font_family];
    if (family.length > 0) {
      NSDictionary *traits = @{NSFontWeightTrait: @(ntui_macos_font_weight_trait(font_weight))};
      NSFontDescriptor *descriptor = [NSFontDescriptor fontDescriptorWithFontAttributes:@{
        NSFontFamilyAttribute: family,
        NSFontTraitsAttribute: traits,
      }];
      font = [NSFont fontWithDescriptor:descriptor size:size];
    }
  }
  if (font == nil) {
    font = [NSFont systemFontOfSize:size weight:ntui_macos_system_weight(font_weight)];
  }
  if (font_style != NULL && strcmp(font_style, "italic") == 0) {
    NSFont *italic = [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:NSItalicFontMask];
    if (italic != nil) font = italic;
  }
  return font;
}

static int ntui_macos_text_has_token(const char *text, const char *token) {
  return text != NULL && token != NULL && strstr(text, token) != NULL;
}

static NSColor *ntui_macos_ns_color(NtuiMacosColor color) {
  return [NSColor colorWithDeviceRed:(CGFloat)color.r
                               green:(CGFloat)color.g
                                blue:(CGFloat)color.b
                               alpha:(CGFloat)color.a];
}

static NSTextAlignment ntui_macos_text_alignment(const char *text_align, const char *direction) {
  const int rtl = direction != NULL && strcmp(direction, "rtl") == 0;
  if (text_align == NULL) return rtl ? NSTextAlignmentRight : NSTextAlignmentLeft;
  if (strcmp(text_align, "center") == 0) return NSTextAlignmentCenter;
  if (strcmp(text_align, "right") == 0) return NSTextAlignmentRight;
  if (strcmp(text_align, "left") == 0) return NSTextAlignmentLeft;
  if (strcmp(text_align, "end") == 0) return rtl ? NSTextAlignmentLeft : NSTextAlignmentRight;
  if (strcmp(text_align, "start") == 0) return rtl ? NSTextAlignmentRight : NSTextAlignmentLeft;
  return NSTextAlignmentLeft;
}

static int ntui_macos_atlas_matches(
    const NtuiMacosGlyphAtlas *atlas,
    const char *font_family,
    const char *font_style,
    int font_weight,
    int size_px) {
  const char *family = font_family == NULL ? "" : font_family;
  const char *style = font_style == NULL ? "" : font_style;
  return atlas->texture != nil &&
         atlas->size_px == size_px &&
         atlas->weight == font_weight &&
         strcmp(atlas->family, family) == 0 &&
         strcmp(atlas->style, style) == 0;
}

static int ntui_macos_create_glyph_atlas(
    const char *font_family,
    const char *font_style,
    double font_size,
    int font_weight) {
  if (g_ntui_device == nil) return 0;
  const int size_px = (int)ceil(fmax(font_size, 1.0));
  if (ntui_macos_atlas_matches(&g_ntui_text_atlas, font_family, font_style, font_weight, size_px)) {
    return 1;
  }

  NSFont *font = ntui_macos_resolve_font(font_family, font_style, font_size, font_weight);
  if (font == nil) return 0;
  CTFontRef ct_font = CTFontCreateWithName((__bridge CFStringRef)font.fontName, (CGFloat)size_px, NULL);
  if (ct_font == NULL) return 0;

  const int cell = (int)ceil(fmax((double)size_px * 1.8, 24.0));
  const int columns = 16;
  const int rows = (NTUI_MACOS_ATLAS_COUNT + columns - 1) / columns;
  const int width = cell * columns;
  const int height = cell * rows;
  const size_t bytes_per_row = (size_t)width * 4U;
  unsigned char *pixels = (unsigned char *)calloc((size_t)height, bytes_per_row);
  if (pixels == NULL) {
    CFRelease(ct_font);
    return 0;
  }

  CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      pixels,
      (size_t)width,
      (size_t)height,
      8,
      bytes_per_row,
      color_space,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(color_space);
  if (context == NULL) {
    free(pixels);
    CFRelease(ct_font);
    return 0;
  }

  CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0);
  CGContextSetTextDrawingMode(context, kCGTextFill);
  g_ntui_text_atlas.texture = nil;
  memset(g_ntui_text_atlas.family, 0, sizeof(g_ntui_text_atlas.family));
  memset(g_ntui_text_atlas.style, 0, sizeof(g_ntui_text_atlas.style));
  memset(g_ntui_text_atlas.glyphs, 0, sizeof(g_ntui_text_atlas.glyphs));
  snprintf(g_ntui_text_atlas.family, sizeof(g_ntui_text_atlas.family), "%s", font_family == NULL ? "" : font_family);
  snprintf(g_ntui_text_atlas.style, sizeof(g_ntui_text_atlas.style), "%s", font_style == NULL ? "" : font_style);
  g_ntui_text_atlas.weight = font_weight;
  g_ntui_text_atlas.size_px = size_px;
  g_ntui_text_atlas.width = width;
  g_ntui_text_atlas.height = height;
  g_ntui_text_atlas.ascent = (float)CTFontGetAscent(ct_font);

  for (int offset = 0; offset < NTUI_MACOS_ATLAS_COUNT; offset += 1) {
    const UniChar character = (UniChar)(NTUI_MACOS_ATLAS_FIRST + offset);
    CGGlyph glyph = 0;
    if (!CTFontGetGlyphsForCharacters(ct_font, &character, &glyph, 1) || glyph == 0) continue;

    CGRect bounds = CTFontGetBoundingRectsForGlyphs(ct_font, kCTFontOrientationDefault, &glyph, NULL, 1);
    CGSize advance = CGSizeZero;
    CTFontGetAdvancesForGlyphs(ct_font, kCTFontOrientationDefault, &glyph, &advance, 1);

    const int column = offset % columns;
    const int row = offset / columns;
    const CGFloat draw_x = (CGFloat)(column * cell) + 4.0 - bounds.origin.x;
    const CGFloat draw_y = (CGFloat)(row * cell) + 4.0 - bounds.origin.y;
    const CGPoint position = CGPointMake(draw_x, draw_y);
    CTFontDrawGlyphs(ct_font, &glyph, &position, 1, context);

    NtuiMacosGlyph *entry = &g_ntui_text_atlas.glyphs[offset];
    entry->u0 = (float)((column * cell) / (double)width);
    entry->v0 = (float)((row * cell) / (double)height);
    entry->u1 = (float)(((column + 1) * cell) / (double)width);
    entry->v1 = (float)(((row + 1) * cell) / (double)height);
    entry->advance = (float)advance.width;
    entry->offset_x = (float)bounds.origin.x - 4.0f;
    entry->offset_y = (float)(-bounds.origin.y - bounds.size.height) - 4.0f;
    entry->width = (float)cell;
    entry->height = (float)cell;
  }

  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                        width:(NSUInteger)width
                                                                                       height:(NSUInteger)height
                                                                                    mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> texture = [g_ntui_device newTextureWithDescriptor:descriptor];
  if (texture != nil) {
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0
                 withBytes:pixels
               bytesPerRow:bytes_per_row];
  }

  CGContextRelease(context);
  free(pixels);
  CFRelease(ct_font);
  g_ntui_text_atlas.texture = texture;
  if (texture != nil) {
    g_ntui_font_texture_count += 1;
    g_ntui_font_texture_bytes += (uint64_t)((size_t)width * (size_t)height * 4U);
  }
  return texture != nil;
}

static id<MTLTexture> ntui_macos_create_appkit_text_texture(
    const char *text,
    double box_width,
    double font_size,
    double line_height,
    int font_weight,
    const char *text_align,
    const char *font_family,
    const char *font_style,
    NtuiMacosColor color,
    const NtuiMacosTextRenderOptions *options,
    int *out_width,
    int *out_height) {
  if (text == NULL || text[0] == 0 || box_width <= 0.0 || font_size <= 0.0) return nil;
  const int has_prelaid_run = options != NULL && options->line_index >= 0 && options->run_index >= 0;
  const int image_width = (int)ceil(fmax(1.0, box_width));
  const int image_height = (int)ceil(line_height > 0.0
      ? fmax(1.0, line_height)
      : fmax(font_size * 1.25, has_prelaid_run ? font_size * 1.25 : 0.0));
  if (image_width <= 0 || image_height <= 0) return nil;

  NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:NULL
                    pixelsWide:image_width
                    pixelsHigh:image_height
                 bitsPerSample:8
               samplesPerPixel:4
                      hasAlpha:YES
                      isPlanar:NO
                colorSpaceName:NSDeviceRGBColorSpace
                   bytesPerRow:0
                  bitsPerPixel:32];
  if (bitmap == nil) return nil;

  NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:context];
  [context setShouldAntialias:YES];
  [[NSColor clearColor] setFill];
  NSRectFill(NSMakeRect(0, 0, image_width, image_height));

  NSAffineTransform *flip = [NSAffineTransform transform];
  [flip translateXBy:0.0 yBy:(CGFloat)image_height];
  [flip scaleXBy:1.0 yBy:-1.0];
  [flip concat];

  NSString *string = [NSString stringWithUTF8String:text] ?: @"";
  NSFont *font = ntui_macos_resolve_font(font_family, font_style, font_size, font_weight);
  NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
  paragraph.alignment = ntui_macos_text_alignment(text_align, options == NULL ? "ltr" : options->direction);
  paragraph.lineBreakMode = has_prelaid_run ? NSLineBreakByClipping : NSLineBreakByWordWrapping;
  paragraph.minimumLineHeight = (CGFloat)image_height;
  paragraph.maximumLineHeight = (CGFloat)image_height;
  paragraph.lineSpacing = 0.0;
  paragraph.paragraphSpacing = 0.0;
  paragraph.paragraphSpacingBefore = 0.0;
  if (options != NULL && options->text_indent > 0.0) {
    paragraph.firstLineHeadIndent = (CGFloat)options->text_indent;
  }
  if (options != NULL && options->direction != NULL && strcmp(options->direction, "rtl") == 0) {
    paragraph.baseWritingDirection = NSWritingDirectionRightToLeft;
  } else {
    paragraph.baseWritingDirection = NSWritingDirectionLeftToRight;
  }

  NSMutableDictionary *attributes = [@{
    NSFontAttributeName: font,
    NSForegroundColorAttributeName: ntui_macos_ns_color(color),
    NSParagraphStyleAttributeName: paragraph,
  } mutableCopy];
  if (options != NULL && options->letter_spacing != 0.0) {
    attributes[NSKernAttributeName] = @((CGFloat)options->letter_spacing);
  }
  if (options != NULL && ntui_macos_text_has_token(options->text_decoration_line, "underline")) {
    attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    if (options->text_decoration_color != NULL && options->text_decoration_color[0] != 0) {
      attributes[NSUnderlineColorAttributeName] = ntui_macos_ns_color(ntui_macos_parse_color(options->text_decoration_color, color));
    }
  }
  if (options != NULL && ntui_macos_text_has_token(options->text_decoration_line, "line-through")) {
    attributes[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
    if (options->text_decoration_color != NULL && options->text_decoration_color[0] != 0) {
      attributes[NSStrikethroughColorAttributeName] = ntui_macos_ns_color(ntui_macos_parse_color(options->text_decoration_color, color));
    }
  }
  if (options != NULL && options->text_shadow != NULL && options->text_shadow[0] != 0) {
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowBlurRadius = 2.0;
    shadow.shadowOffset = NSMakeSize(1.0, -1.0);
    shadow.shadowColor = [NSColor colorWithDeviceWhite:0.0 alpha:0.35];
    attributes[NSShadowAttributeName] = shadow;
  }

  NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:string attributes:attributes];
  if (options != NULL && options->word_spacing != 0.0) {
    for (NSUInteger index = 0; index < string.length; index += 1) {
      if ([string characterAtIndex:index] == ' ') {
        [attributed addAttribute:NSKernAttributeName
                           value:@((CGFloat)(options->letter_spacing + options->word_spacing))
                           range:NSMakeRange(index, 1)];
      }
    }
  }
  [attributed drawWithRect:NSMakeRect(0, 0, image_width, image_height)
                   options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
  [NSGraphicsContext restoreGraphicsState];

  CGImageRef image = [bitmap CGImage];
  if (image == NULL) return nil;
  NSError *error = nil;
  NSDictionary *texture_options = @{
    MTKTextureLoaderOptionSRGB: @NO,
    MTKTextureLoaderOptionOrigin: MTKTextureLoaderOriginTopLeft,
  };
  id<MTLTexture> texture = [g_ntui_texture_loader newTextureWithCGImage:image options:texture_options error:&error];
  if (texture == nil) {
    NSLog(@"ntui_macos_renderer: failed to create text texture: %@", error);
    return nil;
  }
  g_ntui_appkit_fallback_texture_count += 1;
  g_ntui_appkit_fallback_texture_bytes += (uint64_t)((size_t)image_width * (size_t)image_height * 4U);
  *out_width = image_width;
  *out_height = image_height;
  return texture;
}

static double ntui_macos_atlas_text_width(
    const char *text,
    const NtuiMacosGlyphAtlas *atlas,
    const NtuiMacosTextRenderOptions *options) {
  double width = 0.0;
  for (const unsigned char *cursor = (const unsigned char *)text; cursor != NULL && *cursor != 0; cursor += 1) {
    if (*cursor < NTUI_MACOS_ATLAS_FIRST || *cursor > NTUI_MACOS_ATLAS_LAST) continue;
    const NtuiMacosGlyph *glyph = &atlas->glyphs[*cursor - NTUI_MACOS_ATLAS_FIRST];
    width += glyph->advance;
    if (options != NULL) {
      width += options->letter_spacing;
      if (*cursor == ' ') width += options->word_spacing;
    }
  }
  return width;
}

static double ntui_macos_aligned_text_x(
    double x,
    double box_width,
    double text_width,
    const char *text_align,
    const char *direction) {
  const NSTextAlignment alignment = ntui_macos_text_alignment(text_align, direction);
  if (alignment == NSTextAlignmentCenter) return x + fmax(0.0, (box_width - text_width) * 0.5);
  if (alignment == NSTextAlignmentRight) return x + fmax(0.0, box_width - text_width);
  return x;
}

static int ntui_macos_metal_draw_glyph_atlas_text(
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
    const NtuiMacosTextRenderOptions *options) {
  if (g_ntui_encoder == nil || color.a <= 0.0 || text == NULL || text[0] == 0) return 1;
  ntui_macos_ensure_font_manager();
  NtuiFontAtlas *font = ntui_font_manager_get_font(&g_ntui_font_manager, font_family, font_weight, font_style);
  if (font == NULL) font = g_ntui_font_manager.default_font;
  if (font == NULL) return 0;
  id<MTLTexture> texture = ntui_macos_texture_for_font(font);
  if (texture == nil) return 0;

  const int has_prelaid_run = options != NULL && options->line_index >= 0 && options->run_index >= 0;
  NtuiTextLayoutPolicy layout_policy = {
      .wrap_enabled = box_width > 0.0 && !has_prelaid_run ? 1 : 0,
      .has_explicit_line_height = line_height > 0.0 ? 1 : 0,
      .has_prelaid_text_run = has_prelaid_run,
      .letter_spacing_px = options == NULL ? 0.0f : (float)options->letter_spacing,
      .word_spacing_px = options == NULL ? 0.0f : (float)options->word_spacing,
      .text_indent_px = options == NULL ? 0.0f : (float)options->text_indent,
  };

  NtuiTextLayout layout;
  if (!ntui_text_layout_build_with_policy(
          text,
          (float)font_size,
          (float)line_height,
          box_width > 0.0 ? (float)box_width : 0.0f,
          &layout_policy,
          font,
          &layout)) {
    return 0;
  }

  float *packed_vertices = NULL;
  int float_count = 0;
  const NtuiTextAlign align = ntui_text_align_from_string_with_direction(
      text_align,
      options == NULL ? "ltr" : options->direction);
  const int vertices_ok = ntui_text_build_vertices_with_policy(
      text,
      &layout,
      (float)font_size,
      (float)line_height,
      (float)x,
      (float)baseline_y,
      box_width > 0.0 ? (float)box_width : 0.0f,
      align,
      font,
      &packed_vertices,
      &float_count,
      &layout_policy);
  if (!vertices_ok) {
    ntui_text_layout_destroy(&layout);
    return 0;
  }
  if (packed_vertices == NULL || float_count <= 0) {
    ntui_text_layout_destroy(&layout);
    return 1;
  }

  const int vertex_count = float_count / 4;
  const double resolved_line_height = line_height > 0.0
      ? line_height
      : (layout.line_count > 0 ? layout.height_px / (double)layout.line_count : font_size * 1.25);
  const double clip_top = baseline_offset > 0.0 ? baseline_y - baseline_offset : baseline_y - font_size;
  double vertical_shift = 0.0;
  if (baseline_offset > 0.0 && resolved_line_height > 0.0) {
    double min_y = 0.0;
    double max_y = 0.0;
    int has_ink_bounds = 0;
    for (int index = 0; index < vertex_count; index += 1) {
      const int base = index * 4;
      const double y = (double)packed_vertices[base + 1];
      if (!has_ink_bounds) {
        min_y = y;
        max_y = y;
        has_ink_bounds = 1;
      } else {
        if (y < min_y) min_y = y;
        if (y > max_y) max_y = y;
      }
    }
    if (has_ink_bounds) {
      const double line_center_y = clip_top + resolved_line_height * 0.5;
      const double ink_center_y = (min_y + max_y) * 0.5;
      const double max_shift = fmax(1.0, resolved_line_height * 0.5);
      vertical_shift = ntui_macos_clamp(line_center_y - ink_center_y, -max_shift, max_shift);
    }
  }

  NtuiMacosVertex *metal_vertices = (NtuiMacosVertex *)malloc((size_t)vertex_count * sizeof(NtuiMacosVertex));
  if (metal_vertices == NULL) {
    free(packed_vertices);
    ntui_text_layout_destroy(&layout);
    return 0;
  }
  for (int index = 0; index < vertex_count; index += 1) {
    const int base = index * 4;
    ntui_macos_write_vertex(
        &metal_vertices[index],
        (double)packed_vertices[base],
        (double)packed_vertices[base + 1] + vertical_shift,
        (double)packed_vertices[base + 2],
        (double)packed_vertices[base + 3],
        color);
  }

  const double clip_width = box_width > 0.0 ? box_width : layout.width_px;
  const double clip_height = layout.height_px > 0.0 ? layout.height_px : resolved_line_height;
  const int scissor_enabled = ntui_macos_set_text_scissor(clip_width > 0.0 ? x : 0.0, clip_top, clip_width, clip_height);

  [g_ntui_encoder setRenderPipelineState:g_ntui_text_pipeline];
  [g_ntui_encoder setFragmentTexture:texture atIndex:0];
  [g_ntui_encoder setVertexBytes:metal_vertices length:(NSUInteger)((size_t)vertex_count * sizeof(NtuiMacosVertex)) atIndex:0];
  [g_ntui_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)vertex_count];

  const double text_width = layout.width_px;
  if (options != NULL && ntui_macos_text_has_token(options->text_decoration_line, "underline")) {
    const double thickness = options->text_decoration_thickness > 0.0 ? options->text_decoration_thickness : fmax(1.0, font_size / 16.0);
    const double offset = options->text_underline_offset != 0.0 ? options->text_underline_offset : fmax(1.0, font_size / 8.0);
    const double decoration_baseline_y = baseline_y + vertical_shift;
    NtuiMacosColor decoration = ntui_macos_parse_color(options->text_decoration_color, color);
    decoration.a *= color.a;
    ntui_macos_metal_draw_rect(x, decoration_baseline_y + offset, fmin(clip_width, text_width), thickness, decoration);
  }
  if (options != NULL && ntui_macos_text_has_token(options->text_decoration_line, "line-through")) {
    const double decoration_baseline_y = baseline_y + vertical_shift;
    NtuiMacosColor decoration = ntui_macos_parse_color(options->text_decoration_color, color);
    decoration.a *= color.a;
    ntui_macos_metal_draw_rect(x, decoration_baseline_y - (font_size * 0.35), fmin(clip_width, text_width), fmax(1.0, font_size / 16.0), decoration);
  }

  if (scissor_enabled) ntui_macos_reset_scissor();
  free(metal_vertices);
  free(packed_vertices);
  ntui_text_layout_destroy(&layout);
  return 1;
}

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
    const NtuiMacosTextRenderOptions *options) {
  if (g_ntui_encoder == nil || color.a <= 0.0) return 1;
  if (!ntui_macos_should_use_appkit_text_fallback(text, options) &&
      ntui_macos_metal_draw_glyph_atlas_text(
          text,
          x,
          baseline_y,
          box_width,
          font_size,
          line_height,
          baseline_offset,
          font_weight,
          text_align,
          font_family,
          font_style,
          color,
          options)) {
    return 1;
  }

  int texture_width = 0;
  int texture_height = 0;
  id<MTLTexture> texture = ntui_macos_create_appkit_text_texture(
      text,
      box_width,
      font_size,
      line_height,
      font_weight,
      text_align,
      font_family,
      font_style,
      color,
      options,
      &texture_width,
      &texture_height);
  if (texture == nil) return 1;

  double text_top = baseline_y - font_size;
  if (baseline_offset > 0.0) text_top = baseline_y - baseline_offset;
  NtuiMacosVertex vertices[6];
  ntui_macos_make_quad(
      vertices,
      x,
      text_top,
      (double)texture_width,
      (double)texture_height,
      (NtuiMacosColor){.r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0});
  ntui_macos_flip_quad_texture_y(vertices);
  [g_ntui_encoder setRenderPipelineState:g_ntui_texture_pipeline];
  [g_ntui_encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
  [g_ntui_encoder setFragmentTexture:texture atIndex:0];
  [g_ntui_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  return 1;
}

int ntui_macos_metal_end_frame(void) {
  if (g_ntui_encoder == nil || g_ntui_command_buffer == nil || g_ntui_drawable == nil) return 0;
  [g_ntui_encoder endEncoding];
  [g_ntui_command_buffer presentDrawable:g_ntui_drawable];
  [g_ntui_command_buffer commit];
  g_ntui_frames_submitted += 1;
  g_ntui_encoder = nil;
  g_ntui_command_buffer = nil;
  g_ntui_drawable = nil;
  return 1;
}
