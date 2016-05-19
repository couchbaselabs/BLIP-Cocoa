//
//  BLIPHTTPLogic.h
//  BLIP
//
//  Created by Jens Alfke on 11/13/13.
//  Copyright (c) 2013-2015 Couchbase, Inc. All rights reserved.

#import <Foundation/Foundation.h>


/** Implements the core logic of HTTP request/response handling, especially processing
    redirects and authentication challenges, without actually doing any of the networking.
    It just tells you what HTTP request to send and how to interpret the response. */
@interface BLIPHTTPLogic : NSObject

- (instancetype) initWithURLRequest:(NSURLRequest *)request;

- (void) setValue: (NSString*)value forHTTPHeaderField:(NSString*)header;
- (void) setObject: (NSString*)value forKeyedSubscript: (NSString*)key;

/** Set this to YES to handle redirects.
    If enabled, redirects are handled by updating the URL and setting shouldRetry. */
@property BOOL handleRedirects;

@property (readonly) NSURLRequest* URLRequest;

/** Creates an HTTP request message to send. Caller is responsible for releasing it. */
- (CFHTTPMessageRef) newHTTPRequest;

/** Call this when a response is received, then check shouldContinue and shouldRetry. */
- (void) receivedResponse: (CFHTTPMessageRef)response;

/** After a response is received, this will be YES if the HTTP status indicates success. */
@property (readonly) BOOL shouldContinue;

/** After a response is received, this will be YES if the client needs to retry with a new
    request. If so, it should call -createHTTPRequest again to get the new request, which will
    have either a different URL or new authentication headers. */
@property (readonly) BOOL shouldRetry;

/** The URL. This will change after receiving a redirect response. */
@property (readonly) NSURL* URL;

/** The TCP port number, based on the URL. */
@property (readonly) UInt16 port;

/** Yes if TLS/SSL should be used (based on the URL). */
@property (readonly) BOOL useTLS;

/** The auth credential being used. */
@property (readwrite) NSURLCredential* credential;

/** A default User-Agent header string that will be used if the URLRequest doesn't contain one.
    You can use this as the basis for your own by appending to it. */
+ (NSString*) userAgent;

/** The HTTP status code of the response. */
@property (readonly) int httpStatus;

/** The error from a failed redirect or authentication. This isn't set for regular non-success
    HTTP statuses like 404, only for failures to redirect or authenticate. */
@property (readonly) NSError* error;

/** Parses the value of a "WWW-Authenticate" header into a dictionary. In the dictionary, the key
    "WWW-Authenticate" will contain the entire header, "Scheme" will contain the scheme (the first
    word), and the first parameter and value will appear as an extra key/value. (Only the first
    parameter is parsed; this could be improved.) */
+ (NSDictionary*) parseAuthHeader: (NSString*)authHeader;

@end
