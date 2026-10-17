/**
 * AutoDroid-WDA HTTP 端点
 *
 *   GET  /autodroid/status          运行状态与最近一次结果
 *   POST /autodroid/run             下发脚本包并开始执行（body 见 ADTRunner.startRun）
 *   POST /autodroid/stop            请求停止当前执行
 *   GET  /autodroid/logs?since=N    增量读取运行日志
 *
 * 这些端点不带 WDA session，平台可以直接把它们当作「设备端执行器」的接口使用。
 */

#import <Foundation/Foundation.h>

#import "FBCommandHandler.h"

NS_ASSUME_NONNULL_BEGIN

@interface ADTAutoDroidCommands : NSObject <FBCommandHandler>
@end

NS_ASSUME_NONNULL_END
