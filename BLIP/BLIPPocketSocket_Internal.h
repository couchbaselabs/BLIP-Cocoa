//
//  BLIPPocketSocket_Internal.h
//  BLIP
//
//  Created by Jens Alfke on 4/11/15.
//  Copyright (c) 2015 Couchbase. All rights reserved.

#import "BLIPPocketSocketConnection.h"
#import "PSWebSocket.h"


@interface BLIPPocketSocketConnection () <PSWebSocketDelegate>

// Designated initializer
- (instancetype) initWithWebSocket: (PSWebSocket*)webSocket
                    transportQueue: (dispatch_queue_t)transportQueue
                               URL: (NSURL*)url
                          incoming: (BOOL)incoming;

@end
