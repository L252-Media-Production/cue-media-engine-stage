// Objective-C++ wrapper around the Blackmagic DeckLink API (SDK 16.0): scheduled 1080p59.94 output
// of BGRA CVPixelBuffers on one connector.
//
// The SDK headers live in vendor/DeckLinkSDK/include (not committed, see docs/sdk-setup.md). Without
// them this file builds a stub that reports "SDK not installed".

#import "DeckLinkOutputBridge.h"

static NSString *const kDLErrorDomain = @"DeckLinkOutputBridge";

static NSError *DLMakeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kDLErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

@interface DLDeviceInfo ()
@property (nonatomic, readwrite) NSInteger index;
@property (nonatomic, copy, readwrite) NSString *displayName;
@property (nonatomic, copy, readwrite) NSString *modelName;
@property (nonatomic, readwrite) BOOL canOutput;
@property (nonatomic, readwrite) BOOL supports1080p5994;
@end
@implementation DLDeviceInfo
@end

@interface DLOutputCounters ()
@property (nonatomic, readwrite) uint64_t scheduled;
@property (nonatomic, readwrite) uint64_t completed;
@property (nonatomic, readwrite) uint64_t displayedLate;
@property (nonatomic, readwrite) uint64_t dropped;
@property (nonatomic, readwrite) uint64_t flushed;
@property (nonatomic, readwrite) uint32_t buffered;
@end
@implementation DLOutputCounters
@end

#if __has_include("DeckLinkAPI.h")

#include <atomic>
#include <mutex>
#include <unordered_map>
#import "DeckLinkAPI.h"

static NSString *StringFromCF(CFStringRef s) {
    if (!s) return @"";
    return (__bridge_transfer NSString *)s;
}

/// The Nth device the driver lists, or null. The caller releases it.
static IDeckLink *DeviceAtIndex(NSInteger index) {
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) return nullptr;
    IDeckLink *found = nullptr;
    IDeckLink *device = nullptr;
    NSInteger i = 0;
    while (iterator->Next(&device) == S_OK) {
        if (i == index) {
            found = device;
            break;
        }
        device->Release();
        i++;
    }
    iterator->Release();
    return found;
}

@class DeckLinkOutputBridge;

@interface DeckLinkOutputBridge ()
- (void)frameCompleted:(IDeckLinkVideoFrame *)frame result:(BMDOutputFrameCompletionResult)result;
@end

/// Receives frame-completion events from the card.
class OutputCallback : public IDeckLinkVideoOutputCallback {
public:
    explicit OutputCallback(DeckLinkOutputBridge *owner) : mOwner(owner), mRefCount(1) {}

    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        CFUUIDBytes iunknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (memcmp(&iid, &iunknown, sizeof(REFIID)) == 0 ||
            memcmp(&iid, &IID_IDeckLinkVideoOutputCallback, sizeof(REFIID)) == 0) {
            *ppv = static_cast<IDeckLinkVideoOutputCallback *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++mRefCount; }
    ULONG Release() override {
        ULONG n = --mRefCount;
        if (n == 0) delete this;
        return n;
    }

    HRESULT ScheduledFrameCompleted(IDeckLinkVideoFrame *frame, BMDOutputFrameCompletionResult result) override {
        [mOwner frameCompleted:frame result:result];
        return S_OK;
    }
    HRESULT ScheduledPlaybackHasStopped() override { return S_OK; }

private:
    ~OutputCallback() {}
    __unsafe_unretained DeckLinkOutputBridge *mOwner;
    std::atomic<ULONG> mRefCount;
};

@interface DeckLinkOutputBridge () {
    IDeckLink *_deckLink;
    IDeckLinkOutput *_output;
    IDeckLinkMacOutput *_macOutput;
    OutputCallback *_callback;

    BMDTimeValue _frameDuration;
    BMDTimeScale _timeScale;
    NSInteger _depth;
    dispatch_semaphore_t _roomSignal;

    std::mutex _submitLock;       // serialises submitFrame and the playback start
    int64_t _nextFrame;
    bool _playing;
    std::atomic<bool> _started;

    std::mutex _liveLock;         // guards _live
    std::unordered_map<void *, CVPixelBufferRef> _live; // scheduled frame -> pixel buffer kept alive

    std::atomic<uint64_t> _scheduled, _completed, _late, _dropped, _flushed;
}
@end

@implementation DeckLinkOutputBridge

+ (NSArray<DLDeviceInfo *> *)listDevices {
    NSMutableArray<DLDeviceInfo *> *result = [NSMutableArray array];
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) return result;

    IDeckLink *device = nullptr;
    NSInteger i = 0;
    while (iterator->Next(&device) == S_OK) {
        DLDeviceInfo *info = [[DLDeviceInfo alloc] init];
        info.index = i;

        CFStringRef name = nullptr;
        info.displayName = (device->GetDisplayName(&name) == S_OK) ? StringFromCF(name) : @"";
        name = nullptr;
        info.modelName = (device->GetModelName(&name) == S_OK) ? StringFromCF(name) : @"";

        IDeckLinkOutput *output = nullptr;
        if (device->QueryInterface(IID_IDeckLinkOutput, (void **)&output) == S_OK && output) {
            info.canOutput = YES;
            BMDDisplayMode actual = bmdModeUnknown;
            bool supported = false;
            if (output->DoesSupportVideoMode(bmdVideoConnectionUnspecified, bmdModeHD1080p5994,
                                             bmdFormat8BitBGRA, bmdNoVideoOutputConversion,
                                             bmdSupportedVideoModeDefault, &actual, &supported) == S_OK) {
                info.supports1080p5994 = supported;
            }
            output->Release();
        }
        [result addObject:info];
        device->Release();
        i++;
    }
    iterator->Release();
    return result;
}

- (nullable instancetype)initWithDeviceIndex:(NSInteger)index
                                       depth:(NSInteger)depth
                                       error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    _depth = MAX((NSInteger)2, depth);
    _roomSignal = dispatch_semaphore_create(0);
    _started = false;
    _playing = false;
    _nextFrame = 0;
    _scheduled = _completed = _late = _dropped = _flushed = 0;

    _deckLink = DeviceAtIndex(index);
    if (!_deckLink) {
        if (error) *error = DLMakeError(1, [NSString stringWithFormat:
            @"No DeckLink device at index %ld. Is Blackmagic Desktop Video installed? Try --list-decklink.", (long)index]);
        return nil;
    }

    CFStringRef name = nullptr;
    _deviceName = (_deckLink->GetDisplayName(&name) == S_OK) ? StringFromCF(name) : @"DeckLink";

    if (_deckLink->QueryInterface(IID_IDeckLinkOutput, (void **)&_output) != S_OK || !_output) {
        if (error) *error = DLMakeError(2, [NSString stringWithFormat:@"%@ has no video output.", _deviceName]);
        return nil;
    }
    if (_output->QueryInterface(IID_IDeckLinkMacOutput, (void **)&_macOutput) != S_OK || !_macOutput) {
        if (error) *error = DLMakeError(3, @"This driver does not offer the macOS CVPixelBuffer interface.");
        return nil;
    }

    BMDDisplayMode actual = bmdModeUnknown;
    bool supported = false;
    HRESULT hr = _output->DoesSupportVideoMode(bmdVideoConnectionUnspecified, bmdModeHD1080p5994,
                                               bmdFormat8BitBGRA, bmdNoVideoOutputConversion,
                                               bmdSupportedVideoModeDefault, &actual, &supported);
    if (hr != S_OK || !supported) {
        if (error) *error = DLMakeError(4, [NSString stringWithFormat:
            @"%@ does not support 1080p59.94 BGRA output.", _deviceName]);
        return nil;
    }

    IDeckLinkDisplayMode *mode = nullptr;
    if (_output->GetDisplayMode(bmdModeHD1080p5994, &mode) != S_OK || !mode) {
        if (error) *error = DLMakeError(5, @"Could not read the 1080p59.94 display mode.");
        return nil;
    }
    mode->GetFrameRate(&_frameDuration, &_timeScale);
    mode->Release();
    _frameRate = (double)_timeScale / (double)_frameDuration;
    return self;
}

- (BOOL)startOutputAndReturnError:(NSError **)error {
    if (_started) return YES;
    if (_output->EnableVideoOutput(bmdModeHD1080p5994, bmdVideoOutputFlagDefault) != S_OK) {
        if (error) *error = DLMakeError(10, [NSString stringWithFormat:
            @"EnableVideoOutput failed on %@. Is another application using this connector?", _deviceName]);
        return NO;
    }
    _callback = new OutputCallback(self);
    _output->SetScheduledFrameCompletionCallback(_callback);
    _nextFrame = 0;
    _playing = false;
    _started = true;
    return YES;
}

- (BOOL)submitFrame:(CVPixelBufferRef)pixelBuffer {
    if (!_started) return NO;
    std::lock_guard<std::mutex> guard(_submitLock);

    IDeckLinkMutableVideoFrame *frame = nullptr;
    if (_macOutput->CreateVideoFrameFromCVPixelBufferRef((void *)pixelBuffer, &frame) != S_OK || !frame) {
        return NO;
    }
    CFRetain(pixelBuffer);
    {
        std::lock_guard<std::mutex> live(_liveLock);
        _live[(void *)frame] = pixelBuffer;
    }

    HRESULT hr = _output->ScheduleVideoFrame(frame, _nextFrame * _frameDuration, _frameDuration, _timeScale);
    if (hr != S_OK) {
        {
            std::lock_guard<std::mutex> live(_liveLock);
            _live.erase((void *)frame);
        }
        CFRelease(pixelBuffer);
        frame->Release();
        return NO;
    }
    frame->Release(); // the card holds its own reference until the frame completes
    _nextFrame++;
    _scheduled++;

    if (!_playing && _nextFrame >= _depth) {
        if (_output->StartScheduledPlayback(0, _timeScale, 1.0) == S_OK) _playing = true;
    }
    return YES;
}

- (BOOL)waitForRoomWithTimeout:(NSInteger)milliseconds {
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)milliseconds * NSEC_PER_MSEC);
    for (;;) {
        if (!_started) return NO;
        uint32_t buffered = 0;
        if (_output->GetBufferedVideoFrameCount(&buffered) == S_OK && buffered < (uint32_t)_depth) return YES;
        if (dispatch_semaphore_wait(_roomSignal, deadline) != 0) return NO; // timed out
    }
}

- (void)frameCompleted:(IDeckLinkVideoFrame *)frame result:(BMDOutputFrameCompletionResult)result {
    switch (result) {
        case bmdOutputFrameCompleted: _completed++; break;
        case bmdOutputFrameDisplayedLate: _late++; break;
        case bmdOutputFrameDropped: _dropped++; break;
        case bmdOutputFrameFlushed: _flushed++; break;
        default: break;
    }
    CVPixelBufferRef held = nullptr;
    {
        std::lock_guard<std::mutex> live(_liveLock);
        auto it = _live.find((void *)frame);
        if (it != _live.end()) {
            held = it->second;
            _live.erase(it);
        }
    }
    if (held) CFRelease(held);
    dispatch_semaphore_signal(_roomSignal);
}

- (void)stop {
    if (!_started.exchange(false)) return;
    if (_playing) {
        BMDTimeValue actualStop = 0;
        _output->StopScheduledPlayback(0, &actualStop, _timeScale);
        _playing = false;
    }
    _output->SetScheduledFrameCompletionCallback(nullptr);
    _output->DisableVideoOutput();
    if (_callback) {
        _callback->Release();
        _callback = nullptr;
    }
    {
        std::lock_guard<std::mutex> live(_liveLock);
        for (auto &entry : _live) CFRelease(entry.second);
        _live.clear();
    }
    dispatch_semaphore_signal(_roomSignal); // wake anyone waiting for room
}

- (DLOutputCounters *)counters {
    DLOutputCounters *c = [[DLOutputCounters alloc] init];
    c.scheduled = _scheduled;
    c.completed = _completed;
    c.displayedLate = _late;
    c.dropped = _dropped;
    c.flushed = _flushed;
    uint32_t buffered = 0;
    if (_output && _started) _output->GetBufferedVideoFrameCount(&buffered);
    c.buffered = buffered;
    return c;
}

- (void)dealloc {
    [self stop];
    if (_macOutput) _macOutput->Release();
    if (_output) _output->Release();
    if (_deckLink) _deckLink->Release();
}

@end

#else // SDK headers not present: stub that explains what is missing

@implementation DeckLinkOutputBridge

+ (NSArray<DLDeviceInfo *> *)listDevices {
    return @[];
}

- (nullable instancetype)initWithDeviceIndex:(NSInteger)index
                                       depth:(NSInteger)depth
                                       error:(NSError **)error {
    if (error) *error = DLMakeError(100, @"Built without the DeckLink SDK. See docs/sdk-setup.md.");
    return nil;
}

- (BOOL)startOutputAndReturnError:(NSError **)error { return NO; }
- (BOOL)submitFrame:(CVPixelBufferRef)pixelBuffer { return NO; }
- (BOOL)waitForRoomWithTimeout:(NSInteger)milliseconds { return NO; }
- (void)stop {}
- (DLOutputCounters *)counters { return [[DLOutputCounters alloc] init]; }

@end

#endif
