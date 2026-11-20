// Objective-C interface to NDI (SDK 6.x). The implementation is Objective-C++ in NDIBridge.mm and
// loads libndi.dylib at run time, so nothing links against the NDI library at build time.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// One NDI source found on the network, as "MACHINE (SOURCE NAME)".
@interface NDISourceInfo : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *address;
@end

@interface NDIRuntime : NSObject
/// Load libndi and initialise NDI. Safe to call repeatedly. (Named "prepare" because Swift reserves "load".)
+ (BOOL)prepareAndReturnError:(NSError * _Nullable * _Nullable)error;
/// Look for sources for up to `seconds`, returning as soon as the list has been stable briefly.
+ (NSArray<NDISourceInfo *> *)findSourcesWaiting:(NSTimeInterval)seconds;
@end

/// Sends packed 8-bit 4:2:2 (UYVY) frames. The input is the same half-width BGRA-typed buffer the
/// compositor produces for SDI (`OutputPixelFormat.yuv8`), so it is sent without conversion.
@interface NDISenderBridge : NSObject
- (nullable instancetype)initWithName:(NSString *)name
                           clockVideo:(BOOL)clockVideo
                                error:(NSError * _Nullable * _Nullable)error;
/// Queue one frame (asynchronous). With clockVideo the call is rate-limited to 59.94 fps.
- (BOOL)sendPackedYUV:(CVPixelBufferRef)pixelBuffer;
@property (nonatomic, readonly) uint64_t framesSent;
- (int)connectionCount;
- (void)resetStatistics;
- (void)stop;
@end

/// Receives one NDI source and keeps its newest frame as a BGRA pixel buffer.
@interface NDIReceiverBridge : NSObject
/// Finds the first source whose name contains `text` (case-insensitive), waiting up to `seconds`.
- (nullable instancetype)initWithSourceNameContaining:(NSString *)text
                                          waitSeconds:(NSTimeInterval)seconds
                                                error:(NSError * _Nullable * _Nullable)error;
@property (nonatomic, copy, readonly) NSString *sourceName;
@property (nonatomic, readonly) uint64_t framesReceived;
@property (nonatomic, readonly) int width;
@property (nonatomic, readonly) int height;
- (void)start;
- (void)stop;
/// The newest frame, or nil if none has arrived yet. The caller owns the returned reference.
- (nullable CVPixelBufferRef)copyLatestFrame CF_RETURNS_RETAINED;
@end

NS_ASSUME_NONNULL_END
