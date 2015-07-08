//
//  BLIPPocketSocketListener.h
//  BLIP
//
//  Created by Jens Alfke on 4/11/15.
//  Copyright (c) 2015 Couchbase. All rights reserved.

#import "BLIPPocketSocketConnection.h"


@interface BLIPPocketSocketListener : NSObject

- (instancetype) initWithPaths: (NSArray*)paths
                      delegate: (id<BLIPConnectionDelegate>)delegate
                         queue: (dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;

- (instancetype) init NS_UNAVAILABLE;

/** Starts the listener.
    @param interface  The name of the network interface, or nil to listen on all interfaces
        (See the GCDAsyncSocket documentation for more details.)
    @param port  The TCP port to listen on.
    @param certs  SSL identity and supporting certificates, or nil to not use SSL
    @param error  On return, will be filled in with an error if the method returned NO.
    @return  YES on success, NO on failure. */
- (BOOL) acceptOnInterface: (NSString*)interface
                      port: (uint16_t)port
           SSLCertificates: (NSArray*)certs
                     error: (NSError**)error;

/** Stops the listener from accepting any more connections. */
- (void) disconnect;

@property (readonly) uint16_t port;

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

- (BOOL) checkClientCertificateAuthentication: (SecTrustRef)trust
                                  fromAddress: (NSData*)address;

@end


@interface BLIPPocketSocketConnection (Incoming)
@property (readonly) NSURLCredential* credential;
@end
