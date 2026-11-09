// LinkiGhost — ghost mode for the official Telegram iOS app.
//
// The tweak runs inside the Telegram process and drops selected MTProto
// requests right before they are handed to the network stack. Nothing in the
// UI changes: the app still shows "read", still animates the typing indicator
// locally, it just never tells the server.
//
// Hook point: -[MTRequestMessageService addRequest:] in MtProtoKit, the single
// place every RPC goes through.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// TL constructor ids. Taken from TelegramApi/swift_scheme.tl; these never change.
// Macros, not enum: 0xcc104937 does not fit into int and switch needs a real
// integer constant expression.
#define kLinkiCIDSetTyping            0x58943ee2u // messages.setTyping
#define kLinkiCIDSetEncryptedTyping   0x791451edu // messages.setEncryptedTyping
#define kLinkiCIDReadHistory          0x0e306d3au // messages.readHistory
#define kLinkiCIDChannelReadHistory   0xcc104937u // channels.readHistory
#define kLinkiCIDReadEncryptedHistory 0x7f4b690au // messages.readEncryptedHistory
#define kLinkiCIDAccountUpdateStatus  0x6628562cu // account.updateStatus

static const int32_t kLinkiGhostErrorCode = -1000;

// Declared locally so the tweak does not need MtProtoKit headers at build time.
@interface MTRequest : NSObject
@property (nonatomic, strong, readonly) NSData *payload;
@property (nonatomic, copy) void (^completed)(id result, id info, id error);
@end

@interface MTRpcError : NSObject
- (instancetype)initWithErrorCode:(int32_t)errorCode errorDescription:(NSString *)errorDescription;
@end

@interface MTRequestMessageService : NSObject
- (void)addRequest:(MTRequest *)request;
@end

static uint32_t LinkiConstructorId(NSData *payload) {
    if (payload.length < 4) {
        return 0;
    }
    uint32_t cid = 0;
    [payload getBytes:&cid range:NSMakeRange(0, sizeof(cid))];
    return cid;
}

static BOOL LinkiIsGhosted(uint32_t cid) {
    switch (cid) {
        case kLinkiCIDSetTyping:
        case kLinkiCIDSetEncryptedTyping:
        case kLinkiCIDReadHistory:
        case kLinkiCIDChannelReadHistory:
        case kLinkiCIDReadEncryptedHistory:
        case kLinkiCIDAccountUpdateStatus:
            return YES;
        default:
            return NO;
    }
}

%hook MTRequestMessageService

- (void)addRequest:(MTRequest *)request {
    uint32_t cid = LinkiConstructorId(request.payload);
    if (LinkiIsGhosted(cid)) {
        // Answer the caller with an error instead of sending: signals waiting
        // on this request finish instead of hanging forever.
        void (^completion)(id, id, id) = request.completed;
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // MTRpcError lives in the Telegram binary, not in the tweak, so it
                // must be looked up at runtime: a class literal would be an
                // undefined symbol at link time.
                Class errorClass = objc_getClass("MTRpcError");
                id error = nil;
                if (errorClass != Nil) {
                    error = [[errorClass alloc] initWithErrorCode:kLinkiGhostErrorCode
                                                 errorDescription:@"LINKIGHOST"];
                }
                completion(nil, nil, error);
            });
        }
        return;
    }
    %orig;
}

%end
