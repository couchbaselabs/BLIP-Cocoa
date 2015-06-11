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
#import "PSWebSocket.h"
#import "PSWebSocketServer.h"
#import "Test.h"


@interface BLIPPocketSocketListener () <PSWebSocketServerDelegate>
@end


@implementation BLIPPocketSocketListener
{
    PSWebSocketServer* _server;
    NSString* _path;
    id<BLIPConnectionDelegate> _delegate;
    dispatch_queue_t _delegateQueue;
    NSMutableDictionary* _sockets;   // Maps NSValue (PSWebSocket*) to BLIPPocketSocketConnection

    NSMutableDictionary* _passwords;
}

- (instancetype) initWithPath: (NSString*)path
                     delegate: (id<BLIPConnectionDelegate>)delegate
                        queue: (dispatch_queue_t)queue
{
    self = [super init];
    if (self) {
        _path = [path copy];
        _delegate = delegate;
        _delegateQueue = queue ?: dispatch_get_main_queue();
    }
    return self;
}

- (BOOL) acceptOnInterface: (NSString*)interface
                      port: (uint16_t)port
                     error: (NSError**)error
{
    _sockets = [NSMutableDictionary new];
    _server = [PSWebSocketServer serverWithHost: interface port: port];
    _server.delegate = self;
    _server.delegateQueue = dispatch_queue_create("BLIP Listener", DISPATCH_QUEUE_SERIAL);
    [_server start];
    return YES;
}

- (void)serverDidStart:(PSWebSocketServer *)server {
    Log(@"BLIPPocketSocketListener is listening...");
    [self listenerDidStart];
}

- (void)serverDidStop:(PSWebSocketServer *)server {
    Log(@"BLIPPocketSocketListener stopped");
    _server = nil;
    _delegate = nil;
    _sockets = nil;
    [self listenerDidStop];
}

- (void)server:(PSWebSocketServer *)server
        didFailWithError:(NSError *)error
{
    Log(@"BLIPPocketSocketListener failed to open: %@", error);
    [self listenerDidFailWithError: error];
}

- (void)listenerDidStart { }
- (void)listenerDidStop { }
- (void)listenerDidFailWithError:(NSError *)error { }

- (void) disconnect {
    [_server stop];
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


- (BOOL)server:(PSWebSocketServer *)server
        acceptWebSocketWithRequest:(NSURLRequest *)request
        response:(NSHTTPURLResponse**)outResponse
{
    LogTo(BLIP, @"Got request for %@ ; headers = %@", request.URL, request.allHTTPHeaderFields);
    int status;
    NSDictionary* headers = nil;
    NSString* username;
    if (![self checkAuthentication: request user: &username]) {
        // Auth failure:
        LogTo(BLIP, @"Rejected bad login for user '%@'", username);
        headers = @{@"WWW-Authenticate": $sprintf(@"Basic realm=\"%@\"", _realm)};
        status = 401;
    } else {
        LogTo(BLIP, @"Authenticated user '%@'", username);
        NSString* path = request.URL.path;
        if (![path isEqualToString: _path]) {
            // Wrong path:
            status = 404;
        } else {
            // Success:
            status = 200;
            headers = @{@"Sec-WebSocket-Protocol": @"BLIP"};
        }
    }

    *outResponse = [[NSHTTPURLResponse alloc] initWithURL: request.URL
                                               statusCode: status
                                              HTTPVersion: @"HTTP/1.1"
                                             headerFields: headers];
    return (status < 300);
}


#pragma mark - DELEGATE:


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
    NSURLRequest* request = self.webSocket.URLRequest;
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
