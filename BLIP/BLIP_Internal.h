//
//  BLIP_Internal.h
//  BLIP
//
//  Created by Jens Alfke on 5/10/08.
//  Copyright 2008-2013 Jens Alfke.
//  Copyright (c) 2013-2015 Couchbase, Inc. All rights reserved.

#import "BLIPConnection.h"
#import "BLIPRequest.h"
#import "BLIPResponse.h"
#import "BLIPProperties.h"

#import "MYLogging.h"
#import "Test.h"


UsingLogDomain(BLIP);
UsingLogDomain(BLIPLifecycle);


@class MYBuffer;
@protocol MYReader, MYWriter;


/* Private declarations and APIs for BLIP implementation. Not for use by clients! */


/* Flag bits in a BLIP frame header */
typedef NS_OPTIONS(UInt8, BLIPMessageFlags) {
    kBLIP_MSG       = 0x00,       // initiating message
    kBLIP_RPY       = 0x01,       // response to a MSG
    kBLIP_ERR       = 0x02,       // error response to a MSG
    kBLIP_ACKMSG    = 0x04,       // acknowledging data received in a MSG
    kBLIP_ACKRPY    = 0x05,       // acknowledging data received in a RPY

    kBLIP_TypeMask  = 0x07,       // bits reserved for storing message type
    kBLIP_Compressed= 0x08,       // data is gzipped
    kBLIP_Urgent    = 0x10,       // please send sooner/faster
    kBLIP_NoReply   = 0x20,       // no RPY needed
    kBLIP_MoreComing= 0x40,       // More frames coming (Applies only to individual frame)
    kBLIP_Meta      = 0x80,       // Special message type, handled internally (hello, bye, ...)

    kBLIP_MaxFlag   = 0xFF
};

/* BLIP message types; encoded in each frame's header. */
typedef BLIPMessageFlags BLIPMessageType;


@interface BLIPConnection ()
- (BOOL) _sendRequest: (BLIPRequest*)q response: (BLIPResponse*)response;
- (BOOL) _sendResponse: (BLIPResponse*)response;
- (void) _messageReceivedProperties: (BLIPMessage*)message;
- (void) _sendAckWithNumber: (uint32_t)number
                  isRequest: (BOOL)isRequest
              bytesReceived: (uint64_t)bytesReceived;
@end


@interface BLIPMessage ()
{
    @protected
    BLIPConnection* _connection;
    BLIPMessageFlags _flags;
    uint32_t _number;
    NSDictionary *_properties;
    NSData *_body;
    MYBuffer *_encodedBody;
    id<MYReader> _outgoing;
    id<MYWriter> _incoming;
    NSMutableData *_mutableBody;
    NSMutableArray* _bodyStreams;
    BOOL _isMine, _isMutable, _sent, _propertiesAvailable, _complete;
    int64_t _bytesWritten, _bytesReceived;
    id _representedObject;
}
@property BOOL sent, propertiesAvailable, complete;
- (BLIPMessageFlags) _flags;
- (void) _setFlag: (BLIPMessageFlags)flag value: (BOOL)value;
- (void) _encode;
@end


@interface BLIPMessage ()
- (instancetype) _initWithConnection: (BLIPConnection*)connection
                              isMine: (BOOL)isMine
                               flags: (BLIPMessageFlags)flags
                              number: (uint32_t)msgNo
                                body: (NSData*)body;
- (NSData*) nextFrameWithMaxSize: (uint16_t)maxSize moreComing: (BOOL*)outMoreComing;
@property (readonly) int64_t _bytesWritten;
@property (readonly) BOOL _needsAckToContinue;
- (void) _assignedNumber: (uint32_t)number;
- (BOOL) _receivedFrameWithFlags: (BLIPMessageFlags)flags body: (NSData*)body;
- (BOOL) _receivedAck: (uint64_t)bytesReceived;
- (BOOL) _needsAckToContinue;
- (void) _connectionClosed;
@end


@interface BLIPRequest ()
- (instancetype) _initWithConnection: (BLIPConnection*)connection
                                body: (NSData*)body
                          properties: (NSDictionary*)properties;
@end


@interface BLIPResponse ()
- (instancetype) _initWithRequest: (BLIPRequest*)request;
#if DEBUG
- (instancetype) _initIncomingWithProperties: (NSDictionary*)properties body: (NSData*)body;
#endif
@end
