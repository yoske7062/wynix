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
    BOOL m4 = getenv("HARNESS_MTL4") != NULL;
    id<MTL4CommandQueue> q4 = nil; id<MTL4CommandAllocator> al4 = nil; id<MTL4CommandBuffer> cb4 = nil;
    if (m4) {
        if (@available(macOS 26.0, *)) { q4 = [dev newMTL4CommandQueue]; al4 = [dev newCommandAllocator]; cb4 = [dev newCommandBuffer]; }
        if (!cb4) { fprintf(stderr, "MTL4 unavailable\n"); return 4; }
    }
    __block double gpu = 0; __block int done = 0, errors = 0;
    NSUInteger w = 0, h = 0;
    CGSize want = layer.drawableSize, seen = want;
    for (int i = 0; i < frames; i++) { @autoreleasepool {
        id<CAMetalDrawable> d = [layer nextDrawable];
        if (!d) { fprintf(stderr, "no drawable\n"); return 2; }
        seen = layer.drawableSize;  // the game must keep seeing its own size, never the screen's
        w = d.texture.width; h = d.texture.height;
        if (m4) { if (@available(macOS 26.0, *)) {
            // Metal 4 presentation: wait, render, commit, signal, present.
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [q4 waitForDrawable:d];
            [al4 reset];
            [cb4 beginCommandBufferWithAllocator:al4];
            MTL4RenderPassDescriptor *rp4 = [MTL4RenderPassDescriptor new];
            rp4.colorAttachments[0].texture = d.texture;
            rp4.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp4.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp4.colorAttachments[0].clearColor = MTLClearColorMake((i % 60) / 60.0, 0.3, 0.6, 1);
            [[cb4 renderCommandEncoderWithDescriptor:rp4] endEncoding];
            [cb4 endCommandBuffer];
            id<MTL4CommandBuffer> bufs[1] = { cb4 };
            MTL4CommitOptions *o = [MTL4CommitOptions new];
            [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) {
                if (f.error) errors++;
                gpu += f.GPUEndTime - f.GPUStartTime; done++;
                dispatch_semaphore_signal(sem);
            }];
            [q4 commit:bufs count:1 options:o];
            [q4 signalDrawable:d];
            [d present];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);  // reuse allocator/buffer next frame
            continue;
        } }
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
