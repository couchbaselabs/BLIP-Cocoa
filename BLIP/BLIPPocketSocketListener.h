//
//  BLIPPocketSocketListener.h
//  BLIP
//
//  Created by Jens Alfke on 4/11/15.
//  Copyright (c) 2015 Couchbase. All rights reserved.

#import "BLIPPocketSocketConnection.h"


@interface BLIPPocketSocketListener : NSObject

- (instancetype) initWithPath: (NSString*)path
                     delegate: (id<BLIPConnectionDelegate>)delegate
                        queue: (dispatch_queue_t)queue;

/** Starts the listener.
    @param interface  The name of the network interface, or nil to listen on all interfaces
        (See the GCDAsyncSocket documentation for more details.)
    @param port  The TCP port to listen on.
    @param error  On return, will be filled in with an error if the method returned NO.
    @return  YES on success, NO on failure. */
- (BOOL) acceptOnInterface: (NSString*)interface
                      port: (uint16_t)port
                     error: (NSError**)error;

/** Stops the listener from accepting any more connections. */
- (void) disconnect;

#pragma mark - AUTHENTICATION:

/** Security realm string to return in authentication challenges. */
@property (copy) NSString* realm;

/** Sets user names and passwords for authentication.
    @param passwords  A dictionary mapping user names to passwords. */
- (void) setPasswords: (NSDictionary*)passwords;

#pragma mark - PROTECTED:

- (void) listenerDidStart;
- (void) listenerDidStop;
- (void) listenerDidFailWithError: (NSError*)error;

- (void)blipConnectionDidOpen:(BLIPConnection*)b;

+ (BOOL) fromRequest: (NSURLRequest*)request
         getUsername: (NSString**)outUser
            password: (NSString**)outPassword;

@end


@interface BLIPPocketSocketConnection (Incoming)
@property (readonly) NSURLCredential* credential;
@end
