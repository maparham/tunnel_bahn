#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^RelayStateHandler)(BOOL isReady, NSError * _Nullable error);
typedef void (^RelaySendCompletion)(NSError * _Nullable error);
typedef void (^RelayReceiveCompletion)(NSData * _Nullable data, BOOL isComplete, NSError * _Nullable error);

/// Thin ObjC wrapper around `nw_connection_t` with interface binding.
/// Avoids `NWConnection` entirely so the bridging header can precompile without the
/// Swift-overlay type, which is not reachable via `<Network/Network.h>` alone.
@interface RelayOutboundConnection : NSObject

/// Creates a TCP or UDP connection bound to `interfaceName` (e.g. "utun3").
/// Calls `[flow setMetadata:]` so the connection is not re-intercepted by the proxy.
/// Returns nil if parameter or endpoint creation fails.
+ (nullable RelayOutboundConnection *)connectionWithFlow:(NEAppProxyFlow *)flow
                                                hostname:(const char *)hostname
                                                    port:(const char *)port
                                                   isTCP:(BOOL)isTCP
                                           interfaceName:(const char * _Nullable)interfaceName
    NS_SWIFT_NAME(makeConnection(flow:hostname:port:isTCP:interfaceName:));

/// Starts the connection on `queue`. `stateHandler` is called with isReady=YES when
/// connected, or isReady=NO (with optional error) when failed or cancelled.
- (void)startWithQueue:(dispatch_queue_t)queue stateHandler:(RelayStateHandler)stateHandler
    NS_SWIFT_NAME(start(queue:stateHandler:));

/// Send `data`. `completion` called with nil on success or an error.
- (void)sendData:(NSData *)data completion:(RelaySendCompletion)completion
    NS_SWIFT_NAME(sendData(_:completion:));

/// Receive between `minLength` and `maxLength` bytes. TCP streaming.
- (void)receiveMinLength:(NSUInteger)minLength
              maxLength:(NSUInteger)maxLength
             completion:(RelayReceiveCompletion)completion
    NS_SWIFT_NAME(receive(minLength:maxLength:completion:));

/// Receive a single datagram (UDP).
- (void)receiveMessageWithCompletion:(RelayReceiveCompletion)completion
    NS_SWIFT_NAME(receiveMessage(completion:));

/// Signal EOF to the remote (half-close write side).
- (void)signalEOF;

/// Cancel and tear down the connection.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
