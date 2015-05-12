//
//  BLIPPocketSocketConnection.h
//  BLIP
//
//  Created by Jens Alfke on 4/10/15.
//  Copyright (c) 2015 Couchbase. All rights reserved.

#import "BLIPConnection.h"
@class PSWebSocket;


@interface BLIPPocketSocketConnection : BLIPConnection

- (instancetype) initWithURLRequest:(NSURLRequest *)request;
- (instancetype) initWithURL:(NSURL *)url;

- (void) setCredential: (NSURLCredential*)credential;

- (BOOL) connect: (NSError**)outError;

/** The underlying WebSocket. */
@property (readonly) PSWebSocket* webSocket;

- (void) closeWithCode: (NSInteger)code reason:(NSString *)reason;

@end
