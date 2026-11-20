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
//   -[MTL4CommandQueue waitForDrawable:/signalDrawable:] Metal 4 presentation (D3DMetal 4.0): wait on
//                                      the real drawable; before signalling, upscale in our own MTL4
//                                      command buffer committed on the same queue.
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
//   WYNIX_BENCH_FILE=<path>    record one timestamp per presented frame of Wine's D3DMetal layers (upscaled or
//                              not; works without WYNIX_UPSCALE) and write frame intervals in ms, one per line,
//                              after a "# wynix-bench v1 ..." header, every ~10 s and at exit. A path ending in
//                              "/" is a folder: the file is "<epoch>-<pid>.txt" inside it.
//   WYNIX_UPSCALE_MAX=WxH      cap on the output size (default 1920x1080); a smaller display is kept

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <os/lock.h>
#include <time.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sys/resource.h>
#include <pthread/qos.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>

static BOOL gLog, gAnyLayer, gLabel;
static volatile BOOL gDisabled;
static volatile BOOL gD3DMetalLoaded;  // only D3DMetal games are upscaled; DXMT/DXVK/Steam are not
static NSUInteger gTestOutW, gTestOutH, gMaxW = 1920, gMaxH = 1080;
static IMP gOrigWaitDrawable, gOrigSignalDrawable;  // MTL4CommandQueue (Metal 4 presentation, D3DMetal 4.0)
static IMP gOrigSetDrawableSize, gOrigDrawableSize, gOrigNextDrawable, gOrigPresent, gOrigPresentAt, gOrigPresentAfter;
static char kStateKey, kInfoKey;
static BOOL gUpscale;
static void hudTick(CAMetalLayer *layer);
static void gameBoostTick(CAMetalLayer *layer);

// ---- Chip temperature ----
// Private IOHIDEventSystem API (same one Stats/iStat use; works under Rosetta). Hottest "tdie" sensor
// in degrees C, or 0 when unavailable. ponytail: Apple Silicon sensor names only; Intel Macs get 0.
typedef struct __IOHIDEventSystemClient *WynixHIDClient;
typedef struct __IOHIDServiceClient *WynixHIDService;
typedef struct __IOHIDEvent *WynixHIDEvent;
extern WynixHIDClient IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(WynixHIDClient, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(WynixHIDClient);
extern WynixHIDEvent IOHIDServiceClientCopyEvent(WynixHIDService, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(WynixHIDEvent, int32_t);
extern CFTypeRef IOHIDServiceClientCopyProperty(WynixHIDService, CFStringRef);

static double chipTemperature(void) {
    static NSArray *sensors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WynixHIDClient c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!c) return;
        IOHIDEventSystemClientSetMatching(c, (__bridge CFDictionaryRef)@{@"PrimaryUsagePage": @0xff00, @"PrimaryUsage": @5});
        NSMutableArray *found = [NSMutableArray array];
        for (id s in CFBridgingRelease(IOHIDEventSystemClientCopyServices(c))) {
            NSString *name = CFBridgingRelease(IOHIDServiceClientCopyProperty((__bridge WynixHIDService)s, CFSTR("Product")));
            if ([name containsString:@"tdie"]) [found addObject:s];
        }
        sensors = found;  // the services keep working after the client is gone only while referenced
    });
    double hottest = 0;
    for (id s in sensors) {
        WynixHIDEvent e = IOHIDServiceClientCopyEvent((__bridge WynixHIDService)s, 15 /* temperature */, 0, 0);
        if (!e) continue;
        double t = IOHIDEventGetFloatValue(e, 15 << 16);
        CFRelease(e);
        if (t > hottest && t < 150) hottest = t;
    }
    return hottest;
}

// ---- Benchmark recording (WYNIX_BENCH_FILE) ----
// One uint64 timestamp (ns, CLOCK_UPTIME_RAW) per presented frame in a preallocated buffer (8 MB, pages
// are only touched as used). The render thread takes a spin-free os_unfair_lock for two stores;
// all file I/O is on a background queue. ponytail: stops recording after 1M frames (~2 h at 120 fps).
#define BENCH_MAX 1000000
static const char *gBenchPath;
static uint64_t gBenchT[BENCH_MAX];
static unsigned gBenchN, gBenchWritten, gBenchIn[2], gBenchOut[2];
static BOOL gBenchUpscaled;
static char *gD3DMetalPath;
static os_unfair_lock gBenchLock = OS_UNFAIR_LOCK_INIT;
static NSLock *gBenchFlushLock;
static char *gBenchFile;  // resolved file name, set on the first flush


#define LOG(...) do { if (gLog) { fprintf(stderr, "wynix_upscale: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

@interface WynixLayerState : NSObject
@property id<MTLFXSpatialScaler> scaler;
@property NSArray<id<MTLTexture>> *ring;
@property NSUInteger next, inW, inH, outW, outH;
@property MTLPixelFormat format;
@property id<MTLTexture> label;   // pre-rendered "WYNIX Boost" box, same format as the drawable
@property BOOL labelTried;
@property MTLFXSpatialScalerDescriptor *desc;
@property id mtl4Scaler;       // id<MTL4FXSpatialScaler>, created lazily on the first Metal 4 frame
@property id mtl4Residency;    // id<MTLResidencySet> holding the ring textures
@property BOOL mtl4Tried;
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
@property BOOL mtl4Handled;   // the Metal 4 queue path upscaled this frame; present must not disable proxying
@end

@implementation WynixProxyDrawable
- (CAMetalLayer *)layer { return self.real.layer; }
- (NSUInteger)drawableID { return self.real.drawableID; }
- (CFTimeInterval)presentedTime { return self.real.presentedTime; }
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)block { [self.real addPresentedHandler:block]; }
// Direct presents (no command buffer) cannot carry the upscale; show the real drawable.
// Seeing one means this game presents some other way: stop proxying from the next frame.
- (void)present { if (!self.mtl4Handled) gDisabled = YES; [self.real present]; }
- (void)presentAtTime:(CFTimeInterval)t { if (!self.mtl4Handled) gDisabled = YES; [self.real presentAtTime:t]; }
- (void)presentAfterMinimumDuration:(CFTimeInterval)d { if (!self.mtl4Handled) gDisabled = YES; [self.real presentAfterMinimumDuration:d]; }
// Anything else (private selectors Metal may probe) goes to the real drawable.
- (id)forwardingTargetForSelector:(SEL)sel { return self.real; }
@end

static BOOL isWineLayer(CAMetalLayer *layer) {
    if (gAnyLayer) return YES;
    if (!gD3DMetalLoaded) return NO;
    id d = layer.delegate;
    return d && strstr(class_getName([d class]), "WineMetalView") != NULL;
}

static void benchTick(id<MTLDrawable> d) {
    if (!gBenchPath) return;
    NSUInteger inW = 0, inH = 0, outW = 0, outH = 0; BOOL up = NO;
    if ([(NSObject *)d isKindOfClass:[WynixProxyDrawable class]]) {
        WynixProxyDrawable *p = (WynixProxyDrawable *)d;
        inW = p.texture.width; inH = p.texture.height; outW = p.state.outW; outH = p.state.outH; up = YES;
        if (!isWineLayer(p.real.layer)) return;
    } else {
        id<CAMetalDrawable> md = (id<CAMetalDrawable>)d;
        if (![(NSObject *)d conformsToProtocol:@protocol(CAMetalDrawable)] || !isWineLayer(md.layer)) return;
        inW = outW = md.texture.width; inH = outH = md.texture.height;
    }
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    os_unfair_lock_lock(&gBenchLock);
    if (gBenchN < BENCH_MAX) gBenchT[gBenchN++] = now;
    gBenchIn[0] = (unsigned)inW; gBenchIn[1] = (unsigned)inH; gBenchOut[0] = (unsigned)outW; gBenchOut[1] = (unsigned)outH;
    gBenchUpscaled = up;
    os_unfair_lock_unlock(&gBenchLock);
}

// Appends the intervals not yet written. Not called on the render thread. Files with under 120 frames
// are never created (Steam's own windows also present through D3DMetal).
static void benchFlush(void) {
    [gBenchFlushLock lock];
    os_unfair_lock_lock(&gBenchLock);
    unsigned n = gBenchN, from = gBenchWritten;
    unsigned in0 = gBenchIn[0], in1 = gBenchIn[1], out0 = gBenchOut[0], out1 = gBenchOut[1]; BOOL up = gBenchUpscaled;
    os_unfair_lock_unlock(&gBenchLock);  // timestamps below index n are never rewritten
    if (n > from && (gBenchFile || n >= 120)) {
        NSMutableString *text = [NSMutableString string];
        if (!gBenchFile) {
            NSString *path = [NSString stringWithUTF8String:gBenchPath];
            if ([path hasSuffix:@"/"]) {
                [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
                path = [path stringByAppendingFormat:@"%ld-%d.txt", (long)time(NULL), getpid()];
            }
            gBenchFile = strdup(path.UTF8String);
            NSString *ver = @"unknown";
            if (gD3DMetalPath) {
                NSString *fw = [NSString stringWithUTF8String:gD3DMetalPath];
                for (NSString *rel in @[@"Versions/A/Resources/Info.plist", @"Resources/Info.plist"]) {
                    NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:[fw stringByAppendingPathComponent:rel]];
                    NSString *v = pl[@"CFBundleShortVersionString"] ?: pl[@"CFBundleVersion"];
                    if (v) { ver = v; break; }
                }
            }
            [text appendFormat:@"# wynix-bench v1 in=%ux%u out=%ux%u upscale=%d d3dmetal=%@\n", in0, in1, out0, out1, up ? 1 : 0, ver];
        }
        for (unsigned i = from ? from : 1; i < n; i++)
            [text appendFormat:@"%.3f\n", (gBenchT[i] - gBenchT[i - 1]) / 1e6];
        FILE *f = fopen(gBenchFile, "a");
        if (f) { fputs(text.UTF8String, f); fclose(f); }
    }
    os_unfair_lock_lock(&gBenchLock); gBenchWritten = n; os_unfair_lock_unlock(&gBenchLock);
    [gBenchFlushLock unlock];
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
    s.desc = desc;
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
    hudTick(self);
    gameBoostTick(self);
    if (!gUpscale) {  // timing only: install the present hooks on the first Wine frame, never proxy
        if (isWineLayer(self) && self.device) {
            static dispatch_once_t once;
            dispatch_once(&once, ^{ hookPresent(self.device); });
        }
        return ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);
    }
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
    benchTick(d);
    ((void (*)(id, SEL, id))gOrigPresent)(self, _cmd, upscaleInto(self, d));
}
static void hookedPresentAt(id<MTLCommandBuffer> self, SEL _cmd, id<MTLDrawable> d, CFTimeInterval t) {
    benchTick(d);
    ((void (*)(id, SEL, id, CFTimeInterval))gOrigPresentAt)(self, _cmd, upscaleInto(self, d), t);
}
static void hookedPresentAfter(id<MTLCommandBuffer> self, SEL _cmd, id<MTLDrawable> d, CFTimeInterval t) {
    benchTick(d);
    ((void (*)(id, SEL, id, CFTimeInterval))gOrigPresentAfter)(self, _cmd, upscaleInto(self, d), t);
}


// ---- Metal 4 presentation: [queue waitForDrawable:d]; commit; [queue signalDrawable:d]; [d present] ----
// Same idea as the command buffer path, but the upscale goes into our own MTL4 command buffer
// committed on the game's queue right before signalDrawable:, so queue order puts it after the game's work.

@interface WynixMTL4Slot : NSObject  // per queue: one allocator + command buffer, reused once the GPU is done
@property id allocator, cb;
@property volatile BOOL busy;
@end
@implementation WynixMTL4Slot
@end
static char kMTL4SlotKey;

static id gMTL4Compiler;  // id<MTL4Compiler>, one per process (one device)

static id mtl4ScalerFor(WynixLayerState *s, id<MTLDevice> dev) API_AVAILABLE(macos(26.0)) {
    if (s.mtl4Scaler || s.mtl4Tried) return s.mtl4Scaler;
    s.mtl4Tried = YES;
    if (!gMTL4Compiler) gMTL4Compiler = [dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:NULL];
    if (!gMTL4Compiler || !s.desc) return nil;
    id<MTL4FXSpatialScaler> sc = [s.desc newSpatialScalerWithDevice:dev compiler:gMTL4Compiler];
    MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new];
    id<MTLResidencySet> rs = [dev newResidencySetWithDescriptor:rd error:NULL];
    if (!sc || !rs) return nil;
    for (id<MTLTexture> t in s.ring) [rs addAllocation:t];
    [rs commit];
    s.mtl4Residency = rs; s.mtl4Scaler = sc;
    LOG("Metal 4 scaler ready");
    return sc;
}

// Encodes proxy texture -> real texture on `queue`. NO = could not (caller disables proxying).
static BOOL mtl4Upscale(id<MTL4CommandQueue> queue, WynixProxyDrawable *p) API_AVAILABLE(macos(26.0)) {
    id<MTLDevice> dev = p.real.layer.device;
    WynixMTL4Slot *slot = objc_getAssociatedObject(queue, &kMTL4SlotKey);
    if (!slot) { slot = [WynixMTL4Slot new]; objc_setAssociatedObject(queue, &kMTL4SlotKey, slot, OBJC_ASSOCIATION_RETAIN); }
    @synchronized (p.state) {
        id<MTL4FXSpatialScaler> sc = mtl4ScalerFor(p.state, dev);
        if (!sc) return NO;
        // ponytail: one cached buffer per queue; if the GPU still holds it, use a throwaway one
        WynixMTL4Slot *use = slot.busy ? [WynixMTL4Slot new] : slot;
        if (!use.cb) { use.allocator = [dev newCommandAllocator]; use.cb = [dev newCommandBuffer]; }
        id<MTL4CommandAllocator> al = use.allocator; id<MTL4CommandBuffer> cb = use.cb;
        if (!al || !cb) return NO;
        [al reset];  // idle: the last commit's feedback already fired
        use.busy = YES;
        [cb beginCommandBufferWithAllocator:al];
        [cb useResidencySet:p.state.mtl4Residency];
        id<MTLResidencySet> lrs = p.real.layer.residencySet;
        if (lrs) [cb useResidencySet:lrs];
        sc.colorTexture = p.texture;
        sc.outputTexture = p.real.texture;
        [sc encodeToCommandBuffer:cb];
        [cb endCommandBuffer];
        MTL4CommitOptions *o = [MTL4CommitOptions new];
        [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) { use.busy = NO; }];
        [queue commit:&cb count:1 options:o];
    }
    return YES;
}

static void hookedWaitForDrawable(id self, SEL _cmd, id d) {
    if ([(NSObject *)d isKindOfClass:[WynixProxyDrawable class]]) d = ((WynixProxyDrawable *)d).real;
    ((void (*)(id, SEL, id))gOrigWaitDrawable)(self, _cmd, d);
}

static void hookedSignalDrawable(id self, SEL _cmd, id d) {
    benchTick(d);
    if ([(NSObject *)d isKindOfClass:[WynixProxyDrawable class]]) {
        WynixProxyDrawable *p = (WynixProxyDrawable *)d;
        if (@available(macos 26.0, *)) {
            if (mtl4Upscale(self, p)) p.mtl4Handled = YES;
        }
        if (!p.mtl4Handled) { gDisabled = YES; LOG("Metal 4 upscale failed, disabled"); }
        d = p.real;
    }
    ((void (*)(id, SEL, id))gOrigSignalDrawable)(self, _cmd, d);
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
    if (@available(macos 26.0, *)) {  // Metal 4 queue class: absent on older macOS, then only the path above exists
        if ([dev respondsToSelector:@selector(newMTL4CommandQueue)]) {
            Class qc = [[dev newMTL4CommandQueue] class];
            gOrigWaitDrawable = qc ? hookOne(qc, @selector(waitForDrawable:), (IMP)hookedWaitForDrawable) : NULL;
            gOrigSignalDrawable = qc ? hookOne(qc, @selector(signalDrawable:), (IMP)hookedSignalDrawable) : NULL;
            LOG("MTL4 queue class %s %s", qc ? class_getName(qc) : "-", gOrigSignalDrawable ? "hooked" : "not hooked");
        }
    }
}

static void onImageAdded(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (!gD3DMetalLoaded && dladdr(mh, &info) && info.dli_fname && strstr(info.dli_fname, "D3DMetal.framework")) {
        gD3DMetalLoaded = YES;
        const char *e = strstr(info.dli_fname, "D3DMetal.framework") + strlen("D3DMetal.framework");
        gD3DMetalPath = strndup(info.dli_fname, e - info.dli_fname);
    }
}

// ---- WYNIX performance HUD ----
// A small box in the top-right corner of the game window: FPS (updated 10x a second), CPU, GPU,
// memory and the Mac's temperature, each with a green/yellow/orange/red dot. Drawn as a layer on
// top of Wine's Metal view inside the game process, so it works without WYNIX open and in
// fullscreen. Shown while drive_c/steamy/hud exists in this bottle (WYNIX creates or removes it,
// so the toggle applies live). Steam's own windows never get it.
static char *gHudFlag;
static BOOL gHudSkip;  // set lazily by isSteamProcess(): Wine rewrites argv[0] after our constructor

// Reads this process's current argv[0] (what `ps` shows, e.g. C:\...\steam.exe) on the first frame.
static BOOL isSteamProcess(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, getpid() };
    size_t size = 0;
    cached = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int)) return cached;
    char *buf = malloc(size);
    if (buf && sysctl(mib, 3, buf, &size, NULL, 0) == 0) {
        char *p = buf + sizeof(int), *end = buf + size;
        while (p < end && *p) p++;   // skip exec path
        while (p < end && !*p) p++;  // skip padding
        if (p < end) {
            NSString *a0 = [[NSString alloc] initWithBytes:p length:strnlen(p, end - p) encoding:NSUTF8StringEncoding].lowercaseString;
            cached = [a0 containsString:@"steam.exe"] || [a0 containsString:@"steamwebhelper"] || [a0 containsString:@"steamservice"];
        }
    }
    free(buf);
    gHudSkip = cached;
    return cached;
}
static _Atomic uint64_t gHudFrames;
static __weak CALayer *gHudHost;
static CALayer *gHudLayer;       // dark rounded box
static CATextLayer *gHudText;

static BOOL isWineView(CAMetalLayer *layer) {
    id d = layer.delegate;
    return d && strstr(class_getName([d class]), "WineMetalView") != NULL;
}

static void hudTick(CAMetalLayer *layer) {
    if (!gHudFlag || !isWineView(layer) || isSteamProcess()) return;
    atomic_fetch_add_explicit(&gHudFrames, 1, memory_order_relaxed);
    CALayer *host = gHudHost;
    // Several Wine windows can present (launcher + game): stick to the biggest one, never alternate.
    if (host != layer && (!host || layer.bounds.size.width * layer.bounds.size.height > host.bounds.size.width * host.bounds.size.height)) {
        gHudHost = layer;
    }
}

static double cpuPercent(void) {
    static uint64_t lastBusy, lastTotal;
    host_cpu_load_info_data_t info; mach_msg_type_number_t n = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &n) != KERN_SUCCESS) return -1;
    uint64_t busy = (uint64_t)info.cpu_ticks[CPU_STATE_USER] + info.cpu_ticks[CPU_STATE_SYSTEM] + info.cpu_ticks[CPU_STATE_NICE];
    uint64_t total = busy + info.cpu_ticks[CPU_STATE_IDLE];
    double pct = total > lastTotal ? 100.0 * (busy - lastBusy) / (total - lastTotal) : -1;
    lastBusy = busy; lastTotal = total;
    return pct;
}

static double gpuPercent(void) {
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    if (!s) return -1;
    double pct = -1;
    CFDictionaryRef stats = IORegistryEntryCreateCFProperty(s, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
    if (stats) {
        NSNumber *u = ((__bridge NSDictionary *)stats)[@"Device Utilization %"];
        if (u) pct = u.doubleValue;
        CFRelease(stats);
    }
    IOObjectRelease(s);
    return pct;
}

// Same idea as Activity Monitor's "Memory Used": app memory + wired + compressed.
static double memoryUsedGB(double *totalGB) {
    vm_statistics64_data_t vm; mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
    uint64_t total = 0; size_t len = sizeof total;
    sysctlbyname("hw.memsize", &total, &len, NULL, 0);
    *totalGB = total / 1073741824.0;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &n) != KERN_SUCCESS) return -1;
    uint64_t used = ((uint64_t)vm.internal_page_count - vm.purgeable_count + vm.wire_count + vm.compressor_page_count) * vm_kernel_page_size;
    return used / 1073741824.0;
}

// 0 green, 1 yellow, 2 orange, 3 red. `low` = lower values are worse (FPS).
static int health(double v, double a, double b, double c, BOOL low) {
    if (v < 0) return -1;
    if (low) return v >= a ? 0 : v >= b ? 1 : v >= c ? 2 : 3;
    return v < a ? 0 : v < b ? 1 : v < c ? 2 : 3;
}

static void hudRow(NSMutableAttributedString *s, NSString *name, NSString *value, int h, NSFont *font, NSFont *bold) {
    NSArray *colors = @[[NSColor colorWithSRGBRed:0.20 green:0.82 blue:0.40 alpha:1], [NSColor colorWithSRGBRed:1.00 green:0.82 blue:0.20 alpha:1],
                        [NSColor colorWithSRGBRed:1.00 green:0.55 blue:0.15 alpha:1], [NSColor colorWithSRGBRed:1.00 green:0.27 blue:0.27 alpha:1]];
    NSColor *dim = [NSColor colorWithWhite:1 alpha:0.6];
    if (s.length) [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:(h >= 0 ? @"● " : @"  ")
        attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: h >= 0 ? colors[h] : dim}]];
    static NSParagraphStyle *tabs;
    if (!tabs) {  // values start in one column whatever the label's width
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.tabStops = @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:font.pointSize * 4.6 options:@{}]];
        tabs = ps;
    }
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:[name stringByAppendingString:@"\t"]
        attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: dim, NSParagraphStyleAttributeName: tabs}]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:value
        attributes:@{NSFontAttributeName: bold, NSForegroundColorAttributeName: NSColor.whiteColor}]];
}

static struct { volatile double cpu, gpu, temp, mem, memTotal; } gSample = { -1, -1, -1, -1, 0 };

/// Off the main thread. CPU, GPU and memory are cheap (10x a second); temperature every 2 s.
static void hudSample(void) {
    static int n;
    if (!gHudFlag || access(gHudFlag, F_OK) != 0) return;
    double c = cpuPercent(), g = gpuPercent(), total = 0, m = memoryUsedGB(&total);
    gSample.cpu = c < 0 ? gSample.cpu : gSample.cpu < 0 ? c : gSample.cpu * 0.5 + c * 0.5;
    gSample.gpu = g < 0 ? gSample.gpu : gSample.gpu < 0 ? g : gSample.gpu * 0.5 + g * 0.5;
    gSample.mem = m; gSample.memTotal = total;
    if (n++ % 20 == 0) { double t = chipTemperature(); gSample.temp = t > 0 ? t : -1; }
}

static void hudUpdate(void) {
    static uint64_t lastFrames, lastNs;
    static double fps, cpu = -1, gpu = -1, mem = -1, memTotal, temp = -1;
    static int ticks;
    CALayer *host = gHudHost;
    BOOL on = access(gHudFlag, F_OK) == 0;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), frames = atomic_load(&gHudFrames);
    if (lastNs) {
        double inst = (frames - lastFrames) * 1e9 / (double)(now - lastNs);
        fps = fps == 0 ? inst : fps * 0.6 + inst * 0.4;  // ~0.25 s smoothing: moves fast, doesn't flicker
    }
    BOOL presenting = frames != lastFrames;
    lastFrames = frames; lastNs = now;
    ticks = presenting ? 0 : ticks + 1;
    if (!on || !host || ticks > 20) {  // off, or no frame for 2 s
        if (gHudLayer.superlayer) { [CATransaction begin]; [CATransaction setDisableActions:YES]; [gHudLayer removeFromSuperlayer]; [CATransaction commit]; }
        fps = 0;
        return;
    }
    // Readings come from hudSample() on a background queue: the chip temperature alone costs ~19 ms
    // (measured on an M4, 2026-11-20), and doing it here blocked the game's main thread 10x a second,
    // a dropped frame every 100 ms. This tick only reads the cached values.
    cpu = gSample.cpu; gpu = gSample.gpu; temp = gSample.temp; mem = gSample.mem; memTotal = gSample.memTotal;
    CGFloat size = 11;
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightMedium];
    NSFont *bold = [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightSemibold];
    NSMutableAttributedString *s = [NSMutableAttributedString new];
    hudRow(s, @"FPS", [NSString stringWithFormat:@"%.0f", fps], health(fps, 55, 40, 25, YES), font, bold);
    hudRow(s, @"CPU", cpu < 0 ? @"-" : [NSString stringWithFormat:@"%.0f%%", cpu], health(cpu, 60, 80, 92, NO), font, bold);
    hudRow(s, @"GPU", gpu < 0 ? @"-" : [NSString stringWithFormat:@"%.0f%%", gpu], health(gpu, 70, 85, 95, NO), font, bold);
    hudRow(s, @"RAM", mem < 0 ? @"-" : [NSString stringWithFormat:@"%.1f/%.0f GB", mem, memTotal],
           mem < 0 ? -1 : health(100 * mem / memTotal, 70, 82, 92, NO), font, bold);
    hudRow(s, @"TEMP", temp < 0 ? @"-" : [NSString stringWithFormat:@"%.0f°C", temp], health(temp, 75, 88, 98, NO), font, bold);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!gHudLayer) {
        gHudLayer = [CALayer layer];
        gHudLayer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.55].CGColor;
        gHudLayer.cornerRadius = 8;
        gHudLayer.zPosition = 1000;
        gHudText = [CATextLayer layer];
        [gHudLayer addSublayer:gHudText];
    }
    if (gHudLayer.superlayer != host) [host addSublayer:gHudLayer];
    gHudLayer.contentsScale = gHudText.contentsScale = MAX(host.contentsScale, 2);
    gHudText.string = s;
    CGSize text = [s size];
    CGFloat pad = 8, m = 12, w = ceil(MAX(text.width, 110)) + 2 * pad, th = ceil(text.height), h = th + 2 * pad;
    CGRect b = host.bounds;
    gHudLayer.frame = CGRectMake(b.size.width - w - m, [host contentsAreFlipped] ? m : b.size.height - h - m, w, h);
    gHudText.frame = CGRectMake(pad, pad, w - 2 * pad, th);
    [CATransaction commit];
}

static void hudInit(void) {
    Dl_info info;
    if (!dladdr((const void *)hudInit, &info) || !info.dli_fname) return;
    const char *f = strstr(info.dli_fname, "/Frameworks/wynix_upscale.dylib");
    if (!f) return;
    NSString *contents = [[NSString alloc] initWithBytes:info.dli_fname length:f - info.dli_fname encoding:NSUTF8StringEncoding];
    gHudFlag = strdup([contents stringByAppendingPathComponent:@"drive_c/steamy/hud"].fileSystemRepresentation);
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), NSEC_PER_SEC / 10, NSEC_PER_SEC / 50);
    dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { @try { hudUpdate(); } @catch (id e) {} } });
    dispatch_resume(timer);
    static dispatch_source_t sampler;
    sampler = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_queue_create("wynix.hud.sample", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)));
    dispatch_source_set_timer(sampler, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), NSEC_PER_SEC / 10, NSEC_PER_SEC / 50);
    dispatch_source_set_event_handler(sampler, ^{ @autoreleasepool { hudSample(); } });
    dispatch_resume(sampler);
}

// ---- Game priority ----
// No admin rights needed: the thread that hands frames to the screen gets macOS's highest QoS
// (user-interactive: performance cores first, scheduled ahead of everything else) and the game
// process is marked as the foreground app. Never for Steam's own processes.
static void gameBoostTick(CAMetalLayer *layer) {
    static _Thread_local BOOL threadDone;
    if (threadDone || !isWineView(layer) || isSteamProcess()) return;
    threadDone = YES;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        setpriority(PRIO_DARWIN_PROCESS, 0, 0);  // leave the background band inherited from a lowered Steam
        task_category_policy_data_t p = { TASK_FOREGROUND_APPLICATION };
        task_policy_set(mach_task_self(), TASK_CATEGORY_POLICY, (task_policy_t)&p, TASK_CATEGORY_POLICY_COUNT);
        LOG("game priority: render thread user-interactive, task foreground");
    });
}

__attribute__((constructor)) static void wynixUpscaleInit(void) {
    const char *on = getenv("WYNIX_UPSCALE");
    gUpscale = on && strcmp(on, "1") == 0;
    const char *bf = getenv("WYNIX_BENCH_FILE");
    if (bf && *bf) gBenchPath = strdup(bf);
    hudInit();
    if (!gUpscale && !gBenchPath && !gHudFlag) return;
    gLog = getenv("WYNIX_UPSCALE_LOG") != NULL;
    gLabel = getenv("WYNIX_UPSCALE_LABEL") && strcmp(getenv("WYNIX_UPSCALE_LABEL"), "1") == 0;
    gAnyLayer = getenv("WYNIX_UPSCALE_ANY_LAYER") != NULL;
    const char *to = getenv("WYNIX_UPSCALE_OUTPUT");
    if (to) { unsigned w = 0, h = 0; if (sscanf(to, "%ux%u", &w, &h) == 2) { gTestOutW = w; gTestOutH = h; } }
    const char *mx = getenv("WYNIX_UPSCALE_MAX");
    if (mx) { unsigned w = 0, h = 0; if (sscanf(mx, "%ux%u", &w, &h) == 2 && w >= 64 && h >= 64) { gMaxW = w; gMaxH = h; } }
    if (gBenchPath) {
        gBenchFlushLock = [NSLock new];
        static dispatch_source_t timer;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_queue_create("wynix.bench", DISPATCH_QUEUE_SERIAL));
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{ benchFlush(); });
        dispatch_resume(timer);
        atexit(benchFlush);
    }
    if (!gUpscale) {  // bench only: just the nextDrawable hook (it installs the present hooks)
        Method mn = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
        if (!mn) return;
        gOrigNextDrawable = method_getImplementation(mn);
        class_replaceMethod([CAMetalLayer class], @selector(nextDrawable), (IMP)hookedNextDrawable, method_getTypeEncoding(mn));
        _dyld_register_func_for_add_image(onImageAdded);
        return;
    }
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
