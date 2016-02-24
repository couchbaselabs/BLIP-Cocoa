//
//  BLIPRequest.m
//  BLIP
//
//  Created by Jens Alfke on 5/22/08.
//  Copyright 2008-2013 Jens Alfke.
//  Copyright (c) 2013-2015 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "BLIPRequest.h"
#import "BLIPConnection.h"
#import "BLIP_Internal.h"

#import "ExceptionUtils.h"


@implementation BLIPRequest
{
    BLIPResponse *_response;
}


- (instancetype) _initWithConnection: (BLIPConnection*)connection
                                body: (NSData*)body
                          properties: (NSDictionary*)properties
{
    self = [self _initWithConnection: connection
                              isMine: YES
                               flags: kBLIP_MSG
                              number: 0
                                body: body];
    if (self) {
        if (body)
            self.body = body;
        if (properties)
            _properties = [properties copy];
    }
    return self;
}

+ (BLIPRequest*) requestWithBody: (NSData*)body {
    return [[self alloc] _initWithConnection: nil body: body properties: nil];
}

+ (BLIPRequest*) requestWithBodyString: (NSString*)bodyString {
    return [self requestWithBody: [bodyString dataUsingEncoding: NSUTF8StringEncoding]];
}

+ (BLIPRequest*) requestWithBody: (NSData*)body
                      properties: (NSDictionary*)properties
{
    return [[self alloc] _initWithConnection: nil body: body properties: properties];
}

- (id)mutableCopyWithZone:(NSZone *)zone {
    Assert(self.complete);
    BLIPRequest *copy = [[self class] requestWithBody: self.body 
                                           properties: self.properties];
    copy.compressed = self.compressed;
    copy.urgent = self.urgent;
    copy.noReply = self.noReply;
    return copy;
}


- (BOOL) noReply                            {return (_flags & kBLIP_NoReply) != 0;}
- (void) setNoReply: (BOOL)noReply          {[self _setFlag: kBLIP_NoReply value: noReply];}
- (BLIPConnection*) connection        {return _connection;}

- (void) setConnection: (BLIPConnection*)conn {
    Assert(_isMine && !_sent,@"Connection can only be set before sending");
     _connection = conn;
}


- (BLIPResponse*) send {
    Assert(_connection,@"%@ has no connection to send over",self);
    Assert(!_sent,@"%@ was already sent",self);
    [self _encode];
    BLIPResponse *response = self.response;
    if ([_connection _sendRequest: self response: response])
        self.sent = YES;
    else
        response = nil;
    return response;
}


- (BLIPResponse*) response {
    if (! _response && ! self.noReply)
        _response = [[BLIPResponse alloc] _initWithRequest: self];
    return _response;
}

- (void) deferResponse {
    // This will allocate _response, causing -repliedTo to become YES, so BLIPConnection won't
    // send an automatic empty response after the current request handler returns.
    LogTo(BLIP,@"Deferring response to %@",self);
    [self response];
}

- (BOOL) repliedTo {
    return _response != nil;
}

- (void) respondWithData: (NSData*)data contentType: (NSString*)contentType {
    BLIPResponse *response = self.response;
    response.body = data;
    response.contentType = contentType;
    [response send];
}

- (void) respondWithString: (NSString*)string {
    [self respondWithData: [string dataUsingEncoding: NSUTF8StringEncoding]
              contentType: @"text/plain; charset=UTF-8"];
}

- (void) respondWithJSON: (id)jsonObject {
    BLIPResponse *response = self.response;
    response.bodyJSON = jsonObject;
    [response send];
}

- (void) respondWithError: (NSError*)error {
    self.response.error = error; 
    [self.response send];
}

- (void) respondWithErrorCode: (int)errorCode message: (NSString*)errorMessage {
    [self respondWithError: BLIPMakeError(errorCode, @"%@",errorMessage)];
}

- (void) respondWithException: (NSException*)exception {
    [self respondWithError: BLIPMakeError(kBLIPError_HandlerFailed, @"%@", exception.reason)];
}


@end
