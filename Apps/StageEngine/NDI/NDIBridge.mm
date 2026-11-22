// Objective-C++ wrapper around NDI (SDK 6.x): sources discovery, a sender and a receiver.
//
// libndi.dylib is loaded with dlopen, so the build needs only the headers in vendor/NDISDK/include
// (not committed, see docs/sdk-setup.md). Without them this file builds a stub.

#import "NDIBridge.h"

static NSString *const kNDIErrorDomain = @"NDIBridge";

static NSError *NDIMakeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kNDIErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

@interface NDISourceInfo ()
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *address;
@end
@implementation NDISourceInfo
@end

#if __has_include("Processing.NDI.Lib.h")

#include <dlfcn.h>
#include <atomic>
#include <mutex>
#include <thread>
#include "Processing.NDI.Lib.h"
#include "Processing.NDI.DynamicLoad.h"

typedef const NDIlib_v6 *(*NDILoadFunction)(void);

static const NDIlib_v6 *gNDI = nullptr;
static NSString *gNDILoadFailure = nil;

static const NDIlib_v6 *LoadNDI(NSString **failure) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        const char *env = getenv("STAGE_NDI_LIB");
        if (env) [candidates addObject:@(env)];
        const char *runtime = getenv("NDI_RUNTIME_DIR_V6");
        if (runtime) [candidates addObject:[@(runtime) stringByAppendingPathComponent:@"libndi.dylib"]];
        [candidates addObject:@"/usr/local/lib/libndi.dylib"];
        [candidates addObject:@"/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"];
        [candidates addObject:@"/Applications/NDI Video Monitor.app/Contents/Frameworks/libndi.dylib"];
        [candidates addObject:[[NSBundle mainBundle].privateFrameworksPath stringByAppendingPathComponent:@"libndi.dylib"] ?: @""];
        [candidates addObject:@"libndi.dylib"];

        void *handle = nullptr;
        for (NSString *path in candidates) {
            if (path.length == 0) continue;
            handle = dlopen(path.fileSystemRepresentation, RTLD_LOCAL | RTLD_LAZY);
            if (handle) break;
        }
        if (!handle) {
            gNDILoadFailure = [NSString stringWithFormat:
                @"Could not load libndi.dylib. Install the NDI SDK or NDI Tools, or set STAGE_NDI_LIB to its path. Tried:\n  %@",
                [candidates componentsJoinedByString:@"\n  "]];
            return;
        }
        NDILoadFunction load = (NDILoadFunction)dlsym(handle, "NDIlib_v6_load");
        if (!load) {
            gNDILoadFailure = @"libndi.dylib was found but has no NDIlib_v6_load (NDI runtime older than 6).";
            return;
        }
        const NDIlib_v6 *lib = load();
        if (!lib || !lib->initialize()) {
            gNDILoadFailure = @"NDI failed to initialise (unsupported CPU or blocked network access).";
            return;
        }
        gNDI = lib;
    });
    if (!gNDI && failure) *failure = gNDILoadFailure ?: @"NDI is unavailable.";
    return gNDI;
}

@implementation NDIRuntime

+ (BOOL)prepareAndReturnError:(NSError **)error {
    NSString *failure = nil;
    if (LoadNDI(&failure)) return YES;
    if (error) *error = NDIMakeError(1, failure);
    return NO;
}

+ (NSArray<NDISourceInfo *> *)findSourcesWaiting:(NSTimeInterval)seconds {
    NSMutableArray<NDISourceInfo *> *result = [NSMutableArray array];
    const NDIlib_v6 *ndi = LoadNDI(nil);
    if (!ndi) return result;

    NDIlib_find_create_t settings;
    settings.show_local_sources = true;
    settings.p_groups = nullptr;
    settings.p_extra_ips = nullptr;
    NDIlib_find_instance_t finder = ndi->find_create_v2(&settings);
    if (!finder) return result;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    // Wait for the list to change, then once more so a slow second source is not missed.
    while ([deadline timeIntervalSinceNow] > 0) {
        if (!ndi->find_wait_for_sources(finder, 1000)) {
            uint32_t count = 0;
            ndi->find_get_current_sources(finder, &count);
            if (count > 0) break;
        }
    }
    ndi->find_wait_for_sources(finder, 500);

    uint32_t count = 0;
    const NDIlib_source_t *sources = ndi->find_get_current_sources(finder, &count);
    for (uint32_t i = 0; i < count; i++) {
        NDISourceInfo *info = [[NDISourceInfo alloc] init];
        info.name = sources[i].p_ndi_name ? @(sources[i].p_ndi_name) : @"";
        info.address = sources[i].p_url_address ? @(sources[i].p_url_address) : @"";
        [result addObject:info];
    }
    ndi->find_destroy(finder);
    return result;
}

@end

// MARK: - Sender

@interface NDISenderBridge () {
    NDIlib_send_instance_t _sender;
    std::mutex _lock;
    CVPixelBufferRef _previous; // still referenced by NDI until the next async send
    std::atomic<uint64_t> _framesSent;
    BOOL _stopped;
}
@end

@implementation NDISenderBridge

- (nullable instancetype)initWithName:(NSString *)name clockVideo:(BOOL)clockVideo error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    NSString *failure = nil;
    const NDIlib_v6 *ndi = LoadNDI(&failure);
    if (!ndi) {
        if (error) *error = NDIMakeError(1, failure);
        return nil;
    }
    NDIlib_send_create_t settings;
    settings.p_ndi_name = name.UTF8String;
    settings.p_groups = nullptr;
    settings.clock_video = clockVideo;
    settings.clock_audio = false;
    _sender = ndi->send_create(&settings);
    if (!_sender) {
        if (error) *error = NDIMakeError(2, @"NDI could not create a sender.");
        return nil;
    }
    _previous = nullptr;
    _framesSent = 0;
    _stopped = NO;
    return self;
}

- (BOOL)sendPackedYUV:(CVPixelBufferRef)pixelBuffer {
    std::lock_guard<std::mutex> guard(_lock);
    if (_stopped) return NO;

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    CFRetain(pixelBuffer);

    NDIlib_video_frame_v2_t frame;
    frame.xres = (int)CVPixelBufferGetWidth(pixelBuffer) * 2; // two pixels per 4-byte texel
    frame.yres = (int)CVPixelBufferGetHeight(pixelBuffer);
    frame.FourCC = NDIlib_FourCC_video_type_UYVY;
    frame.frame_rate_N = 60000;
    frame.frame_rate_D = 1001;
    frame.picture_aspect_ratio = 16.0f / 9.0f;
    frame.frame_format_type = NDIlib_frame_format_type_progressive;
    frame.timecode = NDIlib_send_timecode_synthesize;
    frame.p_data = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    frame.line_stride_in_bytes = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);
    frame.p_metadata = nullptr;
    frame.timestamp = 0;

    // Asynchronous: NDI keeps reading `frame.p_data` until the next send call, which also tells us
    // the previous buffer is free.
    gNDI->send_send_video_async_v2(_sender, &frame);

    if (_previous) {
        CVPixelBufferUnlockBaseAddress(_previous, kCVPixelBufferLock_ReadOnly);
        CFRelease(_previous);
    }
    _previous = pixelBuffer;
    _framesSent++;
    return YES;
}

- (uint64_t)framesSent { return _framesSent; }

- (int)connectionCount {
    if (!_sender || _stopped) return 0;
    return gNDI->send_get_no_connections(_sender, 0);
}

- (void)resetStatistics { _framesSent = 0; }

- (void)stop {
    std::lock_guard<std::mutex> guard(_lock);
    if (_stopped) return;
    _stopped = YES;
    if (_sender) {
        gNDI->send_send_video_async_v2(_sender, nullptr); // flush: NDI is done with the last buffer
        gNDI->send_destroy(_sender);
        _sender = nullptr;
    }
    if (_previous) {
        CVPixelBufferUnlockBaseAddress(_previous, kCVPixelBufferLock_ReadOnly);
        CFRelease(_previous);
        _previous = nullptr;
    }
}

- (void)dealloc { [self stop]; }

@end

// MARK: - Receiver

@interface NDIReceiverBridge () {
    NDIlib_recv_instance_t _receiver;
    std::thread _thread;
    std::atomic<bool> _running;
    std::mutex _lock;
    CVPixelBufferRef _latest;
    CVPixelBufferPoolRef _pool;
    int _poolWidth, _poolHeight;
    std::atomic<uint64_t> _framesReceived;
    uint64_t _latestSequence;   // guarded by _lock
    std::atomic<int> _width, _height;
    NDIlib_framesync_instance_t _framesync;
    BOOL _useFrameSync;
    int64_t _firstTimestamp;    // frame-sync mode: source timestamps (100 ns units), guarded by _lock
    int64_t _lastTimestamp;
}
@end

@implementation NDIReceiverBridge

- (nullable instancetype)initWithSourceNameContaining:(NSString *)text
                                          waitSeconds:(NSTimeInterval)seconds
                                            frameSync:(BOOL)frameSync
                                                error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _useFrameSync = frameSync;
    _framesync = nullptr;
    _firstTimestamp = 0;
    _lastTimestamp = 0;
    NSString *failure = nil;
    const NDIlib_v6 *ndi = LoadNDI(&failure);
    if (!ndi) {
        if (error) *error = NDIMakeError(1, failure);
        return nil;
    }

    NDIlib_find_create_t settings;
    settings.show_local_sources = true;
    settings.p_groups = nullptr;
    settings.p_extra_ips = nullptr;
    NDIlib_find_instance_t finder = ndi->find_create_v2(&settings);
    if (!finder) {
        if (error) *error = NDIMakeError(2, @"NDI could not start source discovery.");
        return nil;
    }

    NDIlib_source_t chosen;
    bool found = false;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    NSMutableArray<NSString *> *seen = [NSMutableArray array];
    while (!found) {
        uint32_t count = 0;
        const NDIlib_source_t *sources = ndi->find_get_current_sources(finder, &count);
        [seen removeAllObjects];
        for (uint32_t i = 0; i < count && !found; i++) {
            NSString *name = sources[i].p_ndi_name ? @(sources[i].p_ndi_name) : @"";
            [seen addObject:name];
            if ([name rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) {
                chosen = sources[i];
                _sourceName = [name copy];
                found = true;
            }
        }
        if (found || [deadline timeIntervalSinceNow] <= 0) break;
        ndi->find_wait_for_sources(finder, 500);
    }

    if (!found) {
        ndi->find_destroy(finder);
        if (error) {
            *error = NDIMakeError(3, [NSString stringWithFormat:
                @"No NDI source matching \"%@\" was found. Sources seen: %@", text,
                seen.count ? [seen componentsJoinedByString:@"; "] : @"none"]);
        }
        return nil;
    }

    NDIlib_recv_create_v3_t recv;
    recv.source_to_connect_to = chosen;
    recv.color_format = NDIlib_recv_color_format_BGRX_BGRA;
    recv.bandwidth = NDIlib_recv_bandwidth_highest;
    recv.allow_video_fields = false;
    recv.p_ndi_recv_name = "CueME Stage";
    _receiver = ndi->recv_create_v3(&recv);
    ndi->find_destroy(finder); // the receiver has its own copy of the address by now
    if (!_receiver) {
        if (error) *error = NDIMakeError(4, @"NDI could not create a receiver.");
        return nil;
    }
    if (_useFrameSync) {
        _framesync = ndi->framesync_create(_receiver);
        if (!_framesync) {
            if (error) *error = NDIMakeError(5, @"NDI could not create the frame synchronizer.");
            return nil;
        }
    }

    _running = false;
    _latest = nullptr;
    _pool = nullptr;
    _poolWidth = _poolHeight = 0;
    _framesReceived = 0;
    _latestSequence = 0;
    _width = _height = 0;
    return self;
}

- (uint64_t)framesReceived { return _framesReceived; }
- (uint64_t)latestSequence {
    std::lock_guard<std::mutex> guard(_lock);
    return _latestSequence;
}
- (int)width { return _width; }
- (int)height { return _height; }

- (void)start {
    if (_running.exchange(true)) return;
    if (_useFrameSync) return; // the synchronizer runs its own capture thread
    _thread = std::thread([self] { [self captureLoop]; });
}

- (void)stop {
    if (_running.exchange(false)) {
        if (_thread.joinable()) _thread.join();
    }
}

/// Frame-sync mode: ask NDI for the best frame for this moment, copy it only if it is a new one.
- (nullable CVPixelBufferRef)pullFrameSyncFrame {
    if (!_framesync || !_running) return nullptr;
    NDIlib_video_frame_v2_t video;
    video.p_data = nullptr;
    gNDI->framesync_capture_video(_framesync, &video, NDIlib_frame_format_type_progressive);

    if (video.p_data) {
        int64_t timestamp = video.timestamp;
        bool isNew;
        {
            std::lock_guard<std::mutex> guard(_lock);
            isNew = (_latest == nullptr) || (timestamp != _lastTimestamp);
        }
        if (isNew) {
            [self storeFrame:video]; // copies into a pooled buffer and counts the frame
            std::lock_guard<std::mutex> guard(_lock);
            _lastTimestamp = timestamp;
            if (timestamp != INT64_MIN) {
                if (_firstTimestamp == 0) _firstTimestamp = timestamp;
                // Sequence number from the source's own clock, so skipped frames show up as gaps.
                const double framePeriod = 10000000.0 * 1001.0 / 60000.0; // 100 ns units at 59.94 fps
                _latestSequence = (uint64_t)llround((double)(timestamp - _firstTimestamp) / framePeriod) + 1;
            }
        }
        gNDI->framesync_free_video(_framesync, &video);
    }
    std::lock_guard<std::mutex> guard(_lock);
    return _latest ? (CVPixelBufferRef)CFRetain(_latest) : nullptr;
}

- (nullable CVPixelBufferRef)copyLatestFrame {
    if (_useFrameSync) return [self pullFrameSyncFrame];
    std::lock_guard<std::mutex> guard(_lock);
    if (!_latest) return nullptr;
    return (CVPixelBufferRef)CFRetain(_latest);
}

- (void)captureLoop {
    pthread_setname_np("stage.ndi.receive");
    while (_running) {
        NDIlib_video_frame_v2_t video;
        NDIlib_frame_type_e type = gNDI->recv_capture_v2(_receiver, &video, nullptr, nullptr, 100);
        if (type != NDIlib_frame_type_video) continue;
        [self storeFrame:video];
        gNDI->recv_free_video_v2(_receiver, &video);
    }
}

/// Copy a received frame into a pooled BGRA pixel buffer the compositor can read as a texture.
- (void)storeFrame:(const NDIlib_video_frame_v2_t &)video {
    int width = video.xres, height = video.yres;
    if (width <= 0 || height <= 0 || !video.p_data) return;
    if (video.FourCC != NDIlib_FourCC_video_type_BGRA && video.FourCC != NDIlib_FourCC_video_type_BGRX) return;

    if (!_pool || width != _poolWidth || height != _poolHeight) {
        if (_pool) CVPixelBufferPoolRelease(_pool);
        NSDictionary *attributes = @{
            (id)kCVPixelBufferWidthKey : @(width),
            (id)kCVPixelBufferHeightKey : @(height),
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferMetalCompatibilityKey : @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        NSDictionary *poolAttributes = @{(id)kCVPixelBufferPoolMinimumBufferCountKey : @4};
        _pool = nullptr;
        CVPixelBufferPoolCreate(nullptr, (__bridge CFDictionaryRef)poolAttributes,
                                (__bridge CFDictionaryRef)attributes, &_pool);
        _poolWidth = width;
        _poolHeight = height;
    }
    if (!_pool) return;

    CVPixelBufferRef buffer = nullptr;
    if (CVPixelBufferPoolCreatePixelBuffer(nullptr, _pool, &buffer) != kCVReturnSuccess || !buffer) return;

    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    size_t dstStride = CVPixelBufferGetBytesPerRow(buffer);
    const uint8_t *src = video.p_data;
    size_t srcStride = video.line_stride_in_bytes ? (size_t)video.line_stride_in_bytes : (size_t)width * 4;
    bool opaque = (video.FourCC == NDIlib_FourCC_video_type_BGRX); // BGRX's fourth byte is undefined
    for (int y = 0; y < height; y++) {
        if (opaque) {
            const uint32_t *s = (const uint32_t *)(src + y * srcStride);
            uint32_t *d = (uint32_t *)(dst + y * dstStride);
            for (int x = 0; x < width; x++) d[x] = s[x] | 0xFF000000u;
        } else {
            memcpy(dst + y * dstStride, src + y * srcStride, (size_t)width * 4);
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);

    CVPixelBufferRef old = nullptr;
    {
        std::lock_guard<std::mutex> guard(_lock);
        old = _latest;
        _latest = buffer;
        _latestSequence = _framesReceived + 1;
    }
    if (old) CFRelease(old);
    _width = width;
    _height = height;
    _framesReceived++;
}

- (void)dealloc {
    [self stop];
    if (_framesync && gNDI) gNDI->framesync_destroy(_framesync);
    if (_receiver && gNDI) gNDI->recv_destroy(_receiver);
    if (_latest) CFRelease(_latest);
    if (_pool) CVPixelBufferPoolRelease(_pool);
}

@end

#else // NDI headers not present: stubs that explain what is missing

static NSString *const kNoSDK = @"Built without the NDI SDK headers. See docs/sdk-setup.md.";

@implementation NDIRuntime
+ (BOOL)prepareAndReturnError:(NSError **)error {
    if (error) *error = NDIMakeError(100, kNoSDK);
    return NO;
}
+ (NSArray<NDISourceInfo *> *)findSourcesWaiting:(NSTimeInterval)seconds { return @[]; }
@end

@implementation NDISenderBridge
- (nullable instancetype)initWithName:(NSString *)name clockVideo:(BOOL)clockVideo error:(NSError **)error {
    if (error) *error = NDIMakeError(100, kNoSDK);
    return nil;
}
- (BOOL)sendPackedYUV:(CVPixelBufferRef)pixelBuffer { return NO; }
- (uint64_t)framesSent { return 0; }
- (int)connectionCount { return 0; }
- (void)resetStatistics {}
- (void)stop {}
@end

@implementation NDIReceiverBridge
- (nullable instancetype)initWithSourceNameContaining:(NSString *)text waitSeconds:(NSTimeInterval)seconds frameSync:(BOOL)frameSync error:(NSError **)error {
    if (error) *error = NDIMakeError(100, kNoSDK);
    return nil;
}
- (uint64_t)framesReceived { return 0; }
- (uint64_t)latestSequence { return 0; }
- (int)width { return 0; }
- (int)height { return 0; }
- (void)start {}
- (void)stop {}
- (nullable CVPixelBufferRef)copyLatestFrame { return nullptr; }
@end

#endif
