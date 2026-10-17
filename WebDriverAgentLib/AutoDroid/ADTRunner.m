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

#import <JavaScriptCore/JavaScriptCore.h>

static NSString *const ADTRunnerDefaultAdapterName = @"adapter";
static NSString *const ADTRunnerRunsDirectoryName = @"autodroid_runs";

@interface ADTRunner ()
@property (atomic, assign) BOOL running;
@property (nonatomic, copy, nullable) NSString *currentRunId;
@property (nonatomic, strong, nullable) NSDictionary *lastResult;
@property (nonatomic, strong) NSMutableArray<NSString *> *logs;
@property (nonatomic, strong) NSLock *logLock;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (atomic, assign) BOOL stopRequested;
@property (nonatomic, strong) ADTPrimitives *primitives;
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
    }
    return self;
}

#pragma mark - 状态与日志

- (NSDictionary *)status
{
    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    status[@"running"] = @(self.running);
    status[@"run_id"] = self.currentRunId ?: [NSNull null];
    status[@"stop_requested"] = @(self.stopRequested);
    status[@"last_result"] = self.lastResult ?: [NSNull null];
    status[@"version"] = @"autodroid-wda/1";
    [self.logLock lock];
    status[@"log_count"] = @(self.logs.count);
    [self.logLock unlock];
    return status;
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
    if (self.running) {
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

- (void)executeWork:(NSDictionary *)work
{
    NSString *runId = work[@"run_id"];
    NSDictionary *request = work[@"request"];
    NSDictionary *bundle = work[@"bundle"];
    NSDictionary *manifest = bundle[@"manifest"];
    NSString *mainSource = [bundle[@"main_js"] isKindOfClass:NSString.class] ? bundle[@"main_js"] : nil;
    NSDictionary *result = nil;

    @try {
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
        context.exceptionHandler = ^(JSContext *jsContext, JSValue *exception) {
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

        JSValue *resultValue = context[@"__AUTODROID_RESULT__"];
        if (resultValue != nil && !resultValue.isUndefined && !resultValue.isNull) {
            result = [resultValue toObject];
        }
        JSValue *exception = context.exception;
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
    summary[@"run_id"] = runId;
    summary[@"finished_at"] = @((long long)(NSDate.date.timeIntervalSince1970 * 1000));
    self.lastResult = summary;
    self.running = NO;
    [self appendLog:[NSString stringWithFormat:@"[runner] 执行结束: %@", [summary description]]];
}

#pragma mark - 运行目录

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
    NSDictionary *caseFiles = bundle[@"case_files"];
    if ([caseFiles isKindOfClass:NSDictionary.class]) {
        for (NSString *relativePath in caseFiles) {
            NSString *source = caseFiles[relativePath];
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
