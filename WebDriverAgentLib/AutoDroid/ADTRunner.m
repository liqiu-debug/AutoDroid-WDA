/**
 * AutoDroid-WDA 运行器实现
 *
 * 执行流程：
 *   1. 把平台下发的 bundle 落盘到 Documents/autodroid_runs/<run_id>/（manifest.json、
 *      runtime.js、main.js、cases/*、assets/*），与 Android 侧脚本包结构一致；
 *   2. 在专用串行队列上建 JSContext，注入原生原语（__adt）与适配层 adapter.js；
 *   3. 执行 main.js → runtime.js 逐步执行并在结束时写入 report.json 并回传平台；
 *   4. 读取 global.__AUTODROID_RESULT__ 作为本次运行的摘要。
 *
 * 之所以用串行队列而非 WDA 的 HTTP 处理线程：一次执行可能持续几分钟，
 * 不能占用 HTTP 线程，否则 /autodroid/status 之类查询会一起被阻塞。
 */

#import "ADTRunner.h"
#import "ADTPrimitives.h"
#import "ADTImageTools.h"
#import <XCTest/XCTest.h>

#import <JavaScriptCore/JavaScriptCore.h>
#import <UserNotifications/UserNotifications.h>

static NSString *const ADTRunnerDefaultAdapterName = @"adapter";
static NSString *const ADTRunnerRunsDirectoryName = @"autodroid_runs";

@interface ADTRunner () <UNUserNotificationCenterDelegate>
@property (atomic, assign) BOOL running;
@property (nonatomic, copy, nullable) NSString *currentRunId;
@property (nonatomic, strong, nullable) NSDictionary *lastResult;
@property (nonatomic, strong) NSMutableArray<NSString *> *logs;
@property (nonatomic, strong) NSLock *logLock;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (atomic, assign) BOOL stopRequested;
@property (nonatomic, strong) ADTPrimitives *primitives;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *schedules;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *scheduleEvents;
@property (nonatomic, strong) dispatch_source_t scheduleTimer;
@property (nonatomic, copy) NSString *schedulerInstance;
@property (nonatomic, copy) NSString *notificationPermission;
@property (nonatomic, assign) BOOL requestingNotificationPermission;
@property (nonatomic, assign) NSUInteger scheduleRevision;
@property (nonatomic, assign) BOOL fetchingSchedule;
@end

@implementation ADTRunner

+ (instancetype)shared
{
    static ADTRunner *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ADTRunner alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _logs = [NSMutableArray array];
        _logLock = [[NSLock alloc] init];
        _workQueue = dispatch_queue_create("com.autodroid.wda.runner", DISPATCH_QUEUE_SERIAL);
        _schedules = [NSMutableArray array];
        _scheduleEvents = [NSMutableArray array];
        _schedulerInstance = NSUUID.UUID.UUIDString;
        _notificationPermission = @"尚未授权";
        NSString *statePath = [[self documentsDirectory] stringByAppendingPathComponent:@"autodroid_scheduler.json"];
        NSData *stateData = [NSData dataWithContentsOfFile:statePath];
        NSDictionary *state = stateData ? [NSJSONSerialization JSONObjectWithData:stateData options:NSJSONReadingMutableContainers error:NULL] : nil;
        if ([state[@"items"] isKindOfClass:NSArray.class]) { _schedules = [state[@"items"] mutableCopy]; }
        if ([state[@"events"] isKindOfClass:NSArray.class]) {
            _scheduleEvents = [state[@"events"] mutableCopy];
            for (NSMutableDictionary *event in _scheduleEvents) {
                if (![event[@"finished"] boolValue]) {
                    event[@"finished"] = @YES;
                    NSDictionary *report = [self reportForRunId:event[@"run_id"]];
                    event[@"result"] = report ? @{@"success": report[@"success"] ?: @NO, @"upload_ok": @NO}
                        : @{@"error": @"执行器重启，本次结果未知", @"script_fetch_failed": @YES};
                }
            }
        }
        [self configureNotificationCenter];
        _scheduleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(_scheduleTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_scheduleTimer, ^{ [weakSelf tickSchedules]; });
        dispatch_resume(_scheduleTimer);
    }
    return self;
}

- (void)configureNotificationCenter
{
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
}

#pragma mark - 状态与日志

- (NSDictionary *)status
{
  @synchronized (self) {
    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    status[@"running"] = @((BOOL)(self.running || self.fetchingSchedule));
    status[@"run_id"] = self.currentRunId ?: [NSNull null];
    status[@"stop_requested"] = @(self.stopRequested);
    status[@"last_result"] = self.lastResult ?: [NSNull null];
    status[@"version"] = @"autodroid-wda/1";
    [self.logLock lock];
    status[@"log_count"] = @(self.logs.count);
    [self.logLock unlock];
    return status;
  }
}

- (NSArray<NSString *> *)logsSince:(NSInteger)index
{
    [self.logLock lock];
    NSArray<NSString *> *snapshot = [self.logs copy];
    [self.logLock unlock];
    if (index < 0) {
        index = 0;
    }
    if (index >= (NSInteger)snapshot.count) {
        return @[];
    }
    return [snapshot subarrayWithRange:NSMakeRange((NSUInteger)index, snapshot.count - (NSUInteger)index)];
}

- (void)appendLog:(NSString *)line
{
    [self.logLock lock];
    [self.logs addObject:line];
    if (self.logs.count > 6000) {
        [self.logs removeObjectsInRange:NSMakeRange(0, 2000)];
    }
    [self.logLock unlock];
}

- (BOOL)isSafeRunId:(NSString *)runId
{
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    return [runId isKindOfClass:NSString.class] && runId.length > 0 && runId.length <= 128
        && [runId rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

- (NSDictionary *)reportForRunId:(NSString *)runId
{
    if (![self isSafeRunId:runId]) { return nil; }
    NSString *root = [[self documentsDirectory] stringByAppendingPathComponent:ADTRunnerRunsDirectoryName];
    NSString *path = [[root stringByAppendingPathComponent:runId] stringByAppendingPathComponent:@"report.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) { return nil; }
    id report = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [report isKindOfClass:NSDictionary.class] ? report : nil;
}

- (NSDictionary *)stopRun
{
    if (!self.running) {
        return @{@"stopped": @NO, @"message": @"当前没有正在执行的脚本"};
    }
    self.stopRequested = YES;
    [self appendLog:@"[runner] 收到停止请求，将在下一个动作前中止"];
    return @{@"stopped": @YES};
}

#pragma mark - 启动执行

- (NSDictionary *)startRun:(NSDictionary *)request
{
  @synchronized (self) {
    if (self.running || self.fetchingSchedule) {
        return @{@"accepted": @NO, @"error": [NSString stringWithFormat:@"已有执行在进行中: %@", self.currentRunId ?: @""]};
    }
    NSDictionary *bundle = request[@"bundle"];
    if (![bundle isKindOfClass:NSDictionary.class]) {
        return @{@"accepted": @NO, @"error": @"缺少 bundle"};
    }
    NSDictionary *manifest = bundle[@"manifest"];
    NSString *runtimeSource = bundle[@"runtime_js"];
    NSString *mainSource = bundle[@"main_js"];
    if (![manifest isKindOfClass:NSDictionary.class] || ![runtimeSource isKindOfClass:NSString.class]
        || ![mainSource isKindOfClass:NSString.class]) {
        return @{@"accepted": @NO, @"error": @"bundle 缺少 manifest/runtime_js/main_js"};
    }

    NSString *runId = [request[@"run_id"] isKindOfClass:NSString.class] ? request[@"run_id"] : nil;
    if (runId.length == 0) {
        runId = [NSString stringWithFormat:@"run-%lld", (long long)(NSDate.date.timeIntervalSince1970 * 1000)];
    }
    if (![self isSafeRunId:runId]) {
        return @{@"accepted": @NO, @"error": @"run_id 格式不合法"};
    }
    self.running = YES;
    self.stopRequested = NO;
    self.currentRunId = runId;
    self.lastResult = nil;
    [self.logLock lock];
    [self.logs removeAllObjects];
    [self.logLock unlock];

    NSDictionary *work = @{@"run_id": runId, @"request": request, @"bundle": bundle};
    dispatch_async(self.workQueue, ^{
        [self executeWork:work];
    });
    return @{@"accepted": @YES, @"run_id": runId};
  }
}

- (void)executeWork:(NSDictionary *)work
{
    NSString *runId = work[@"run_id"];
    NSDictionary *request = work[@"request"];
    NSDictionary *bundle = work[@"bundle"];
    NSDictionary *manifest = bundle[@"manifest"];
    NSString *mainSource = [bundle[@"main_js"] isKindOfClass:NSString.class] ? bundle[@"main_js"] : nil;
    NSDictionary *result = nil;
    NSNumber *startedAt = @(NSDate.date.timeIntervalSince1970 * 1000);

    @try {
        [ADTImageTools resetHandles];
        if (mainSource.length == 0) {
            @throw [NSException exceptionWithName:@"ADTRunnerError" reason:@"bundle 缺少 main_js" userInfo:nil];
        }
        NSString *baseDir = [self prepareRunDirectory:runId bundle:bundle];
        [self appendLog:[NSString stringWithFormat:@"[runner] 运行目录: %@", baseDir]];

        ADTPrimitives *primitives = [[ADTPrimitives alloc] init];
        primitives.runBaseDir = baseDir;
        NSString *targetBundleId = [request[@"target_bundle_id"] isKindOfClass:NSString.class] ? request[@"target_bundle_id"] : nil;
        if (targetBundleId.length > 0) {
            primitives.activeBundleID = targetBundleId;
        }
        NSString *deviceSerial = [request[@"device_serial"] isKindOfClass:NSString.class] ? request[@"device_serial"] : nil;
        primitives.deviceSerial = deviceSerial;
        primitives.logHandler = ^(NSString *level, NSString *message) {
            [self appendLog:[NSString stringWithFormat:@"[%@] %@", level, message]];
        };
        self.primitives = primitives;

        JSContext *context = [[JSContext alloc] init];
        context[@"__adt"] = primitives;
        __weak typeof(self) weakSelf = self;
        context[@"__AUTODROID_SHOULD_STOP__"] = ^BOOL {
            return weakSelf.stopRequested;
        };
        context.exceptionHandler = ^(JSContext *jsContext, JSValue *exception) {
            jsContext.exception = exception;
            [weakSelf appendLog:[NSString stringWithFormat:@"[js-error] %@", exception.toString]];
        };

        // 运行配置：runtime.js 会优先读 global.__AUTODROID__
        NSMutableDictionary *runtimeConfig = [NSMutableDictionary dictionary];
        runtimeConfig[@"baseDir"] = baseDir;
        runtimeConfig[@"runId"] = runId;
        if ([request[@"server"] isKindOfClass:NSString.class]) {
            runtimeConfig[@"server"] = request[@"server"];
        }
        if ([request[@"token"] isKindOfClass:NSString.class]) {
            runtimeConfig[@"token"] = request[@"token"];
        }
        if (request[@"notify"] != nil) {
            runtimeConfig[@"notify"] = request[@"notify"];
        }
        // 目标平台固定为 ios：runtime.js 据此裁剪 execute_on 不匹配的步骤
        runtimeConfig[@"platform"] = @"ios";
        NSData *configData = [NSJSONSerialization dataWithJSONObject:runtimeConfig options:0 error:NULL];
        NSString *configJson = configData != nil ? [[NSString alloc] initWithData:configData encoding:NSUTF8StringEncoding] : @"{}";
        [context evaluateScript:[NSString stringWithFormat:@"globalThis.__AUTODROID__ = %@;", configJson]];

        // 适配层优先取脚本包里的 adapter_js（平台随包下发，改适配层无需重装 WDA）
        NSString *adapterSource = [bundle[@"adapter_js"] isKindOfClass:NSString.class] ? bundle[@"adapter_js"] : nil;
        if (adapterSource.length == 0) {
            adapterSource = [self adapterSource];
        }
        if (adapterSource.length == 0) {
            @throw [NSException exceptionWithName:@"ADTRunnerError"
                                           reason:@"脚本包缺少 adapter_js（平台需下发 iOS 适配层，或改用内置适配层构建）"
                                         userInfo:nil];
        }
        // 落盘便于排查（运行目录里保留本次实际使用的适配层）
        [adapterSource writeToFile:[baseDir stringByAppendingPathComponent:@"adapter.js"]
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:NULL];
        [context evaluateScript:adapterSource];
        if (context.exception != nil) {
            @throw [NSException exceptionWithName:@"ADTRunnerError"
                                           reason:[NSString stringWithFormat:@"适配层加载失败: %@", context.exception.toString]
                                         userInfo:nil];
        }

        NSString *mainPath = [baseDir stringByAppendingPathComponent:@"main.js"];
        [self appendLog:[NSString stringWithFormat:@"[runner] 开始执行 main.js（kind=%@）", manifest[@"kind"] ?: @"?"]];
        [context evaluateScript:mainSource withSourceURL:[NSURL fileURLWithPath:mainPath]];

        JSValue *exception = context.exception;
        JSValue *resultValue = context[@"__AUTODROID_RESULT__"];
        if (resultValue != nil && !resultValue.isUndefined && !resultValue.isNull) {
            result = [resultValue toObject];
        }
        if (exception != nil && !exception.isNull && !exception.isUndefined) {
            result = @{@"upload_ok": @NO, @"error": [exception toString] ?: @"未知 JS 异常"};
            [self appendLog:[NSString stringWithFormat:@"[runner] 执行异常: %@", [exception toString]]];
        }
    } @catch (NSException *exception) {
        result = @{@"error": exception.reason ?: exception.name};
        [self appendLog:[NSString stringWithFormat:@"[runner] 执行失败: %@", exception.reason ?: exception.name]];
    }

    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    if ([result isKindOfClass:NSDictionary.class]) {
        [summary addEntriesFromDictionary:result];
    }
    if (!summary.count) { summary[@"error"] = @"脚本结束但未生成执行结果"; }
    if (summary[@"error"] && ![self reportForRunId:runId]) {
        // Native preparation/JavaScript exceptions can happen before runtime.js
        // writes a report. Keep a normal failure payload so the client can retry
        // uploading it instead of losing this run from the platform entirely.
        summary[@"success"] = @NO;
        summary[@"upload_ok"] = @NO;
        NSMutableArray *cases = [NSMutableArray array];
        for (NSDictionary *entry in manifest[@"cases"]) {
            [cases addObject:@{@"case_id": entry[@"id"] ?: NSNull.null,
                @"name": entry[@"name"] ?: @"用例", @"alias": entry[@"alias"] ?: NSNull.null,
                @"success": @NO, @"steps": @[@{@"order": @0, @"action": @"system", @"status": @"FAIL",
                    @"error": summary[@"error"], @"error_code": @"E2999_EXECUTION_ERROR"}]}];
        }
        NSDictionary *report = @{@"run_id": runId, @"platform": @"ios", @"format_version": @1,
            @"kind": manifest[@"kind"] ?: @"case", @"scenario_id": manifest[@"scenario_id"] ?: NSNull.null,
            @"case_id": [manifest[@"kind"] isEqual:@"case"] && cases.count ? (cases.firstObject[@"case_id"] ?: NSNull.null) : NSNull.null,
            @"device": @{@"serial": request[@"device_serial"] ?: @"", @"brand": @"Apple"},
            @"notify": request[@"notify"] ?: @YES, @"success": @NO, @"started_at": startedAt,
            @"finished_at": @(NSDate.date.timeIntervalSince1970 * 1000), @"cases": cases, @"logs": [self logsSince:0]};
        NSString *directory = [[[self documentsDirectory] stringByAppendingPathComponent:ADTRunnerRunsDirectoryName]
                              stringByAppendingPathComponent:runId];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];
        [data writeToFile:[directory stringByAppendingPathComponent:@"report.json"] atomically:YES];
    }
    summary[@"run_id"] = runId;
    summary[@"finished_at"] = @((long long)(NSDate.date.timeIntervalSince1970 * 1000));
    if ([request[@"system_notify"] boolValue]) { [self notifyCompletion:summary request:request]; }
    @synchronized (self) {
        self.lastResult = summary;
        for (NSMutableDictionary *event in self.scheduleEvents) {
            if ([event[@"run_id"] isEqual:runId]) {
                event[@"finished"] = @YES; event[@"result"] = summary;
                event[@"logs"] = [self logsSince:0];
            }
        }
        self.running = NO;
        [self persistScheduler];
    }
    [self appendLog:[NSString stringWithFormat:@"[runner] 执行结束: %@", [summary description]]];
    [ADTImageTools resetHandles];
    [self returnToClient:request];
}

- (void)returnToClient:(NSDictionary *)request
{
    // Activate the client only after results are durable. The client, not WDA,
    // owns permission, notification deduplication and the notification's identity.
    if (![request[@"notify_app"] boolValue]) { return; }
    NSString *bundleId = request[@"completion_bundle_id"];
    if (![bundleId isKindOfClass:NSString.class] || ![bundleId isEqual:@"com.liuzhenyu.autodroid.ios"]) { return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [[[XCUIApplication alloc] initWithBundleIdentifier:bundleId] activate]; }
        @catch (NSException *exception) { [self appendLog:@"[notification] 无法返回 AutoDroid，打开 App 后补发通知"]; }
    });
}

#pragma mark - 运行目录

- (NSDictionary *)notificationStatus:(BOOL)requestPermission
{
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    if (requestPermission) {
        @synchronized (self) { self.requestingNotificationPermission = YES; }
        [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge
                             completionHandler:^(BOOL granted, NSError *error) {
            @synchronized (self) {
                self.notificationPermission = granted ? @"已允许" : (error.localizedDescription ?: @"未允许，请在系统设置中开启");
                self.requestingNotificationPermission = NO;
            }
        }];
    }
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        @synchronized (self) {
            self.notificationPermission = settings.authorizationStatus == UNAuthorizationStatusAuthorized || settings.authorizationStatus == UNAuthorizationStatusProvisional ? @"已允许" : @"未允许，请开启通知权限";
        }
    }];
    @synchronized (self) { return @{@"status": self.notificationPermission, @"pending": @(self.requestingNotificationPermission)}; }
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
        withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler
{
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionList);
}

- (void)notifyCompletion:(NSDictionary *)result request:(NSDictionary *)request
{
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [result[@"success"] boolValue] ? @"AutoDroid · 执行成功" : @"AutoDroid · 执行失败";
    if ([result[@"aborted"] boolValue]) { content.title = @"AutoDroid · 已停止"; }
    content.body = request[@"name"] ?: @"任务已结束，打开 AutoDroid 查看报告。";
    content.sound = UNNotificationSound.defaultSound;
    NSString *identifier = result[@"run_id"] ?: NSUUID.UUID.UUIDString;
    UNNotificationRequest *notification = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:notification withCompletionHandler:^(NSError *error) {
        if (error) { [self appendLog:[@"[notification] " stringByAppendingString:error.localizedDescription]]; }
    }];
}

- (NSDictionary *)scheduleStatus
{
    @synchronized (self) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSDictionary *item in self.schedules) {
            [items addObject:@{@"id": item[@"id"], @"next_run": item[@"next_run"], @"enabled": item[@"enabled"]}];
        }
        // Deliberately exclude credentials and executable bundles from status responses.
        return @{@"instance": self.schedulerInstance, @"items": items, @"events": [[NSArray alloc] initWithArray:self.scheduleEvents copyItems:YES]};
    }
}

- (void)persistScheduler
{
    // Persist only safe metadata; access tokens live in memory until logout/restart.
    NSDictionary *state = [self scheduleStatus];
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:NULL];
    [data writeToFile:[[self documentsDirectory] stringByAppendingPathComponent:@"autodroid_scheduler.json"] atomically:YES];
}

- (NSDictionary *)replaceSchedules:(NSDictionary *)request
{
    NSArray *items = request[@"items"];
    if (![items isKindOfClass:NSArray.class] || items.count > 100) { return @{@"error": @"定时任务格式无效或超过 100 条"}; }
    NSMutableArray *validated = [NSMutableArray array];
    NSMutableSet *identifiers = [NSMutableSet set];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:NSDictionary.class]) { return @{@"error": @"任务格式无效"}; }
        NSURL *url = [item[@"fetch_url"] isKindOfClass:NSString.class] ? [NSURL URLWithString:item[@"fetch_url"]] : nil;
        if (![self isSafeRunId:item[@"id"]] || [identifiers containsObject:item[@"id"]]
            || url == nil || ![@[@"http", @"https"] containsObject:url.scheme ?: @""] || url.host.length == 0
            || ![item[@"token"] isKindOfClass:NSString.class] || [item[@"token"] length] == 0
            || ![item[@"server"] isKindOfClass:NSString.class] || ![item[@"username"] isKindOfClass:NSString.class]
            || ![@[@"once", @"daily", @"weekly", @"interval"] containsObject:item[@"rule"]]
            || ![item[@"next_run"] isKindOfClass:NSNumber.class]
            || ![item[@"hour"] isKindOfClass:NSNumber.class] || [item[@"hour"] integerValue] < 0 || [item[@"hour"] integerValue] > 23
            || ![item[@"minute"] isKindOfClass:NSNumber.class] || [item[@"minute"] integerValue] < 0 || [item[@"minute"] integerValue] > 59
            || ![item[@"weekday"] isKindOfClass:NSNumber.class] || [item[@"weekday"] integerValue] < 1 || [item[@"weekday"] integerValue] > 7
            || ![item[@"interval"] isKindOfClass:NSNumber.class] || [item[@"interval"] doubleValue] < 60) {
            return @{@"error": @"定时任务缺少有效目标、凭据或时间参数"};
        }
        [identifiers addObject:item[@"id"]];
        NSMutableDictionary *copy = [item mutableCopy]; copy[@"enabled"] = @YES;
        [validated addObject:copy];
    }
    @synchronized (self) {
        self.scheduleRevision += 1; self.schedules = validated;
        [self persistScheduler];
        return [self scheduleStatus];
    }
}

- (void)advanceSchedule:(NSMutableDictionary *)item now:(NSDate *)now
{
    NSString *rule = item[@"rule"];
    if ([rule isEqual:@"once"]) { item[@"enabled"] = @NO; return; }
    NSDate *next;
    if ([rule isEqual:@"interval"]) { next = [now dateByAddingTimeInterval:MAX(60, [item[@"interval"] doubleValue])]; }
    else {
        NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        calendar.timeZone = [NSTimeZone timeZoneWithName:item[@"timezone"] ?: @""] ?: NSTimeZone.localTimeZone;
        NSDateComponents *components = [[NSDateComponents alloc] init];
        components.hour = [item[@"hour"] integerValue]; components.minute = [item[@"minute"] integerValue]; components.second = 0;
        if ([rule isEqual:@"weekly"]) { components.weekday = [item[@"weekday"] integerValue]; }
        next = [calendar nextDateAfterDate:now matchingComponents:components options:NSCalendarMatchNextTime];
    }
    item[@"next_run"] = @(next.timeIntervalSince1970);
}

- (void)tickSchedules
{
    @synchronized (self) {
        if (self.running || self.fetchingSchedule) { return; }
        NSDate *now = NSDate.date;
        for (NSMutableDictionary *item in self.schedules) {
            if (![item[@"enabled"] boolValue] || ![item[@"token"] length] || [item[@"next_run"] doubleValue] > now.timeIntervalSince1970) { continue; }
            [self advanceSchedule:item now:now];
            self.fetchingSchedule = YES;
            NSUInteger revision = self.scheduleRevision;
            NSDictionary *task = [item copy];
            NSMutableDictionary *event = [@{@"run_id": NSUUID.UUID.UUIDString, @"name": task[@"name"] ?: @"定时任务",
                @"server": task[@"server"], @"username": task[@"username"], @"started_at": @(now.timeIntervalSince1970), @"finished": @NO,
                @"notify_app": @([task[@"notify_app"] boolValue])} mutableCopy];
            [self.scheduleEvents addObject:event];
            if (self.scheduleEvents.count > 100) { [self.scheduleEvents removeObjectAtIndex:0]; }
            [self persistScheduler];
            NSMutableURLRequest *fetch = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:task[@"fetch_url"]]
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
            [fetch setValue:[@"Bearer " stringByAppendingString:task[@"token"]] forHTTPHeaderField:@"Authorization"];
            [[NSURLSession.sharedSession dataTaskWithRequest:fetch completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    @synchronized (self) {
                        self.fetchingSchedule = NO;
                        NSString *failure = nil;
                        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
                        NSDictionary *bundle = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                        if (revision != self.scheduleRevision) { failure = @"任务已修改或取消，未执行"; }
                        else if (error || status != 200) { failure = [NSString stringWithFormat:@"获取最新脚本失败（HTTP %ld）：%@", (long)status, error.localizedDescription ?: @"请检查平台和登录状态"]; }
                        else if (![bundle isKindOfClass:NSDictionary.class] || ![bundle[@"manifest"] isKindOfClass:NSDictionary.class] || ![bundle[@"precheck"] isKindOfClass:NSDictionary.class]
                                 || ![bundle[@"precheck"][@"ok"] boolValue] || ![bundle[@"manifest"][@"platform"] isEqual:@"ios"]
                                 || ![bundle[@"format_version"] isEqual:@1] || ![bundle[@"adapter_js"] isKindOfClass:NSString.class]) {
                            failure = @"最新脚本预检失败，已取消本次执行";
                        }
                        if (!failure) {
                            NSMutableDictionary *run = [task mutableCopy]; run[@"bundle"] = bundle; run[@"run_id"] = event[@"run_id"];
                            NSDictionary *accepted = [self startRun:run];
                            if (![accepted[@"accepted"] boolValue]) { failure = accepted[@"error"] ?: @"执行器未接受任务"; }
                        }
                        if (failure) {
                            NSDictionary *result = @{@"run_id": event[@"run_id"], @"success": @NO, @"error": failure, @"script_fetch_failed": @YES};
                            event[@"finished"] = @YES; event[@"result"] = result; event[@"logs"] = @[failure];
                            if ([task[@"system_notify"] boolValue]) { [self notifyCompletion:result request:task]; }
                            [self returnToClient:task];
                            if (status == 401 && revision == self.scheduleRevision) {
                                for (NSMutableDictionary *pending in self.schedules) { pending[@"enabled"] = @NO; [pending removeObjectForKey:@"token"]; }
                            }
                        }
                        [self persistScheduler];
                    }
                });
            }] resume];
            break;
        }
    }
}

- (NSString *)documentsDirectory
{
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

- (NSString *)prepareRunDirectory:(NSString *)runId bundle:(NSDictionary *)bundle
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *root = [[self documentsDirectory] stringByAppendingPathComponent:ADTRunnerRunsDirectoryName];
    [fileManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
    // 只保留最近 10 次运行，避免长期运行撑爆沙箱
    [self pruneRunsRoot:root keep:10];
    NSString *baseDir = [root stringByAppendingPathComponent:runId];
    [fileManager createDirectoryAtPath:baseDir withIntermediateDirectories:YES attributes:nil error:NULL];

    NSDictionary *manifest = bundle[@"manifest"];
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:NULL];
    if (manifestData != nil) {
        [manifestData writeToFile:[baseDir stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
    }
    NSString *runtimeSource = bundle[@"runtime_js"];
    if ([runtimeSource isKindOfClass:NSString.class]) {
        [runtimeSource writeToFile:[baseDir stringByAppendingPathComponent:@"runtime.js"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    NSString *mainSource = bundle[@"main_js"];
    if ([mainSource isKindOfClass:NSString.class]) {
        [mainSource writeToFile:[baseDir stringByAppendingPathComponent:@"main.js"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    // Platform packages use [{path, content}]; accept the older path -> source form too.
    id caseFiles = bundle[@"case_files"];
    NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
    if ([caseFiles isKindOfClass:NSArray.class]) {
        [files addObjectsFromArray:caseFiles];
    } else if ([caseFiles isKindOfClass:NSDictionary.class]) {
        for (NSString *path in caseFiles) {
            [files addObject:@{@"path": path, @"content": caseFiles[path]}];
        }
    }
    for (id file in files) {
        if ([file isKindOfClass:NSDictionary.class]) {
            NSString *relativePath = file[@"path"];
            NSString *source = file[@"content"];
            if (![relativePath isKindOfClass:NSString.class] || relativePath.length == 0
                || relativePath.isAbsolutePath || [relativePath.pathComponents containsObject:@".."]
                || [relativePath containsString:@"\\"]) {
                @throw [NSException exceptionWithName:@"ADTRunnerError" reason:@"脚本包包含非法文件路径" userInfo:nil];
            }
            if (![source isKindOfClass:NSString.class]) {
                continue;
            }
            NSString *fullPath = [baseDir stringByAppendingPathComponent:relativePath];
            [fileManager createDirectoryAtPath:[fullPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
            [source writeToFile:fullPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
    }
    NSDictionary *assets = bundle[@"assets"];
    if ([assets isKindOfClass:NSDictionary.class]) {
        NSString *assetsDir = [baseDir stringByAppendingPathComponent:@"assets"];
        [fileManager createDirectoryAtPath:assetsDir withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSString *assetName in assets) {
            if (assetName.isAbsolutePath || [assetName.pathComponents containsObject:@".."]
                || [assetName containsString:@"\\"]) {
                @throw [NSException exceptionWithName:@"ADTRunnerError" reason:@"资源包包含非法文件路径" userInfo:nil];
            }
            NSString *base64 = assets[assetName];
            if (![base64 isKindOfClass:NSString.class]) {
                continue;
            }
            NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (data == nil) {
                continue;
            }
            NSString *fullPath = [assetsDir stringByAppendingPathComponent:assetName];
            [fileManager createDirectoryAtPath:[fullPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
            [data writeToFile:fullPath atomically:YES];
        }
    }
    return baseDir;
}

- (void)pruneRunsRoot:(NSString *)root keep:(NSInteger)keep
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:root error:NULL] ?: @[];
    NSMutableArray<NSDictionary *> *directories = [NSMutableArray array];
    for (NSString *entry in entries) {
        NSString *fullPath = [root stringByAppendingPathComponent:entry];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory] || !isDirectory) {
            continue;
        }
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:fullPath error:NULL];
        NSDate *modified = attributes[NSFileModificationDate] ?: NSDate.distantPast;
        [directories addObject:@{@"path": fullPath, @"modified": modified}];
    }
    if ((NSInteger)directories.count <= keep) {
        return;
    }
    [directories sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
        return [rhs[@"modified"] compare:lhs[@"modified"]];
    }];
    for (NSInteger i = keep; i < (NSInteger)directories.count; i++) {
        [fileManager removeItemAtPath:directories[(NSUInteger)i][@"path"] error:NULL];
    }
}

#pragma mark - 适配层资源

/// 内置兜底适配层（正常路径由脚本包下发的 adapter_js 提供；此处仅在资源存在时生效）
- (NSString *)adapterSource
{
    NSBundle *bundle = [NSBundle bundleForClass:ADTRunner.class];
    NSString *path = [bundle pathForResource:ADTRunnerDefaultAdapterName ofType:@"js"];
    if (path == nil) {
        // 兼容资源被拷进主 bundle 的情况
        path = [NSBundle.mainBundle pathForResource:ADTRunnerDefaultAdapterName ofType:@"js"];
    }
    if (path == nil) {
        return nil;
    }
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
}

@end
