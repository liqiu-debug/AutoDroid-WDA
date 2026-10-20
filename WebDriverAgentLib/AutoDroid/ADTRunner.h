/**
 * AutoDroid-WDA 运行器
 *
 * 职责：接收平台下发的脚本包（与 Android 侧同一份 bundle 格式），在设备本机
 * 用 JavaScriptCore 执行 runtime.js，运行过程与结果经 runtime.js 自身回传平台。
 *
 * 端点见 ADTAutoDroidCommands（/autodroid/status|run|stop|logs）。
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ADTRunner : NSObject

+ (instancetype)shared;

/// 是否正在执行
@property (atomic, readonly) BOOL running;

/// 运行状态（供 /autodroid/status）
- (NSDictionary *)status;

/// 启动一次执行：请求体为平台下发的 bundle 与运行配置
/// 返回 @{@"accepted": BOOL, @"run_id": ..., @"error": ...}
- (NSDictionary *)startRun:(NSDictionary *)request;

/// 请求停止当前执行（在下一个原语调用处生效，尽力而为）
- (NSDictionary *)stopRun;

/// 增量读取运行日志
- (NSArray<NSString *> *)logsSince:(NSInteger)index;

/// Read a completed run's on-device report for UI display / retrying upload.
- (nullable NSDictionary *)reportForRunId:(NSString *)runId;

- (NSDictionary *)scheduleStatus;
- (NSDictionary *)replaceSchedules:(NSDictionary *)request;
- (NSDictionary *)notificationStatus:(BOOL)requestPermission;

@end

NS_ASSUME_NONNULL_END
