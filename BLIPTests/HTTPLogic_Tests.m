//
//  HTTPLogic_Tests.m
//  BLIP
//
//  Created by Jens Alfke on 6/30/15.
//  Copyright © 2015 Couchbase, Inc. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "BLIPHTTPLogic.h"


@interface HTTPLogic_Tests : XCTestCase
@end


@implementation HTTPLogic_Tests
{
    NSURLRequest* request;
    BLIPHTTPLogic* logic;
}

- (void)setUp {
    [super setUp];
    request = [NSURLRequest requestWithURL: [NSURL URLWithString: @"http://example.com/foo/"]];
    logic = [[BLIPHTTPLogic alloc] initWithURLRequest: request];
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (CFHTTPMessageRef) respond: (int)status headers: (NSDictionary*)headers {
    CFHTTPMessageRef r = CFHTTPMessageCreateResponse(NULL, status, CFSTR("Unauthorized"),
                                                     kCFHTTPVersion1_1);
    for (NSString* key in headers)
        CFHTTPMessageSetHeaderFieldValue(r, (__bridge CFStringRef)key,
                                         (__bridge CFStringRef)headers[key]);
    CFAutorelease(r);
    return r;
}

- (void)testRequest {
    logic[@"X-Foo"] = @"bar";
    NSURLRequest* r = logic.URLRequest;
    XCTAssertEqualObjects(r.URL, request.URL);
    XCTAssertEqualObjects(r.HTTPMethod, request.HTTPMethod);
    XCTAssertEqualObjects(r.allHTTPHeaderFields[@"X-Foo"], @"bar");
    XCTAssertEqual(logic.port, 80);
    XCTAssertFalse(logic.useTLS);
    XCTAssertNil(logic.credential);
}

- (void) testOKResponse {
    [logic receivedResponse: [self respond: 200 headers: @{}]];
    XCTAssertTrue(logic.shouldContinue);
    XCTAssertFalse(logic.shouldRetry);
    XCTAssertEqual(logic.httpStatus, 200);
}

- (void) testNotFoundResponse {
    [logic receivedResponse: [self respond: 404 headers: @{}]];
    XCTAssertFalse(logic.shouldContinue);
    XCTAssertFalse(logic.shouldRetry);
    XCTAssertEqual(logic.httpStatus, 404);
}

- (void) testRedirects {
    NSString* loc = @"http://couchbase.com/";
    int retry;
    for (retry=1; retry <= 100; retry++) {
        [logic receivedResponse: [self respond: 302 headers: @{@"Location": loc}]];
        XCTAssertFalse(logic.shouldContinue);
        if (!logic.shouldRetry)
            break;
        XCTAssertEqual(logic.httpStatus, 302);
        XCTAssertEqualObjects(logic.URL, [NSURL URLWithString: loc]);
        request = logic.URLRequest;
        XCTAssertEqualObjects(request.URL, [NSURL URLWithString: loc]);
        loc = [loc stringByAppendingString: @"x"];
    }
    XCTAssertGreaterThan(retry, 10);
    XCTAssertLessThan(retry, 100);
    XCTAssertNotNil(logic.error);
}

- (void) testBasicAuth {
    NSURLCredential* cred = [NSURLCredential credentialWithUser: @"bob" password: @"123456" persistence: NSURLCredentialPersistenceNone];
    logic.credential = cred;
    NSURLRequest* r = logic.URLRequest;
    XCTAssertNil(r.allHTTPHeaderFields[@"Authorization"]);

    [logic receivedResponse: [self respond: 401 headers: @{@"WWW-Authenticate": @"Basic realm=\"slack\""}]];
    XCTAssertFalse(logic.shouldContinue);
    XCTAssertTrue(logic.shouldRetry);
    XCTAssertEqualObjects(logic.URLRequest.allHTTPHeaderFields[@"Authorization"], @"Basic Ym9iOjEyMzQ1Ng==");

    [logic receivedResponse: [self respond: 401 headers: @{@"WWW-Authenticate": @"Basic realm=\"slack\""}]];
    XCTAssertFalse(logic.shouldContinue);
    XCTAssertFalse(logic.shouldRetry);
    XCTAssertNotNil(logic.error);
}

- (void) testDigestAuth {
    NSURLCredential* cred = [NSURLCredential credentialWithUser: @"bob" password: @"123456" persistence: NSURLCredentialPersistenceNone];
    logic.credential = cred;
    NSURLRequest* r = logic.URLRequest;
    XCTAssertNil(r.allHTTPHeaderFields[@"Authorization"]);

    [logic receivedResponse: [self respond: 401 headers: @{@"WWW-Authenticate": @"Digest realm=\"testrealm@example.com\", qop=\"auth,auth-int\", nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""}]];
    XCTAssertFalse(logic.shouldContinue);
    XCTAssertTrue(logic.shouldRetry);
    XCTAssertEqualObjects(logic.URLRequest.allHTTPHeaderFields[@"Authorization"], @"Digest username=\"Mufasa\", realm=\"testrealm@host.com\", nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", uri=\"/dir/index.html\", response=\"e966c932a9242554e42c8ee200cec7f6\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"");

    [logic receivedResponse: [self respond: 401 headers: @{@"WWW-Authenticate": @"Basic realm=\"slack\""}]];
    XCTAssertFalse(logic.shouldContinue);
    XCTAssertFalse(logic.shouldRetry);
    XCTAssertNotNil(logic.error);
}

@end
