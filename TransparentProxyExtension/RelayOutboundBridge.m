#import "RelayOutboundBridge.h"

#import <Network/Network.h>
#import <NetworkExtension/NetworkExtension.h>

API_AVAILABLE(macos(10.14))
extern nw_interface_t nw_interface_create_with_name(const char *name);

static NSString *domainForNWError(nw_error_t err) {
    return nw_error_get_error_domain(err) == nw_error_domain_posix
        ? NSPOSIXErrorDomain
        : @"com.apple.network";
}

@implementation RelayOutboundConnection {
    nw_connection_t _conn;
}

+ (nullable RelayOutboundConnection *)connectionWithFlow:(NEAppProxyFlow *)flow
                                                hostname:(const char *)hostname
                                                    port:(const char *)port
                                                   isTCP:(BOOL)isTCP
                                           interfaceName:(const char * _Nullable)interfaceName {
    nw_parameters_t params;
    if (isTCP) {
        params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                 NW_PARAMETERS_DEFAULT_CONFIGURATION);
    } else {
        params = nw_parameters_create_secure_udp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                 NW_PARAMETERS_DEFAULT_CONFIGURATION);
    }
    if (params == NULL) { return nil; }

    [flow setMetadata:params];

    if (interfaceName != NULL && interfaceName[0] != '\0') {
        nw_interface_t iface = nw_interface_create_with_name(interfaceName);
        if (iface != NULL) {
            nw_parameters_require_interface(params, iface);
        }
    }

    nw_endpoint_t endpoint = nw_endpoint_create_host(hostname, port);
    if (endpoint == NULL) { return nil; }

    nw_connection_t conn = nw_connection_create(endpoint, params);
    if (conn == NULL) { return nil; }

    RelayOutboundConnection *obj = [[RelayOutboundConnection alloc] init];
    obj->_conn = conn;
    return obj;
}

- (void)startWithQueue:(dispatch_queue_t)queue stateHandler:(RelayStateHandler)stateHandler {
    nw_connection_t conn = _conn;
    nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state,
                                                     nw_error_t _Nullable error) {
        switch (state) {
            case nw_connection_state_preparing:
                NSLog(@"[APPSPLIT_RELAY] nw_connection state=preparing");
                break;
            case nw_connection_state_waiting:
                if (error != NULL) {
                    NSLog(@"[APPSPLIT_RELAY] nw_connection state=waiting domain=%d code=%d",
                          (int)nw_error_get_error_domain(error),
                          (int)nw_error_get_error_code(error));
                } else {
                    NSLog(@"[APPSPLIT_RELAY] nw_connection state=waiting (no error)");
                }
                break;
            case nw_connection_state_ready:
                NSLog(@"[APPSPLIT_RELAY] nw_connection state=ready");
                stateHandler(YES, nil);
                break;
            case nw_connection_state_failed:
            case nw_connection_state_cancelled: {
                NSError *nsErr = nil;
                if (error != NULL) {
                    nsErr = [NSError errorWithDomain:domainForNWError(error)
                                               code:(NSInteger)nw_error_get_error_code(error)
                                           userInfo:nil];
                    NSLog(@"[APPSPLIT_RELAY] nw_connection state=%s domain=%d code=%d",
                          state == nw_connection_state_failed ? "failed" : "cancelled",
                          (int)nw_error_get_error_domain(error),
                          (int)nw_error_get_error_code(error));
                } else {
                    NSLog(@"[APPSPLIT_RELAY] nw_connection state=%s (no error)",
                          state == nw_connection_state_failed ? "failed" : "cancelled");
                }
                stateHandler(NO, nsErr);
                break;
            }
            default:
                break;
        }
    });
    nw_connection_set_queue(conn, queue);
    nw_connection_start(conn);
}

- (void)sendData:(NSData *)data completion:(RelaySendCompletion)completion {
    const void *bytes = data.bytes;
    NSUInteger length = data.length;
    dispatch_data_t dispatchData = dispatch_data_create(bytes, length,
                                                        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                                                        DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(_conn,
                       dispatchData,
                       NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                       false,
                       ^(nw_error_t _Nullable error) {
        if (error != NULL) {
            NSError *nsErr = [NSError errorWithDomain:domainForNWError(error)
                                                code:(NSInteger)nw_error_get_error_code(error)
                                            userInfo:nil];
            completion(nsErr);
        } else {
            completion(nil);
        }
    });
}

- (void)receiveMinLength:(NSUInteger)minLength
              maxLength:(NSUInteger)maxLength
             completion:(RelayReceiveCompletion)completion {
    nw_connection_receive(_conn,
                          (uint32_t)minLength,
                          (uint32_t)maxLength,
                          ^(dispatch_data_t _Nullable content,
                            nw_content_context_t _Nullable context,
                            bool is_complete,
                            nw_error_t _Nullable error) {
        NSData *data = nil;
        if (content != NULL) {
            data = (NSData *)dispatch_data_create_map(content, NULL, NULL);
        }
        NSError *nsErr = nil;
        if (error != NULL) {
            nsErr = [NSError errorWithDomain:domainForNWError(error)
                                       code:(NSInteger)nw_error_get_error_code(error)
                                   userInfo:nil];
        }
        completion(data, (BOOL)is_complete, nsErr);
    });
}

- (void)receiveMessageWithCompletion:(RelayReceiveCompletion)completion {
    nw_connection_receive_message(_conn,
                                  ^(dispatch_data_t _Nullable content,
                                    nw_content_context_t _Nullable context,
                                    bool is_complete,
                                    nw_error_t _Nullable error) {
        NSData *data = nil;
        if (content != NULL) {
            data = (NSData *)dispatch_data_create_map(content, NULL, NULL);
        }
        NSError *nsErr = nil;
        if (error != NULL) {
            nsErr = [NSError errorWithDomain:domainForNWError(error)
                                       code:(NSInteger)nw_error_get_error_code(error)
                                   userInfo:nil];
        }
        completion(data, (BOOL)is_complete, nsErr);
    });
}

- (void)signalEOF {
    nw_connection_send(_conn,
                       NULL,
                       NW_CONNECTION_FINAL_MESSAGE_CONTEXT,
                       true,
                       ^(nw_error_t _Nullable error) {});
}

- (void)cancel {
    nw_connection_cancel(_conn);
}

@end
