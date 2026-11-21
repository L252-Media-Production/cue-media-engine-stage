// Objective-C interface for capturing SDI video from one DeckLink connector.
// The implementation is Objective-C++ in DeckLinkInputBridge.mm; this header is plain Objective-C
// so Swift can import it through the bridging header.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Captures 1080p video (8-bit 4:2:2 YUV) from one connector. The connector must be set to Input in
/// Desktop Video Setup. The card detects the incoming format; a 1920x1080 signal in another frame rate
/// is followed, anything else is reported as unsupported.
///
/// Frames come back packed exactly as the card delivers them ("2vuy": Cb Y0 Cr Y1), stored in a BGRA
/// pixel buffer half the frame width (960x1080), which is the layout `YUV422Unpacker` expects.
@interface DeckLinkInputBridge : NSObject

- (nullable instancetype)initWithDeviceIndex:(NSInteger)index
                                       error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, copy, readonly) NSString *deviceName;

- (BOOL)startAndReturnError:(NSError * _Nullable * _Nullable)error;
- (void)stop;

/// Captured frames wait in a short queue (oldest first). `popFrame` removes and returns the oldest,
/// or nil if the queue is empty. The caller owns the returned reference.
- (nullable CVPixelBufferRef)popFrame CF_RETURNS_RETAINED;
/// Remove and release the oldest frame. Returns NO if the queue was empty.
- (BOOL)dropOldestFrame;
/// When the card delivered the frame that `popFrame` last returned (nanoseconds, same clock as
/// `DispatchTime.now().uptimeNanoseconds`).
@property (nonatomic, readonly) uint64_t lastPopArrivalNanos;
/// Frames currently waiting in the queue.
@property (nonatomic, readonly) NSInteger queuedFrames;
/// Frames discarded because the queue was full (nobody was taking them).
@property (nonatomic, readonly) uint64_t framesOverflowed;
/// Frames the card delivered with a valid signal.
@property (nonatomic, readonly) uint64_t framesCaptured;
/// Frames the card delivered flagged "no input source".
@property (nonatomic, readonly) uint64_t framesNoSignal;
/// Frames that arrived in a format we cannot use, or that we could not copy (no buffer available).
@property (nonatomic, readonly) uint64_t framesRejected;
/// Times the card reported a new input format (the first detection counts).
@property (nonatomic, readonly) uint64_t formatChanges;
/// A signal is currently present on the connector.
@property (nonatomic, readonly) BOOL signalPresent;
/// The signal is a format this build cannot use (not 1920x1080).
@property (nonatomic, readonly) BOOL unsupportedSignal;
/// The input format the card reports, for example "HD 1080p 59.94" (empty until detected).
@property (nonatomic, copy, readonly) NSString *detectedMode;

@end

NS_ASSUME_NONNULL_END
