#import <XCTest/XCTest.h>
#import "ADTRunner.h"

@interface ADTAuditRunner : ADTRunner
@property (nonatomic, copy) NSString *testDirectory;
@end
@implementation ADTAuditRunner
- (void)configureNotificationCenter {}
- (NSString *)documentsDirectory
{
    if (!self.testDirectory) {
        self.testDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:self.testDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return self.testDirectory;
}
@end

static XCTestExpectation *ADTFetchStarted;
@interface ADTAuditProtocol : NSURLProtocol
@end
@implementation ADTAuditProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqual:@"audit.invalid"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading
{
    [ADTFetchStarted fulfill];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:401 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]];
        [self.client URLProtocolDidFinishLoading:self];
    });
}
- (void)stopLoading {}
@end

@interface ADTRunnerTests : XCTestCase
@end
@implementation ADTRunnerTests
- (void)testJavaScriptFailureKeepsAnUploadableFailureReport
{
    ADTAuditRunner *runner = [[ADTAuditRunner alloc] init];
    NSString *runId = NSUUID.UUID.UUIDString;
    NSDictionary *bundle = @{@"manifest": @{@"kind": @"case", @"platform": @"ios",
        @"cases": @[@{@"id": @7, @"name": @"异常用例"}]}, @"runtime_js": @"// test",
        @"adapter_js": @"// test", @"main_js": @"throw new Error('audit failure')", @"case_files": @[]};
    NSDictionary *started = [runner startRun:@{@"run_id": runId, @"bundle": bundle, @"notify": @NO}];
    XCTAssertTrue([started[@"accepted"] boolValue]);
    XCTNSPredicateExpectation *finished = [[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) { return ![runner.status[@"running"] boolValue]; }]
        object:runner];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[finished] timeout:10], XCTWaiterResultCompleted);
    NSDictionary *report = [runner reportForRunId:runId];
    XCTAssertEqualObjects(report[@"run_id"], runId);
    XCTAssertEqualObjects(report[@"case_id"], @7);
    XCTAssertEqualObjects(report[@"notify"], @NO);
    XCTAssertEqualObjects(report[@"success"], @NO);
    XCTAssertTrue([report[@"cases"][0][@"steps"][0][@"error"] containsString:@"audit failure"]);
    [runner replaceSchedules:@{@"items": @[]}];
}

- (void)testExpiredFetchFromReplacedSchedulesDoesNotDisableNewSchedules
{
    [NSURLProtocol registerClass:ADTAuditProtocol.class];
    ADTAuditRunner *runner = [[ADTAuditRunner alloc] init];
    NSMutableDictionary *task = [@{@"id": @"old-task", @"name": @"旧任务", @"rule": @"interval",
        @"next_run": @(NSDate.date.timeIntervalSince1970 - 1), @"hour": @9, @"minute": @0,
        @"weekday": @2, @"interval": @60, @"server": @"http://audit.invalid", @"username": @"old",
        @"fetch_url": @"http://audit.invalid/script", @"token": @"old-token"} mutableCopy];
    ADTFetchStarted = [self expectationWithDescription:@"Old script fetch started"];
    XCTAssertNil([runner replaceSchedules:@{@"items": @[task]}][@"error"]);
    XCTAssertEqual([XCTWaiter waitForExpectations:@[ADTFetchStarted] timeout:5], XCTWaiterResultCompleted);
    task[@"id"] = @"new-task"; task[@"username"] = @"new"; task[@"token"] = @"new-token";
    task[@"next_run"] = @(NSDate.date.timeIntervalSince1970 + 3600);
    [runner replaceSchedules:@{@"items": @[task]}];
    XCTNSPredicateExpectation *finished = [[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
            return [runner.scheduleStatus[@"events"] count] && [runner.scheduleStatus[@"events"][0][@"finished"] boolValue];
        }] object:runner];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[finished] timeout:5], XCTWaiterResultCompleted);
    XCTAssertEqualObjects(runner.scheduleStatus[@"items"][0][@"id"], @"new-task");
    XCTAssertTrue([runner.scheduleStatus[@"items"][0][@"enabled"] boolValue]);
    [runner replaceSchedules:@{@"items": @[]}];
    [NSURLProtocol unregisterClass:ADTAuditProtocol.class];
    ADTFetchStarted = nil;
}

- (void)testScriptWithoutResultCannotSilentlyFinish
{
    ADTAuditRunner *runner = [[ADTAuditRunner alloc] init];
    NSString *runId = NSUUID.UUID.UUIDString;
    NSDictionary *bundle = @{@"manifest": @{@"kind": @"case", @"platform": @"ios",
        @"cases": @[@{@"id": @8, @"name": @"缺失结果"}]}, @"runtime_js": @"// test",
        @"adapter_js": @"// test", @"main_js": @"var incomplete = true;", @"case_files": @[]};
    [runner startRun:@{@"run_id": runId, @"bundle": bundle, @"notify": @NO}];
    XCTNSPredicateExpectation *finished = [[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) { return ![runner.status[@"running"] boolValue]; }]
        object:runner];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[finished] timeout:10], XCTWaiterResultCompleted);
    XCTAssertEqualObjects([runner reportForRunId:runId][@"success"], @NO);
    XCTAssertTrue([runner.status[@"last_result"][@"error"] containsString:@"未生成执行结果"]);
    [runner replaceSchedules:@{@"items": @[]}];
}
@end
