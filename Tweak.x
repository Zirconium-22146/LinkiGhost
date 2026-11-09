// LinkiGhost — ghost mode for Telegram / Swiftgram on iOS.
//
// The tweak runs inside the app process and reacts to MTProto requests right
// before they are handed to the network stack:
//
//   * "typing" / read receipts -> the request is dropped and answered with an
//     error, so the caller's signal finishes instead of hanging;
//   * "online"                 -> account.updateStatus(offline: false) is
//     rewritten to (offline: true), which actively tells the server "offline"
//     instead of just stopping the updates (otherwise the server keeps the last
//     status for a few minutes).
//
// Hook point: -[MTRequestMessageService addRequest:] in MtProtoKit, the single
// place every RPC goes through.
//
// Settings live in the iPhone Settings app (LinkiGhost pane) and fall back to a
// plain plist file, so the tweak stays usable without PreferenceLoader.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// TL constructor ids. Taken from TelegramApi/swift_scheme.tl; these never change.
// Macros, not enum: 0xcc104937 does not fit into int and switch needs a real
// integer constant expression.
#define kLinkiCIDSetTyping            0x58943ee2u // messages.setTyping
#define kLinkiCIDSetEncryptedTyping   0x791451edu // messages.setEncryptedTyping
#define kLinkiCIDReadHistory          0x0e306d3au // messages.readHistory
#define kLinkiCIDChannelReadHistory   0xcc104937u // channels.readHistory
#define kLinkiCIDReadEncryptedHistory 0x7f4b690au // messages.readEncryptedHistory
#define kLinkiCIDAccountUpdateStatus  0x6628562cu // account.updateStatus
#define kLinkiCIDSponsoredMessages    0x3d6ce850u // messages.getSponsoredMessages

#define kLinkiBoolFalse               0xbc799737u
#define kLinkiBoolTrue                0x997275b5u

static const int32_t kLinkiGhostErrorCode = -1000;

// MARK: - Logging

static NSString *LinkiLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        path = [dir stringByAppendingPathComponent:@"linkighost.log"];
    });
    return path;
}

static BOOL gLogEnabled = YES;

static void LinkiLog(NSString *format, ...) {
    if (!gLogEnabled) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    static NSDateFormatter *formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss.SSS";
    });

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [formatter stringFromDate:[NSDate date]], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    @synchronized(@"linkighost-log") {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *path = LinkiLogPath();
        NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];
        if (attributes != nil && [attributes fileSize] > 512 * 1024) {
            [fm removeItemAtPath:path error:nil];
            attributes = nil;
        }
        if (attributes == nil) {
            [fm createFileAtPath:path contents:nil attributes:nil];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    }
}

// MARK: - Settings

// Priority: manual file first (handy in Filza), then the preferences domain
// written by the settings pane (rootless path first).
static NSArray<NSString *> *LinkiPrefPaths(void) {
    return @[
        @"/var/jb/etc/linkighost.plist",
        @"/var/jb/var/mobile/Library/Preferences/bond.linkigram.ghost.plist",
        @"/var/mobile/Library/Preferences/bond.linkigram.ghost.plist",
    ];
}

static NSDictionary *gPrefs = nil;
static NSTimeInterval gPrefsMtime = 0;
static NSTimeInterval gPrefsNextCheck = 0;

static NSDictionary *LinkiPrefs(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (gPrefs != nil && now < gPrefsNextCheck) {
        return gPrefs;
    }
    gPrefsNextCheck = now + 1.0;

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in LinkiPrefPaths()) {
        NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];
        if (attributes == nil) {
            continue;
        }
        NSTimeInterval mtime = [[attributes fileModificationDate] timeIntervalSince1970];
        if (gPrefs != nil && mtime == gPrefsMtime) {
            return gPrefs;
        }
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data == nil) {
            continue;
        }
        id parsed = [NSPropertyListSerialization propertyListWithData:data
                                                             options:NSPropertyListImmutable
                                                              format:NULL
                                                               error:nil];
        if (![parsed isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        gPrefs = parsed;
        gPrefsMtime = mtime;
        id logEnabled = gPrefs[@"LogEnabled"];
        gLogEnabled = logEnabled == nil ? YES : [logEnabled boolValue];
        LinkiLog(@"settings loaded from %@: %@", path, gPrefs);
        return gPrefs;
    }

    if (gPrefs == nil) {
        gPrefs = @{};
    }
    return gPrefs;
}

static BOOL LinkiBool(NSString *key, BOOL fallback) {
    id value = LinkiPrefs()[key];
    return value == nil ? fallback : [value boolValue];
}

// MARK: - Request helpers

// Declared locally so the tweak does not need MtProtoKit headers at build time.
@interface MTRequest : NSObject
@property (nonatomic, strong, readonly) NSData *payload;
@property (nonatomic, strong, readonly) id metadata;
@property (nonatomic, strong, readonly) id shortMetadata;
@property (nonatomic, strong, readonly) id (^responseParser)(NSData *);
@property (nonatomic, copy) void (^completed)(id result, id info, id error);
- (void)setPayload:(NSData *)payload metadata:(id)metadata shortMetadata:(id)shortMetadata responseParser:(id (^)(NSData *))responseParser;
@end

@interface MTRequestMessageService : NSObject
- (void)addRequest:(MTRequest *)request;
@end

@interface MTRpcError : NSObject
- (instancetype)initWithErrorCode:(int32_t)errorCode errorDescription:(NSString *)errorDescription;
@end

static uint32_t LinkiConstructorId(NSData *payload) {
    if (payload.length < 4) {
        return 0;
    }
    uint32_t cid = 0;
    [payload getBytes:&cid range:NSMakeRange(0, sizeof(cid))];
    return cid;
}

// account.updateStatus carries exactly one Bool after the constructor id, so
// flipping it to boolTrue turns "I am online" into "I am offline".
static NSData *LinkiForceOfflinePayload(NSData *payload) {
    if (payload.length < 8) {
        return nil;
    }
    uint32_t cid = 0;
    uint32_t flag = 0;
    [payload getBytes:&cid range:NSMakeRange(0, sizeof(cid))];
    [payload getBytes:&flag range:NSMakeRange(sizeof(cid), sizeof(flag))];
    if (cid != kLinkiCIDAccountUpdateStatus || flag != kLinkiBoolFalse) {
        return nil;
    }
    NSMutableData *rewritten = [payload mutableCopy];
    uint32_t offline = kLinkiBoolTrue;
    [rewritten replaceBytesInRange:NSMakeRange(sizeof(cid), sizeof(offline)) withBytes:&offline];
    return rewritten;
}

// MARK: - Counters (diagnostics)

static int gGhostTyping = 0;
static int gGhostRead = 0;
static int gGhostOnline = 0;
static int gGhostAds = 0;
static int gSeen = 0;

static void LinkiScheduleReport(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!LinkiBool(@"ShowAlert", NO)) {
                return;
            }
            NSString *text = [NSString stringWithFormat:
                @"hook: %@\n"
                @"requests seen: %d\n"
                @"typing: %d, read: %d, online: %d, ads: %d\n"
                @"log: Documents/linkighost.log",
                gSeen > 0 ? @"работает" : @"НЕ получает запросы",
                gSeen, gGhostTyping, gGhostRead, gGhostOnline, gGhostAds];

            UIWindow *window = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            for (UIWindow *candidate in [UIApplication sharedApplication].windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                    break;
                }
            }
#pragma clang diagnostic pop
            UIViewController *controller = window.rootViewController;
            while (controller.presentedViewController != nil) {
                controller = controller.presentedViewController;
            }
            if (controller == nil) {
                return;
            }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LinkiGhost"
                                                                           message:text
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [controller presentViewController:alert animated:YES completion:nil];
        });
    });
}

// MARK: - Hook

%hook MTRequestMessageService

- (void)addRequest:(MTRequest *)request {
    uint32_t cid = LinkiConstructorId(request.payload);
    gSeen++;

    BOOL drop = NO;

    if (LinkiBool(@"Enabled", YES)) {
        BOOL ghostTyping = LinkiBool(@"HideTyping", YES);
        BOOL ghostRead = LinkiBool(@"HideRead", YES);
        BOOL ghostOnline = LinkiBool(@"HideOnline", YES);

        if (ghostOnline && cid == kLinkiCIDAccountUpdateStatus) {
            gGhostOnline++;
            NSData *offline = LinkiForceOfflinePayload(request.payload);
            if (offline != nil) {
                LinkiLog(@"online -> forced offline cid=%08x", cid);
                [request setPayload:offline
                           metadata:request.metadata
                      shortMetadata:request.shortMetadata
                     responseParser:request.responseParser];
                %orig;
                return;
            }
            LinkiLog(@"online dropped cid=%08x", cid);
            drop = YES;
        } else if (ghostTyping && (cid == kLinkiCIDSetTyping || cid == kLinkiCIDSetEncryptedTyping)) {
            gGhostTyping++;
            LinkiLog(@"typing dropped cid=%08x", cid);
            drop = YES;
        } else if (ghostRead && (cid == kLinkiCIDReadHistory || cid == kLinkiCIDChannelReadHistory ||
                                 cid == kLinkiCIDReadEncryptedHistory)) {
            gGhostRead++;
            LinkiLog(@"read dropped cid=%08x", cid);
            drop = YES;
        } else if (LinkiBool(@"BlockAds", NO) && cid == kLinkiCIDSponsoredMessages) {
            gGhostAds++;
            LinkiLog(@"ads dropped cid=%08x", cid);
            drop = YES;
        }
    }

    if (!drop) {
        if (gSeen <= 400) {
            LinkiLog(@"passthrough cid=%08x", cid);
        }
        %orig;
        return;
    }

    // Answering with an error is important: without it the caller's signal
    // would wait for a response that never comes.
    void (^completion)(id, id, id) = request.completed;
    if (completion == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        // MTRpcError lives in the app binary, not in the tweak, so it must be
        // looked up at runtime.
        Class errorClass = objc_getClass("MTRpcError");
        id error = nil;
        if (errorClass != Nil) {
            error = [(MTRpcError *)[errorClass alloc] initWithErrorCode:kLinkiGhostErrorCode
                                                       errorDescription:@"LINKIGHOST"];
        }
        completion(nil, nil, error);
    });
}

%end

%ctor {
    LinkiLog(@"=== LinkiGhost 0.2.0 loaded into %@ (iOS %@) ===",
             [[NSBundle mainBundle] bundleIdentifier],
             [[UIDevice currentDevice] systemVersion]);
    LinkiPrefs();
    LinkiScheduleReport();
}
