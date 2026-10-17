/**
 * AutoDroid-WDA 原生原语（JavaScriptCore ↔ XCTest 桥）
 *
 * 这里只提供「最小原语」，AutoJs6 风格的 API 表面由 autodroid/adapter.js 用 JS 实现，
 * 好处是兼容层可读、可单测，且 runtime.js 完全不需要改。
 *
 * 坐标：JS 侧统一使用截图像素；所有涉及坐标的原语在这里按 scale 换算为点（point）。
 */

#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ADTPrimitivesExport <JSExport>

#pragma mark 日志与等待
JSExportAs(log, - (void)jsLog:(NSString *)level message:(NSString *)message);
JSExportAs(sleep, - (void)jsSleep:(double)milliseconds);

#pragma mark 设备信息与截图
- (NSDictionary *)deviceInfo;
- (nullable NSDictionary *)screenshot;

#pragma mark 图像
- (nullable NSDictionary *)imageFromFile:(NSString *)path;
- (nullable NSDictionary *)imageFromBase64:(NSString *)base64;
- (nullable NSDictionary *)imageGrayscale:(double)handle;
JSExportAs(imageClip, - (nullable NSDictionary *)jsImageClip:(double)handle x:(double)x y:(double)y width:(double)width height:(double)height);
JSExportAs(imageScale, - (nullable NSDictionary *)jsImageScale:(double)handle sx:(double)sx sy:(double)sy);
JSExportAs(imageToBase64, - (NSString *)jsImageToBase64:(double)handle format:(NSString *)format quality:(double)quality);
JSExportAs(imageSave, - (BOOL)jsImageSave:(double)handle path:(NSString *)path overwrite:(BOOL)overwrite);
- (void)releaseImage:(double)handle;
JSExportAs(matchTemplate, - (nullable NSDictionary *)jsMatchTemplate:(double)shotHandle template:(double)templateHandle threshold:(double)threshold max:(double)maxCount);
JSExportAs(ssim, - (double)jsSsim:(double)firstHandle second:(double)secondHandle);
- (NSArray<NSString *> *)ocr:(double)handle;

#pragma mark 元素
- (NSArray<NSNumber *> *)findElements:(NSString *)specJson;
JSExportAs(elementAttribute, - (NSString *)jsElementAttribute:(double)elementId name:(NSString *)name);
- (nullable NSDictionary *)elementRect:(double)elementId;
- (BOOL)elementClick:(double)elementId;
- (BOOL)elementLongClick:(double)elementId;
JSExportAs(elementSetText, - (BOOL)jsElementSetText:(double)elementId text:(NSString *)text);
- (NSArray<NSDictionary *> *)sourceNodes;

#pragma mark 手势与系统
JSExportAs(tap, - (BOOL)jsTap:(double)x y:(double)y);
JSExportAs(longPress, - (BOOL)jsLongPress:(double)x y:(double)y duration:(double)duration);
JSExportAs(drag, - (BOOL)jsDrag:(double)x1 y1:(double)y1 x2:(double)x2 y2:(double)y2 duration:(double)duration);
- (BOOL)pressBack;
- (BOOL)pressHome;
- (NSString *)activeApp;
- (BOOL)launchApp:(NSString *)bundleId;
- (BOOL)terminateApp:(NSString *)bundleId;

#pragma mark 输入
- (BOOL)typeText:(NSString *)text;

#pragma mark 网络与文件
JSExportAs(httpRequest, - (NSDictionary *)jsHttpRequest:(NSString *)method url:(NSString *)url body:(nullable NSString *)body headers:(nullable NSString *)headersJson timeout:(double)timeoutMs);
- (BOOL)fsExists:(NSString *)path;
- (NSString *)fsRead:(NSString *)path;
JSExportAs(fsWrite, - (BOOL)jsFsWrite:(NSString *)path content:(NSString *)content);
JSExportAs(fsAppend, - (BOOL)jsFsAppend:(NSString *)path content:(NSString *)content);
JSExportAs(fsWriteBytes, - (BOOL)jsFsWriteBytes:(NSString *)path base64:(nullable NSString *)base64);
- (BOOL)fsEnsureDir:(NSString *)path;
- (BOOL)fsRemove:(NSString *)path;
- (BOOL)fsIsFile:(NSString *)path;
- (BOOL)fsIsDir:(NSString *)path;
- (NSArray<NSString *> *)fsListDir:(NSString *)path;
- (NSString *)fsJoin:(NSArray *)components;
- (NSString *)baseDir;

@end

@interface ADTPrimitives : NSObject <ADTPrimitivesExport>

/// 本次运行目录（runtime.js 的 baseDir，也是 files.* 的根）
@property (nonatomic, copy, nullable) NSString *runBaseDir;
/// 平台要求自动化的目标应用 bundle id（start_app 之前为空，回退到前台应用）
@property (nonatomic, copy, nullable) NSString *activeBundleID;
/// 设备序列号（平台下发，用于上报时的 device.serial）
@property (nonatomic, copy, nullable) NSString *deviceSerial;
/// 运行日志回调（写入 runner 的日志缓冲）
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *level, NSString *message);

@end

NS_ASSUME_NONNULL_END
