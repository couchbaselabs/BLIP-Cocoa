//
//  BLIPPocketSocketConnection.m
//  BLIP
//
//  Created by Jens Alfke on 4/10/15.
//  Copyright (c) 2015 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "BLIPPocketSocket_Internal.h"
#import "BLIPConnection+Transport.h"
#import "BLIPHTTPLogic.h"
#import "BLIP_Internal.h"
#import "PSWebSocket.h"

#import "MYErrorUtils.h"


@implementation BLIPPocketSocketConnection
{
    BLIPHTTPLogic* _httpLogic;
}

@synthesize webSocket=_webSocket, URL=_URL;

// Designated initializer
- (instancetype) initWithWebSocket: (PSWebSocket*)webSocket
                    transportQueue: (dispatch_queue_t)transportQueue
                               URL: (NSURL*)url
                          incoming: (BOOL)incoming {
    Assert(transportQueue);
    self = [super initWithTransportQueue: transportQueue isOpen: incoming];
    if (self) {
        _webSocket = webSocket;
        if (!incoming)
            _webSocket.delegate = self;
        _URL = url;
    }
    return self;
}

// Public API
- (instancetype) initWithURLRequest:(NSURLRequest *)request {
    Assert(request);
    dispatch_queue_t queue = dispatch_queue_create("BLIPConnection", DISPATCH_QUEUE_SERIAL);
    self = [self initWithWebSocket: nil
                    transportQueue: queue
                               URL: request.URL
                          incoming: NO];
    if (self) {
        _httpLogic = [[BLIPHTTPLogic alloc] initWithURLRequest: request];
        [_httpLogic setValue: @"BLIP" forHTTPHeaderField: @"Sec-WebSocket-Protocol"];
    }
    return self;
}

// Public API
- (instancetype) initWithURL:(NSURL *)url {
    return [self initWithURLRequest: [NSURLRequest requestWithURL: url]];
}


- (void) setCredential: (NSURLCredential*)credential {
    //FIX!!
    _httpLogic.credential = credential;
}


// Public API
- (BOOL) connect: (NSError**)outError {
    LogTo(BLIP, @"%@ connecting to <%@>...", self, _httpLogic.URL.absoluteString);
    _webSocket = [PSWebSocket clientSocketWithRequest: _httpLogic.URLRequest];
    _webSocket.delegate = self;
    _webSocket.delegateQueue = self.transportQueue;

    NSURLCredential* credential = _httpLogic.credential;
    if (credential.identity) {
        NSArray* certs = @[(__bridge id)credential.identity];
        if (credential.certificates)
            certs = [certs arrayByAddingObjectsFromArray: credential.certificates];
        _webSocket.SSLClientCertificates = certs;
    }
    
    [_webSocket open];
    return YES;
}

// Public API
- (void) close {
    NSError* error = self.error;
    if (error == nil) {
        [_webSocket close];
    } else if ([error.domain isEqualToString: @"WebSocketCloseCode"]) {
        [_webSocket closeWithCode: error.code reason: error.localizedFailureReason];
    } else {
        Warn(@"BLIPPocketSocketConnection closing due to %@", error.my_compactDescription);
        [_webSocket closeWithCode: 1008 /*PolicyError*/ reason: error.localizedDescription];
    }
}

// Public API
- (void) closeWithCode: (NSInteger)code reason:(NSString *)reason {
    [_webSocket closeWithCode: code reason: reason];
}

// override
- (BOOL) transportCanSend {
    return _webSocket.readyState == PSWebSocketReadyStateOpen;
}

// override
- (void) sendFrame:(NSData *)frame {
    [_webSocket send: frame];
}

// WebSocket delegate method
- (void)webSocket:(PSWebSocket *)webSocket didReceiveMessage:(id)message {
    if ([message isKindOfClass: [NSData class]])
        [self didReceiveFrame: message];
}

// WebSocket delegate method
- (void)webSocketDidOpen:(PSWebSocket *)webSocket {
    [self transportDidOpen];
}

// WebSocket delegate method
- (BOOL)webSocket:(PSWebSocket *)webSocket validateServerTrust: (SecTrustRef)trust {
    return [self.delegate respondsToSelector: @selector(blipConnection:validateServerTrust:)]
        && [self.delegate blipConnection: self validateServerTrust: trust];
}

// WebSocket delegate method
- (void) webSocket: (PSWebSocket *)webSocket didFailWithError: (NSError *)error {
    if ([error my_hasDomain: PSWebSocketErrorDomain code: PSWebSocketErrorCodeTimedOut]) {
        error = [NSError errorWithDomain: NSURLErrorDomain code: NSURLErrorTimedOut
                                userInfo: error.userInfo];
    } else if ([error my_hasDomain: NSOSStatusErrorDomain code: errSSLXCertChainInvalid]) {
        error = [NSError errorWithDomain: NSURLErrorDomain
                                    code: NSURLErrorServerCertificateUntrusted
                                userInfo: nil];
    } else if ([error my_hasDomain: PSWebSocketErrorDomain code: PSWebSocketErrorCodeHandshakeFailed]) {
        // HTTP error; ask _httpLogic what to do:
        CFHTTPMessageRef response = (__bridge CFHTTPMessageRef)error.userInfo[PSHTTPResponseErrorKey];
        NSInteger status = CFHTTPMessageGetResponseStatusCode(response);
        [_httpLogic receivedResponse: response];
        if (_httpLogic.shouldRetry) {
            LogTo(BLIP, @"%@ got HTTP response %ld, retrying...", self, (long)status);
            _webSocket.delegate = nil;
            [self connect: NULL];
            return;
        }
        NSString* message = CFBridgingRelease(CFHTTPMessageCopyResponseStatusLine(response));
        // Failed, but map the error back to HTTP:
        NSString* urlStr = webSocket.URLRequest.URL.absoluteString;
        error = [NSError errorWithDomain: @"HTTP"
                                    code: status
                                userInfo: @{NSLocalizedDescriptionKey: message,
                                            NSURLErrorFailingURLStringErrorKey: urlStr}];
    } else {
        NSDictionary* kErrorMap = @{
            PSWebSocketErrorDomain: @{@(PSWebSocketErrorCodeTimedOut):
                                          @[NSURLErrorDomain, @(NSURLErrorTimedOut)]},
            NSOSStatusErrorDomain: @{@(NSURLErrorServerCertificateUntrusted):
                                        @[NSURLErrorDomain, @(NSURLErrorServerCertificateUntrusted)]},
            (id)kCFErrorDomainCFNetwork: @{@(kCFHostErrorUnknown): @[NSURLErrorDomain, @(kCFURLErrorCannotFindHost)]},
            };
        error = MYMapError(error, kErrorMap);
    }
    [self transportDidCloseWithError: error];
}

// WebSocket delegate method
- (void) webSocket: (PSWebSocket *)webSocket
  didCloseWithCode:(NSInteger)code
            reason:(NSString *)reason
          wasClean:(BOOL)wasClean
{
    NSError* error = nil;
    if (code != PSWebSocketStatusCodeNormal || !wasClean) {
        NSDictionary* info = $dict({NSLocalizedFailureReasonErrorKey, reason});
        error = [NSError errorWithDomain: @"WebSocketCloseCode" code: code userInfo: info];
    }
    [self transportDidCloseWithError: error];
}

// WebSocket delegate method
- (void) webSocketIsHungry: (PSWebSocket *)ws {
    [self feedTransport];
}

@end
