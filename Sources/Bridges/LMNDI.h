#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// NDI® support. Compiles against the NDI SDK headers and loads libndi at runtime,
/// so the app still launches on Macs without NDI Tools installed.
@interface LMNDI : NSObject
+ (BOOL)sdkCompiledIn;
/// Loads libndi (NDI Tools / NDI SDK runtime). Safe to call repeatedly.
+ (BOOL)runtimeAvailable;
+ (NSArray<NSString *> *)findSourcesWaiting:(int)milliseconds NS_SWIFT_NAME(findSources(waiting:));
@end

@interface LMNDISender : NSObject
- (nullable instancetype)initWithName:(NSString *)name;
/// Sends a BGRA frame (alpha is preserved, so keyed graphics work in vMix/OBS/TriCaster).
- (void)sendPixelBuffer:(CVPixelBufferRef)buffer frameRate:(double)fps NS_SWIFT_NAME(send(_:frameRate:));
- (void)stop;
@end

@interface LMNDIReceiver : NSObject
- (nullable instancetype)initWithSource:(NSString *)name handler:(void (^)(CVPixelBufferRef frame))handler;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
