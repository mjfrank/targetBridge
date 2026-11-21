/* tb_metal_view.m — see tb_metal_view.h. */

#import "tb_metal_view.h"

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "tb_dpcm.h"

#include <stdio.h>
#include <string.h>

static NSString *const kTBMetalViewShaders =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct TBVertexOut { float4 position [[position]]; float2 uv; };\n"
     "vertex TBVertexOut tb_fullscreen_vertex(uint vid [[vertex_id]]) {\n"
     "    // Triangle strip covering the viewport.\n"
     "    float2 uv = float2(float(vid & 1u), float(vid >> 1u));\n"
     "    TBVertexOut out;\n"
     "    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);\n"
     "    out.uv = uv;\n"
     "    return out;\n"
     "}\n"
     "fragment float4 tb_rgb_fragment(TBVertexOut in [[stage_in]],\n"
     "                                texture2d<float> tex [[texture(0)]],\n"
     "                                sampler s [[sampler(0)]]) {\n"
     "    return float4(tex.sample(s, in.uv).rgb, 1.0);\n"
     "}\n"
     "// NV12, BT.709, video range: the same conversion the Sender and SDL use.\n"
     "fragment float4 tb_nv12_fragment(TBVertexOut in [[stage_in]],\n"
     "                                 texture2d<float> ytex [[texture(0)]],\n"
     "                                 texture2d<float> uvtex [[texture(1)]],\n"
     "                                 sampler s [[sampler(0)]]) {\n"
     "    float y = (ytex.sample(s, in.uv).r * 255.0 - 16.0) / 219.0;\n"
     "    float2 c = (uvtex.sample(s, in.uv).rg * 255.0 - 128.0) / 224.0;\n"
     "    float3 rgb = float3(y + 1.5748 * c.y,\n"
     "                        y - 0.1873 * c.x - 0.4681 * c.y,\n"
     "                        y + 1.8556 * c.x);\n"
     "    return float4(saturate(rgb), 1.0);\n"
     "}\n";

/* Lossless tile-DPCM (TBD2) decoder, from upstream pull request #201 by
 * Aykut Alpgiray Ates and Biao: one threadgroup per 8x8 tile, one thread per
 * pixel. It writes packed 32-bit pixels (BGRA8 or ARGB2101010, the layout of
 * the uncompressed modes) into a buffer that is then copied into the
 * picture's texture. No bounds checks: tb_dpcm_parse has validated every
 * offset before the kernel runs. */
static NSString *const kTBMetalViewDPCMShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
    "struct DpcmParams {\n"
    "  uint width, height, tilesX, tilesY, tileCount, outStridePx;\n"
    "  uint widthOff, seedOff, payOff;\n"
    "  uint bits, alpha, adaptiveColor, rowOffset, colOffset;\n"
    "};\n"
    "static inline uint tb_width_get(device const uchar *plane, uint idx) {\n"
    "  uchar b = plane[idx >> 1];\n"
    "  return (idx & 1u) ? uint(b >> 4) : uint(b & 0xF);\n"
    "}\n"
    /* n reaches 10 at 10-bit depth and the offset within a byte reaches 7, so a
     * value can span three bytes. */
    "static inline uint tb_bits_at(device const uchar *buf, uint p, uint n) {\n"
    "  if (n == 0u) return 0u;\n"
    "  uint byte = p >> 3, sh = p & 7u;\n"
    "  uint x = uint(buf[byte]);\n"
    "  if (sh + n >  8u) x |= uint(buf[byte + 1]) << 8;\n"
    "  if (sh + n > 16u) x |= uint(buf[byte + 2]) << 16;\n"
    "  return (x >> sh) & ((1u << n) - 1u);\n"
    "}\n"
    "static inline int tb_unzig(uint z) { return int((z >> 1) ^ (~(z & 1u) + 1u)); }\n"
    "\n"
    "kernel void tb_dpcm_decode(device const uchar *blob  [[buffer(0)]],\n"
    "                           device const uint  *gtab  [[buffer(1)]],\n"
    "                           device       uint  *out   [[buffer(2)]],\n"
    "                           constant DpcmParams &P    [[buffer(3)]],\n"
    "                           uint tile [[threadgroup_position_in_grid]],\n"
    "                           uint lane [[thread_position_in_threadgroup]]) {\n"
    "  device const uchar *wp = blob + P.widthOff;\n"
    "  device const uint  *seeds = (device const uint *)(blob + P.seedOff);\n"
    "  device const uchar *pay = blob + P.payOff;\n"
    "  const uint grp = tile / 64u, idx = tile % 64u;\n"
    "\n"
    "  uint jcost = 0u;\n"
    "  {\n"
    "    const uint jt = grp * 64u + lane;\n"
    "    if (lane < idx && jt < P.tileCount) {\n"
    "      const uint jx = jt % P.tilesX, jy = jt / P.tilesX;\n"
    "      const uint jw = min(8u, P.width  - jx * 8u);\n"
    "      const uint jh = min(8u, P.height - jy * 8u);\n"
    "      const uint jn = tb_width_get(wp, jt * 3u + 0u)\n"
    "                    + tb_width_get(wp, jt * 3u + 1u)\n"
    "                    + tb_width_get(wp, jt * 3u + 2u);\n"
    "      jcost = jn * (jw * jh - 1u);\n"
    "    }\n"
    "  }\n"
    "  threadgroup uint red[64];\n"
    "  red[lane] = jcost;\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  for (uint off = 32u; off > 0u; off >>= 1) {\n"
    "    if (lane < off) red[lane] += red[lane + off];\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  }\n"
    "\n"
    "  const uint x = lane & 7u, y = lane >> 3;\n"
    "  const uint txi = tile % P.tilesX, tyi = tile / P.tilesX;\n"
    "  const uint tw = min(8u, P.width  - txi * 8u);\n"
    "  const uint th = min(8u, P.height - tyi * 8u);\n"
    "  const uint coded = tw * th - 1u;\n"
    "  const bool live = (x < tw && y < th);\n"
    "\n"
    "  const uint n0 = tb_width_get(wp, tile * 3u + 0u);\n"
    "  const uint n1 = tb_width_get(wp, tile * 3u + 1u);\n"
    "  const uint n2 = tb_width_get(wp, tile * 3u + 2u);\n"
    /* The group base the wire carries is already byte-aligned; within a group
     * residuals are packed with no padding, so the scan is an exact bit sum. */
    "  const uint b0 = gtab[grp] + red[0];\n"
    "  const uint b1 = b0 + n0 * coded;\n"
    "  const uint b2 = b1 + n1 * coded;\n"
    "\n"
    "  int3 d = int3(0);\n"
    "  if (live && !(x == 0u && y == 0u)) {\n"
    "    const uint k = y * tw + x - 1u;\n"
    "    d.x = tb_unzig(tb_bits_at(pay, b0 + k * n0, n0));\n"
    "    d.y = tb_unzig(tb_bits_at(pay, b1 + k * n1, n1));\n"
    "    d.z = tb_unzig(tb_bits_at(pay, b2 + k * n2, n2));\n"
    "  }\n"
    "\n"
    "  threadgroup int3 rowd[64];\n"
    "  threadgroup int3 cold[8];\n"
    "  rowd[lane] = (x == 0u) ? int3(0) : d;\n"
    "  if (x == 0u) cold[y] = (y == 0u) ? int3(0) : d;\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  if (!live) return;\n"
    "\n"
    "  int3 acc = int3(0);\n"
    "  for (uint j = 1u; j <= y; ++j) acc += cold[j];\n"
    "  for (uint i = 1u; i <= x; ++i) acc += rowd[y * 8u + i];\n"
    "\n"
    /* One LE uint32 per tile holds the seed pixel at either depth. */
    "  const uint mask = (1u << P.bits) - 1u;\n"
    "  const uint sraw = seeds[tile];\n"
    "  const int3 seed = int3(int((sraw >> (0u * P.bits)) & mask),\n"
    "                         int((sraw >> (1u * P.bits)) & mask),\n"
    "                         int((sraw >> (2u * P.bits)) & mask));\n"
    "  uint3 v = uint3(seed + acc) & mask;\n"
    /* In adaptive blobs the seed marker selects the tile's coding space.
     * Restore RGB only after reconstructing all three transformed channels. */
    "  if (P.adaptiveColor != 0u && (sraw & 0x80000000u) != 0u) {\n"
    "    v.x = (v.x + v.y) & mask;\n"
    "    v.z = (v.z + v.y) & mask;\n"
    "  }\n"
    "  out[(P.rowOffset + tyi * 8u + y) * P.outStridePx + (P.colOffset + txi * 8u + x)] =\n"
    "      P.alpha | v.x | (v.y << P.bits) | (v.z << (2u * P.bits));\n"
    "}\n";

/* Matches DpcmParams in the shader. */
struct tb_dpcm_gpu_params {
    uint32_t width, height;
    uint32_t tilesX, tilesY;
    uint32_t tileCount;
    uint32_t outStridePx;
    uint32_t widthOff, seedOff, payOff;
    uint32_t bits;          /* 8 or 10; channel c sits at bit c*bits */
    uint32_t alpha;         /* opaque alpha, pre-shifted for this depth */
    uint32_t adaptiveColor; /* seed bit 31 may select reversible B-G/R-G */
    uint32_t rowOffset, colOffset;
};

/* Largest picture a DPCM frame may describe (the transport's 5K). */
#define TB_DPCM_MAX_W 5120
#define TB_DPCM_MAX_H 2880

/* What the textures currently hold, and how they are filled. */
enum tb_metal_kind {
    TB_METAL_KIND_NONE = 0,
    TB_METAL_KIND_NV12_CPU,   /* Y + CbCr, written by the CPU */
    TB_METAL_KIND_NV12_GPU,   /* Y + CbCr, blitted from the frame memory */
    TB_METAL_KIND_RGB10,      /* BGR10A2, blitted from the frame memory */
    TB_METAL_KIND_NV12_SURFACE, /* Y + CbCr, the decoder's own IOSurface (zero-copy) */
    TB_METAL_KIND_DPCM8,      /* BGRA8, decoded from a DPCM frame on the GPU */
    TB_METAL_KIND_DPCM10      /* BGR10A2, decoded from a DPCM frame on the GPU */
};

/* Kinds drawn from one RGB texture (the others are NV12). */
static int tb_metal_kind_is_rgb(int kind) {
    return kind == TB_METAL_KIND_RGB10 || kind == TB_METAL_KIND_DPCM8 || kind == TB_METAL_KIND_DPCM10;
}

#define TB_METAL_PLANES 2

/* Zero-copy frames stay referenced for this many newer frames, so the decoder
 * cannot reuse a picture the GPU may still be drawing (SDL keeps up to three
 * drawables in flight). */
#define TB_METAL_SURFACE_RING 4

@interface TBMetalView : NSObject {
@public
    id<MTLTexture> _textures[TB_METAL_PLANES];
    id<MTLBuffer>  _sources[TB_METAL_PLANES];
    const void    *_sourcePointers[TB_METAL_PLANES];
    size_t         _sourceLengths[TB_METAL_PLANES];
    CVMetalTextureCacheRef _textureCache;
    CVPixelBufferRef  _ringFrames[TB_METAL_SURFACE_RING];
    CVMetalTextureRef _ringTextures[TB_METAL_SURFACE_RING][TB_METAL_PLANES];
    int               _ringNext;
}
@property (nonatomic, strong) CAMetalLayer *layer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLLibrary> library;
@property (nonatomic, strong) id<MTLSamplerState> sampler;
@property (nonatomic, strong) id<MTLRenderPipelineState> rgbPipeline;
@property (nonatomic) MTLPixelFormat rgbPipelineFormat;
@property (nonatomic, strong) id<MTLRenderPipelineState> nv12Pipeline;
@property (nonatomic) MTLPixelFormat nv12PipelineFormat;
@property (nonatomic) int kind;
@property (nonatomic) int width;
@property (nonatomic) int height;
@property (nonatomic) BOOL filled;
@property (nonatomic) MTLPixelFormat defaultFormat;
@property (nonatomic) int colorSpace;
/* DPCM: compute pipeline (built on first use), the blob's upload buffer and
 * the decoded pixels; all reused while their size fits. */
@property (nonatomic, strong) id<MTLComputePipelineState> dpcmPipeline;
@property (nonatomic) int dpcmPipelineTried;
@property (nonatomic, strong) id<MTLBuffer> dpcmUpload;
@property (nonatomic, strong) id<MTLBuffer> dpcmPixels;
@end

@implementation TBMetalView
@end

struct tb_metal_view {
    void *object; /* TBMetalView, retained */
};

static TBMetalView *tb_view(struct tb_metal_view *v) {
    return v ? (__bridge TBMetalView *)v->object : nil;
}

struct tb_metal_view *tb_metal_view_create(SDL_Renderer *ren) {
    if (!ren) return NULL;
    @autoreleasepool {
        CAMetalLayer *layer = (__bridge CAMetalLayer *)SDL_RenderGetMetalLayer(ren);
        if (!layer || !layer.device) return NULL;

        TBMetalView *view = [TBMetalView new];
        view.layer = layer;
        view.device = layer.device;
        view.defaultFormat = layer.pixelFormat;
        view.queue = [view.device newCommandQueue];
        NSError *error = nil;
        view.library = [view.device newLibraryWithSource:kTBMetalViewShaders options:nil error:&error];
        if (!view.queue || !view.library) {
            fprintf(stderr, "[metal] video view setup failed: %s\n",
                    error ? error.localizedDescription.UTF8String : "no command queue");
            return NULL;
        }
        MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
        sampler.minFilter = MTLSamplerMinMagFilterLinear;
        sampler.magFilter = MTLSamplerMinMagFilterLinear;
        sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
        view.sampler = [view.device newSamplerStateWithDescriptor:sampler];
        if (!view.sampler) return NULL;

        struct tb_metal_view *v = (struct tb_metal_view *)calloc(1, sizeof(*v));
        if (!v) return NULL;
        v->object = (__bridge_retained void *)view;
        fprintf(stderr, "[metal] video view ready on %s\n", view.device.name.UTF8String);
        return v;
    }
}

static void tb_metal_view_release_ring(TBMetalView *view) {
    for (int i = 0; i < TB_METAL_SURFACE_RING; ++i) {
        for (int p = 0; p < TB_METAL_PLANES; ++p) {
            if (view->_ringTextures[i][p]) CFRelease(view->_ringTextures[i][p]);
            view->_ringTextures[i][p] = NULL;
        }
        if (view->_ringFrames[i]) CVPixelBufferRelease(view->_ringFrames[i]);
        view->_ringFrames[i] = NULL;
    }
    view->_ringNext = 0;
}

void tb_metal_view_destroy(struct tb_metal_view *v) {
    if (!v) return;
    TBMetalView *view = (__bridge_transfer TBMetalView *)v->object;
    tb_metal_view_release_ring(view);
    if (view->_textureCache) CFRelease(view->_textureCache);
    view->_textureCache = NULL;
    view.layer.pixelFormat = view.defaultFormat;
    view.layer.colorspace = NULL;
    view = nil;
    free(v);
}

static void tb_metal_view_forget_sources(TBMetalView *view) {
    for (int i = 0; i < TB_METAL_PLANES; ++i) {
        view->_sources[i] = nil;
        view->_sourcePointers[i] = NULL;
        view->_sourceLengths[i] = 0;
    }
}

void tb_metal_view_reset(struct tb_metal_view *v) {
    TBMetalView *view = tb_view(v);
    if (!view) return;
    for (int i = 0; i < TB_METAL_PLANES; ++i) view->_textures[i] = nil;
    tb_metal_view_forget_sources(view);
    tb_metal_view_release_ring(view);
    view.dpcmUpload = nil;
    view.dpcmPixels = nil;
    view.kind = TB_METAL_KIND_NONE;
    view.width = 0;
    view.height = 0;
    view.filled = NO;
}

void tb_metal_view_set_10bit_drawable(struct tb_metal_view *v, int on) {
    TBMetalView *view = tb_view(v);
    if (!view) return;
    const MTLPixelFormat format = on ? MTLPixelFormatBGR10A2Unorm : view.defaultFormat;
    if (view.layer.pixelFormat != format) {
        view.layer.pixelFormat = format;
        fprintf(stderr, "[metal] drawable %s\n", on ? "BGR10A2 (10-bit)" : "8-bit");
    }
}

void tb_metal_view_set_low_latency(struct tb_metal_view *v, int on) {
    TBMetalView *view = tb_view(v);
    if (!view) return;
    /* Two drawables instead of three: one frame less queued for the screen
     * while it waits for the refresh; may stutter sooner under load. */
    const NSUInteger count = on ? 2 : 3;
    if (view.layer.maximumDrawableCount != count) {
        view.layer.maximumDrawableCount = count;
        fprintf(stderr, "[metal] drawables %lu\n", (unsigned long)count);
    }
}

void tb_metal_view_set_display_sync(struct tb_metal_view *v, int on) {
    TBMetalView *view = tb_view(v);
    if (!view) return;
    if (@available(macOS 10.13, *)) {
        if (view.layer.displaySyncEnabled != (BOOL)on) {
            view.layer.displaySyncEnabled = on ? YES : NO;
            fprintf(stderr, "[metal] display sync %s\n", on ? "on" : "off");
        }
    }
}

static id<MTLTexture> tb_metal_view_new_texture(TBMetalView *view, MTLPixelFormat format,
                                                int w, int h, MTLStorageMode storage) {
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:(NSUInteger)w
                                                          height:(NSUInteger)h
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = storage;
    return [view.device newTextureWithDescriptor:desc];
}

/* Makes sure the textures fit `kind` and the picture size. New textures are
 * empty until the next upload fills them completely. */
static BOOL tb_metal_view_prepare(TBMetalView *view, int kind, int w, int h) {
    if (view.kind == kind && view.width == w && view.height == h && view->_textures[0]) return YES;
    for (int i = 0; i < TB_METAL_PLANES; ++i) view->_textures[i] = nil;
    tb_metal_view_forget_sources(view);
    tb_metal_view_release_ring(view);
    view.filled = NO;

    /* CPU uploads need textures the CPU can write (managed); GPU blits go
     * into private textures, the fastest to sample on a discrete GPU. */
    const MTLStorageMode storage =
        kind == TB_METAL_KIND_NV12_CPU ? MTLStorageModeManaged : MTLStorageModePrivate;
    const char *name = "";
    if (kind == TB_METAL_KIND_RGB10 || kind == TB_METAL_KIND_DPCM10) {
        view->_textures[0] = tb_metal_view_new_texture(view, MTLPixelFormatBGR10A2Unorm, w, h, storage);
        name = "BGR10A2 (10-bit)";
    } else if (kind == TB_METAL_KIND_DPCM8) {
        view->_textures[0] = tb_metal_view_new_texture(view, MTLPixelFormatBGRA8Unorm, w, h, storage);
        name = "BGRA8";
    } else {
        view->_textures[0] = tb_metal_view_new_texture(view, MTLPixelFormatR8Unorm, w, h, storage);
        view->_textures[1] = tb_metal_view_new_texture(view, MTLPixelFormatRG8Unorm, w / 2, h / 2, storage);
        name = "NV12";
    }
    if (!view->_textures[0] || (!tb_metal_kind_is_rgb(kind) && !view->_textures[1])) {
        fprintf(stderr, "[metal] could not create %dx%d %s textures\n", w, h, name);
        view.kind = TB_METAL_KIND_NONE;
        return NO;
    }
    view.kind = kind;
    view.width = w;
    view.height = h;
    fprintf(stderr, "[metal] textures %dx%d %s, %s\n", w, h, name,
            kind == TB_METAL_KIND_NV12_CPU ? "CPU upload"
                : (kind == TB_METAL_KIND_DPCM8 || kind == TB_METAL_KIND_DPCM10) ? "DPCM decoded on the GPU"
                : "GPU blit");
    return YES;
}

/* The Receiver's frame memory, wrapped so the GPU reads it in place. */
static id<MTLBuffer> tb_metal_view_source(TBMetalView *view, int plane,
                                          const uint8_t *memory, size_t capacity) {
    if (view->_sources[plane] && view->_sourcePointers[plane] == memory &&
        view->_sourceLengths[plane] == capacity) {
        return view->_sources[plane];
    }
    id<MTLBuffer> buffer = [view.device newBufferWithBytesNoCopy:(void *)memory
                                                          length:capacity
                                                         options:MTLResourceStorageModeShared
                                                     deallocator:nil];
    view->_sources[plane] = buffer;
    view->_sourcePointers[plane] = buffer ? memory : NULL;
    view->_sourceLengths[plane] = buffer ? capacity : 0;
    if (!buffer) fprintf(stderr, "[metal] could not wrap the frame memory\n");
    return buffer;
}

static void tb_metal_view_blit_rows(id<MTLBlitCommandEncoder> blit, id<MTLBuffer> source,
                                    size_t pitch, NSUInteger first_row, NSUInteger rows,
                                    NSUInteger width, id<MTLTexture> texture) {
    [blit copyFromBuffer:source
            sourceOffset:pitch * first_row
       sourceBytesPerRow:pitch
     sourceBytesPerImage:pitch * rows
              sourceSize:MTLSizeMake(width, rows, 1)
               toTexture:texture
        destinationSlice:0
        destinationLevel:0
       destinationOrigin:MTLOriginMake(0, first_row, 0)];
}

static int tb_metal_view_finish(TBMetalView *view, id<MTLCommandBuffer> commands) {
    [commands commit];
    [commands waitUntilCompleted];
    if (commands.status != MTLCommandBufferStatusCompleted) {
        fprintf(stderr, "[metal] upload failed: %s\n",
                commands.error ? commands.error.localizedDescription.UTF8String : "unknown");
        return -1;
    }
    view.filled = YES;
    return 0;
}

static void tb_metal_view_clamp_rows(TBMetalView *view, int h, int *first_row, int *end_row) {
    if (!view.filled) {
        *first_row = 0;
        *end_row = h;
    }
    *first_row &= ~1;
    *end_row = (*end_row + 1) & ~1;
    if (*first_row < 0) *first_row = 0;
    if (*end_row > h) *end_row = h;
}

int tb_metal_view_upload_nv12(struct tb_metal_view *v,
                              const uint8_t *y, int y_stride,
                              const uint8_t *uv, int uv_stride,
                              int w, int h) {
    TBMetalView *view = tb_view(v);
    if (!view || !y || !uv || w <= 1 || h <= 1 || (w & 1) || (h & 1) ||
        y_stride < w || uv_stride < w) return -1;
    @autoreleasepool {
        if (!tb_metal_view_prepare(view, TB_METAL_KIND_NV12_CPU, w, h)) return -1;
        [view->_textures[0] replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h)
                              mipmapLevel:0
                                withBytes:y
                              bytesPerRow:(NSUInteger)y_stride];
        [view->_textures[1] replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w / 2, (NSUInteger)h / 2)
                              mipmapLevel:0
                                withBytes:uv
                              bytesPerRow:(NSUInteger)uv_stride];
        view.filled = YES;
        return 0;
    }
}

int tb_metal_view_upload_nv12_rows(struct tb_metal_view *v,
                                   const uint8_t *y, size_t y_capacity,
                                   const uint8_t *uv, size_t uv_capacity,
                                   int w, int h, int first_row, int end_row) {
    TBMetalView *view = tb_view(v);
    if (!view || !y || !uv || w <= 1 || h <= 1 || (w & 1) || (h & 1)) return -1;
    if (y_capacity < (size_t)w * (size_t)h || uv_capacity < (size_t)w * (size_t)(h / 2)) return -1;
    @autoreleasepool {
        if (!tb_metal_view_prepare(view, TB_METAL_KIND_NV12_GPU, w, h)) return -1;
        id<MTLBuffer> y_source = tb_metal_view_source(view, 0, y, y_capacity);
        id<MTLBuffer> uv_source = tb_metal_view_source(view, 1, uv, uv_capacity);
        if (!y_source || !uv_source) return -1;
        tb_metal_view_clamp_rows(view, h, &first_row, &end_row);
        if (end_row <= first_row) return 0;

        id<MTLCommandBuffer> commands = [view.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        const NSUInteger rows = (NSUInteger)(end_row - first_row);
        tb_metal_view_blit_rows(blit, y_source, (size_t)w, (NSUInteger)first_row, rows,
                                (NSUInteger)w, view->_textures[0]);
        tb_metal_view_blit_rows(blit, uv_source, (size_t)w, (NSUInteger)first_row / 2, rows / 2,
                                (NSUInteger)w / 2, view->_textures[1]);
        [blit endEncoding];
        return tb_metal_view_finish(view, commands);
    }
}

int tb_metal_view_upload_rgb10(struct tb_metal_view *v,
                               const uint8_t *pixels, size_t pixels_capacity,
                               int w, int h, int first_row, int end_row) {
    TBMetalView *view = tb_view(v);
    if (!view || !pixels || w <= 0 || h <= 0) return -1;
    const size_t pitch = (size_t)w * 4u;
    if (pixels_capacity < pitch * (size_t)h) return -1;
    @autoreleasepool {
        if (!tb_metal_view_prepare(view, TB_METAL_KIND_RGB10, w, h)) return -1;
        id<MTLBuffer> source = tb_metal_view_source(view, 0, pixels, pixels_capacity);
        if (!source) return -1;
        tb_metal_view_clamp_rows(view, h, &first_row, &end_row);
        if (end_row <= first_row) return 0;

        id<MTLCommandBuffer> commands = [view.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        tb_metal_view_blit_rows(blit, source, pitch, (NSUInteger)first_row,
                                (NSUInteger)(end_row - first_row), (NSUInteger)w, view->_textures[0]);
        [blit endEncoding];
        return tb_metal_view_finish(view, commands);
    }
}

int tb_metal_view_show_pixbuf(struct tb_metal_view *v, void *cv_pixel_buffer) {
    TBMetalView *view = tb_view(v);
    CVPixelBufferRef pb = (CVPixelBufferRef)cv_pixel_buffer;
    if (!view || !pb) return -1;
    /* The shader expects 8-bit NV12 in video range, as the copy path does. */
    if (CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) return -1;
    if (!CVPixelBufferGetIOSurface(pb)) return -1;
    const int w = (int)CVPixelBufferGetWidth(pb);
    const int h = (int)CVPixelBufferGetHeight(pb);
    if (w <= 1 || h <= 1 || (w & 1) || (h & 1)) return -1;
    @autoreleasepool {
        if (!view->_textureCache &&
            CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, view.device, NULL,
                                      &view->_textureCache) != kCVReturnSuccess) {
            view->_textureCache = NULL;
            fprintf(stderr, "[metal] zero-copy: no texture cache\n");
            return -1;
        }
        CVMetalTextureRef planes[TB_METAL_PLANES] = { NULL, NULL };
        const MTLPixelFormat formats[TB_METAL_PLANES] = { MTLPixelFormatR8Unorm, MTLPixelFormatRG8Unorm };
        for (int p = 0; p < TB_METAL_PLANES; ++p) {
            const size_t pw = CVPixelBufferGetWidthOfPlane(pb, (size_t)p);
            const size_t ph = CVPixelBufferGetHeightOfPlane(pb, (size_t)p);
            if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, view->_textureCache, pb, NULL,
                                                          formats[p], pw, ph, (size_t)p,
                                                          &planes[p]) != kCVReturnSuccess ||
                !planes[p] || !CVMetalTextureGetTexture(planes[p])) {
                for (int q = 0; q < TB_METAL_PLANES; ++q) if (planes[q]) CFRelease(planes[q]);
                return -1;
            }
        }

        if (view.kind != TB_METAL_KIND_NV12_SURFACE || view.width != w || view.height != h) {
            for (int i = 0; i < TB_METAL_PLANES; ++i) view->_textures[i] = nil;
            tb_metal_view_forget_sources(view);
            tb_metal_view_release_ring(view);
            view.kind = TB_METAL_KIND_NV12_SURFACE;
            view.width = w;
            view.height = h;
            fprintf(stderr, "[metal] textures %dx%d NV12, zero-copy from the decoder\n", w, h);
        }

        /* Replace the oldest entry; the newer ones may still be in flight. */
        const int slot = view->_ringNext;
        for (int p = 0; p < TB_METAL_PLANES; ++p) {
            if (view->_ringTextures[slot][p]) CFRelease(view->_ringTextures[slot][p]);
            view->_ringTextures[slot][p] = planes[p];
            view->_textures[p] = CVMetalTextureGetTexture(planes[p]);
        }
        if (view->_ringFrames[slot]) CVPixelBufferRelease(view->_ringFrames[slot]);
        view->_ringFrames[slot] = CVPixelBufferRetain(pb);
        view->_ringNext = (slot + 1) % TB_METAL_SURFACE_RING;
        CVMetalTextureCacheFlush(view->_textureCache, 0);
        view.filled = YES;
        return 0;
    }
}

void tb_metal_view_set_color_space(struct tb_metal_view *v, int color_space) {
    TBMetalView *view = tb_view(v);
    if (!view || view.colorSpace == color_space) return;
    CGColorSpaceRef space = NULL;
    const char *name = "unmanaged";
    if (color_space == TB_COLOR_SPACE_SRGB) {
        space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        name = "sRGB";
    } else if (color_space == TB_COLOR_SPACE_DISPLAY_P3) {
        space = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
        name = "Display P3";
    } else {
        color_space = TB_COLOR_SPACE_UNMANAGED;
    }
    view.layer.colorspace = space;
    if (space) CGColorSpaceRelease(space);
    view.colorSpace = color_space;
    fprintf(stderr, "[metal] colour space %s\n", name);
}

int tb_screen_supports_display_p3(void) {
    @autoreleasepool {
        NSScreen *screen = NSScreen.screens.firstObject;
        return screen && [screen canRepresentDisplayGamut:NSDisplayGamutP3] ? 1 : 0;
    }
}

static id<MTLComputePipelineState> tb_metal_view_dpcm_pipeline(TBMetalView *view) {
    if (view.dpcmPipeline || view.dpcmPipelineTried) return view.dpcmPipeline;
    view.dpcmPipelineTried = 1;
    NSError *error = nil;
    id<MTLLibrary> library = [view.device newLibraryWithSource:kTBMetalViewDPCMShader options:nil error:&error];
    id<MTLFunction> function = [library newFunctionWithName:@"tb_dpcm_decode"];
    if (function) view.dpcmPipeline = [view.device newComputePipelineStateWithFunction:function error:&error];
    /* One threadgroup of 64 threads per tile. */
    if (view.dpcmPipeline && view.dpcmPipeline.maxTotalThreadsPerThreadgroup < 64) view.dpcmPipeline = nil;
    fprintf(stderr, "[metal] DPCM decode %s on %s%s%s\n", view.dpcmPipeline ? "available" : "unavailable",
            view.device.name.UTF8String, error ? ": " : "",
            error ? error.localizedDescription.UTF8String : "");
    return view.dpcmPipeline;
}

int tb_metal_view_supports_dpcm(struct tb_metal_view *v) {
    TBMetalView *view = tb_view(v);
    if (!view) return 0;
    @autoreleasepool {
        return tb_metal_view_dpcm_pipeline(view) ? 1 : 0;
    }
}

static id<MTLBuffer> tb_metal_view_buffer(TBMetalView *view, id<MTLBuffer> current, size_t bytes,
                                          MTLResourceOptions options) {
    if (current && current.length >= bytes) return current;
    return [view.device newBufferWithLength:bytes options:options];
}

int tb_metal_view_show_dpcm(struct tb_metal_view *v, const uint8_t *blob, size_t len) {
    TBMetalView *view = tb_view(v);
    if (!view || !blob) return -1;
    struct tb_dpcm_info info;
    if (tb_dpcm_parse(blob, len, &info) != 0) {
        fprintf(stderr, "[metal] rejected a malformed DPCM frame (%zu bytes)\n", len);
        return -1;
    }
    if (info.width <= 0 || info.height <= 0 || info.width > TB_DPCM_MAX_W || info.height > TB_DPCM_MAX_H) return -1;
    @autoreleasepool {
        id<MTLComputePipelineState> pipeline = tb_metal_view_dpcm_pipeline(view);
        if (!pipeline) return -1;
        const int kind = info.ten_bit ? TB_METAL_KIND_DPCM10 : TB_METAL_KIND_DPCM8;
        if (!tb_metal_view_prepare(view, kind, info.width, info.height)) return -1;

        /* The blob arrives in the parser's memory, which is not page aligned,
         * so it is copied once into a buffer the GPU reads. */
        view.dpcmUpload = tb_metal_view_buffer(view, view.dpcmUpload, len, MTLResourceStorageModeShared);
        const size_t pitch = (size_t)info.width * 4u;
        view.dpcmPixels = tb_metal_view_buffer(view, view.dpcmPixels, pitch * (size_t)info.height,
                                               MTLResourceStorageModePrivate);
        if (!view.dpcmUpload || !view.dpcmPixels) {
            fprintf(stderr, "[metal] DPCM: could not allocate buffers\n");
            return -1;
        }
        memcpy(view.dpcmUpload.contents, blob, len);

        struct tb_dpcm_gpu_params params = {
            (uint32_t)info.width, (uint32_t)info.height,
            (uint32_t)info.tiles_x, (uint32_t)info.tiles_y,
            info.tile_count, (uint32_t)info.width,
            (uint32_t)info.width_plane_off, (uint32_t)info.seed_plane_off,
            (uint32_t)info.payload_off,
            info.ten_bit ? 10u : 8u,
            info.ten_bit ? (3u << 30) : (0xFFu << 24),
            info.adaptive_color ? 1u : 0u,
            0u, 0u
        };

        /* Decode, then copy the pixels into the texture: one command buffer,
         * finished before the picture is drawn, like the other uploads. */
        id<MTLCommandBuffer> commands = [view.queue commandBuffer];
        id<MTLComputeCommandEncoder> compute = [commands computeCommandEncoder];
        [compute setComputePipelineState:pipeline];
        [compute setBuffer:view.dpcmUpload offset:0 atIndex:0];
        [compute setBuffer:view.dpcmUpload offset:info.group_table_off atIndex:1];
        [compute setBuffer:view.dpcmPixels offset:0 atIndex:2];
        [compute setBytes:&params length:sizeof(params) atIndex:3];
        [compute dispatchThreadgroups:MTLSizeMake(info.tile_count, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [compute endEncoding];
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        tb_metal_view_blit_rows(blit, view.dpcmPixels, pitch, 0, (NSUInteger)info.height,
                                (NSUInteger)info.width, view->_textures[0]);
        [blit endEncoding];
        return tb_metal_view_finish(view, commands);
    }
}

static id<MTLRenderPipelineState> tb_metal_view_make_pipeline(TBMetalView *view, NSString *fragment,
                                                              MTLPixelFormat format) {
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [view.library newFunctionWithName:@"tb_fullscreen_vertex"];
    desc.fragmentFunction = [view.library newFunctionWithName:fragment];
    desc.colorAttachments[0].pixelFormat = format;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [view.device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pipeline) {
        fprintf(stderr, "[metal] pipeline failed: %s\n",
                error ? error.localizedDescription.UTF8String : "unknown");
    }
    return pipeline;
}

static id<MTLRenderPipelineState> tb_metal_view_pipeline(TBMetalView *view, MTLPixelFormat format) {
    if (tb_metal_kind_is_rgb(view.kind)) {
        if (!view.rgbPipeline || view.rgbPipelineFormat != format) {
            view.rgbPipeline = tb_metal_view_make_pipeline(view, @"tb_rgb_fragment", format);
            view.rgbPipelineFormat = format;
        }
        return view.rgbPipeline;
    }
    if (!view.nv12Pipeline || view.nv12PipelineFormat != format) {
        view.nv12Pipeline = tb_metal_view_make_pipeline(view, @"tb_nv12_fragment", format);
        view.nv12PipelineFormat = format;
    }
    return view.nv12Pipeline;
}

int tb_metal_view_draw(struct tb_metal_view *v, SDL_Renderer *ren) {
    TBMetalView *view = tb_view(v);
    if (!view || view.kind == TB_METAL_KIND_NONE || !view.filled) return -1;
    @autoreleasepool {
        /* Flushes SDL's queued clear and returns its render encoder for this
         * frame's drawable. SDL sets its own state again for later draws. */
        id<MTLRenderCommandEncoder> encoder =
            (__bridge id<MTLRenderCommandEncoder>)SDL_RenderGetMetalCommandEncoder(ren);
        if (!encoder) return -1;
        id<MTLRenderPipelineState> pipeline = tb_metal_view_pipeline(view, view.layer.pixelFormat);
        if (!pipeline) return -1;
        /* The encoder starts with the scissor covering the whole drawable,
         * as only a clear ran before; the viewport is SDL's output size. */
        int out_w = 0, out_h = 0;
        if (SDL_GetRendererOutputSize(ren, &out_w, &out_h) != 0 || out_w <= 0 || out_h <= 0) return -1;
        [encoder setViewport:(MTLViewport){ 0.0, 0.0, (double)out_w, (double)out_h, 0.0, 1.0 }];
        [encoder setRenderPipelineState:pipeline];
        [encoder setFragmentTexture:view->_textures[0] atIndex:0];
        if (!tb_metal_kind_is_rgb(view.kind)) [encoder setFragmentTexture:view->_textures[1] atIndex:1];
        [encoder setFragmentSamplerState:view.sampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        return 0;
    }
}
