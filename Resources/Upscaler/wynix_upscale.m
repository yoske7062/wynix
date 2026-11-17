// WYNIX Upscale: MetalFX spatial upscaling for Metal games running in Wine (D3DMetal, DX12).
//
// Loaded into the Wine process with DYLD_INSERT_LIBRARIES (x86_64, runs under Rosetta like
// Wine). D3DMetal itself is never modified: this only hooks three public Apple entry points
// in-process.
//
//   -[CAMetalLayer setDrawableSize:]   records the size the game asked for (its resolution).
//   -[CAMetalLayer drawableSize]       getter: while we upscale a layer it reports the game's size, so
//                                      D3DMetal/Wine never see (or fight) the screen-sized real one.
//   -[CAMetalLayer nextDrawable]       sizes the real drawable to the output size (screen, capped) and
//                                      returns a proxy drawable whose texture is an offscreen
//                                      texture at the game's resolution.
//   -[MTLCommandBuffer presentDrawable:] when given a proxy, appends a MetalFX spatial upscale
//                                      (proxy texture -> real drawable) to the SAME command
//                                      buffer, then presents the real drawable. Same command
//                                      buffer = GPU ordering for free, no extra latency.
//
// Sizing: input = last setDrawableSize, else the layer's bounds * contentsScale; output = pixel size
// of the main display's mode (CoreGraphics) scaled down, aspect kept, to fit the cap (default
// 1920x1080: never upscale to 2K; macOS stretches the drawable to a bigger screen). Only upscales
// when input is smaller than output in both dimensions (and >= 64 px); otherwise pure passthrough.
//
// Off unless WYNIX_UPSCALE=1. Any failure (no MetalFX, unsupported format, odd sizes) falls
// back to the untouched original path, so the game always still runs.
//
// Env:
//   WYNIX_UPSCALE=1            enable
//   WYNIX_UPSCALE_ANY_LAYER=1  hook every CAMetalLayer (tests); default only Wine's views
//   WYNIX_UPSCALE_LABEL=1      blit a small "WYNIX Boost" box into the top-left of the real drawable
//   WYNIX_UPSCALE_LOG=1        log decisions to stderr
//   WYNIX_UPSCALE_OUTPUT=WxH   TEST ONLY: output size when the layer has no window/screen
//                              (the offscreen test harness); overrides the display size
//                              (the cap below still applies)
//   WYNIX_UPSCALE_MAX=WxH      cap on the output size (default 1920x1080); a smaller display is kept

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>

static BOOL gLog, gAnyLayer, gLabel;
static volatile BOOL gDisabled;
static volatile BOOL gD3DMetalLoaded;  // only D3DMetal games are upscaled; DXMT/DXVK/Steam are not
static NSUInteger gTestOutW, gTestOutH, gMaxW = 1920, gMaxH = 1080;
static IMP gOrigSetDrawableSize, gOrigDrawableSize, gOrigNextDrawable, gOrigPresent, gOrigPresentAt, gOrigPresentAfter;
static char kStateKey, kInfoKey;

#define LOG(...) do { if (gLog) { fprintf(stderr, "wynix_upscale: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

@interface WynixLayerState : NSObject
@property id<MTLFXSpatialScaler> scaler;
@property NSArray<id<MTLTexture>> *ring;
@property NSUInteger next, inW, inH, outW, outH;
@property MTLPixelFormat format;
@property id<MTLTexture> label;   // pre-rendered "WYNIX Boost" box, same format as the drawable
@property BOOL labelTried;
@end
@implementation WynixLayerState
@end

// Per-layer: the size the game asked for, and whether we currently hold the layer at screen size.
// All fields are guarded by @synchronized(info).
@interface WynixLayerInfo : NSObject
@property BOOL hasReq, active;
@property CGSize req;
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
static CGSize realSize(CAMetalLayer *layer) {  // the layer's true drawable size, never the hooked getter
    return ((CGSize (*)(id, SEL))gOrigDrawableSize)(layer, @selector(drawableSize));
}

// The size the game wants: last setDrawableSize, else the layer's own geometry (Wine updates the
// bounds on resize). Recomputed every call, never frozen.
static CGSize requestedSize(CAMetalLayer *layer, WynixLayerInfo *info) {
    @synchronized (info) { if (info.hasReq) return info.req; }
    CGSize b = layer.bounds.size; CGFloat k = layer.contentsScale;
    return CGSizeMake(round(b.width * k), round(b.height * k));
}

static void hookedSetDrawableSize(CAMetalLayer *self, SEL _cmd, CGSize sz) {
    if (!isWineLayer(self)) { setSizeOrig(self, sz); return; }
    WynixLayerInfo *i = infoFor(self);
    BOOL active;
    @synchronized (i) { i.req = sz; i.hasReq = YES; active = i.active; }
    // While we hold the layer at screen size, the game's size is applied (or not) at the next nextDrawable.
    if (!active) setSizeOrig(self, sz);
}

// What D3DMetal/Wine see: the game's size for layers we are upscaling, the real one otherwise.
static CGSize hookedDrawableSize(CAMetalLayer *self, SEL _cmd) {
    WynixLayerInfo *i = objc_getAssociatedObject(self, &kInfoKey);
    BOOL active = NO;
    if (i) @synchronized (i) { active = i.active; }
    return active ? requestedSize(self, i) : realSize(self);
}

// Pixel size of the main display's current mode (CoreGraphics only: thread-safe on the render
// thread). Cached 2 s under one lock. ponytail: main display only; use the window's display if multi-monitor matters
static CGSize outputSize(void) {
    static CGSize cached; static CFTimeInterval at;
    @synchronized ([WynixLayerInfo class]) {
        CFTimeInterval now = CACurrentMediaTime();
        if (cached.width > 0 && now - at < 2) return cached;
        CGSize out = CGSizeMake(0, 0);
        if (gTestOutW) out = CGSizeMake(gTestOutW, gTestOutH);
        else {
            CGDisplayModeRef m = CGDisplayCopyDisplayMode(CGMainDisplayID());
            if (m) { out = CGSizeMake(CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m)); CGDisplayModeRelease(m); }
        }
        if (out.width > gMaxW || out.height > gMaxH) {  // fit within the cap, aspect preserved
            CGFloat k = MIN(gMaxW / out.width, gMaxH / out.height);
            out = CGSizeMake(round(out.width * k), round(out.height * k));
        }
        cached = out; at = now;
        return out;
    }
}

// Original path: if we had resized the layer, it goes back to the requested size, then the stock drawable.
static id<CAMetalDrawable> passthrough(CAMetalLayer *self, SEL _cmd, WynixLayerInfo *info) {
    BOOL active;
    @synchronized (info) { active = info.active; info.active = NO; }
    if (active) setSizeOrig(self, requestedSize(self, info));
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
    if (gDisabled || !gOrigPresentAt || !gOrigPresentAfter) return passthrough(self, _cmd, info);

    // Every eligibility check happens before the layer is touched.
    CGSize in = requestedSize(self, info), out = outputSize();
    if (in.width < 64 || in.height < 64 || in.width >= out.width || in.height >= out.height)
        return passthrough(self, _cmd, info);  // nothing to gain (or no screen known)
    WynixLayerState *s = stateFor(self, (NSUInteger)in.width, (NSUInteger)in.height,
                                  (NSUInteger)out.width, (NSUInteger)out.height);
    if (!s) return passthrough(self, _cmd, info);
    // MetalFX writes the drawable texture, so it can't be framebuffer-only; a non-framebufferOnly
    // drawable has RenderTarget|ShaderRead|ShaderWrite.
    MTLTextureUsage have = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    if ((s.scaler.outputTextureUsage & have) != s.scaler.outputTextureUsage) return passthrough(self, _cmd, info);
    if (self.framebufferOnly) self.framebufferOnly = NO;
    if (!CGSizeEqualToSize(realSize(self), out)) setSizeOrig(self, out);  // real drawable = screen pixels
    @synchronized (info) { info.active = YES; }
    id<CAMetalDrawable> real = ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);  // keeps pacing
    if (!real) {
        @synchronized (info) { info.active = NO; }
        setSizeOrig(self, requestedSize(self, info));
        return nil;
    }
    if ((real.texture.usage & s.scaler.outputTextureUsage) != s.scaler.outputTextureUsage) return real;

    WynixProxyDrawable *p = [WynixProxyDrawable new];
    p.real = real; p.state = s;
    p.texture = s.ring[s.next++ % s.ring.count];
    return p;
}

// Renders the label once per state (CoreText into a BGRA bitmap, converted to the drawable's
// format) and returns it as a small shared texture. nil = format not handled or any failure.
// An opaque dark box, so a plain blit is enough: no blending, no render pass.
static id<MTLTexture> makeLabel(WynixLayerState *s, id<MTLDevice> dev) {
    MTLPixelFormat f = s.format;
    if (f != MTLPixelFormatBGRA8Unorm && f != MTLPixelFormatBGRA8Unorm_sRGB &&
        f != MTLPixelFormatRGBA16Float && f != MTLPixelFormatRGB10A2Unorm) return nil;
    CGFloat fs = MAX(14, round(s.outH / 60.0));
    NSString *text = [NSString stringWithFormat:@"WYNIX Boost  MetalFX %lux%lu -> %lux%lu",
                      (unsigned long)s.inW, (unsigned long)s.inH, (unsigned long)s.outW, (unsigned long)s.outH];
    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica-Bold"), fs, NULL);
    CFStringRef keys[] = { kCTFontAttributeName, kCTForegroundColorFromContextAttributeName };
    CFTypeRef vals[] = { font, kCFBooleanTrue };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, (const void **)keys, (const void **)vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, (__bridge CFStringRef)text, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    CGFloat pad = fs * 0.5;
    size_t w = (size_t)ceil(CTLineGetTypographicBounds(line, NULL, NULL, NULL) + 2 * pad), h = (size_t)ceil(fs * 1.6);
    NSMutableData *px = nil;
    if (w <= s.outW / 2 && h <= s.outH / 4) {
        px = [NSMutableData dataWithLength:w * h * 4];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef cg = CGBitmapContextCreate(px.mutableBytes, w, h, 8, w * 4, cs,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);  // BGRA bytes
        if (cg) {
            CGContextSetRGBFillColor(cg, 0, 0, 0, 1);
            CGContextFillRect(cg, CGRectMake(0, 0, w, h));
            CGContextSetRGBFillColor(cg, 1, 1, 1, 1);
            CGContextSetTextPosition(cg, pad, fs * 0.45);
            CTLineDraw(line, cg);
            CGContextRelease(cg);
        } else px = nil;
        CGColorSpaceRelease(cs);
    }
    CFRelease(line); CFRelease(as); CFRelease(attrs); CFRelease(font);
    if (!px) return nil;
    const uint8_t *src = px.bytes;
    NSUInteger bpp = f == MTLPixelFormatRGBA16Float ? 8 : 4;
    NSMutableData *out = f == MTLPixelFormatBGRA8Unorm || f == MTLPixelFormatBGRA8Unorm_sRGB ? px
                       : [NSMutableData dataWithLength:w * h * bpp];
    if (f == MTLPixelFormatRGBA16Float) {
        __fp16 *d = out.mutableBytes;
        for (size_t i = 0; i < w * h; i++) {  // text is white on black: gamma-encoded values are fine
            d[4*i] = src[4*i+2] / 255.0f; d[4*i+1] = src[4*i+1] / 255.0f; d[4*i+2] = src[4*i] / 255.0f; d[4*i+3] = 1;
        }
    } else if (f == MTLPixelFormatRGB10A2Unorm) {
        uint32_t *d = out.mutableBytes;
        for (size_t i = 0; i < w * h; i++) {
            uint32_t r = src[4*i+2] * 1023 / 255, g = src[4*i+1] * 1023 / 255, b = src[4*i] * 1023 / 255;
            d[i] = r | (g << 10) | (b << 20) | (3u << 30);
        }
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    if (!t) return nil;
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:out.bytes bytesPerRow:w * bpp];
    return t;
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
        if (gLabel) {
            WynixLayerState *st = p.state;
            if (!st.labelTried) { st.labelTried = YES; @try { st.label = makeLabel(st, cb.device); } @catch (id e) {} }
            id<MTLTexture> l = st.label, dst = p.real.texture;
            if (l && dst.pixelFormat == l.pixelFormat && dst.width >= l.width && dst.height >= l.height) {
                id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
                [b copyFromTexture:l sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                        sourceSize:MTLSizeMake(l.width, l.height, 1) toTexture:dst destinationSlice:0
                  destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                [b endEncoding];
            }
        }
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
    gLabel = getenv("WYNIX_UPSCALE_LABEL") && strcmp(getenv("WYNIX_UPSCALE_LABEL"), "1") == 0;
    gAnyLayer = getenv("WYNIX_UPSCALE_ANY_LAYER") != NULL;
    const char *to = getenv("WYNIX_UPSCALE_OUTPUT");
    if (to) { unsigned w = 0, h = 0; if (sscanf(to, "%ux%u", &w, &h) == 2) { gTestOutW = w; gTestOutH = h; } }
    const char *mx = getenv("WYNIX_UPSCALE_MAX");
    if (mx) { unsigned w = 0, h = 0; if (sscanf(mx, "%ux%u", &w, &h) == 2 && w >= 64 && h >= 64) { gMaxW = w; gMaxH = h; } }
    Method ms = class_getInstanceMethod([CAMetalLayer class], @selector(setDrawableSize:));
    if (!ms) return;
    gOrigSetDrawableSize = method_getImplementation(ms);
    class_replaceMethod([CAMetalLayer class], @selector(setDrawableSize:), (IMP)hookedSetDrawableSize, method_getTypeEncoding(ms));
    Method mn = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
    Method mg = class_getInstanceMethod([CAMetalLayer class], @selector(drawableSize));
    if (!mn || !mg) return;
    gOrigDrawableSize = method_getImplementation(mg);
    class_replaceMethod([CAMetalLayer class], @selector(drawableSize), (IMP)hookedDrawableSize, method_getTypeEncoding(mg));
    gOrigNextDrawable = method_getImplementation(mn);
    class_replaceMethod([CAMetalLayer class], @selector(nextDrawable), (IMP)hookedNextDrawable, method_getTypeEncoding(mn));
    _dyld_register_func_for_add_image(onImageAdded);  // also replays images already loaded
    LOG("active");
}
