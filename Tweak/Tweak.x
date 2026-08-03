#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <sys/syslog.h>
#import <ImageIO/ImageIO.h>
#import "DIDisplayManager.h"
#import "DILocalization.h"

// C 层日志：不依赖 Foundation，dyld 阶段也可用
#define DIRawLog(fmt, ...) syslog(LOG_NOTICE, "[DynamicIslandTweak] " fmt, ##__VA_ARGS__)

// 统一日志宏：syslog + NSLog，无文件写入（避免每条日志开关句柄的 IO 开销，且 /tmp 路径不符合 roothide 规范）
// 注意：fmt 必须是 NSString 字面量（@"..."），用 %s + UTF8String 避免 "C串" @"NSString" 非法拼接
#define DILog(fmt, ...) do { \
    NSString *_diMsg = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; \
    syslog(LOG_NOTICE, "[DynamicIslandTweak] %s", [_diMsg UTF8String]); \
    NSLog(@"[Tweak] %@", _diMsg); \
} while(0)

// 详细日志：仅在 _diVerbose 开启时输出，包住高频 / 调试日志（fetch、符号打印、syncTick）
#define DIVLog(fmt, ...) do { if (_diVerbose) { DILog(fmt, ##__VA_ARGS__); } } while(0)

typedef void (^MRMediaRemoteGetNowPlayingInfoCompletion)(CFDictionaryRef info);
typedef void (^MRMediaRemoteGetNowPlayingClientCompletion)(id client);
typedef void (*MRMediaRemoteRegisterForNowPlayingNotifications_t)(dispatch_queue_t queue);
typedef void (*MRMediaRemoteGetNowPlayingInfo_t)(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingInfoCompletion completion);
// 激进路径：主动请求指定尺寸封面（默认关，受 useOptionalArtwork 控制，签名中等把握，@try 包裹）
typedef void (*MRMediaRemoteGetNowPlayingInfoWithOptionalArtwork_t)(int width, int height, dispatch_queue_t queue, MRMediaRemoteGetNowPlayingInfoCompletion completion);
typedef void (*MRMediaRemoteGetNowPlayingClient_t)(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingClientCompletion completion);
typedef NSString *(*MRNowPlayingClientGetBundleIdentifier_t)(id client);
typedef NSString *(*MRNowPlayingClientGetParentAppBundleIdentifier_t)(id client);

static void syncTick(void);
static void fetchNowPlayingInfo(void);
static void initializeTweakAfterLaunch(void);
static BOOL tweakEnabledFromPrefs(void);
static BOOL notificationEnabledFromPrefs(void);
static void scheduleTweakInitialization(void);
static void registerPrefsObserverIfNeeded(void);
static void initializeNotificationHooksIfNeeded(void);
static void startAfterInjection(void);

static void *_mrHandle = NULL;
static MRMediaRemoteRegisterForNowPlayingNotifications_t _MRRegister = NULL;
static MRMediaRemoteGetNowPlayingInfo_t _MRGetNowPlaying = NULL;
static MRMediaRemoteGetNowPlayingInfoWithOptionalArtwork_t _MRGetNowPlayingWithOptionalArtwork = NULL;
static MRMediaRemoteGetNowPlayingClient_t _MRGetNowPlayingClient = NULL;
static MRNowPlayingClientGetBundleIdentifier_t _MRClientGetBundleID = NULL;
static MRNowPlayingClientGetParentAppBundleIdentifier_t _MRClientGetParentBundleID = NULL;
static NSString *_kInfoTitle = nil;
static NSString *_kInfoArtist = nil;
static NSString *_kInfoPlaybackRate = nil;
static NSString *_kInfoArtworkData = nil;
static NSString *_kInfoArtworkURL = nil;
static NSString *_kInfoBundleID = nil;
static NSString *_kPlayingDidChange = nil;
static NSString *_kInfoDidChange = nil;
static NSString *_kInfoElapsedTime = nil;
static NSString *_kInfoDuration = nil;
static NSTimer *_syncTimer = nil;
static BOOL _didInitializeTweak = NO;
static BOOL _didScheduleTweakInitialization = NO;
static BOOL _didRegisterPrefsObserver = NO;
static BOOL _didInitializeNotificationHooks = NO;

// 日志开关：DEBUG 默认开，Release 默认关，由 prefs verboseLog 覆盖
#ifdef DEBUG
static BOOL _diVerbose = YES;
#else
static BOOL _diVerbose = NO;
#endif
// 激进封面路径开关（prefs useOptionalArtwork，默认 NO）
static BOOL _useOptionalArtwork = NO;
// 切歌一致性校验：曲目变化时 +1，异步封面回来比对，不一致丢弃避免旧图覆盖新曲
static int _artworkGeneration = 0;
// 封面失败重试计数（曲目变化时重置，最多 2 次）
static int _artworkRetryCount = 0;
// 上一次曲目标识（title\artist），用于检测切歌
static NSString *_lastTrackKey = nil;

static NSString *safeString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL tweakEnabledFromPrefs(void) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.dynamicisland.tweak"];
    id value = [prefs objectForKey:@"islandEnabled"];
    return value ? [prefs boolForKey:@"islandEnabled"] : NO;
}

static BOOL notificationEnabledFromPrefs(void) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.dynamicisland.tweak"];
    id value = [prefs objectForKey:@"notificationEnabled"];
    return value ? [prefs boolForKey:@"notificationEnabled"] : NO;
}

// 读取 tweak 层开关（日志详细度、激进封面路径）；键缺省时保留编译期默认
static void reloadTweakPrefs(void) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.dynamicisland.tweak"];
    id vLog = [prefs objectForKey:@"verboseLog"];
    if (vLog) {
        _diVerbose = [prefs boolForKey:@"verboseLog"];
    }
    _useOptionalArtwork = [prefs boolForKey:@"useOptionalArtwork"];
}

// 用 ImageIO 生成缩略图解码，避免全尺寸解码大封面；超大图自动缩到 maxPx
static UIImage *downsampledImage(NSData *data, CGFloat maxPx) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) return nil;
    UIImage *result = nil;
    @autoreleasepool {
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (src) {
            NSDictionary *opts = @{
                (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                (id)kCGImageSourceShouldCacheImmediately: @YES,
                (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPx),
            };
            CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
            if (thumb) {
                result = [UIImage imageWithCGImage:thumb];
                CGImageRelease(thumb);
            }
            CFRelease(src);
        }
        // ImageIO 失败兜底：直接解码
        if (!result) {
            result = [UIImage imageWithData:data];
        }
    }
    return result;
}

// App 图标兜底：运行时探测私有 +[UIImage _applicationIconImageForBundleIdentifier:format:scale:]，失败降级 nil
static UIImage *artworkForBundleID(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    @try {
        SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        if (![UIImage respondsToSelector:sel]) return nil;
        NSMethodSignature *sig = [UIImage methodSignatureForSelector:sel];
        if (!sig) return nil;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:[UIImage class]];
        [inv setSelector:sel];
        int format = 2; // 大图
        CGFloat scale = [UIScreen mainScreen].scale;
        [inv setArgument:&bundleID atIndex:2];
        [inv setArgument:&format atIndex:3];
        [inv setArgument:&scale atIndex:4];
        [inv invoke];
        UIImage *__unsafe_unretained tmp = nil;
        [inv getReturnValue:&tmp];
        return tmp;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void runOnMainQueue(dispatch_block_t block) {
    if (!block) return;
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

static id dictionaryValue(NSDictionary *dictionary, NSString *key) {
    return key ? dictionary[key] : nil;
}

static BOOL loadMediaRemote(void) {
    if (_mrHandle) {
        BOOL cached = (_MRRegister && _MRGetNowPlaying && _kInfoTitle && _kInfoDidChange);
        return cached;
    }

    DIVLog(@"loadMediaRemote: dlopen MediaRemote...");
    _mrHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL);
    if (!_mrHandle) {
        DILog(@"loadMediaRemote: dlopen FAILED: %s", dlerror());
        return NO;
    }
    DIVLog(@"loadMediaRemote: dlopen ok, handle=%p", _mrHandle);

    _MRRegister = dlsym(_mrHandle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    _MRGetNowPlaying = dlsym(_mrHandle, "MRMediaRemoteGetNowPlayingInfo");
    _MRGetNowPlayingWithOptionalArtwork = dlsym(_mrHandle, "MRMediaRemoteGetNowPlayingInfoWithOptionalArtwork");
    _MRGetNowPlayingClient = dlsym(_mrHandle, "MRMediaRemoteGetNowPlayingClient");
    _MRClientGetBundleID = dlsym(_mrHandle, "MRNowPlayingClientGetBundleIdentifier");
    _MRClientGetParentBundleID = dlsym(_mrHandle, "MRNowPlayingClientGetParentAppBundleIdentifier");

    CFStringRef *titlePtr = dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoTitle");
    CFStringRef *artistPtr = dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoArtist");
    CFStringRef *ratePtr = dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoPlaybackRate");
    CFStringRef *artworkPtr = dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoArtworkData");
    CFStringRef *artworkURLPtr = dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoArtworkURL");
    CFStringRef *bundlePtr = dlsym(_mrHandle, "kMRNowPlayingClientBundleIdentifier");
    if (!bundlePtr) bundlePtr = dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoBundleIdentifier");
    CFStringRef *playingChangePtr = dlsym(_mrHandle, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification");
    CFStringRef *infoChangePtr = dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoDidChangeNotification");
    CFStringRef *elapsedPtr = dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoElapsedTime");
    CFStringRef *durationPtr = dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoDuration");

    DIVLog(@"sym ptrs: title=%p artist=%p rate=%p artwork=%p artworkURL=%p bundle=%p playingChange=%p infoChange=%p elapsed=%p duration=%p",
        titlePtr, artistPtr, ratePtr, artworkPtr, artworkURLPtr, bundlePtr, playingChangePtr, infoChangePtr, elapsedPtr, durationPtr);
    DIVLog(@"sym funcs: register=%p get=%p getOptional=%p getClient=%p getBundleID=%p getParentBundleID=%p",
        _MRRegister, _MRGetNowPlaying, _MRGetNowPlayingWithOptionalArtwork, _MRGetNowPlayingClient, _MRClientGetBundleID, _MRClientGetParentBundleID);

    if (titlePtr) _kInfoTitle = (__bridge NSString *)*titlePtr;
    if (artistPtr) _kInfoArtist = (__bridge NSString *)*artistPtr;
    if (ratePtr) _kInfoPlaybackRate = (__bridge NSString *)*ratePtr;
    if (artworkPtr) _kInfoArtworkData = (__bridge NSString *)*artworkPtr;
    if (artworkURLPtr) _kInfoArtworkURL = (__bridge NSString *)*artworkURLPtr;
    if (bundlePtr) _kInfoBundleID = (__bridge NSString *)*bundlePtr;
    if (playingChangePtr) _kPlayingDidChange = (__bridge NSString *)*playingChangePtr;
    if (infoChangePtr) _kInfoDidChange = (__bridge NSString *)*infoChangePtr;
    if (elapsedPtr) _kInfoElapsedTime = (__bridge NSString *)*elapsedPtr;
    if (durationPtr) _kInfoDuration = (__bridge NSString *)*durationPtr;

    BOOL ok = (_MRRegister && _MRGetNowPlaying && _kInfoTitle && _kInfoDidChange);
    DIVLog(@"loadMediaRemote result: ok=%d, _kInfoArtworkData=%@, _kInfoArtworkURL=%@, _kInfoBundleID=%@", ok, _kInfoArtworkData, _kInfoArtworkURL, _kInfoBundleID);
    return ok;
}

static void updateSyncTimer(BOOL playing) {
    if (!tweakEnabledFromPrefs()) {
        [_syncTimer invalidate];
        _syncTimer = nil;
        return;
    }
    if (playing) {
        if (!_syncTimer) {
            // 5s 仅做漂移校准；进度平滑由 DIContentView 的 progressStep(CADisplayLink) 本地推进
            // 大幅降低跨进程调用 + 大 dict(含 artworkData) 拷贝频率
            _syncTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(__unused NSTimer *timer) {
                syncTick();
            }];
        }
    } else {
        [_syncTimer invalidate];
        _syncTimer = nil;
    }
}

static void fetchNowPlayingInfo(void) {
    if (!tweakEnabledFromPrefs()) return;
    if (!_MRGetNowPlaying || !_kInfoTitle) return;

    MRMediaRemoteGetNowPlayingInfoCompletion completion = ^(CFDictionaryRef info) {
        if (!info) {
            DIVLog(@"fetchNowPlayingInfo: info=nil");
            return;
        }
        NSDictionary *dict = (__bridge NSDictionary *)info;
        if (![dict isKindOfClass:[NSDictionary class]]) {
            DIVLog(@"fetchNowPlayingInfo: dict wrong class");
            return;
        }

        NSString *title = safeString(dictionaryValue(dict, _kInfoTitle));
        NSString *artist = safeString(dictionaryValue(dict, _kInfoArtist));
        id rateValue = dictionaryValue(dict, _kInfoPlaybackRate);
        NSNumber *rate = [rateValue isKindOfClass:[NSNumber class]] ? rateValue : nil;
        BOOL playing = rate.floatValue > 0;

        // 切歌检测：title\artist 变化则 +generation、重置重试计数
        NSString *trackKey = [NSString stringWithFormat:@"%@\n%@", title ?: @"", artist ?: @""];
        if (![trackKey isEqualToString:_lastTrackKey]) {
            _lastTrackKey = trackKey;
            _artworkGeneration++;
            _artworkRetryCount = 0;
        }
        int gen = _artworkGeneration;

        // 优先级 1：artworkData（downsample，去掉 5MB 硬丢弃，超大自动缩）
        UIImage *artwork = nil;
        NSData *artData = dictionaryValue(dict, _kInfoArtworkData);
        NSUInteger artLen = ([artData isKindOfClass:[NSData class]]) ? [artData length] : 0;
        if ([artData isKindOfClass:[NSData class]] && artData.length > 0) {
            artwork = downsampledImage(artData, 600);
            DIVLog(@"fetchNowPlayingInfo: title=%@ artist=%@ playing=%d | artData len=%lu image=%@ size=%@",
                title, artist, playing, (unsigned long)artLen, artwork, artwork ? NSStringFromCGSize(artwork.size) : @"(nil)");
        } else {
            DIVLog(@"fetchNowPlayingInfo: title=%@ artist=%@ playing=%d | artData unavailable (key=%@ dataClass=%@ len=%lu)",
                title, artist, playing, _kInfoArtworkData, [artData class], (unsigned long)artLen);
            // 优先级 2：artworkURL 异步下载（downsample），gen 校验后再更新
            if (_kInfoArtworkURL) {
                id artworkURLValue = dictionaryValue(dict, _kInfoArtworkURL);
                NSURL *artworkURL = nil;
                if ([artworkURLValue isKindOfClass:[NSURL class]]) {
                    artworkURL = artworkURLValue;
                } else if ([artworkURLValue isKindOfClass:[NSString class]]) {
                    artworkURL = [NSURL URLWithString:artworkURLValue];
                }
                if (artworkURL) {
                    DIVLog(@"fetchNowPlayingInfo: trying artworkURL=%@", artworkURL);
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        @autoreleasepool {
                            NSData *urlData = [NSData dataWithContentsOfURL:artworkURL];
                            UIImage *urlImage = downsampledImage(urlData, 600);
                            NSUInteger urlLen = (urlData && [urlData isKindOfClass:[NSData class]]) ? [urlData length] : 0;
                            DIVLog(@"artworkURL download: dataLen=%lu image=%@ size=%@",
                                (unsigned long)urlLen, urlImage, urlImage ? NSStringFromCGSize(urlImage.size) : @"(nil)");
                            if (urlImage) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    if (gen != _artworkGeneration) return; // 已切歌，丢弃旧封面
                                    [[DIDisplayManager sharedInstance] updateMediaArtwork:urlImage];
                                });
                            }
                        }
                    });
                } else {
                    DIVLog(@"fetchNowPlayingInfo: artworkURL value missing/invalid (key=%@ valueClass=%@)",
                        _kInfoArtworkURL, [artworkURLValue class]);
                }
            }
        }

        BOOL hasRealArtwork = (artwork != nil);

        __block NSString *bundleID = safeString(dictionaryValue(dict, _kInfoBundleID));
        NSTimeInterval elapsed = 0;
        NSTimeInterval duration = 0;
        double playbackRate = 1.0;
        NSNumber *elapsedNumber = dictionaryValue(dict, _kInfoElapsedTime);
        NSNumber *durationNumber = dictionaryValue(dict, _kInfoDuration);
        NSNumber *rateNumber = dictionaryValue(dict, _kInfoPlaybackRate);
        if ([elapsedNumber isKindOfClass:[NSNumber class]]) elapsed = elapsedNumber.doubleValue;
        if ([durationNumber isKindOfClass:[NSNumber class]]) duration = durationNumber.doubleValue;
        if ([rateNumber isKindOfClass:[NSNumber class]]) playbackRate = rateNumber.doubleValue > 0 ? rateNumber.doubleValue : 1.0;

        void (^deliver)(NSString *) = ^(NSString *resolvedBundleID) {
            // 优先级 3：App 图标兜底，保证弱机 / 首拉失败不空白
            UIImage *finalArtwork = artwork;
            if (!finalArtwork) {
                UIImage *appIcon = artworkForBundleID(resolvedBundleID);
                if (appIcon) {
                    finalArtwork = appIcon;
                    DIVLog(@"fetchNowPlayingInfo: fallback to app icon for bundleID=%@", resolvedBundleID);
                }
            }
            if (title.length > 0 || artist.length > 0) {
                DIDisplayManager *manager = [DIDisplayManager sharedInstance];
                [manager showMediaWithTitle:title artist:artist playing:playing artwork:finalArtwork bundleID:resolvedBundleID];
                [manager updateElapsed:elapsed duration:duration playbackRate:playbackRate];
            }
            updateSyncTimer(playing);

            // 失败重试：无真实封面（仅 App 图标或无图）时延迟重拉，最多 2 次，gen 变化则放弃
            if (!hasRealArtwork && playing && (title.length > 0 || artist.length > 0) && _artworkRetryCount < 2) {
                int genAtSchedule = gen;
                _artworkRetryCount++;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (genAtSchedule != _artworkGeneration) return; // 已切歌
                    DIVLog(@"artwork retry #%d for gen=%d", _artworkRetryCount, genAtSchedule);
                    fetchNowPlayingInfo();
                });
            }
        };

        if (!bundleID && _MRGetNowPlayingClient && (_MRClientGetBundleID || _MRClientGetParentBundleID)) {
            _MRGetNowPlayingClient(dispatch_get_main_queue(), ^(id client) {
                NSString *resolvedBundleID = nil;
                if (client && _MRClientGetBundleID) resolvedBundleID = _MRClientGetBundleID(client);
                if (resolvedBundleID.length == 0 && client && _MRClientGetParentBundleID) resolvedBundleID = _MRClientGetParentBundleID(client);
                deliver(resolvedBundleID);
            });
        } else {
            deliver(bundleID);
        }
    };

    // 激进路径：默认关。仅当 prefs 开启且符号存在时，主动请求 300x300 封面替代标准 API
    if (_useOptionalArtwork && _MRGetNowPlayingWithOptionalArtwork) {
        @try {
            _MRGetNowPlayingWithOptionalArtwork(300, 300, dispatch_get_main_queue(), completion);
            return;
        } @catch (NSException *e) {
            DILog(@"optionalArtwork exception, fallback to standard: %@", e);
        }
    }
    _MRGetNowPlaying(dispatch_get_main_queue(), completion);
}

static void syncTick(void) {
    if (!tweakEnabledFromPrefs()) return;
    if (!_MRGetNowPlaying) return;

    _MRGetNowPlaying(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        if (!info) return;
        NSDictionary *dict = (__bridge NSDictionary *)info;
        if (![dict isKindOfClass:[NSDictionary class]]) return;

        NSTimeInterval elapsed = 0;
        NSTimeInterval duration = 0;
        double playbackRate = 1.0;
        NSNumber *elapsedNumber = dictionaryValue(dict, _kInfoElapsedTime);
        NSNumber *durationNumber = dictionaryValue(dict, _kInfoDuration);
        NSNumber *rateNumber = dictionaryValue(dict, _kInfoPlaybackRate);
        if ([elapsedNumber isKindOfClass:[NSNumber class]]) elapsed = elapsedNumber.doubleValue;
        if ([durationNumber isKindOfClass:[NSNumber class]]) duration = durationNumber.doubleValue;
        if ([rateNumber isKindOfClass:[NSNumber class]]) playbackRate = rateNumber.doubleValue > 0 ? rateNumber.doubleValue : 1.0;
        [[DIDisplayManager sharedInstance] updateElapsed:elapsed duration:duration playbackRate:playbackRate];
    });
}

static void prefsChanged(__unused CFNotificationCenterRef center, __unused void *observer, __unused CFStringRef name, __unused const void *object, __unused CFDictionaryRef userInfo) {
    runOnMainQueue(^{
        reloadTweakPrefs();
        DIDisplayManager *manager = [DIDisplayManager sharedInstance];
        [manager reloadPrefs];
        if (notificationEnabledFromPrefs()) {
            initializeNotificationHooksIfNeeded();
        }
        if (tweakEnabledFromPrefs()) {
            if (_didInitializeTweak) {
                fetchNowPlayingInfo();
            } else {
                scheduleTweakInitialization();
            }
        } else {
            [_syncTimer invalidate];
            _syncTimer = nil;
        }
    });
}

static void initializeTweakAfterLaunch(void) {
    if (_didInitializeTweak) return;
    if (!tweakEnabledFromPrefs()) {
        DILog(@"initializeTweakAfterLaunch: disabled, skip");
        return;
    }
    _didInitializeTweak = YES;
    DILog(@"initializeTweakAfterLaunch begin");

    DIDisplayManager *manager = [DIDisplayManager sharedInstance];
    [manager setup];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!tweakEnabledFromPrefs()) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BOOL mediaRemoteLoaded = loadMediaRemote();
            DILog(@"mediaRemoteLoaded=%d", mediaRemoteLoaded);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!mediaRemoteLoaded || !tweakEnabledFromPrefs()) return;
                @try {
                    _MRRegister(dispatch_get_main_queue());
                    DILog(@"MRRegister called");
                } @catch (NSException *e) {
                    DILog(@"MRRegister exception: %@", e);
                }

                if (_kInfoDidChange) {
                    [[NSNotificationCenter defaultCenter] addObserverForName:_kInfoDidChange object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
                        @try {
                            fetchNowPlayingInfo();
                        } @catch (NSException *e) {
                            DILog(@"infoDidChange exception: %@", e);
                        }
                    }];
                    DILog(@"observer infoDidChange registered");
                }
                if (_kPlayingDidChange) {
                    [[NSNotificationCenter defaultCenter] addObserverForName:_kPlayingDidChange object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
                        @try {
                            fetchNowPlayingInfo();
                        } @catch (NSException *e) {
                            DILog(@"playingDidChange exception: %@", e);
                        }
                    }];
                    DILog(@"observer playingDidChange registered");
                }

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    DILog(@"initial fetchNowPlayingInfo trigger");
                    fetchNowPlayingInfo();
                });
            });
        });
    });
}

static void scheduleTweakInitialization(void) {
    if (_didInitializeTweak || _didScheduleTweakInitialization) return;
    _didScheduleTweakInitialization = YES;
    DILog(@"scheduleTweakInitialization scheduled (+15s)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        _didScheduleTweakInitialization = NO;
        @try {
            initializeTweakAfterLaunch();
        } @catch (NSException *e) {
            DILog(@"scheduled init exception: %@", e);
        }
    });
}

static void registerPrefsObserverIfNeeded(void) {
    if (_didRegisterPrefsObserver) return;
    _didRegisterPrefsObserver = YES;
    @try {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChanged, CFSTR("com.dynamicisland.tweak/prefsChanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        DILog(@"prefs observer registered");
    } @catch (NSException *e) {
        DILog(@"registerPrefsObserver exception: %@", e);
    }
}

@interface NCNotificationRequest : NSObject
@property (nonatomic, readonly) id content;
@property (nonatomic, readonly) NSString *sectionIdentifier;
@end

@interface NCNotificationViewController : UIViewController
@property (nonatomic, copy) NCNotificationRequest *notificationRequest;
@end

@interface NCNotificationShortLookViewController : NCNotificationViewController
@end

static BOOL isVCInBannerContext(UIViewController *viewController) {
    if (!viewController.isViewLoaded) return NO;

    UIView *view = viewController.view.superview;
    while (view) {
        NSString *className = NSStringFromClass([view class]);
        if ([className rangeOfString:@"Banner" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if ([className containsString:@"NotificationList"] || [className containsString:@"CoverSheet"] || [className containsString:@"LockScreen"]) return NO;
        view = view.superview;
    }

    UIViewController *parent = viewController.parentViewController;
    while (parent) {
        NSString *className = NSStringFromClass([parent class]);
        if ([className rangeOfString:@"Banner" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if ([className containsString:@"NotificationList"] || [className containsString:@"CoverSheet"] || [className containsString:@"LockScreen"]) return NO;
        parent = parent.parentViewController;
    }
    return NO;
}

static void extractNotificationContent(NCNotificationRequest *request, NSString **titleOut, NSString **messageOut, UIImage **iconOut, NSString **bundleIDOut) {
    NSString *title = nil;
    NSString *message = nil;
    UIImage *icon = nil;
    NSString *bundleID = nil;

    @try {
        if ([request respondsToSelector:@selector(sectionIdentifier)]) {
            bundleID = safeString([request sectionIdentifier]);
        }

        id content = [request respondsToSelector:@selector(content)] ? [request content] : nil;
        if (content) {
            if ([content respondsToSelector:@selector(title)]) title = safeString([content performSelector:@selector(title)]);
            if ([content respondsToSelector:@selector(message)]) message = safeString([content performSelector:@selector(message)]);
            if (message.length == 0 && [content respondsToSelector:@selector(header)]) message = safeString([content performSelector:@selector(header)]);
            if ([content respondsToSelector:@selector(icon)]) {
                id iconObject = [content performSelector:@selector(icon)];
                if ([iconObject isKindOfClass:[UIImage class]]) icon = iconObject;
            }
        }
    } @catch (__unused NSException *exception) { }

    if (title.length == 0 && message.length == 0) title = DILocalizedString(@"DI_NOTIFICATION_FALLBACK");
    if (titleOut) *titleOut = title;
    if (messageOut) *messageOut = message;
    if (iconOut) *iconOut = icon;
    if (bundleIDOut) *bundleIDOut = bundleID;
}

%group NotificationHooks
%hook NCNotificationShortLookViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;

    if (!tweakEnabledFromPrefs()) return;
    DIDisplayManager *manager = [DIDisplayManager sharedInstance];
    if (!manager.bannerEnabled || !isVCInBannerContext(self)) return;

    // 隐藏原生横幅：仅隐藏 VC 自身视图
    // 不触碰系统 banner 容器（SBUserNotificationBanner 等），以免破坏横幅状态机导致闪退
    self.view.hidden = YES;
    self.view.alpha = 0;

    NCNotificationRequest *request = nil;
    @try {
        request = [self respondsToSelector:@selector(notificationRequest)] ? [self notificationRequest] : nil;
    } @catch (__unused NSException *exception) { }
    if (!request) return;

    NSString *title = nil;
    NSString *message = nil;
    UIImage *icon = nil;
    NSString *bundleID = nil;
    extractNotificationContent(request, &title, &message, &icon, &bundleID);
    [manager showNotificationWithTitle:title message:message icon:icon bundleID:bundleID];
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;

    if (!tweakEnabledFromPrefs()) return;
    DIDisplayManager *manager = [DIDisplayManager sharedInstance];
    if (!manager.bannerEnabled || !isVCInBannerContext(self)) return;

    // 延迟隐藏通知岛：若短时间内有新通知，cancelDelayedHide 会取消此 timer
    [manager cancelDelayedHide];
    manager.delayedHideTimer = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                                 target:manager
                                                               selector:@selector(hideNotification)
                                                               userInfo:nil
                                                                repeats:NO];
}

%end
%end

static void initializeNotificationHooksIfNeeded(void) {
    if (_didInitializeNotificationHooks) return;
    if (!objc_lookUpClass("NCNotificationShortLookViewController")) return;
    _didInitializeNotificationHooks = YES;
    %init(NotificationHooks);
}

static void startAfterInjection(void) {
    DIRawLog("startAfterInjection begin");
    DILog(@"startAfterInjection begin");
    // 不在 %ctor 里 dispatch_async 到主线程
    // 改为监听 UIApplication 启动完成通知，确保 SpringBoard 完全初始化后再执行
    __block id _launchObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
        // 移除观察者，只执行一次
        if (_launchObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:_launchObserver];
            _launchObserver = nil;
        }
        DIRawLog("UIApplicationDidFinishLaunching received");
        DILog(@"UIApplicationDidFinishLaunching received");
        @try {
            reloadTweakPrefs();
            registerPrefsObserverIfNeeded();
            BOOL islandOn = tweakEnabledFromPrefs();
            BOOL notifOn = notificationEnabledFromPrefs();
            DILog(@"prefs: islandEnabled=%d notificationEnabled=%d", islandOn, notifOn);
            if (notifOn) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    @try {
                        initializeNotificationHooksIfNeeded();
                    } @catch (NSException *e) {
                        DILog(@"initNotificationHooks exception: %@", e);
                    }
                });
            }
            if (islandOn) {
                scheduleTweakInitialization();
            }
        } @catch (NSException *e) {
            DILog(@"startAfterInjection dispatch exception: %@", e);
        }
    }];
    // Fallback: 如果 30 秒内没收到启动通知（异常情况），直接初始化
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (_launchObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:_launchObserver];
            _launchObserver = nil;
            DIRawLog("launch notification fallback triggered");
            DILog(@"launch notification fallback triggered");
            @try {
                reloadTweakPrefs();
                registerPrefsObserverIfNeeded();
                BOOL islandOn = tweakEnabledFromPrefs();
                BOOL notifOn = notificationEnabledFromPrefs();
                DILog(@"fallback prefs: islandEnabled=%d notificationEnabled=%d", islandOn, notifOn);
                if (notifOn) initializeNotificationHooksIfNeeded();
                if (islandOn) scheduleTweakInitialization();
            } @catch (NSException *e) {
                DILog(@"fallback exception: %@", e);
            }
        }
    });
}

%ctor {
    // C 层日志优先：不依赖 Foundation，dyld 阶段也能输出
    DIRawLog("========== ctor entered (dylib loaded) ==========");
    // 再用 Foundation 层日志写文件
    DILog(@"========== ctor entered (dylib loaded) ==========");
    @try {
        startAfterInjection();
    } @catch (NSException *e) {
        DILog(@"ctor exception: %@", e);
    }
}
