#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface LMDeckLinkDeviceInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL supportsOutput;
@property (nonatomic) BOOL supportsInput;
@property (nonatomic) BOOL supportsInternalKeying;
@property (nonatomic) BOOL supportsExternalKeying;
@end

/// Thin Objective-C++ wrapper over the Blackmagic DeckLink SDK (playback side).
/// Inputs (e.g. an Apple TV on a DeckLink HDMI/SDI input) appear as AVFoundation capture
/// devices when Blackmagic Desktop Video is installed, so they go through CaptureManager.
@interface LMDeckLinkOutput : NSObject

/// YES when the app was built with the DeckLink SDK headers in Vendor/DeckLinkSDK.
+ (BOOL)sdkCompiledIn;
/// YES when the Desktop Video driver (DeckLinkAPI.framework) is installed and loadable.
+ (BOOL)driverAvailable;
+ (NSArray<LMDeckLinkDeviceInfo *> *)devices;

- (nullable instancetype)initWithDeviceName:(NSString *)name;
/// mode is one of Lumen's VideoMode raw values (e.g. "hd1080p2997").
- (BOOL)startWithMode:(NSString *)mode keying:(BOOL)keying error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(start(withMode:keying:));
/// Copies a BGRA pixel buffer into a DeckLink frame and displays it.
- (void)displayPixelBuffer:(CVPixelBufferRef)buffer NS_SWIFT_NAME(displayPixelBuffer(_:));
- (void)stop;

@end

NS_ASSUME_NONNULL_END
