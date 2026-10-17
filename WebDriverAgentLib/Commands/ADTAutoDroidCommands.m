/**
 * AutoDroid-WDA HTTP 端点实现
 */

#import "ADTAutoDroidCommands.h"

#import "ADTRunner.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBResponsePayload.h"

@implementation ADTAutoDroidCommands

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/autodroid/status"].withoutSession respondWithTarget:self action:@selector(handleStatus:)],
    [[FBRoute POST:@"/autodroid/run"].withoutSession respondWithTarget:self action:@selector(handleRun:)],
    [[FBRoute POST:@"/autodroid/stop"].withoutSession respondWithTarget:self action:@selector(handleStop:)],
    [[FBRoute GET:@"/autodroid/logs"].withoutSession respondWithTarget:self action:@selector(handleLogs:)],
  ];
}

+ (id<FBResponsePayload>)handleStatus:(FBRouteRequest *)request
{
  return FBResponseWithObject([[ADTRunner shared] status]);
}

+ (id<FBResponsePayload>)handleRun:(FBRouteRequest *)request
{
  NSDictionary *result = [[ADTRunner shared] startRun:request.arguments ?: @{}];
  if (![result[@"accepted"] boolValue]) {
    return FBResponseWithUnknownErrorFormat(@"%@", result[@"error"] ?: @"启动失败");
  }
  return FBResponseWithObject(result);
}

+ (id<FBResponsePayload>)handleStop:(FBRouteRequest *)request
{
  return FBResponseWithObject([[ADTRunner shared] stopRun]);
}

+ (id<FBResponsePayload>)handleLogs:(FBRouteRequest *)request
{
  NSInteger since = [request.arguments[@"since"] integerValue] ?: 0;
  NSArray<NSString *> *lines = [[ADTRunner shared] logsSince:since];
  return FBResponseWithObject(@{@"lines": lines, @"next": @(since + (NSInteger)lines.count)});
}

@end
