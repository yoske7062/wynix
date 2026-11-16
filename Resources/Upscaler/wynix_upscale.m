// WYNIX Upscale: MetalFX spatial upscaling for Metal games running in Wine (D3DMetal, DX12).
//
// Loaded into the Wine process with DYLD_INSERT_LIBRARIES (x86_64, runs under Rosetta like
// Wine). D3DMetal itself is never modified: this only hooks two public Apple entry points
// in-process.
//
//   -[CAMetalLayer nextDrawable]       returns a proxy drawable whose texture is a smaller
//                                      offscreen texture (the game's internal resolution).
//   -[MTLCommandBuffer presentDrawable:] when given a proxy, appends a MetalFX spatial upscale
//                                      (proxy texture -> real drawable) to the SAME command
//                                      buffer, then presents the real drawable. Same command
//                                      buffer = GPU ordering for free, no extra latency.
//
// Off unless WYNIX_UPSCALE=1. Any failure (no MetalFX, unsupported format, odd sizes) falls
// back to the untouched original path, so the game always still runs.
//
// Env:
//   WYNIX_UPSCALE=1            enable
//   WYNIX_UPSCALE_SCALE=1.6    output/input ratio (default 1.6, clamped 1.0-2.0)
//   WYNIX_UPSCALE_ANY_LAYER=1  hook every CAMetalLayer (tests); default only Wine's views
//   WYNIX_UPSCALE_LOG=1        log decisions to stderr

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <dlfcn.h>

static BOOL gLog, gAnyLayer, gDisabled;
static volatile BOOL gD3DMetalLoaded;  // only D3DMetal games are upscaled; DXMT/DXVK/Steam are not
static double gScale = 1.6;
static IMP gOrigNextDrawable, gOrigPresent;
static char kStateKey;

#define LOG(...) do { if (gLog) { fprintf(stderr, "wynix_upscale: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

@interface WynixLayerState : NSObject
@property id<MTLFXSpatialScaler> scaler;
@property NSArray<id<MTLTexture>> *ring;
@property NSUInteger next, outW, outH;
@property MTLPixelFormat format;
@end
@implementation WynixLayerState
@end

@interface WynixProxyDrawable : NSObject <CAMetalDrawable>
@property id<CAMetalDrawable> real;
@property id<MTLTexture> texture;
@property WynixLayerState *state;
@end

@implementation WynixProxyDrawable
- (CAMetalLayer *)layer { return self.real.layer; }
- (NSUInteger)drawableID { return self.real.drawableID; }
- (CFTimeInterval)presentedTime { return self.real.presentedTime; }
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)block { [self.real addPresentedHandler:block]; }
// Direct presents (no command buffer) cannot carry the upscale; show the real drawable.
// Seeing one means this game presents some other way: stop proxying from the next frame.
- (void)present { gDisabled = YES; [self.real present]; }
- (void)presentAtTime:(CFTimeInterval)t { gDisabled = YES; [self.real presentAtTime:t]; }
- (void)presentAfterMinimumDuration:(CFTimeInterval)d { gDisabled = YES; [self.real presentAfterMinimumDuration:d]; }
// Anything else (private selectors Metal may probe) goes to the real drawable.
- (id)forwardingTargetForSelector:(SEL)sel { return self.real; }
@end

static BOOL isWineLayer(CAMetalLayer *layer) {
    if (gAnyLayer) return YES;
    if (!gD3DMetalLoaded) return NO;
    id d = layer.delegate;
    return d && strstr(class_getName([d class]), "WineMetalView") != NULL;
}

// Builds (or reuses) the scaler and texture ring for this output size. nil = don't upscale.
static WynixLayerState *stateFor(CAMetalLayer *layer, NSUInteger outW, NSUInteger outH) {
    WynixLayerState *s = objc_getAssociatedObject(layer, &kStateKey);
    MTLPixelFormat fmt = layer.pixelFormat;
    if (s && s.outW == outW && s.outH == outH && s.format == fmt) return s.scaler ? s : nil;

    s = [WynixLayerState new];
    s.outW = outW; s.outH = outH; s.format = fmt;
    objc_setAssociatedObject(layer, &kStateKey, s, OBJC_ASSOCIATION_RETAIN);  // caches failures too

    NSUInteger inW = (NSUInteger)(outW / gScale + 0.5), inH = (NSUInteger)(outH / gScale + 0.5);
    id<MTLDevice> dev = layer.device;
    if (!dev || inW < 64 || inH < 64 || inW >= outW) { LOG("skip %lux%lu", outW, outH); return nil; }
    if (![MTLFXSpatialScalerDescriptor supportsDevice:dev]) { LOG("MetalFX unsupported"); return nil; }

    MTLFXSpatialScalerDescriptor *desc = [MTLFXSpatialScalerDescriptor new];
    desc.inputWidth = inW; desc.inputHeight = inH;
    desc.outputWidth = outW; desc.outputHeight = outH;
    desc.colorTextureFormat = fmt; desc.outputTextureFormat = fmt;
    switch (fmt) {  // _sRGB samples come back linear; float formats may hold HDR values
        case MTLPixelFormatBGRA8Unorm_sRGB: case MTLPixelFormatRGBA8Unorm_sRGB:
            desc.colorProcessingMode = MTLFXSpatialScalerColorProcessingModeLinear; break;
        case MTLPixelFormatRGBA16Float:
            desc.colorProcessingMode = MTLFXSpatialScalerColorProcessingModeHDR; break;
        default:
            desc.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
    }
    id<MTLFXSpatialScaler> scaler = [desc newSpatialScalerWithDevice:dev];
    if (!scaler) { LOG("scaler creation failed for format %lu", (unsigned long)fmt); return nil; }

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                width:inW height:inH mipmapped:NO];
    td.usage = scaler.colorTextureUsage | MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead
             | MTLTextureUsageShaderWrite;
    td.storageMode = MTLStorageModePrivate;
    NSMutableArray *ring = [NSMutableArray array];
    for (NSUInteger i = 0; i < MAX(layer.maximumDrawableCount, 3); i++) {
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        if (!t) return nil;
        [ring addObject:t];
    }
    s.ring = ring; s.scaler = scaler;
    LOG("upscaling %lux%lu -> %lux%lu", inW, inH, outW, outH);
    return s;
}

static void hookPresent(id<MTLDevice> dev);

static id<CAMetalDrawable> hookedNextDrawable(CAMetalLayer *self, SEL _cmd) {
    if (gDisabled || !isWineLayer(self) || !self.device)
        return ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hookPresent(self.device); });
    if (gDisabled) return ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);
    // MetalFX writes the drawable texture, so it can't be framebuffer-only.
    if (self.framebufferOnly) self.framebufferOnly = NO;
    id<CAMetalDrawable> real = ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);  // keeps pacing
    if (!real) return nil;
    id<MTLTexture> out = real.texture;
    WynixLayerState *s = stateFor(self, out.width, out.height);
    if (!s || (out.usage & s.scaler.outputTextureUsage) != s.scaler.outputTextureUsage) return real;

    WynixProxyDrawable *p = [WynixProxyDrawable new];
    p.real = real; p.state = s;
    p.texture = s.ring[s.next++ % s.ring.count];
    return p;
}

static void hookedPresent(id<MTLCommandBuffer> self, SEL _cmd, id<MTLDrawable> drawable) {
    if ([(NSObject *)drawable isKindOfClass:[WynixProxyDrawable class]]) {
        WynixProxyDrawable *p = (WynixProxyDrawable *)drawable;
        id<MTLFXSpatialScaler> scaler = p.state.scaler;
        scaler.colorTexture = p.texture;
        scaler.outputTexture = p.real.texture;
        [scaler encodeToCommandBuffer:self];
        drawable = p.real;
    }
    ((void (*)(id, SEL, id))gOrigPresent)(self, _cmd, drawable);
}

// Hooks presentDrawable: on the command buffer class this device hands out. Done lazily on the
// first Wine Metal frame so Steam, wineserver and other Wine processes never create a device.
static void hookPresent(id<MTLDevice> dev) {
    Class cbClass = [[[dev newCommandQueue] commandBuffer] class];
    Method mp = cbClass ? class_getInstanceMethod(cbClass, @selector(presentDrawable:)) : NULL;
    if (!mp) { gDisabled = YES; LOG("presentDrawable: not found, disabled"); return; }
    gOrigPresent = method_getImplementation(mp);
    // class_replaceMethod overrides on the concrete class even when the IMP is inherited.
    class_replaceMethod(cbClass, @selector(presentDrawable:), (IMP)hookedPresent, method_getTypeEncoding(mp));
    LOG("command buffer class %s", class_getName(cbClass));
}

static void onImageAdded(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (!gD3DMetalLoaded && dladdr(mh, &info) && info.dli_fname && strstr(info.dli_fname, "D3DMetal.framework"))
        gD3DMetalLoaded = YES;
}

__attribute__((constructor)) static void wynixUpscaleInit(void) {
    const char *on = getenv("WYNIX_UPSCALE");
    if (!on || strcmp(on, "1") != 0) return;
    gLog = getenv("WYNIX_UPSCALE_LOG") != NULL;
    gAnyLayer = getenv("WYNIX_UPSCALE_ANY_LAYER") != NULL;
    const char *sc = getenv("WYNIX_UPSCALE_SCALE");
    if (sc) { double v = atof(sc); if (v >= 1.0 && v <= 2.0) gScale = v; }
    Method mn = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
    if (!mn) return;
    gOrigNextDrawable = method_getImplementation(mn);
    class_replaceMethod([CAMetalLayer class], @selector(nextDrawable), (IMP)hookedNextDrawable, method_getTypeEncoding(mn));
    _dyld_register_func_for_add_image(onImageAdded);  // also replays images already loaded
    LOG("active, scale %.2f", gScale);
}
