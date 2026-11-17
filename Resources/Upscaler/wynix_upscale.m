// WYNIX Upscale: MetalFX spatial upscaling for Metal games running in Wine (D3DMetal, DX12).
//
// Loaded into the Wine process with DYLD_INSERT_LIBRARIES (x86_64, runs under Rosetta like
// Wine). D3DMetal itself is never modified: this only hooks two public Apple entry points
// in-process.
//
//   -[CAMetalLayer setDrawableSize:]   records the size the game asked for (its resolution).
//   -[CAMetalLayer nextDrawable]       sizes the real drawable to the screen's native pixels and
//                                      returns a proxy drawable whose texture is an offscreen
//                                      texture at the game's resolution.
//   -[MTLCommandBuffer presentDrawable:] when given a proxy, appends a MetalFX spatial upscale
//                                      (proxy texture -> real drawable) to the SAME command
//                                      buffer, then presents the real drawable. Same command
//                                      buffer = GPU ordering for free, no extra latency.
//
// Sizing: input = the size the layer would normally have (what the game asked for), output = native
// pixel size of the screen the layer's window is on, so macOS can present Direct. Only upscales
// when input is smaller than output in both dimensions (and >= 64 px); otherwise pure passthrough.
//
// Off unless WYNIX_UPSCALE=1. Any failure (no MetalFX, unsupported format, odd sizes) falls
// back to the untouched original path, so the game always still runs.
//
// Env:
//   WYNIX_UPSCALE=1            enable
//   WYNIX_UPSCALE_ANY_LAYER=1  hook every CAMetalLayer (tests); default only Wine's views
//   WYNIX_UPSCALE_LOG=1        log decisions to stderr
//   WYNIX_UPSCALE_OUTPUT=WxH   TEST ONLY: output size when the layer has no window/screen
//                              (the offscreen test harness); ignored when a screen is found

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <dlfcn.h>

static BOOL gLog, gAnyLayer;
static volatile BOOL gDisabled;
static volatile BOOL gD3DMetalLoaded;  // only D3DMetal games are upscaled; DXMT/DXVK/Steam are not
static NSUInteger gTestOutW, gTestOutH;
static IMP gOrigSetDrawableSize, gOrigNextDrawable, gOrigPresent, gOrigPresentAt, gOrigPresentAfter;
static char kStateKey, kInfoKey;

#define LOG(...) do { if (gLog) { fprintf(stderr, "wynix_upscale: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

@interface WynixLayerState : NSObject
@property id<MTLFXSpatialScaler> scaler;
@property NSArray<id<MTLTexture>> *ring;
@property NSUInteger next, inW, inH, outW, outH;
@property MTLPixelFormat format;
@end
@implementation WynixLayerState
@end

// Per-layer sizes: what the game asked for, and the cached screen size.
@interface WynixLayerInfo : NSObject
@property BOOL hasReq;
@property CGSize req, out;
@property CFTimeInterval outAt;
@end
@implementation WynixLayerInfo
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
static WynixLayerState *stateFor(CAMetalLayer *layer, NSUInteger inW, NSUInteger inH, NSUInteger outW, NSUInteger outH) {
    WynixLayerState *s = objc_getAssociatedObject(layer, &kStateKey);
    MTLPixelFormat fmt = layer.pixelFormat;
    if (s && s.inW == inW && s.inH == inH && s.outW == outW && s.outH == outH && s.format == fmt)
        return s.scaler ? s : nil;

    s = [WynixLayerState new];
    s.inW = inW; s.inH = inH; s.outW = outW; s.outH = outH; s.format = fmt;
    objc_setAssociatedObject(layer, &kStateKey, s, OBJC_ASSOCIATION_RETAIN);  // caches failures too

    id<MTLDevice> dev = layer.device;
    if (!dev) return nil;
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

static WynixLayerInfo *infoFor(CAMetalLayer *layer) {
    WynixLayerInfo *i = objc_getAssociatedObject(layer, &kInfoKey);
    if (!i) { i = [WynixLayerInfo new]; objc_setAssociatedObject(layer, &kInfoKey, i, OBJC_ASSOCIATION_RETAIN); }
    return i;
}

static void setSizeOrig(CAMetalLayer *layer, CGSize sz) {
    ((void (*)(id, SEL, CGSize))gOrigSetDrawableSize)(layer, @selector(setDrawableSize:), sz);
}

static void hookedSetDrawableSize(CAMetalLayer *self, SEL _cmd, CGSize sz) {
    WynixLayerInfo *i = infoFor(self);
    @synchronized (i) { i.req = sz; i.hasReq = YES; }
    ((void (*)(id, SEL, CGSize))gOrigSetDrawableSize)(self, _cmd, sz);
}

// Native pixel size of the screen the layer's window is on (KVC, so AppKit is not linked into
// every Wine process). Cached 2 s: nextDrawable runs on a render thread and AppKit is main-thread
// territory, so this is a read-only peek, not a hot-path call. ponytail: no main-thread hop.
static CGSize outputSize(CAMetalLayer *layer, WynixLayerInfo *info) {
    CFTimeInterval now = CACurrentMediaTime();
    if (info.out.width > 0 && now - info.outAt < 2) return info.out;
    CGSize out = CGSizeMake(0, 0);
    @try {
        id screen = nil;
        id d = layer.delegate;
        if ([d respondsToSelector:NSSelectorFromString(@"window")]) screen = [[d valueForKey:@"window"] valueForKey:@"screen"];
        if (!screen) screen = [NSClassFromString(@"NSScreen") valueForKey:@"mainScreen"];
        if (screen) {
            CGRect f = CGRectMake(0, 0, 0, 0);
            [(NSValue *)[screen valueForKey:@"frame"] getValue:&f size:sizeof f];
            double k = [[screen valueForKey:@"backingScaleFactor"] doubleValue];
            out = CGSizeMake(round(f.size.width * k), round(f.size.height * k));
        }
    } @catch (id e) {}
    if (out.width <= 0 && gTestOutW) out = CGSizeMake(gTestOutW, gTestOutH);
    info.out = out; info.outAt = now;
    return out;
}

// Original path: the layer goes back to the size the game asked for, then the stock drawable.
static id<CAMetalDrawable> passthrough(CAMetalLayer *self, SEL _cmd, WynixLayerInfo *info) {
    if (info.hasReq && !CGSizeEqualToSize(self.drawableSize, info.req)) setSizeOrig(self, info.req);
    return ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);
}

static id<CAMetalDrawable> hookedNextDrawable(CAMetalLayer *self, SEL _cmd) {
    if (gDisabled || !isWineLayer(self) || !self.device) {
        WynixLayerInfo *i = objc_getAssociatedObject(self, &kInfoKey);
        return i ? passthrough(self, _cmd, i) : ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hookPresent(self.device); });
    WynixLayerInfo *info = infoFor(self);
    if (!info.hasReq) { info.req = self.drawableSize; info.hasReq = YES; }  // setDrawableSize never called
    if (gDisabled || !gOrigPresentAt || !gOrigPresentAfter) return passthrough(self, _cmd, info);

    CGSize in = info.req, out = outputSize(self, info);
    if (in.width < 64 || in.height < 64 || in.width >= out.width || in.height >= out.height)
        return passthrough(self, _cmd, info);  // nothing to gain (or no screen known)
    WynixLayerState *s = stateFor(self, (NSUInteger)in.width, (NSUInteger)in.height,
                                  (NSUInteger)out.width, (NSUInteger)out.height);
    if (!s) return passthrough(self, _cmd, info);
    // MetalFX writes the drawable texture, so it can't be framebuffer-only.
    if (self.framebufferOnly) self.framebufferOnly = NO;
    if (!CGSizeEqualToSize(self.drawableSize, out)) setSizeOrig(self, out);  // real drawable = screen pixels
    id<CAMetalDrawable> real = ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);  // keeps pacing
    if (!real) return nil;
    if ((real.texture.usage & s.scaler.outputTextureUsage) != s.scaler.outputTextureUsage) return real;

    WynixProxyDrawable *p = [WynixProxyDrawable new];
    p.real = real; p.state = s;
    p.texture = s.ring[s.next++ % s.ring.count];
    return p;
}

// Swaps a proxy for its real drawable after encoding the upscale into this command buffer.
static id<MTLDrawable> upscaleInto(id<MTLCommandBuffer> cb, id<MTLDrawable> drawable) {
    if (![(NSObject *)drawable isKindOfClass:[WynixProxyDrawable class]]) return drawable;
    WynixProxyDrawable *p = (WynixProxyDrawable *)drawable;
    @synchronized (p.state) {  // one scaler per layer; presents from two threads must not interleave
        id<MTLFXSpatialScaler> scaler = p.state.scaler;
        scaler.colorTexture = p.texture;
        scaler.outputTexture = p.real.texture;
        [scaler encodeToCommandBuffer:cb];
    }
    return p.real;
}

static void hookedPresent(id<MTLCommandBuffer> self, SEL _cmd, id<MTLDrawable> d) {
    ((void (*)(id, SEL, id))gOrigPresent)(self, _cmd, upscaleInto(self, d));
}
static void hookedPresentAt(id<MTLCommandBuffer> self, SEL _cmd, id<MTLDrawable> d, CFTimeInterval t) {
    ((void (*)(id, SEL, id, CFTimeInterval))gOrigPresentAt)(self, _cmd, upscaleInto(self, d), t);
}
static void hookedPresentAfter(id<MTLCommandBuffer> self, SEL _cmd, id<MTLDrawable> d, CFTimeInterval t) {
    ((void (*)(id, SEL, id, CFTimeInterval))gOrigPresentAfter)(self, _cmd, upscaleInto(self, d), t);
}

// Hooks presentDrawable: on the command buffer class this device hands out. Done lazily on the
// first Wine Metal frame so Steam, wineserver and other Wine processes never create a device.
static IMP hookOne(Class c, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    // class_replaceMethod overrides on the concrete class even when the IMP is inherited.
    class_replaceMethod(c, sel, imp, method_getTypeEncoding(m));
    return orig;
}

static void hookPresent(id<MTLDevice> dev) {
    Class cbClass = [[[dev newCommandQueue] commandBuffer] class];
    gOrigPresent = cbClass ? hookOne(cbClass, @selector(presentDrawable:), (IMP)hookedPresent) : NULL;
    if (!gOrigPresent) { gDisabled = YES; LOG("presentDrawable: not found, disabled"); return; }
    gOrigPresentAt = hookOne(cbClass, @selector(presentDrawable:atTime:), (IMP)hookedPresentAt);
    gOrigPresentAfter = hookOne(cbClass, @selector(presentDrawable:afterMinimumDuration:), (IMP)hookedPresentAfter);
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
    const char *to = getenv("WYNIX_UPSCALE_OUTPUT");
    if (to) { unsigned w = 0, h = 0; if (sscanf(to, "%ux%u", &w, &h) == 2) { gTestOutW = w; gTestOutH = h; } }
    Method ms = class_getInstanceMethod([CAMetalLayer class], @selector(setDrawableSize:));
    if (!ms) return;
    gOrigSetDrawableSize = method_getImplementation(ms);
    class_replaceMethod([CAMetalLayer class], @selector(setDrawableSize:), (IMP)hookedSetDrawableSize, method_getTypeEncoding(ms));
    Method mn = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
    if (!mn) return;
    gOrigNextDrawable = method_getImplementation(mn);
    class_replaceMethod([CAMetalLayer class], @selector(nextDrawable), (IMP)hookedNextDrawable, method_getTypeEncoding(mn));
    _dyld_register_func_for_add_image(onImageAdded);  // also replays images already loaded
    LOG("active");
}
