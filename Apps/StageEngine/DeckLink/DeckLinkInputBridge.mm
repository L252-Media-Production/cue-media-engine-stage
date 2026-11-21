// Objective-C++ wrapper around the Blackmagic DeckLink API for SDI capture on one connector.
//
// Like the output bridge it speaks the *_v14_2_1 interfaces, which Desktop Video 14.x to 16.x drivers
// understand (see docs/sdk-setup.md). Without the SDK headers it builds a stub.

#import "DeckLinkInputBridge.h"

static NSString *const kDLInErrorDomain = @"DeckLinkInputBridge";

static NSError *DLInError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kDLInErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

#if __has_include("DeckLinkAPI.h")

#include <atomic>
#include <deque>
#include <mutex>
#import "DeckLinkAPI.h"
#import "DeckLinkAPI_v14_2_1.h"

static const long kCaptureWidth = 1920;
static const long kCaptureHeight = 1080;
static const size_t kQueueLimit = 8;

static NSString *InStringFromCF(CFStringRef s) {
    if (!s) return @"";
    return (__bridge_transfer NSString *)s;
}

static bool InSameIID(REFIID a, REFIID b) {
    return memcmp(&a, &b, sizeof(REFIID)) == 0;
}

static IDeckLink *InDeviceAtIndex(NSInteger index) {
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance_v14_2_1();
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

@class DeckLinkInputBridge;

@interface DeckLinkInputBridge ()
- (void)videoFrameArrived:(IDeckLinkVideoInputFrame_v14_2_1 *)frame;
- (void)formatChanged:(BMDVideoInputFormatChangedEvents)events
                 mode:(IDeckLinkDisplayMode *)mode
                flags:(BMDDetectedVideoInputFormatFlags)flags;
@end

/// Receives frames and format-change events from the card.
class InputCallback : public IDeckLinkInputCallback_v14_2_1 {
public:
    explicit InputCallback(DeckLinkInputBridge *owner) : mOwner(owner), mRefCount(1) {}

    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        CFUUIDBytes iunknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (InSameIID(iid, iunknown) || InSameIID(iid, IID_IDeckLinkInputCallback_v14_2_1)) {
            *ppv = static_cast<IDeckLinkInputCallback_v14_2_1 *>(this);
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

    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents events, IDeckLinkDisplayMode *mode,
                                    BMDDetectedVideoInputFormatFlags flags) override {
        [mOwner formatChanged:events mode:mode flags:flags];
        return S_OK;
    }
    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame_v14_2_1 *video, IDeckLinkAudioInputPacket *) override {
        if (video) [mOwner videoFrameArrived:video];
        return S_OK;
    }

private:
    ~InputCallback() {}
    __unsafe_unretained DeckLinkInputBridge *mOwner;
    std::atomic<ULONG> mRefCount;
};

@interface DeckLinkInputBridge () {
    IDeckLink *_deckLink;
    IDeckLinkInput_v14_2_1 *_input;
    InputCallback *_callback;
    CVPixelBufferPoolRef _pool;

    std::atomic<bool> _running;
    std::mutex _frameLock;            // guards _queue
    std::deque<CVPixelBufferRef> _queue;

    std::atomic<uint64_t> _captured, _noSignal, _rejected, _formatChanges, _overflowed;
    std::atomic<bool> _signal, _unsupported;
    std::mutex _modeLock;
    NSString *_modeName;
}
@end

@implementation DeckLinkInputBridge

- (nullable instancetype)initWithDeviceIndex:(NSInteger)index error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    _running = false;
    _captured = _noSignal = _rejected = _formatChanges = _overflowed = 0;
    _signal = false;
    _unsupported = false;
    _modeName = @"1080p59.94 (initial mode, no change reported)";

    _deckLink = InDeviceAtIndex(index);
    if (!_deckLink) {
        if (error) *error = DLInError(1, [NSString stringWithFormat:
            @"No DeckLink device at index %ld. Try --list-decklink.", (long)index]);
        return nil;
    }
    CFStringRef name = nullptr;
    _deviceName = (_deckLink->GetDisplayName(&name) == S_OK) ? InStringFromCF(name) : @"DeckLink";

    HRESULT qhr = _deckLink->QueryInterface(IID_IDeckLinkInput_v14_2_1, (void **)&_input);
    if (qhr != S_OK || !_input) {
        if (error) *error = DLInError(2, [NSString stringWithFormat:
            @"%@ has no video input (result 0x%08X). In Desktop Video Setup, set this connector to Input.",
            _deviceName, (unsigned)qhr]);
        return nil;
    }

    // Packed 4:2:2 frames land in half-width BGRA buffers (2 pixels per 4-byte texel).
    NSDictionary *attributes = @{
        (id)kCVPixelBufferWidthKey : @(kCaptureWidth / 2),
        (id)kCVPixelBufferHeightKey : @(kCaptureHeight),
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    NSDictionary *poolAttributes = @{(id)kCVPixelBufferPoolMinimumBufferCountKey : @6};
    if (CVPixelBufferPoolCreate(nullptr, (__bridge CFDictionaryRef)poolAttributes,
                                (__bridge CFDictionaryRef)attributes, &_pool) != kCVReturnSuccess) {
        if (error) *error = DLInError(3, @"Could not create the capture buffer pool.");
        return nil;
    }
    return self;
}

- (BOOL)startAndReturnError:(NSError **)error {
    if (_running) return YES;
    _callback = new InputCallback(self);
    _input->SetCallback(_callback);
    HRESULT hr = _input->EnableVideoInput(bmdModeHD1080p5994, bmdFormat8BitYUV, bmdVideoInputEnableFormatDetection);
    if (hr != S_OK) {
        _input->SetCallback(nullptr);
        _callback->Release();
        _callback = nullptr;
        if (error) *error = DLInError(10, [NSString stringWithFormat:
            @"EnableVideoInput failed on %@ (result 0x%08X). Is the connector set to Input in Desktop Video Setup, and not in use by another application?",
            _deviceName, (unsigned)hr]);
        return NO;
    }
    hr = _input->StartStreams();
    if (hr != S_OK) {
        _input->DisableVideoInput();
        _input->SetCallback(nullptr);
        _callback->Release();
        _callback = nullptr;
        if (error) *error = DLInError(11, [NSString stringWithFormat:
            @"StartStreams failed on %@ (result 0x%08X).", _deviceName, (unsigned)hr]);
        return NO;
    }
    _running = true;
    return YES;
}

- (void)stop {
    if (!_running.exchange(false)) return;
    _input->StopStreams();
    _input->DisableVideoInput();
    _input->SetCallback(nullptr);
    if (_callback) {
        _callback->Release();
        _callback = nullptr;
    }
}

- (void)formatChanged:(BMDVideoInputFormatChangedEvents)events
                 mode:(IDeckLinkDisplayMode *)mode
                flags:(BMDDetectedVideoInputFormatFlags)flags {
    if (!mode || !(events & bmdVideoInputDisplayModeChanged)) return;
    _formatChanges++;

    CFStringRef cfName = nullptr;
    NSString *modeName = (mode->GetName(&cfName) == S_OK) ? InStringFromCF(cfName) : @"unknown";
    {
        std::lock_guard<std::mutex> guard(_modeLock);
        _modeName = modeName;
    }

    bool usable = (mode->GetWidth() == kCaptureWidth && mode->GetHeight() == kCaptureHeight);
    _unsupported = !usable;
    if (!usable) return;

    // Follow the new 1920x1080 mode (the official capture sample does the same here).
    _input->PauseStreams();
    _input->EnableVideoInput(mode->GetDisplayMode(), bmdFormat8BitYUV, bmdVideoInputEnableFormatDetection);
    _input->FlushStreams();
    _input->StartStreams();
}

- (void)videoFrameArrived:(IDeckLinkVideoInputFrame_v14_2_1 *)frame {
    if (frame->GetFlags() & bmdFrameHasNoInputSource) {
        _noSignal++;
        _signal = false;
        return;
    }
    _signal = true;

    if (frame->GetWidth() != kCaptureWidth || frame->GetHeight() != kCaptureHeight ||
        frame->GetPixelFormat() != bmdFormat8BitYUV) {
        _rejected++;
        return;
    }
    void *bytes = nullptr;
    if (frame->GetBytes(&bytes) != S_OK || !bytes) {
        _rejected++;
        return;
    }

    CVPixelBufferRef buffer = nullptr;
    if (CVPixelBufferPoolCreatePixelBuffer(nullptr, _pool, &buffer) != kCVReturnSuccess || !buffer) {
        _rejected++;
        return;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    size_t dstRow = CVPixelBufferGetBytesPerRow(buffer);
    const uint8_t *src = (const uint8_t *)bytes;
    size_t srcRow = (size_t)frame->GetRowBytes();
    size_t copyRow = MIN(srcRow, dstRow);
    for (long y = 0; y < kCaptureHeight; y++) {
        memcpy(dst + y * dstRow, src + y * srcRow, copyRow);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);

    CVPixelBufferRef overflow = nullptr;
    {
        std::lock_guard<std::mutex> guard(_frameLock);
        _queue.push_back(buffer);
        if (_queue.size() > kQueueLimit) {
            overflow = _queue.front();
            _queue.pop_front();
        }
    }
    if (overflow) {
        CVPixelBufferRelease(overflow);
        _overflowed++;
    }
    _captured++;
}

- (nullable CVPixelBufferRef)popFrame {
    std::lock_guard<std::mutex> guard(_frameLock);
    if (_queue.empty()) return nullptr;
    CVPixelBufferRef frame = _queue.front();   // the queue's reference passes to the caller
    _queue.pop_front();
    return frame;
}

- (BOOL)dropOldestFrame {
    CVPixelBufferRef frame = nullptr;
    {
        std::lock_guard<std::mutex> guard(_frameLock);
        if (_queue.empty()) return NO;
        frame = _queue.front();
        _queue.pop_front();
    }
    CVPixelBufferRelease(frame);
    return YES;
}

- (NSInteger)queuedFrames {
    std::lock_guard<std::mutex> guard(_frameLock);
    return (NSInteger)_queue.size();
}
- (uint64_t)framesOverflowed { return _overflowed; }
- (uint64_t)framesCaptured { return _captured; }
- (uint64_t)framesNoSignal { return _noSignal; }
- (uint64_t)framesRejected { return _rejected; }
- (uint64_t)formatChanges { return _formatChanges; }
- (BOOL)signalPresent { return _signal; }
- (BOOL)unsupportedSignal { return _unsupported; }
- (NSString *)detectedMode {
    std::lock_guard<std::mutex> guard(_modeLock);
    return _modeName;
}

- (void)dealloc {
    [self stop];
    for (CVPixelBufferRef frame : _queue) CVPixelBufferRelease(frame);
    _queue.clear();
    if (_pool) CVPixelBufferPoolRelease(_pool);
    if (_input) _input->Release();
    if (_deckLink) _deckLink->Release();
}

@end

#else // SDK headers not present: stub that explains what is missing

@implementation DeckLinkInputBridge

- (nullable instancetype)initWithDeviceIndex:(NSInteger)index error:(NSError **)error {
    if (error) *error = DLInError(100, @"Built without the DeckLink SDK. See docs/sdk-setup.md.");
    return nil;
}
- (BOOL)startAndReturnError:(NSError **)error { return NO; }
- (void)stop {}
- (nullable CVPixelBufferRef)popFrame { return nullptr; }
- (BOOL)dropOldestFrame { return NO; }
- (NSInteger)queuedFrames { return 0; }
- (uint64_t)framesOverflowed { return 0; }
- (uint64_t)framesCaptured { return 0; }
- (uint64_t)framesNoSignal { return 0; }
- (uint64_t)framesRejected { return 0; }
- (uint64_t)formatChanges { return 0; }
- (BOOL)signalPresent { return NO; }
- (BOOL)unsupportedSignal { return NO; }
- (NSString *)detectedMode { return @""; }

@end

#endif
