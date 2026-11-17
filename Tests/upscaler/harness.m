// Fake "game" for wynix_upscale.dylib: offscreen CAMetalLayer, renders into whatever texture
// nextDrawable returns, presents through a command buffer. Checks the hook engaged, frames
// complete without errors, and reports GPU time per frame.
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
int main(int argc, char **argv) { @autoreleasepool {
    int frames = argc > 1 ? atoi(argv[1]) : 600;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = dev; layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // Game resolution WxH (argv[2], argv[3]; default 2560x1440).
    layer.drawableSize = CGSizeMake(argc > 3 ? atoi(argv[2]) : 2560, argc > 3 ? atoi(argv[3]) : 1440);
    __block double gpu = 0; __block int done = 0, errors = 0;
    NSUInteger w = 0, h = 0;
    CGSize want = layer.drawableSize, seen = want;
    for (int i = 0; i < frames; i++) { @autoreleasepool {
        id<CAMetalDrawable> d = [layer nextDrawable];
        if (!d) { fprintf(stderr, "no drawable\n"); return 2; }
        seen = layer.drawableSize;  // the game must keep seeing its own size, never the screen's
        w = d.texture.width; h = d.texture.height;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = d.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake((i % 60) / 60.0, 0.3, 0.6, 1);
        [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        [cb presentDrawable:d];
        [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
            if (c.status != MTLCommandBufferStatusCompleted) errors++;
            gpu += c.GPUEndTime - c.GPUStartTime; done++;
        }];
        [cb commit];
        if (i == frames - 1) [cb waitUntilCompleted];
    }}
    [NSThread sleepForTimeInterval:0.2];
    printf("render %lux%lu frames %d errors %d gpu_ms_per_frame %.3f\n", (unsigned long)w, (unsigned long)h, done, errors, gpu / done * 1000);
    printf("layer_size %lux%lu\n", (unsigned long)seen.width, (unsigned long)seen.height);
    if (!CGSizeEqualToSize(seen, want)) { fprintf(stderr, "drawableSize leaked the real size\n"); return 3; }
    return errors ? 1 : 0;
}}
