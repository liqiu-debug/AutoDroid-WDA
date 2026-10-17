/**
 * AutoDroid-WDA 图像工具
 *
 * 为 runtime.js 的 images.* / ocr.* 提供 iOS 实现：
 *   - 图像句柄注册表（JS 侧只持有 {__h, width, height}）；
 *   - 基础操作：读取/裁剪/缩放/灰度/JPEG Base64；
 *   - 模板匹配：盒式滤波 + 归一化互相关（NCC），对齐 PC 侧 TM_CCOEFF_NORMED 语义；
 *   - SSIM：同套局部均值/方差统计；
 *   - OCR：Vision 框架（VNRecognizeTextRequest，中英文）。
 *
 * 坐标约定：全部使用「截图像素」。若匹配前为控制耗时做了降采样，结果会换算回原图坐标。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ADTImageTools : NSObject

/// 注册一张图，返回句柄 id（JS 侧用它引用图片）
+ (NSInteger)registerImage:(UIImage *)image;
+ (nullable UIImage *)imageForHandle:(NSInteger)handle;
+ (CGSize)pixelSizeForHandle:(NSInteger)handle;
+ (void)releaseHandle:(NSInteger)handle;
+ (void)resetHandles;

/// 灰度图（8 位）→ UIImage
+ (nullable UIImage *)grayscaleImage:(UIImage *)image;
/// 裁剪（像素坐标）
+ (nullable UIImage *)clipImage:(UIImage *)image x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width height:(CGFloat)height;
/// 缩放（比例）
+ (nullable UIImage *)scaleImage:(UIImage *)image sx:(CGFloat)sx sy:(CGFloat)sy;
/// JPEG/PNG Base64
+ (nullable NSString *)base64FromImage:(UIImage *)image format:(NSString *)format quality:(CGFloat)quality;

/// 多尺度模板匹配见 packager 侧 runtime.js；此处只做单尺度 NCC。
/// 返回 @{@"similarity": double, @"x": double, @"y": double, @"width": double, @"height": double} 或 nil
+ (nullable NSDictionary *)matchTemplate:(UIImage *)screenshot template:(UIImage *)template threshold:(CGFloat)threshold;

/// 结构相似度（灰度，8x8 窗口）
+ (CGFloat)ssimBetween:(UIImage *)a second:(UIImage *)b;

/// OCR：返回识别到的文本行
+ (NSArray<NSString *> *)recognizeText:(UIImage *)image;

@end

/// 灰度图像缓冲（float，行优先），图像运算内部使用
typedef struct {
    NSInteger width;
    NSInteger height;
    float *data;   // width * height
} ADTGrayBuffer;

@interface ADTImageTools (Private)

+ (BOOL)fillGrayBuffer:(ADTGrayBuffer *)buffer fromImage:(UIImage *)image;
+ (void)freeGrayBuffer:(ADTGrayBuffer *)buffer;

@end

NS_ASSUME_NONNULL_END
