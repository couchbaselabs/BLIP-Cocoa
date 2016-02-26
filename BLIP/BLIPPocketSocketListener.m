//
//  BLIPPocketSocketListener.m
//  BLIP
//
//  Created by Jens Alfke on 4/11/15.
//  Copyright (c) 2015 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "BLIPPocketSocketListener.h"
#import "BLIPPocketSocket_Internal.h"
#import "BLIPConnection+Transport.h"
#import "BLIP_Internal.h"
#import "PSWebSocket.h"
#import "PSWebSocketServer.h"


@interface BLIPPocketSocketListener () <PSWebSocketServerDelegate>
@end


@implementation BLIPPocketSocketListener
{
    PSWebSocketServer* _server;
    NSArray* _paths;
    id<BLIPConnectionDelegate> _delegate;
    dispatch_queue_t _delegateQueue;
    NSMutableDictionary* _sockets;   // Maps NSValue (PSWebSocket*) to BLIPPocketSocketConnection

    NSMutableDictionary* _passwords;
}

- (instancetype) initWithPaths: (NSArray*)paths
                      delegate: (id<BLIPConnectionDelegate>)delegate
                         queue: (dispatch_queue_t)queue
{
    self = [super init];
    if (self) {
        _paths = [paths copy];
        _delegate = delegate;
        _delegateQueue = queue ?: dispatch_get_main_queue();
    }
    return self;
}

- (instancetype)init {
    NSAssert(NO, @"init method is unavailable");
    return nil;
}

- (BOOL) acceptOnInterface: (NSString*)interface
                      port: (uint16_t)port
           SSLCertificates: (NSArray*)certs
                     error: (NSError**)error
{
    LogTo(BLIP, @"%@ opening on %@:%d at paths {'%@'}", self, interface, port,
          [_paths componentsJoinedByString: @"', '"]);
    _sockets = [NSMutableDictionary new];
    _server = [PSWebSocketServer serverWithHost: interface port: port SSLCertificates: certs];
    _server.delegate = self;
    _server.delegateQueue = dispatch_queue_create("BLIP Listener", DISPATCH_QUEUE_SERIAL);
    [_server start];
    return YES;
}

- (void)serverDidStart:(PSWebSocketServer *)server {
    LogTo(BLIP, @"BLIPPocketSocketListener is listening on port %d...", _server.realPort);
    [self listenerDidStart];
}

- (void)serverDidStop:(PSWebSocketServer *)server {
    LogTo(BLIP, @"BLIPPocketSocketListener stopped");
    _server.delegate = nil;
    _server = nil;
    _delegate = nil;
    _sockets = nil;
    [self listenerDidStop];
}

- (void)server:(PSWebSocketServer *)server
        didFailWithError:(NSError *)error
{
    Warn(@"BLIPPocketSocketListener failed to open: %@", error.my_compactDescription);
    [self listenerDidFailWithError: error];
}

- (void)listenerDidStart { }
- (void)listenerDidStop { }
- (void)listenerDidFailWithError:(NSError *)error { }

- (void) disconnect {
    LogTo(BLIP, @"BLIPPocketSocketListener disconnect");
    [_server stop];
    _server.delegate = nil;
    _server = nil;
    _sockets = nil;
}

- (uint16_t) port {
    return _server.realPort;
}


#pragma mark - AUTHENTICATION:


@synthesize realm=_realm;

- (void) setPasswords: (NSDictionary*)passwords {
    _passwords = [passwords copy];
}

- (NSString*) passwordForUser:(NSString *)username {
    return _passwords[username];
}


+ (BOOL) fromRequest: (NSURLRequest*)request
         getUsername: (NSString**)outUser
            password: (NSString**)outPassword
{
    *outUser = nil;
    NSString* auth = [request valueForHTTPHeaderField: @"Authorization"];
    if (!auth)
        return YES;
    if (![auth hasPrefix: @"Basic "])
        return NO;
    NSData* credData = [[NSData alloc]
                            initWithBase64EncodedString: [auth substringFromIndex: 6]
                            options: NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!credData)
        return NO;
    NSString* cred = [[NSString alloc] initWithData: credData encoding: NSUTF8StringEncoding];
    NSRange colon = [cred rangeOfString:@":"];
    if (colon.length == 0)
        return NO;
    *outUser = [cred substringToIndex: colon.location];
    if (outPassword)
        *outPassword = [cred substringFromIndex: NSMaxRange(colon)];
    return YES;
}


- (BOOL) checkAuthentication: (NSURLRequest*)request user: (NSString**)outUser {
    NSString* password;
    if (![[self class] fromRequest: request getUsername: outUser password: &password])
        return NO;
    else if (*outUser == nil)
        return (_passwords == nil);
    else
        return [password isEqualToString: [self passwordForUser: *outUser]];
}


- (BOOL) checkClientCertificateAuthentication: (SecTrustRef)trust
                                  fromAddress: (NSData*)address
{
    return YES;
}


#pragma mark - DELEGATE:


- (BOOL)server:(PSWebSocketServer *)server
        acceptWebSocketFrom:(NSData*)address
        withRequest:(NSURLRequest *)request
        trust:(SecTrustRef)trust
        response:(NSHTTPURLResponse**)outResponse
{
    LogTo(BLIP, @"Got request for %@ ; trust %@ ; headers = %@",
          request.URL, trust, request.allHTTPHeaderFields);

    int status;
    NSDictionary* headers = nil;
    if (![self checkClientCertificateAuthentication: trust fromAddress: address]) {
        LogTo(BLIP, @"Rejected bad client cert");
        status = 401;
    } else {
        NSString* username;
        if (![self checkAuthentication: request user: &username]) {
            // Auth failure:
            LogTo(BLIP, @"Rejected bad login for user '%@'", username);
            headers = @{@"WWW-Authenticate": $sprintf(@"Basic realm=\"%@\"", _realm)};
            status = 401;
        } else {
            if (username)
                LogTo(BLIP, @"Authenticated user '%@'", username);
            NSString* path = request.URL.path;
            if (![_paths containsObject: path]) {
                // Unknown path:
                status = 404;
            } else {
                // Success:
                status = 200;
                headers = @{@"Sec-WebSocket-Protocol": @"BLIP"};
            }
        }
    }

    *outResponse = [[NSHTTPURLResponse alloc] initWithURL: request.URL
                                               statusCode: status
                                              HTTPVersion: @"HTTP/1.1"
                                             headerFields: headers];
    return (status < 300);
}


- (void)server:(PSWebSocketServer *)server
        webSocketDidOpen:(PSWebSocket *)webSocket
{
    CFTypeRef ref = [webSocket copyStreamPropertyForKey: (id)kCFStreamPropertySSLContext];
    NSString* scheme = @"ws";
    if (ref) {
        scheme = @"wss";
        CFRelease(ref);
    }
    NSString* host = webSocket.remoteHost;
    NSURL* url = [NSURL URLWithString: $sprintf(@"%@://%@/", scheme, host)];
    LogTo(BLIP, @"Accepted incoming connection from %@", url);

    BLIPPocketSocketConnection* conn;
    conn = [[BLIPPocketSocketConnection alloc] initWithWebSocket: webSocket
                                                  transportQueue: _server.delegateQueue
                                                             URL: url
                                                        incoming: YES];
    id key = [NSValue valueWithNonretainedObject: webSocket];
    _sockets[key] = conn;

    [conn setDelegate: _delegate queue: _delegateQueue];
    dispatch_async(_delegateQueue, ^{
        [self blipConnectionDidOpen: conn];
    });
}

- (void)server:(PSWebSocketServer *)server
     webSocket:(PSWebSocket *)webSocket
     didReceiveMessage:(id)message
{
    id key = [NSValue valueWithNonretainedObject: webSocket];
    BLIPPocketSocketConnection* conn = _sockets[key];
    [conn webSocket: webSocket didReceiveMessage: message];
}

- (void)server:(PSWebSocketServer *)server
        webSocketIsHungry:(PSWebSocket *)webSocket
{
    id key = [NSValue valueWithNonretainedObject: webSocket];
    BLIPPocketSocketConnection* conn = _sockets[key];
    [conn webSocketIsHungry: webSocket];
}

- (void)server:(PSWebSocketServer *)server
     webSocket:(PSWebSocket *)webSocket
     didFailWithError:(NSError *)error
{
    id key = [NSValue valueWithNonretainedObject: webSocket];
    BLIPPocketSocketConnection* conn = _sockets[key];
    [conn webSocket: webSocket didFailWithError: error];
    [_sockets removeObjectForKey: key];
}

- (void)server:(PSWebSocketServer *)server
     webSocket:(PSWebSocket *)webSocket
     didCloseWithCode:(NSInteger)code
        reason:(NSString *)reason
      wasClean:(BOOL)wasClean
{
    id key = [NSValue valueWithNonretainedObject: webSocket];
    BLIPPocketSocketConnection* conn = _sockets[key];
    [conn webSocket: webSocket didCloseWithCode: code reason: reason wasClean: wasClean];
    [_sockets removeObjectForKey: key];
}


- (void)blipConnectionDidOpen:(BLIPConnection*)b {
}


@end



@implementation BLIPPocketSocketConnection (Incoming)

- (NSURLCredential*) credential {
    // First check for an SSL client certificate:
    PSWebSocket* webSocket = self.webSocket;
    NSArray* clientCerts = webSocket.SSLClientCertificates;
    if (clientCerts) {
        if (clientCerts.count == 0)
            return nil; // should never happen
        SecIdentityRef identity = (__bridge SecIdentityRef)clientCerts[0];
        clientCerts = [clientCerts subarrayWithRange: NSMakeRange(1, clientCerts.count -1)];
        return [NSURLCredential credentialWithIdentity: identity certificates: clientCerts
                                           persistence: NSURLCredentialPersistenceNone];
    }

    // Then check for HTTP auth:
    NSURLRequest* request = webSocket.URLRequest;
    if (!request)
        return nil;
    NSString *username, *password;
    if (![BLIPPocketSocketListener fromRequest: request getUsername: &username password: &password]
        || !username)
        return nil;
    return [NSURLCredential credentialWithUser: username password: password
                                   persistence: NSURLCredentialPersistenceNone];
}

@end
