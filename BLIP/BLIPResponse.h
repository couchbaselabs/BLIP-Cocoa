//
//  BLIPResponse.h
//  BLIP
//
//  Created by Jens Alfke on 9/15/13.
//  Copyright (c) 2013-2015 Couchbase, Inc. All rights reserved.

#import "BLIPMessage.h"


/** A reply to a BLIPRequest, in the <a href=".#blipdesc">BLIP</a> protocol. */
@interface BLIPResponse : BLIPMessage

/** Sends this response. */
- (BOOL) send;

/** The error returned by the peer, or nil if the response is successful. */
@property (strong) NSError* error;

/** Sets a target/action to be called when an incoming response is complete.
    Use this on the response returned from -[BLIPRequest send], to be notified when the response is available. */
@property (strong) void (^onComplete)(BLIPResponse*);


@end
