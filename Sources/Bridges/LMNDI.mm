#import "LMNDI.h"
#include <dlfcn.h>

#if __has_include(<Processing.NDI.Lib.h>)
#define LM_HAS_NDI 1
#include <Processing.NDI.Lib.h>
#else
#define LM_HAS_NDI 0
#endif

#if LM_HAS_NDI
// Resolved from libndi at runtime so we never hard-link it.
static decltype(&NDIlib_initialize) p_initialize;
static decltype(&NDIlib_send_create) p_send_create;
static decltype(&NDIlib_send_send_video_v2) p_send_video;
static decltype(&NDIlib_send_destroy) p_send_destroy;
static decltype(&NDIlib_find_create_v2) p_find_create;
static decltype(&NDIlib_find_wait_for_sources) p_find_wait;
static decltype(&NDIlib_find_get_current_sources) p_find_sources;
static decltype(&NDIlib_find_destroy) p_find_destroy;
static decltype(&NDIlib_recv_create_v3) p_recv_create;
static decltype(&NDIlib_recv_capture_v2) p_recv_capture;
static decltype(&NDIlib_recv_free_video_v2) p_recv_free_video;
static decltype(&NDIlib_recv_destroy) p_recv_destroy;

static BOOL LMLoadNDI(void) {
    static BOOL loaded = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSString *env in @[@"NDI_RUNTIME_DIR_V6", @"NDI_RUNTIME_DIR_V5"]) {
            const char *d = getenv(env.UTF8String);
            if (d) [paths addObject:[[NSString stringWithUTF8String:d] stringByAppendingPathComponent:@"libndi.dylib"]];
        }
        [paths addObjectsFromArray:@[
            @"/usr/local/lib/libndi.dylib",
            @"/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
            @"/Library/NDI Advanced SDK for Apple/lib/macOS/libndi_advanced.dylib",
            [[NSBundle mainBundle].privateFrameworksPath stringByAppendingPathComponent:@"libndi.dylib"],
        ]];
        void *h = NULL;
        for (NSString *p in paths) {
            h = dlopen(p.fileSystemRepresentation, RTLD_LOCAL | RTLD_LAZY);
            if (h) break;
        }
        if (!h) return;
#define LOAD(var, sym) var = (decltype(var))dlsym(h, #sym); if (!var) return;
        LOAD(p_initialize, NDIlib_initialize)
        LOAD(p_send_create, NDIlib_send_create)
        LOAD(p_send_video, NDIlib_send_send_video_v2)
        LOAD(p_send_destroy, NDIlib_send_destroy)
        LOAD(p_find_create, NDIlib_find_create_v2)
        LOAD(p_find_wait, NDIlib_find_wait_for_sources)
        LOAD(p_find_sources, NDIlib_find_get_current_sources)
        LOAD(p_find_destroy, NDIlib_find_destroy)
        LOAD(p_recv_create, NDIlib_recv_create_v3)
        LOAD(p_recv_capture, NDIlib_recv_capture_v2)
        LOAD(p_recv_free_video, NDIlib_recv_free_video_v2)
        LOAD(p_recv_destroy, NDIlib_recv_destroy)
#undef LOAD
        loaded = p_initialize();
    });
    return loaded;
}
#endif

@implementation LMNDI

+ (BOOL)sdkCompiledIn { return LM_HAS_NDI; }

+ (BOOL)runtimeAvailable {
#if LM_HAS_NDI
    return LMLoadNDI();
#else
    return NO;
#endif
}

+ (NSArray<NSString *> *)findSourcesWaiting:(int)milliseconds {
    NSMutableArray *out = [NSMutableArray array];
#if LM_HAS_NDI
    if (!LMLoadNDI()) return out;
    NDIlib_find_instance_t f = p_find_create(NULL);
    if (!f) return out;
    p_find_wait(f, (uint32_t)milliseconds);
    uint32_t count = 0;
    const NDIlib_source_t *sources = p_find_sources(f, &count);
    for (uint32_t i = 0; i < count; i++) {
        if (sources[i].p_ndi_name) [out addObject:[NSString stringWithUTF8String:sources[i].p_ndi_name]];
    }
    p_find_destroy(f);
#endif
    return out;
}

@end

@implementation LMNDISender {
#if LM_HAS_NDI
    NDIlib_send_instance_t _send;
#endif
    NSLock *_lock;
}

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (!self) return nil;
    _lock = [NSLock new];
#if LM_HAS_NDI
    if (!LMLoadNDI()) return nil;
    NDIlib_send_create_t desc;
    desc.p_ndi_name = name.UTF8String;
    desc.p_groups = NULL;
    desc.clock_video = false;
    desc.clock_audio = false;
    _send = p_send_create(&desc);
    if (!_send) return nil;
    return self;
#else
    return nil;
#endif
}

- (void)sendPixelBuffer:(CVPixelBufferRef)buffer frameRate:(double)fps {
#if LM_HAS_NDI
    [_lock lock];
    if (!_send) { [_lock unlock]; return; }
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    NDIlib_video_frame_v2_t frame;
    frame.xres = (int)CVPixelBufferGetWidth(buffer);
    frame.yres = (int)CVPixelBufferGetHeight(buffer);
    frame.FourCC = NDIlib_FourCC_video_type_BGRA;
    // 29.97 → 30000/1001, 59.94 → 60000/1001
    if (fabs(fps - 29.97) < 0.01) { frame.frame_rate_N = 30000; frame.frame_rate_D = 1001; }
    else if (fabs(fps - 59.94) < 0.01) { frame.frame_rate_N = 60000; frame.frame_rate_D = 1001; }
    else { frame.frame_rate_N = (int)lround(fps * 1000); frame.frame_rate_D = 1000; }
    frame.picture_aspect_ratio = (float)frame.xres / (float)frame.yres;
    frame.frame_format_type = NDIlib_frame_format_type_progressive;
    frame.timecode = NDIlib_send_timecode_synthesize;
    frame.p_data = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    frame.line_stride_in_bytes = (int)CVPixelBufferGetBytesPerRow(buffer);
    frame.p_metadata = NULL;
    frame.timestamp = 0;
    p_send_video(_send, &frame);
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    [_lock unlock];
#endif
}

- (void)stop {
#if LM_HAS_NDI
    [_lock lock];
    if (_send) { p_send_destroy(_send); _send = NULL; }
    [_lock unlock];
#endif
}

- (void)dealloc { [self stop]; }

@end

@implementation LMNDIReceiver {
#if LM_HAS_NDI
    NDIlib_recv_instance_t _recv;
#endif
    NSThread *_thread;
    volatile BOOL _running;
    void (^_handler)(CVPixelBufferRef);
}

- (instancetype)initWithSource:(NSString *)name handler:(void (^)(CVPixelBufferRef))handler {
    self = [super init];
    if (!self) return nil;
#if LM_HAS_NDI
    if (!LMLoadNDI()) return nil;
    _handler = [handler copy];
    NDIlib_recv_create_v3_t desc;
    desc.source_to_connect_to.p_ndi_name = name.UTF8String;
    desc.source_to_connect_to.p_url_address = NULL;
    desc.color_format = NDIlib_recv_color_format_BGRX_BGRA;
    desc.bandwidth = NDIlib_recv_bandwidth_highest;
    desc.allow_video_fields = false;
    desc.p_ndi_recv_name = "Lumen";
    _recv = p_recv_create(&desc);
    if (!_recv) return nil;
    _running = YES;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(loop) object:nil];
    _thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [_thread start];
    return self;
#else
    return nil;
#endif
}

- (void)loop {
#if LM_HAS_NDI
    CVPixelBufferPoolRef pool = NULL;
    int poolW = 0, poolH = 0;
    while (_running) {
        NDIlib_video_frame_v2_t video;
        NDIlib_frame_type_e t = p_recv_capture(_recv, &video, NULL, NULL, 500);
        if (t != NDIlib_frame_type_video) continue;
        if (!pool || poolW != video.xres || poolH != video.yres) {
            if (pool) CVPixelBufferPoolRelease(pool);
            NSDictionary *attrs = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferWidthKey: @(video.xres),
                (id)kCVPixelBufferHeightKey: @(video.yres),
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            };
            CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &pool);
            poolW = video.xres; poolH = video.yres;
        }
        CVPixelBufferRef pb = NULL;
        if (pool && CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pb) == kCVReturnSuccess) {
            CVPixelBufferLockBaseAddress(pb, 0);
            uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
            size_t dstStride = CVPixelBufferGetBytesPerRow(pb);
            size_t row = MIN(dstStride, (size_t)video.line_stride_in_bytes);
            for (int y = 0; y < video.yres; y++) {
                memcpy(dst + y * dstStride, video.p_data + y * video.line_stride_in_bytes, row);
            }
            CVPixelBufferUnlockBaseAddress(pb, 0);
            _handler(pb);
            CVPixelBufferRelease(pb);
        }
        p_recv_free_video(_recv, &video);
    }
    if (pool) CVPixelBufferPoolRelease(pool);
    p_recv_destroy(_recv);
    _recv = NULL;
#endif
}

- (void)stop { _running = NO; }

- (void)dealloc { _running = NO; }

@end
