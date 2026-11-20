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
/// The device accepts 1080p59.94 output with BGRA frames.
@property (nonatomic, readonly) BOOL supports1080p5994;
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

/// Schedule one BGRA frame at the next display time. Playback starts once `depth` frames are queued.
/// Returns NO if the frame could not be scheduled.
- (BOOL)submitFrame:(CVPixelBufferRef)pixelBuffer;

/// Block until fewer than `depth` frames are queued, or the timeout passes. NO on timeout or stop.
- (BOOL)waitForRoomWithTimeout:(NSInteger)milliseconds;

- (void)stop;

- (DLOutputCounters *)counters;

@end

NS_ASSUME_NONNULL_END
