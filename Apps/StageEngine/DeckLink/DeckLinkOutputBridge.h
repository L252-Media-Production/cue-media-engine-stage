// Objective-C interface to the Blackmagic DeckLink API (SDK 16.0).
// The implementation is Objective-C++ in DeckLinkOutputBridge.mm. This header is plain Objective-C
// so Swift can import it through the bridging header.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// One DeckLink device as the driver lists it. On a Duo 2 each SDI connector is its own device.
@interface DLDeviceInfo : NSObject
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, copy, readonly) NSString *displayName;
@property (nonatomic, copy, readonly) NSString *modelName;
/// The device can currently be used for video output.
@property (nonatomic, readonly) BOOL canOutput;
/// The device can currently be used for video capture (its connector is set to input).
@property (nonatomic, readonly) BOOL canInput;
/// The device accepts 1080p59.94 output with 8-bit YUV frames.
@property (nonatomic, readonly) BOOL supports1080p5994;
/// What the hardware can do on this connector: "capture", "playback", both, or "unknown".
@property (nonatomic, copy, readonly) NSString *ioSupport;
/// Result code from asking the device for its output interface (0 = success).
@property (nonatomic, readonly) int32_t outputQueryResult;
/// Sub-device index reported by the driver, or -1.
@property (nonatomic, readonly) NSInteger subDeviceIndex;
@end

/// Counters from the card's scheduled playback.
@interface DLOutputCounters : NSObject
@property (nonatomic, readonly) uint64_t scheduled;
@property (nonatomic, readonly) uint64_t completed;
@property (nonatomic, readonly) uint64_t displayedLate;
@property (nonatomic, readonly) uint64_t dropped;
@property (nonatomic, readonly) uint64_t flushed;
/// Frames currently queued on the card.
@property (nonatomic, readonly) uint32_t buffered;
/// Lowest queue level seen since the last reset (UINT32_MAX if never sampled). The closer to 0, the
/// closer the output came to running dry.
@property (nonatomic, readonly) uint32_t minBuffered;
@end

/// Scheduled 1080p59.94 video output on one DeckLink connector.
///
/// Frames are scheduled ahead of time on the card's own clock. `depth` frames are queued before
/// playback starts, and `waitForRoomWithTimeout:` blocks until the card has consumed one, which
/// is how the render loop gets paced by the hardware.
@interface DeckLinkOutputBridge : NSObject

+ (NSArray<DLDeviceInfo *> *)listDevices;

- (nullable instancetype)initWithDeviceIndex:(NSInteger)index
                                       depth:(NSInteger)depth
                                       error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) double frameRate;
@property (nonatomic, copy, readonly) NSString *deviceName;

- (BOOL)startOutputAndReturnError:(NSError * _Nullable * _Nullable)error;

/// Schedule one frame at the next display time. The buffer holds packed 8-bit 4:2:2 YUV ("2vuy") in
/// a BGRA buffer half the frame width (see `OutputPixelFormat.yuv8`). Playback starts once `depth` frames are queued.
/// Returns NO if the frame could not be scheduled.
- (BOOL)submitFrame:(CVPixelBufferRef)pixelBuffer;

/// Block until fewer than `depth` frames are queued, or the timeout passes. NO on timeout or stop.
- (BOOL)waitForRoomWithTimeout:(NSInteger)milliseconds;

- (void)stop;

- (DLOutputCounters *)counters;

/// Zero the counters and the low-water mark (call after warm-up).
- (void)resetStatistics;

@end

NS_ASSUME_NONNULL_END
