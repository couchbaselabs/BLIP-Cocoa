//
//  BLIPMessage.m
//  BLIP
//
//  Created by Jens Alfke on 5/10/08.
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

#import "BLIPMessage.h"
#import "BLIPConnection.h"
#import "BLIP_Internal.h"

#import "ExceptionUtils.h"
#import "MYData.h"
#import "MYBuffer+Zip.h"


#define kMaxUnackedBytes 128000
#define kAckByteInterval  50000


NSString* const BLIPErrorDomain = @"BLIP";

NSError *BLIPMakeError( int errorCode, NSString *message, ... ) {
    va_list args;
    va_start(args,message);
    message = [[NSString alloc] initWithFormat: message arguments: args];
    va_end(args);
    LogTo(BLIP,@"BLIPError #%i: %@",errorCode,message);
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: message};
    return [NSError errorWithDomain: BLIPErrorDomain code: errorCode userInfo: userInfo];
}


@implementation BLIPMessage


@synthesize onDataReceived=_onDataReceived, onDataSent=_onDataSent, onSent=_onSent;


- (instancetype) _initWithConnection: (BLIPConnection*)connection
                              isMine: (BOOL)isMine
                               flags: (BLIPMessageFlags)flags
                              number: (uint32_t)msgNo
                                body: (NSData*)body
{
    self = [super init];
    if (self != nil) {
        _connection = connection;
        _isMine = isMine;
        _isMutable = isMine;
        _flags = flags;
        _number = msgNo;
        if (isMine) {
            _body = body.copy;
            _properties = [[NSMutableDictionary alloc] init];
            _propertiesAvailable = YES;
            _complete = YES;
        } else {
            Assert(!body);
        }
        LogTo(BLIPLifecycle,@"INIT %@",self);
    }
    return self;
}

#if DEBUG
- (void) dealloc {
    LogTo(BLIPLifecycle,@"DEALLOC %@",self);
}
#endif


- (NSString*) description {
    NSUInteger length = (_body.length ?: _mutableBody.length) ?: _encodedBody.minLength;
    NSMutableString *desc = [NSMutableString stringWithFormat: @"%@[#%u%s, %lu bytes",
                             self.class,
                             (unsigned int)_number,
                             (_isMine ? "->" : "<-"),
                             (unsigned long)length];
    if (_flags & kBLIP_Compressed) {
        if (_encodedBody && _encodedBody.minLength != length)
            [desc appendFormat: @" (%lu gzipped)", (unsigned long)_encodedBody.minLength];
        else
            [desc appendString: @", gzipped"];
    }
    if (_bodyStreams.count > 0)
        [desc appendString: @" +stream"];
    if (_flags & kBLIP_Urgent)
        [desc appendString: @", urgent"];
    if (_flags & kBLIP_NoReply)
        [desc appendString: @", noreply"];
    if (_flags & kBLIP_Meta)
        [desc appendString: @", META"];
    if (_flags & kBLIP_MoreComing)
        [desc appendString: @", incomplete"];
    [desc appendString: @"]"];
    return desc;
}

- (NSString*) descriptionWithProperties {
    NSMutableString *desc = (NSMutableString*)self.description;
    [desc appendFormat: @" %@", self.properties];
    return desc;
}


#pragma mark -
#pragma mark PROPERTIES & METADATA:


@synthesize connection=_connection, number=_number, isMine=_isMine, isMutable=_isMutable,
            _bytesWritten, sent=_sent, propertiesAvailable=_propertiesAvailable, complete=_complete,
            representedObject=_representedObject;


- (void) _setFlag: (BLIPMessageFlags)flag value: (BOOL)value {
    Assert(_isMine && _isMutable);
    if (value)
        _flags |= flag;
    else
        _flags &= ~flag;
}

- (BLIPMessageFlags) _flags                 {return _flags;}

- (BOOL) isRequest                          {return (_flags & kBLIP_TypeMask) == kBLIP_MSG;}
- (BOOL) compressed                         {return (_flags & kBLIP_Compressed) != 0;}
- (BOOL) urgent                             {return (_flags & kBLIP_Urgent) != 0;}
- (void) setCompressed: (BOOL)compressed    {[self _setFlag: kBLIP_Compressed value: compressed];}
- (void) setUrgent: (BOOL)high              {[self _setFlag: kBLIP_Urgent value: high];}


- (NSData*) body {
    if (! _body && _isMine)
        return [_mutableBody copy];
    else
        return _body;
}

- (void) setBody: (NSData*)body {
    Assert(_isMine && _isMutable);
    if (_mutableBody)
        [_mutableBody setData: body];
    else
        _mutableBody = [body mutableCopy];
}

- (void) _addToBody: (NSData*)data {
    if (data.length) {
        if (_mutableBody)
            [_mutableBody appendData: data];
        else
            _mutableBody = [data mutableCopy];
        _body = nil;
    }
}

- (void) addToBody: (NSData*)data {
    Assert(_isMine && _isMutable);
    [self _addToBody: data];
}

- (void) addStreamToBody:(NSInputStream *)stream {
    if (!_bodyStreams)
        _bodyStreams = [NSMutableArray new];
    [_bodyStreams addObject: stream];
}


- (NSString*) bodyString {
    NSData *body = self.body;
    if (body)
        return [[NSString alloc] initWithData: body encoding: NSUTF8StringEncoding];
    else
        return nil;
}

- (void) setBodyString: (NSString*)string {
    self.body = [string dataUsingEncoding: NSUTF8StringEncoding];
    self.contentType = @"text/plain; charset=UTF-8";
}


- (id) bodyJSON {
    NSData* body = self.body;
    if (body.length == 0)
        return nil;
    NSError* error;
    id jsonObj = [NSJSONSerialization JSONObjectWithData: body
                                                 options: NSJSONReadingAllowFragments
                                                   error: &error];
    if (!jsonObj)
        Warn(@"Couldn't parse %@ body as JSON: %@", self, error.my_compactDescription);
    return jsonObj;
}


- (void) setBodyJSON: (id)jsonObj {
    NSError* error;
    NSData* body = [NSJSONSerialization dataWithJSONObject: jsonObj options: 0 error: &error];
    Assert(body, @"Couldn't encode as JSON: %@", error.my_compactDescription);
    self.body = body;
    self.contentType = @"application/json";
    self.compressed = (body.length > 100);
}


- (NSDictionary*) properties {
    return _properties;
}

- (NSMutableDictionary*) mutableProperties {
    Assert(_isMine && _isMutable);
    return (NSMutableDictionary*)_properties;
}

- (NSString*) objectForKeyedSubscript: (NSString*)key {
    return _properties[key];
}

- (void) setObject: (NSString*)value forKeyedSubscript:(NSString*)key {
    [self.mutableProperties setValue: value forKey: key];
}


- (NSString*) contentType               {return self[@"Content-Type"];}
- (void) setContentType: (NSString*)t   {self[@"Content-Type"] = t;}
- (NSString*) profile                   {return self[@"Profile"];}
- (void) setProfile: (NSString*)p       {self[@"Profile"] = p;}


#pragma mark -
#pragma mark I/O:


- (void) _encode {
    Assert(_isMine && _isMutable);
    _isMutable = NO;
    _properties = [_properties copy];

    // _encodedBody and _outgoing do not include the properties
    _encodedBody = [[MYBuffer alloc] init];
    [_encodedBody writeData: (_body ?: _mutableBody)];
    for (NSInputStream* stream in _bodyStreams)
        [_encodedBody writeContentsOfStream: stream];
    _bodyStreams = nil;
    if (self.compressed)
        _outgoing = [[MYZipReader alloc] initWithReader: _encodedBody compressing: YES];
    else
        _outgoing = _encodedBody;
}


- (void) _assignedNumber: (uint32_t)number {
    Assert(_number==0,@"%@ has already been sent",self);
    _number = number;
    _isMutable = NO;
}


// Generates the next outgoing frame.
- (NSData*) nextFrameWithMaxSize: (uint16_t)maxSize moreComing: (BOOL*)outMoreComing {
    Assert(_number!=0);
    Assert(_isMine);
    Assert(_outgoing);
    *outMoreComing = NO;
    if (_bytesWritten==0)
        LogTo(BLIP,@"Now sending %@",self);
    size_t headerSize = MYLengthOfVarUInt(_number) + MYLengthOfVarUInt(_flags);

    NSMutableData* frame = [NSMutableData dataWithCapacity: maxSize];
    frame.length = headerSize;
    int64_t prevBytesWritten = _bytesWritten;
    if (_bytesWritten == 0) {
        // First frame: always write entire properties:
        NSData* propertyData = BLIPEncodeProperties(_properties);
        [frame appendData: propertyData];
        _bytesWritten += propertyData.length;
    }

    // Now read from payload:
    ssize_t frameLen = frame.length;
    if (frameLen < maxSize) {
        frame.length = maxSize;
        ssize_t bytesRead = [_outgoing readBytes: (uint8_t*)frame.mutableBytes + frameLen
                                       maxLength: maxSize - frameLen];
        if (bytesRead < 0) {
            // Yikes! Couldn't read message content. Abort.
            Warn(@"Unable to send %@: Couldn't read body from stream", self);
            if (_onDataSent)
                _onDataSent(self, 0);
            self.complete = YES;
            return nil;
        }
        frame.length = frameLen + bytesRead;
        _bytesWritten += bytesRead;
    }

    // Write the header at the start of the frame:
    if (_outgoing.atEnd) {
        _flags &= ~kBLIP_MoreComing;
        _outgoing = nil;
    } else {
        _flags |= kBLIP_MoreComing;
        *outMoreComing = YES;
    }
    void* pos = MYEncodeVarUInt(frame.mutableBytes, _number);
    MYEncodeVarUInt(pos, _flags);

    LogVerbose(BLIP,@"%@ pushing frame, bytes %lu-%lu%@", self,
          (unsigned long)prevBytesWritten, (unsigned long)_bytesWritten,
          (*outMoreComing ? @"" : @" (finished)"));
    if (_onDataSent)
        _onDataSent(self, _bytesWritten);
    if (!*outMoreComing)
        self.complete = YES;
    return frame;
}


- (BOOL) _needsAckToContinue {
    Assert(_isMine);
    return _bytesWritten - _bytesReceived >= kMaxUnackedBytes;
}


- (BOOL) _receivedAck: (uint64_t)bytesReceived {
    Assert(_isMine);
    if (bytesReceived <= _bytesReceived || bytesReceived > _bytesWritten)
        return NO;
    _bytesReceived = bytesReceived;
    return YES;
}


// Parses the next incoming frame.
- (BOOL) _receivedFrameWithFlags: (BLIPMessageFlags)flags body: (NSData*)frameBody {
    LogVerbose(BLIP,@"%@ rcvd bytes %lu-%lu, flags=%x",
          self, (unsigned long)_bytesReceived, (unsigned long)_bytesReceived+frameBody.length, flags);
    Assert(!_isMine);
    Assert(_flags & kBLIP_MoreComing);

    if (!self.isRequest)
        _flags = flags | kBLIP_MoreComing;

    int64_t oldBytesReceived = _bytesReceived;
    _bytesReceived += frameBody.length;
    BOOL shouldAck = (flags & kBLIP_MoreComing)
            && oldBytesReceived > 0
            && (oldBytesReceived / kAckByteInterval) < (_bytesReceived / kAckByteInterval);

    if (!_incoming)
        _incoming = _encodedBody = [[MYBuffer alloc] init];
    if (![_incoming writeData: frameBody])
        return NO;
    
    if (! _properties) {
        // Try to extract the properties:
        BOOL complete;
        _properties = BLIPReadPropertiesFromBuffer(_encodedBody, &complete);
        if (_properties) {
            if (flags & kBLIP_Compressed) {
                // Now that properties are read, enable decompression for the rest of the stream:
                _flags |= kBLIP_Compressed;
                NSData* restOfFrame = _encodedBody.flattened;
                _encodedBody = [[MYBuffer alloc] init];
                _incoming = [[MYZipWriter alloc] initWithWriter: _encodedBody compressing:NO];
                if (restOfFrame.length > 0 && ![_incoming writeData: restOfFrame])
                    return NO;
            }
            self.propertiesAvailable = YES;
            [_connection _messageReceivedProperties: self];
        } else if (complete) {
            return NO;
        }
    }

    if (_properties && _onDataReceived) {
        LogVerbose(BLIP, @"%@ -> calling onDataReceived(%lu bytes)",
              self, (unsigned long)_encodedBody.maxLength);
        _onDataReceived(self, _encodedBody);
    }

    if (! (flags & kBLIP_MoreComing)) {
        // End of message:
        _flags &= ~kBLIP_MoreComing;
        if (! _properties)
            return NO;
        _body = _encodedBody.flattened;
        _encodedBody = nil;
        _incoming = nil;
        _onDataReceived = nil;
        self.complete = YES;
    }

    if (shouldAck)
        [_connection _sendAckWithNumber: _number isRequest: self.isRequest
                          bytesReceived: _bytesReceived];

    return YES;
}


- (void) _connectionClosed {
    if (_isMine) {
        _bytesWritten = 0;
        _flags |= kBLIP_MoreComing;
    }
}


@end
