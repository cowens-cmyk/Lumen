#import "LMDeckLink.h"

#if __has_include("DeckLinkAPI.h")
#define LM_HAS_DECKLINK 1
#include "DeckLinkAPI.h"
#include "DeckLinkAPIVersion.h"
// The SDK's dispatch file loads DeckLinkAPI.framework at runtime.
#include "DeckLinkAPIDispatch.cpp"
#else
#define LM_HAS_DECKLINK 0
#endif

@implementation LMDeckLinkDeviceInfo
@end

static NSError *LMError(NSString *msg) {
    return [NSError errorWithDomain:@"Lumen.DeckLink" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

#if LM_HAS_DECKLINK

static BMDDisplayMode LMModeFromString(NSString *s) {
    NSDictionary<NSString *, NSNumber *> *map = @{
        @"hd1080p2997": @(bmdModeHD1080p2997),
        @"hd1080p30": @(bmdModeHD1080p30),
        @"hd1080p5994": @(bmdModeHD1080p5994),
        @"hd1080p60": @(bmdModeHD1080p6000),
        @"hd1080i5994": @(bmdModeHD1080i5994),
        @"hd1080p25": @(bmdModeHD1080p25),
        @"hd1080i50": @(bmdModeHD1080i50),
        @"hd720p5994": @(bmdModeHD720p5994),
        @"uhd2160p2997": @(bmdMode4K2160p2997),
        @"uhd2160p5994": @(bmdMode4K2160p5994),
    };
    NSNumber *n = map[s];
    return n ? (BMDDisplayMode)n.unsignedIntValue : bmdModeHD1080p2997;
}

static NSString *LMDeviceName(IDeckLink *dl) {
    CFStringRef name = NULL;
    if (dl->GetDisplayName(&name) == S_OK && name) {
        return (__bridge_transfer NSString *)name;
    }
    return @"DeckLink";
}

static IDeckLink *LMFindDevice(NSString *wanted) {
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
    if (!it) return NULL;
    IDeckLink *dl = NULL, *found = NULL;
    while (it->Next(&dl) == S_OK) {
        if (!found && [LMDeviceName(dl) isEqualToString:wanted]) {
            found = dl;
        } else {
            dl->Release();
        }
    }
    it->Release();
    return found;
}

#endif

@implementation LMDeckLinkOutput {
#if LM_HAS_DECKLINK
    IDeckLink *_device;
    IDeckLinkOutput *_output;
    IDeckLinkKeyer *_keyer;
    IDeckLinkMutableVideoFrame *_frame;
    long _width, _height;
#endif
    NSLock *_lock;
}

+ (BOOL)sdkCompiledIn { return LM_HAS_DECKLINK; }

+ (BOOL)driverAvailable {
#if LM_HAS_DECKLINK
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
    if (!it) return NO;
    it->Release();
    return YES;
#else
    return [[NSFileManager defaultManager] fileExistsAtPath:@"/Library/Frameworks/DeckLinkAPI.framework"];
#endif
}

+ (NSArray<LMDeckLinkDeviceInfo *> *)devices {
    NSMutableArray *out = [NSMutableArray array];
#if LM_HAS_DECKLINK
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
    if (!it) return out;
    IDeckLink *dl = NULL;
    while (it->Next(&dl) == S_OK) {
        LMDeckLinkDeviceInfo *info = [LMDeckLinkDeviceInfo new];
        info.name = LMDeviceName(dl);
        IDeckLinkProfileAttributes *attr = NULL;
        if (dl->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attr) == S_OK) {
            bool flag = false;
            if (attr->GetFlag(BMDDeckLinkSupportsInternalKeying, &flag) == S_OK) info.supportsInternalKeying = flag;
            flag = false;
            if (attr->GetFlag(BMDDeckLinkSupportsExternalKeying, &flag) == S_OK) info.supportsExternalKeying = flag;
            int64_t io = 0;
            if (attr->GetInt(BMDDeckLinkVideoIOSupport, &io) == S_OK) {
                info.supportsOutput = (io & bmdDeviceSupportsPlayback) != 0;
                info.supportsInput = (io & bmdDeviceSupportsCapture) != 0;
            }
            attr->Release();
        }
        [out addObject:info];
        dl->Release();
    }
    it->Release();
#endif
    return out;
}

- (instancetype)initWithDeviceName:(NSString *)name {
    self = [super init];
    if (!self) return nil;
    _lock = [NSLock new];
#if LM_HAS_DECKLINK
    _device = LMFindDevice(name);
    if (!_device) return nil;
    if (_device->QueryInterface(IID_IDeckLinkOutput, (void **)&_output) != S_OK) {
        _device->Release();
        return nil;
    }
    return self;
#else
    return nil;
#endif
}

- (BOOL)startWithMode:(NSString *)mode keying:(BOOL)keying error:(NSError **)error {
#if LM_HAS_DECKLINK
    BMDDisplayMode m = LMModeFromString(mode);
    IDeckLinkDisplayMode *dm = NULL;
    BMDDisplayMode actual = 0;
    bool supported = false;
    if (_output->DoesSupportVideoMode(bmdVideoConnectionUnspecified, m, bmdFormat8BitBGRA, bmdNoVideoOutputConversion,
                                      bmdSupportedVideoModeDefault, &actual, &supported) != S_OK || !supported) {
        if (error) *error = LMError(@"This DeckLink output doesn't support that video mode in BGRA.");
        return NO;
    }
    if (_output->GetDisplayMode(m, &dm) == S_OK && dm) {
        _width = dm->GetWidth();
        _height = dm->GetHeight();
        dm->Release();
    } else {
        _width = 1920; _height = 1080;
    }
    if (_output->EnableVideoOutput(m, bmdVideoOutputFlagDefault) != S_OK) {
        if (error) *error = LMError(@"Couldn't enable video output (is another app using this DeckLink?).");
        return NO;
    }
    if (keying && _device->QueryInterface(IID_IDeckLinkKeyer, (void **)&_keyer) == S_OK) {
        // External keying: fill on this connector, key (alpha) on its paired connector — for ATEM/TriCaster DSKs.
        if (_keyer->Enable(true) == S_OK) {
            _keyer->SetLevel(255);
        } else if (_keyer->Enable(false) == S_OK) {
            _keyer->SetLevel(255);
        }
    }
    if (_output->CreateVideoFrame((int32_t)_width, (int32_t)_height, (int32_t)(_width * 4), bmdFormat8BitBGRA,
                                  bmdFrameFlagDefault, &_frame) != S_OK) {
        if (error) *error = LMError(@"Couldn't allocate a DeckLink frame.");
        return NO;
    }
    return YES;
#else
    if (error) *error = LMError(@"Lumen was built without the DeckLink SDK. See README → DeckLink.");
    return NO;
#endif
}

- (void)displayPixelBuffer:(CVPixelBufferRef)buffer {
#if LM_HAS_DECKLINK
    [_lock lock];
    if (!_frame || !_output) { [_lock unlock]; return; }
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    size_t srcStride = CVPixelBufferGetBytesPerRow(buffer);
    size_t rows = MIN((size_t)_height, CVPixelBufferGetHeight(buffer));
    size_t rowBytes = MIN((size_t)_width * 4, CVPixelBufferGetWidth(buffer) * 4);
    void *dst = NULL;
#if defined(BLACKMAGIC_DECKLINK_API_VERSION) && BLACKMAGIC_DECKLINK_API_VERSION >= 0x0e030000
    IDeckLinkVideoBuffer *vb = NULL;
    if (_frame->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&vb) == S_OK) {
        vb->StartAccess(bmdBufferAccessWrite);
        vb->GetBytes(&dst);
    }
#else
    _frame->GetBytes(&dst);
#endif
    if (dst && src) {
        for (size_t y = 0; y < rows; y++) {
            memcpy((uint8_t *)dst + y * _width * 4, src + y * srcStride, rowBytes);
        }
    }
#if defined(BLACKMAGIC_DECKLINK_API_VERSION) && BLACKMAGIC_DECKLINK_API_VERSION >= 0x0e030000
    if (vb) { vb->EndAccess(bmdBufferAccessWrite); vb->Release(); }
#endif
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    _output->DisplayVideoFrameSync(_frame);
    [_lock unlock];
#endif
}

- (void)stop {
#if LM_HAS_DECKLINK
    [_lock lock];
    if (_keyer) { _keyer->Disable(); _keyer->Release(); _keyer = NULL; }
    if (_output) { _output->DisableVideoOutput(); }
    if (_frame) { _frame->Release(); _frame = NULL; }
    [_lock unlock];
#endif
}

- (void)dealloc {
    [self stop];
#if LM_HAS_DECKLINK
    if (_output) { _output->Release(); _output = NULL; }
    if (_device) { _device->Release(); _device = NULL; }
#endif
}

@end
