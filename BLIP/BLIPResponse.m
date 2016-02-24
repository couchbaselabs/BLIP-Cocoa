//
//  BLIPResponse.m
//  BLIP
//
//  Created by Jens Alfke on 9/15/13.
//  Copyright (c) 2013-2015 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "BLIPResponse.h"
#import "BLIPConnection.h"
#import "BLIP_Internal.h"

#import "ExceptionUtils.h"


@implementation BLIPResponse
{
    void (^_onComplete)();
}

- (instancetype) _initWithRequest: (BLIPRequest*)request {
    Assert(request);
    self = [super _initWithConnection: request.connection
                               isMine: !request.isMine
                                flags: kBLIP_RPY | kBLIP_MoreComing
                               number: request.number
                                 body: nil];
    if (self != nil) {
        if (_isMine && request.urgent)
            _flags |= kBLIP_Urgent;
    }
    return self;
}


#if DEBUG
// For testing only
- (instancetype) _initIncomingWithProperties: (NSDictionary*)properties body: (NSData*)body {
    self = [self _initWithConnection: nil
                              isMine: NO
                               flags: kBLIP_MSG
                              number: 0
                                body: nil];
    if (self != nil ) {
        _body = [body copy];
        _isMutable = NO;
        _properties = properties;
    }
    return self;
}
#endif


- (NSError*) error {
    if ((_flags & kBLIP_TypeMask) != kBLIP_ERR)
        return nil;
    
    NSMutableDictionary *userInfo = [_properties mutableCopy];
    NSString *domain = userInfo[@"Error-Domain"];
    int code = [userInfo[@"Error-Code"] intValue];
    if (domain==nil || code==0) {
        domain = BLIPErrorDomain;
        if (code==0)
            code = kBLIPError_Unspecified;
    }
    [userInfo removeObjectForKey: @"Error-Domain"];
    [userInfo removeObjectForKey: @"Error-Code"];

    NSString* message = self.bodyString;
    if (message.length > 0)
        userInfo[NSLocalizedDescriptionKey] = message;

    return [NSError errorWithDomain: domain code: code userInfo: userInfo];
}

- (void) _setError: (NSError*)error {
    _flags &= ~kBLIP_TypeMask;
    if (error) {
        // Setting this stuff is a PITA because this object might be technically immutable,
        // in which case the standard setters would barf if I called them.
        _flags |= kBLIP_ERR;

        NSMutableDictionary *errorProps = [self.properties mutableCopy];
        if (! errorProps)
            errorProps = [[NSMutableDictionary alloc] init];
        NSDictionary *userInfo = error.userInfo;
        for (NSString *key in userInfo) {
            id value = $castIf(NSString,userInfo[key]);
            if (value && ![key isEqualToString: NSLocalizedDescriptionKey]
                      && ![key isEqualToString: NSLocalizedFailureReasonErrorKey]) {
                errorProps[key] = value;
            }
        }
        errorProps[@"Error-Domain"] = error.domain;
        errorProps[@"Error-Code"] = $sprintf(@"%li",(long)error.code);
        _properties = errorProps;

        NSString* message = userInfo[NSLocalizedDescriptionKey]
                         ?: userInfo[NSLocalizedFailureReasonErrorKey];
        _mutableBody = [[message dataUsingEncoding: NSUTF8StringEncoding] mutableCopy];
        _body = nil;

    } else {
        _flags |= kBLIP_RPY;
        [self.mutableProperties removeAllObjects];
    }
}

- (void) setError: (NSError*)error {
    Assert(_isMine && _isMutable);
    [self _setError: error];
}


- (BOOL) send {
    Assert(_connection,@"%@ has no connection to send over",self);
    Assert(!_sent,@"%@ was already sent",self);
    [self _encode];
    BOOL sent = self.sent = [_connection _sendResponse: self];
    Assert(sent);
    return sent;
}


@synthesize onComplete=_onComplete;


- (void) setComplete: (BOOL)complete {
    [super setComplete: complete];
    if (complete && _onComplete) {
        @try{
            _onComplete(self);
        }catchAndReport(@"BLIPRequest onComplete block");
        _onComplete = nil;
    }
}


- (void) _connectionClosed {
    [super _connectionClosed];
    if (!_isMine && !_complete) {
        NSError *error = _connection.error;
        if (!error)
            error = BLIPMakeError(kBLIPError_Disconnected,
                                  @"Connection closed before response was received");
        // Change incoming response to an error:
        _isMutable = YES;
        _properties = [_properties mutableCopy];
        [self _setError: error];
        _isMutable = NO;
        
        self.complete = YES;    // Calls onComplete target
    }
}


@end
