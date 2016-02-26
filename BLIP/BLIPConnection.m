//
//  BLIPConnection.m
//  BLIP
//
//  Created by Jens Alfke on 4/1/13.
//  Copyright (c) 2013-2015 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "BLIPConnection.h"
#import "BLIPConnection+Transport.h"
#import "BLIPRequest.h"
#import "BLIP_Internal.h"

#import "ExceptionUtils.h"
#import "MYData.h"
#import <objc/message.h>


DefineLogDomain(BLIP);
DefineLogDomain(BLIPLifecycle);


#define kDefaultFrameSize 4096


#if DEBUG
static char kQueueSpecificKey = 0;
#define OnTransportQueue() (dispatch_get_specific(&kQueueSpecificKey) == (void*)1)
#else
#define OnTransportQueue() YES
#endif


@interface BLIPConnection ()
@property (readwrite) BOOL active;
@end


@implementation BLIPConnection
{
    dispatch_queue_t _transportQueue;
    bool _transportIsOpen;
    NSError* _error;
    __weak id<BLIPConnectionDelegate> _delegate;
    dispatch_queue_t _delegateQueue;
    
    NSMutableArray *_outBox;            // Outgoing messages to be sent
    NSMutableArray *_iceBox;            // Outgoing messages paused pending acks
    BLIPMessage* _sendingMsg;           // Message currently being sent (popped from _outBox)
    uint32_t _numRequestsSent;

    uint32_t _numRequestsReceived;
    NSMutableDictionary *_pendingRequests, *_pendingResponses; // Messages being received
    NSUInteger _pendingDelegateCalls;
#if DEBUG
    NSUInteger _maxPendingDelegateCalls;
#endif
    NSMutableDictionary* _registeredActions;
}

@synthesize error=_error, dispatchPartialMessages=_dispatchPartialMessages, active=_active;
@synthesize delegate=_delegate, transportQueue=_transportQueue;


- (instancetype) initWithTransportQueue: (dispatch_queue_t)transportQueue
                                 isOpen: (BOOL)isOpen
{
    Assert(transportQueue);
    self = [super init];
    if (self) {
        _transportQueue = transportQueue;
        _transportIsOpen = isOpen;
#if DEBUG
        dispatch_queue_set_specific(_transportQueue, &kQueueSpecificKey, (void*)1, NULL);
#endif
        _delegateQueue = dispatch_get_main_queue();
        _pendingRequests = [[NSMutableDictionary alloc] init];
        _pendingResponses = [[NSMutableDictionary alloc] init];
    }
    return self;
}


// Public API
- (void) setDelegate: (id<BLIPConnectionDelegate>)delegate
               queue: (dispatch_queue_t)delegateQueue
{
    Assert(!_delegate, @"Don't change the delegate");
    _delegate = delegate;
    _delegateQueue = delegateQueue ?: dispatch_get_main_queue();
}


- (void) _onDelegateQueue: (void (^)())block {
    ++_pendingDelegateCalls;
#if DEBUG
    if (_pendingDelegateCalls > _maxPendingDelegateCalls) {
        LogTo(BLIP, @"New record: %lu pending delegate calls", (unsigned long)_pendingDelegateCalls);
        _maxPendingDelegateCalls = _pendingDelegateCalls;
    }
#endif
    dispatch_async(_delegateQueue, ^{
        block();
        [self _endDelegateCall];
    });
}


- (void) _callDelegate: (SEL)selector block: (void(^)(id<BLIPConnectionDelegate>))block {
    Assert(OnTransportQueue());
    id<BLIPConnectionDelegate> delegate = _delegate;
    if (delegate && [delegate respondsToSelector: selector]) {
        [self _onDelegateQueue: ^{
            block(delegate);
        }];
    }
}

- (void) _endDelegateCall {
    dispatch_async(_transportQueue, ^{
        if (--_pendingDelegateCalls == 0)
            [self updateActive];
    });
}


// Public API
- (NSURL*) URL {
    return nil; // Subclasses should override
}


- (void) updateActive {
    BOOL active = _outBox.count || _iceBox.count || _pendingRequests.count ||
                    _pendingResponses.count || _sendingMsg || _pendingDelegateCalls;
    if (active != _active) {
        LogVerbose(BLIP, @"%@ active = %@", self, (active ?@"YES" : @"NO"));
        self.active = active;
    }
}


#pragma mark - OPEN/CLOSE:


// Public API
- (BOOL) connect: (NSError**)outError {
    AssertAbstractMethod();
}

// Public API
- (void)close {
    AssertAbstractMethod();
}


- (void) _closeWithError: (NSError*)error {
    self.error = error;
    [self close];
}


// Subclasses call this
- (void) transportDidOpen {
    LogTo(BLIP, @"%@ is open!", self);
    _transportIsOpen = true;
    if (_outBox.count > 0)
        [self feedTransport]; // kick the queue to start sending

    [self _callDelegate: @selector(blipConnectionDidOpen:)
                  block: ^(id<BLIPConnectionDelegate> delegate) {
        [delegate blipConnectionDidOpen: self];
    }];
}


// Subclasses call this
- (void) transportDidCloseWithError:(NSError *)error {
    LogTo(BLIP, @"%@ closed with error %@", self, error.my_compactDescription);
    if (_transportIsOpen) {
        _transportIsOpen = NO;
        [self _callDelegate: @selector(blipConnection:didCloseWithError:)
                      block: ^(id<BLIPConnectionDelegate> delegate) {
                          [delegate blipConnection: self didCloseWithError: error];
                      }];
    } else {
        if (error && !_error)
            self.error = error;
        [self _callDelegate: @selector(blipConnection:didFailWithError:)
                      block: ^(id<BLIPConnectionDelegate> delegate) {
            [delegate blipConnection: self didFailWithError: error];
        }];
    }
}


#pragma mark - SENDING:


// Public API
- (BLIPRequest*) request {
    return [[BLIPRequest alloc] _initWithConnection: self body: nil properties: nil];
}

// Public API
- (BLIPRequest*) requestWithBody: (NSData*)body
                      properties: (NSDictionary*)properties
{
    return [[BLIPRequest alloc] _initWithConnection: self body: body properties: properties];
}

// Public API
- (BLIPResponse*) sendRequest: (BLIPRequest*)request {
    if (!request.isMine || request.sent) {
        // This was an incoming request that I'm being asked to forward or echo;
        // or it's an outgoing request being sent to multiple connections.
        // Since a particular BLIPRequest can only be sent once, make a copy of it to send:
        request = [request mutableCopy];
    }
    BLIPConnection* itsConnection = request.connection;
    if (itsConnection==nil)
        request.connection = self;
    else
        Assert(itsConnection==self,@"%@ is already assigned to a different connection",request);
    return [request send];
}


- (void) _queueMessage: (BLIPMessage*)msg isNew: (BOOL)isNew sendNow: (BOOL)sendNow {
    Assert(![_outBox containsObject: msg]);
    Assert(![_iceBox containsObject: msg]);
    Assert(msg != _sendingMsg);

    NSInteger n = _outBox.count, index;
    if (msg.urgent && n > 1) {
        // High-priority gets queued after the last existing high-priority message,
        // leaving one regular-priority message in between if possible.
        for (index=n-1; index>0; index--) {
            BLIPMessage *otherMsg = _outBox[index];
            if ([otherMsg urgent]) {
                index = MIN(index+2, n);
                break;
            } else if (isNew && otherMsg._bytesWritten==0) {
                // But have to keep message starts in order
                index = index+1;
                break;
            }
        }
        if (index==0)
            index = 1;
    } else {
        // Regular priority goes at the end of the queue:
        index = n;
    }
    if (! _outBox)
        _outBox = [[NSMutableArray alloc] init];
    [_outBox insertObject: msg atIndex: index];

    if (isNew)
        LogTo(BLIP,@"%@ queuing outgoing %@ at index %li",self,msg,(long)index);
    if (sendNow) {
        if (n==0 && _transportIsOpen) {
            dispatch_async(_transportQueue, ^{
                [self feedTransport];  // send the first message now
            });
        }
    }
    [self updateActive];
}


- (void) _pauseMessage: (BLIPMessage*)msg {
    Assert(![_outBox containsObject: msg]);
    Assert(![_iceBox containsObject: msg]);
    LogVerbose(BLIP, @"%@: Pausing %@", self, msg);
    if (!_iceBox)
        _iceBox = [NSMutableArray new];
    [_iceBox addObject: msg];
}


- (void) _unpauseMessage: (BLIPMessage*)msg {
    if (!_iceBox)
        return;
    NSUInteger index = [_iceBox indexOfObjectIdenticalTo: msg];
    if (index != NSNotFound) {
        Assert(![_outBox containsObject: msg]);
        LogVerbose(BLIP, @"%@: Resuming %@", self, msg);
        [_iceBox removeObjectAtIndex: index];
        if (msg != _sendingMsg)
            [self _queueMessage: msg isNew: NO sendNow: YES];
    }
}


// BLIPMessageSender protocol: Called from -[BLIPRequest send]
- (BOOL) _sendRequest: (BLIPRequest*)q response: (BLIPResponse*)response {
    Assert(!q.sent,@"message has already been sent");
    __block BOOL result;
    dispatch_sync(_transportQueue, ^{
        if (_transportIsOpen && !self.transportCanSend) {
            Warn(@"%@: Attempt to send a request after the connection has started closing: %@",self,q);
            result = NO;
            return;
        }
        [q _assignedNumber: ++_numRequestsSent];
        if (response) {
            [response _assignedNumber: _numRequestsSent];
            _pendingResponses[@(response.number)] = response;
            [self updateActive];
        }
        [self _queueMessage: q isNew: YES sendNow: YES];
        result = YES;
    });
    return result;
}

// Internal API: Called from -[BLIPResponse send]
- (BOOL) _sendResponse: (BLIPResponse*)response {
    Assert(!response.sent,@"message has already been sent");
    dispatch_async(_transportQueue, ^{
        [self _queueMessage: response isNew: YES sendNow: YES];
    });
    return YES;
}


// Subclasses call this
// Pull a frame from the outBox queue and send it to the transport:
- (void) feedTransport {
    if (_outBox.count > 0 && !_sendingMsg) {
        // Pop first message in queue:
        BLIPMessage *msg = _outBox[0];
        [_outBox removeObjectAtIndex: 0];
        _sendingMsg = msg;      // Remember that this message is being sent

        // As an optimization, allow message to send a big frame unless there's a higher-priority
        // message right behind it:
        size_t frameSize = kDefaultFrameSize;
        if (msg.urgent || _outBox.count==0 || ! [_outBox[0] urgent])
            frameSize *= 4;

        // Ask the message to generate its next frame. Do this on the delegate queue:
        __block BOOL moreComing;
        __block NSData* frame;
        dispatch_async(_delegateQueue, ^{
            frame = [msg nextFrameWithMaxSize: (uint16_t)frameSize moreComing: &moreComing];
            BOOL requeue = !msg._needsAckToContinue;
            void (^onSent)() = moreComing ? nil : msg.onSent;
            dispatch_async(_transportQueue, ^{
                // SHAZAM! Send the frame to the transport:
                if (frame)
                    [self sendFrame: frame];
                _sendingMsg = nil;

                if (moreComing) {
                    // add the message back so it can send its next frame later:
                    if (requeue)
                        [self _queueMessage: msg isNew: NO sendNow: NO];
                    else
                        [self _pauseMessage: msg];
                } else {
                    if (onSent)
                        [self _onDelegateQueue: onSent];
                }
                [self updateActive];
            });
        });
    } else {
        //LogVerbose(BLIP,@"%@: no more work for writer",self);
    }
}


- (BLIPMessage*) outgoingMessageWithNumber: (uint32_t)number isRequest: (BOOL)isRequest {
    for (BLIPMessage* msg in _outBox) {
        if (msg.number == number && msg.isRequest == isRequest)
            return msg;
    }
    for (BLIPMessage* msg in _iceBox) {
        if (msg.number == number && msg.isRequest == isRequest)
            return msg;
    }
    if (_sendingMsg.number == number && _sendingMsg.isRequest == isRequest)
        return _sendingMsg;
    return nil;
}


// Can be called from any queue.
- (void) _sendAckWithNumber: (uint32_t)number
                  isRequest: (BOOL)isRequest
              bytesReceived: (uint64_t)bytesReceived
{
    LogVerbose(BLIP, @"%@: Sending %s of %u (%llu bytes)",
          self, (isRequest ? "ACKMSG" : "ACKRPY"), number, bytesReceived);
    BLIPMessageFlags flags = (isRequest ?kBLIP_ACKMSG :kBLIP_ACKRPY) | kBLIP_Urgent | kBLIP_NoReply;
    char buf[3*10]; // max size of varint is 10 bytes
    void* pos = &buf[0];
    pos = MYEncodeVarUInt(pos, number);
    pos = MYEncodeVarUInt(pos, flags);
    pos = MYEncodeVarUInt(pos, bytesReceived);
    NSData* frame = [[NSData alloc] initWithBytes: &buf[0] length: ((char*)pos - &buf[0])];
    [self sendFrame: frame];
}


// Subclass must override.
- (BOOL) transportCanSend {
    AssertAbstractMethod();
}

// Subclass must override. Can be called from any queue.
- (void) sendFrame:(NSData *)frame {
    AssertAbstractMethod();
}


#pragma mark - RECEIVING FRAMES:


// Subclasses call this
- (void) didReceiveFrame:(NSData*)frame {
    const void* start = frame.bytes;
    const void* end = start + frame.length;
    uint64_t messageNum;
    const void* pos = MYDecodeVarUInt(start, end, &messageNum);
    if (pos) {
        uint64_t flags;
        pos = MYDecodeVarUInt(pos, end, &flags);
        if (pos && flags <= kBLIP_MaxFlag) {
            NSData* body = [NSData dataWithBytes: pos length: frame.length - (pos-start)];
            [self receivedFrameWithNumber: (uint32_t)messageNum
                                    flags: (BLIPMessageFlags)flags
                                     body: body];
            return;
        }
    }
    [self _closeWithError: BLIPMakeError(kBLIPError_BadFrame,
                                         @"Bad varint encoding in frame flags")];
}


- (void) receivedFrameWithNumber: (uint32_t)requestNumber
                           flags: (BLIPMessageFlags)flags
                            body: (NSData*)body
{
    static const char* kTypeStrs[8] = {"MSG","RPY","ERR","3??", "ACKMSG", "ACKRPY", "6??", "7??"};
    BLIPMessageType type = flags & kBLIP_TypeMask;
    LogVerbose(BLIP,@"%@ rcvd frame of %s #%u, length %lu",self,kTypeStrs[type],(unsigned int)requestNumber,(unsigned long)body.length);

    id key = @(requestNumber);
    BOOL complete = ! (flags & kBLIP_MoreComing);
    switch(type) {
        case kBLIP_MSG: {
            // Incoming request:
            BLIPRequest *request = _pendingRequests[key];
            if (request) {
                // Continuation frame of a request:
                if (complete) {
                    [_pendingRequests removeObjectForKey: key];
                }
            } else if (requestNumber == _numRequestsReceived+1) {
                // Next new request:
                request = [[BLIPRequest alloc] _initWithConnection: self
                                                            isMine: NO
                                                             flags: flags | kBLIP_MoreComing
                                                            number: requestNumber
                                                              body: nil];
                if (! complete)
                    _pendingRequests[key] = request;
                _numRequestsReceived++;
            } else {
                return [self _closeWithError: BLIPMakeError(kBLIPError_BadFrame, 
                                               @"Received bad request frame #%u (next is #%u)",
                                               (unsigned int)requestNumber,
                                               (unsigned)_numRequestsReceived+1)];
            }

            [self _receivedFrameWithFlags: flags body: body complete: complete forMessage: request];
            break;
        }
            
        case kBLIP_RPY:
        case kBLIP_ERR: {
            BLIPResponse *response = _pendingResponses[key];
            if (response) {
                if (complete) {
                    [_pendingResponses removeObjectForKey: key];
                }
                [self _receivedFrameWithFlags: flags body: body complete: complete forMessage: response];

            } else {
                if (requestNumber <= _numRequestsSent)
                    LogTo(BLIP,@"??? %@ got unexpected response frame to my msg #%u",
                          self,(unsigned int)requestNumber); //benign
                else
                    return [self _closeWithError: BLIPMakeError(kBLIPError_BadFrame, 
                                                          @"Bogus message number %u in response",
                                                          (unsigned int)requestNumber)];
            }
            break;
        }

        case kBLIP_ACKMSG:
        case kBLIP_ACKRPY: {
            BLIPMessage* msg = [self outgoingMessageWithNumber: requestNumber
                                                     isRequest: (type == kBLIP_ACKMSG)];
            if (!msg) {
                LogTo(BLIP, @"??? %@ Received ACK for non-current message (%s %u)",
                      self, kTypeStrs[type], requestNumber);
                break;
            }
            uint64_t bytesReceived;
            if (!MYDecodeVarUInt(body.bytes, body.bytes + body.length, &bytesReceived))
                return [self _closeWithError: BLIPMakeError(kBLIPError_BadFrame, @"Bad ACK body")];
            [self _onDelegateQueue: ^{
                BOOL ok = [msg _receivedAck: bytesReceived];
                dispatch_async(_transportQueue, ^{
                    if (ok)
                        [self _unpauseMessage: msg];
                    else
                        [self _closeWithError: BLIPMakeError(kBLIPError_BadFrame,@"Bad ACK count")];
                });
            }];
            break;
        }
            
        default:
            // To leave room for future expansion, undefined message types are just ignored.
            Log(@"??? %@ received header with unknown message type %i", self,type);
            break;
    }
    [self updateActive];
}


- (void) _receivedFrameWithFlags: (BLIPMessageFlags)flags
                            body: (NSData*)body
                        complete: (BOOL)complete
                      forMessage: (BLIPMessage*)message
{
   [self _onDelegateQueue: ^{
        BOOL ok = [message _receivedFrameWithFlags: flags body: body];
        if (!ok) {
            dispatch_async(_transportQueue, ^{
                [self _closeWithError: BLIPMakeError(kBLIPError_BadFrame,
                                                     @"Couldn't parse message frame")];
            });
        } else if (complete && !self.dispatchPartialMessages) {
            if (message.isRequest)
                [self _dispatchRequest: (BLIPRequest*)message];
            else
                [self _dispatchResponse: (BLIPResponse*)message];
        }
    }];
}


#pragma mark - REGISTERING ACTIONS:


- (void) onRequestProfile: (NSString*)profile sendDelegateAction: (SEL)action {
    [self _onDelegateQueue: ^{
        if (action) {
            Assert([_delegate respondsToSelector: action]);
            if (!_registeredActions)
                _registeredActions = [NSMutableDictionary new];
            _registeredActions[profile] = NSStringFromSelector(action);
        } else {
            [_registeredActions removeObjectForKey: profile];
        }
    }];
}

- (void) registerDelegateActions: (NSDictionary*)actions {
    [self _onDelegateQueue: ^{
        if (!_registeredActions)
            _registeredActions = [NSMutableDictionary new];
        [_registeredActions addEntriesFromDictionary: actions];
    }];
}


- (BOOL) _sendRegisteredAction: (BLIPRequest*)request {
    typedef void (*ActionMethodCall)(id self, SEL cmd, BLIPRequest* request);

    NSString* profile = request.profile;
    if (profile) {
        NSString* actionStr = _registeredActions[profile];
        if (actionStr) {
            SEL action = NSSelectorFromString(actionStr);
            // ARC-safe equivalent of [_delegate performSelector: action withObject: request] :
            ((ActionMethodCall)objc_msgSend)(_delegate, action, request);
            return YES;
        }
    }
    return NO;
}


#pragma mark - DISPATCHING:


// called on delegate queue
- (void) _messageReceivedProperties: (BLIPMessage*)message {
    if (self.dispatchPartialMessages) {
        if (message.isRequest)
            [self _dispatchRequest: (BLIPRequest*)message];
        else
            [self _dispatchResponse: (BLIPResponse*)message];
    }
}


// Called on the delegate queue (by _dispatchRequest)!
- (BOOL) _dispatchMetaRequest: (BLIPRequest*)request {
#if 0
    NSString* profile = request.profile;
    if ([profile isEqualToString: kBLIPProfile_Bye]) {
        [self _handleCloseRequest: request];
        return YES;
    }
#endif
    return NO;
}


// called on delegate queue
- (void) _dispatchRequest: (BLIPRequest*)request {
    id<BLIPConnectionDelegate> delegate = _delegate;
    LogTo(BLIP,@"Dispatching %@",request.descriptionWithProperties);
    @try{
        BOOL handled;
        if (request._flags & kBLIP_Meta)
            handled =[self _dispatchMetaRequest: request];
        else {
            handled = [self _sendRegisteredAction: request]
                      || ([delegate respondsToSelector: @selector(blipConnection:receivedRequest:)]
                          && [delegate blipConnection: self receivedRequest: request]);
        }

        if (request.complete) {
            if (!handled) {
                LogTo(BLIP,@"No handler found for incoming %@",request);
                [request respondWithErrorCode: kBLIPError_NotFound message: @"No handler was found"];
            } else if (! request.noReply && ! request.repliedTo) {
                LogTo(BLIP,@"Returning default empty response to %@",request);
                [request respondWithData: nil contentType: nil];
            }
        }
    }@catch( NSException *x ) {
        MYReportException(x,@"Dispatching BLIP request");
        [request respondWithException: x];
    }
}

// called on delegate queue
- (void) _dispatchResponse: (BLIPResponse*)response {
    LogTo(BLIP,@"Dispatching %@",response);
    // (Don't use _callDelegate:block: because I'm already on the delegate queue)
    id<BLIPConnectionDelegate> delegate = _delegate;
    if ([delegate respondsToSelector: @selector(blipConnection:receivedResponse:)])
        [delegate blipConnection: self receivedResponse: response];
}


@end
