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
    [[FBRoute POST:@"/autodroid/report"].withoutSession respondWithTarget:self action:@selector(handleReport:)],
    [[FBRoute GET:@"/autodroid/schedules"].withoutSession respondWithTarget:self action:@selector(handleSchedules:)],
    [[FBRoute POST:@"/autodroid/schedules"].withoutSession respondWithTarget:self action:@selector(handleReplaceSchedules:)],
    [[FBRoute GET:@"/autodroid/notifications"].withoutSession respondWithTarget:self action:@selector(handleNotifications:)],
    [[FBRoute POST:@"/autodroid/notifications"].withoutSession respondWithTarget:self action:@selector(handleRequestNotifications:)],
  ];
}

+ (id<FBResponsePayload>)handleStatus:(FBRouteRequest *)request
{
  return FBResponseWithObject([[ADTRunner shared] status]);
}

+ (id<FBResponsePayload>)handleSchedules:(FBRouteRequest *)request
{
  return FBResponseWithObject([[ADTRunner shared] scheduleStatus]);
}
+ (id<FBResponsePayload>)handleReplaceSchedules:(FBRouteRequest *)request
{
  NSDictionary *result = [[ADTRunner shared] replaceSchedules:request.arguments ?: @{}];
  if (result[@"error"]) { return FBResponseWithUnknownErrorFormat(@"%@", result[@"error"]); }
  return FBResponseWithObject(result);
}
+ (id<FBResponsePayload>)handleNotifications:(FBRouteRequest *)request
{
  return FBResponseWithObject([[ADTRunner shared] notificationStatus:NO]);
}
+ (id<FBResponsePayload>)handleRequestNotifications:(FBRouteRequest *)request
{
  return FBResponseWithObject([[ADTRunner shared] notificationStatus:YES]);
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

+ (id<FBResponsePayload>)handleReport:(FBRouteRequest *)request
{
  NSString *runId = request.arguments[@"run_id"];
  NSDictionary *report = [[ADTRunner shared] reportForRunId:runId];
  return FBResponseWithObject(@{@"found": @((BOOL)(report != nil)), @"report": report ?: (id)NSNull.null});
}

@end
