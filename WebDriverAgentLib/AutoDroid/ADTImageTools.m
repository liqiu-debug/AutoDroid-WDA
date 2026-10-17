/**
 * AutoDroid-WDA 图像工具实现
 *
 * 模板匹配策略（与 PC 侧 TM_CCOEFF_NORMED 语义对齐，但避免全图逐点卷积的高开销）：
 *   1) 粗筛：把截图与模板按整数因子降采样到最长边 ≤ 240，用积分图 + 滑窗互相关
 *      在粗分辨率上找出若干个候选位置；
 *   2) 精修：把候选位置映射回全分辨率，在其邻域内用全分辨率模板精确计算 NCC。
 * 局部均值/方差统一由积分图（I 与 I²）O(1) 得到，保证归一化项精确。
 */

#import "ADTImageTools.h"

#import <Vision/Vision.h>

static NSMutableDictionary<NSNumber *, UIImage *> *gImageHandles;
static NSInteger gNextImageHandle = 1;
static NSLock *gImageLock;

/// 粗筛目标分辨率（截图最长边降到此值）
static const NSInteger ADTCoarseMaxDimension = 240;
/// 精修候选数量
static const NSInteger ADTCandidateCount = 6;

typedef struct {
    double *sum;
    double *sum2;
    NSInteger width;
    NSInteger height;
} ADTIntegralImage;

static inline void ADTFreeIntegral(ADTIntegralImage *image) {
    free(image->sum);
    free(image->sum2);
    image->sum = NULL;
    image->sum2 = NULL;
}

static BOOL ADTBuildIntegral(const ADTGrayBuffer *buffer, ADTIntegralImage *outImage) {
    if (buffer->width <= 0 || buffer->height <= 0 || buffer->data == NULL) {
        return NO;
    }
    NSInteger w = buffer->width;
    NSInteger h = buffer->height;
    NSInteger stride = w + 1;
    double *sum = calloc((size_t)(stride * (h + 1)), sizeof(double));
    double *sum2 = calloc((size_t)(stride * (h + 1)), sizeof(double));
    if (sum == NULL || sum2 == NULL) {
        free(sum);
        free(sum2);
        return NO;
    }
    for (NSInteger y = 0; y < h; y++) {
        double rowSum = 0.0;
        double rowSum2 = 0.0;
        const float *row = buffer->data + y * w;
        double *sumRow = sum + (y + 1) * stride;
        double *sum2Row = sum2 + (y + 1) * stride;
        const double *prevSumRow = sum + y * stride;
        const double *prevSum2Row = sum2 + y * stride;
        for (NSInteger x = 0; x < w; x++) {
            double value = (double)row[x];
            rowSum += value;
            rowSum2 += value * value;
            sumRow[x + 1] = prevSumRow[x + 1] + rowSum;
            sum2Row[x + 1] = prevSum2Row[x + 1] + rowSum2;
        }
    }
    outImage->sum = sum;
    outImage->sum2 = sum2;
    outImage->width = w;
    outImage->height = h;
    return YES;
}

/// 矩形区域（左闭右开）内灰度之和
static inline double ADTIntegralRectSum(const double *integral, NSInteger stride, NSInteger x, NSInteger y, NSInteger w, NSInteger h) {
    const double *top = integral + y * stride;
    const double *bottom = integral + (y + h) * stride;
    return bottom[x + w] - bottom[x] - top[x + w] + top[x];
}

/// 用整数因子做块平均降采样
static BOOL ADTDownsample(const ADTGrayBuffer *src, NSInteger factor, ADTGrayBuffer *dst) {
    if (factor <= 1) {
        return NO;
    }
    NSInteger w = src->width / factor;
    NSInteger h = src->height / factor;
    if (w < 2 || h < 2) {
        return NO;
    }
    float *data = malloc((size_t)(w * h) * sizeof(float));
    if (data == NULL) {
        return NO;
    }
    double inv = 1.0 / (double)(factor * factor);
    for (NSInteger y = 0; y < h; y++) {
        for (NSInteger x = 0; x < w; x++) {
            double acc = 0.0;
            for (NSInteger dy = 0; dy < factor; dy++) {
                const float *row = src->data + (y * factor + dy) * src->width + x * factor;
                for (NSInteger dx = 0; dx < factor; dx++) {
                    acc += row[dx];
                }
            }
            data[y * w + x] = (float)(acc * inv);
        }
    }
    dst->width = w;
    dst->height = h;
    dst->data = data;
    return YES;
}

/// 在给定分辨率上计算 NCC 的最大值（返回相似度与左上角坐标，坐标为该分辨率的像素）
static BOOL ADTBestNCCOffset(const ADTGrayBuffer *shot,
                             const ADTGrayBuffer *tpl,
                             const ADTIntegralImage *shotSum,
                             const ADTIntegralImage *shotSum2,
                             NSInteger searchX0, NSInteger searchY0,
                             NSInteger searchX1, NSInteger searchY1,
                             double *outScore, NSInteger *outX, NSInteger *outY) {
    NSInteger tw = tpl->width;
    NSInteger th = tpl->height;
    NSInteger sw = shot->width;
    NSInteger sh = shot->height;
    if (tw <= 0 || th <= 0 || tw > sw || th > sh) {
        return NO;
    }
    NSInteger maxX = sw - tw;
    NSInteger maxY = sh - th;
    NSInteger startX = MAX(0, searchX0);
    NSInteger startY = MAX(0, searchY0);
    NSInteger endX = MIN(maxX, searchX1);
    NSInteger endY = MIN(maxY, searchY1);
    if (startX > endX || startY > endY) {
        return NO;
    }

    double n = (double)(tw * th);
    double tplSum = 0.0;
    double tplSum2 = 0.0;
    for (NSInteger y = 0; y < th; y++) {
        const float *row = tpl->data + y * tw;
        for (NSInteger x = 0; x < tw; x++) {
            double value = (double)row[x];
            tplSum += value;
            tplSum2 += value * value;
        }
    }
    double tplMean = tplSum / n;
    double tplVar = tplSum2 - n * tplMean * tplMean;
    if (tplVar <= 1e-6) {
        return NO;   // 模板无纹理，无法可靠匹配
    }
    double tplStd = sqrt(tplVar);

    NSInteger stride = shotSum->width + 1;
    double bestScore = -2.0;
    NSInteger bestX = -1;
    NSInteger bestY = -1;

    for (NSInteger y = startY; y <= endY; y++) {
        for (NSInteger x = startX; x <= endX; x++) {
            double sumI = ADTIntegralRectSum(shotSum->sum, stride, x, y, tw, th);
            double sumI2 = ADTIntegralRectSum(shotSum2->sum, stride, x, y, tw, th);
            double varI = sumI2 - sumI * sumI / n;
            if (varI <= 1e-6) {
                continue;
            }
            double cross = 0.0;
            for (NSInteger ty = 0; ty < th; ty++) {
                const float *shotRow = shot->data + (y + ty) * sw + x;
                const float *tplRow = tpl->data + ty * tw;
                for (NSInteger tx = 0; tx < tw; tx++) {
                    cross += (double)shotRow[tx] * (double)tplRow[tx];
                }
            }
            double score = (cross - sumI * tplMean) / (tplStd * sqrt(varI));
            if (score > bestScore) {
                bestScore = score;
                bestX = x;
                bestY = y;
            }
        }
    }
    if (bestX < 0) {
        return NO;
    }
    *outScore = bestScore;
    *outX = bestX;
    *outY = bestY;
    return YES;
}

/// 粗筛：返回候选左上角坐标（粗分辨率），按相似度降序
static NSArray<NSValue *> *ADTCoarseCandidates(const ADTGrayBuffer *shotC,
                                               const ADTGrayBuffer *tplC,
                                               const ADTIntegralImage *shotSum,
                                               const ADTIntegralImage *shotSum2,
                                               NSDictionary<NSNumber *, NSNumber *> **outScores) {
    NSMutableArray<NSValue *> *candidates = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSNumber *> *scores = [NSMutableDictionary dictionary];
    NSInteger tw = tplC->width;
    NSInteger th = tplC->height;
    NSInteger sw = shotC->width;
    NSInteger sh = shotC->height;
    if (tw > sw || th > sh) {
        *outScores = scores;
        return candidates;
    }
    NSInteger stride = shotSum->width + 1;
    double n = (double)(tw * th);
    double tplSum = 0.0;
    double tplSum2 = 0.0;
    for (NSInteger i = 0; i < tw * th; i++) {
        double value = (double)tplC->data[i];
        tplSum += value;
        tplSum2 += value * value;
    }
    double tplMean = tplSum / n;
    double tplStd = sqrt(MAX(0.0, tplSum2 - n * tplMean * tplMean));
    if (tplStd <= 1e-6) {
        *outScores = scores;
        return candidates;
    }

    NSMutableArray<NSDictionary *> *all = [NSMutableArray array];
    for (NSInteger y = 0; y <= sh - th; y++) {
        for (NSInteger x = 0; x <= sw - tw; x++) {
            double sumI = ADTIntegralRectSum(shotSum->sum, stride, x, y, tw, th);
            double sumI2 = ADTIntegralRectSum(shotSum2->sum, stride, x, y, tw, th);
            double varI = sumI2 - sumI * sumI / n;
            if (varI <= 1e-6) {
                continue;
            }
            double cross = 0.0;
            for (NSInteger ty = 0; ty < th; ty++) {
                const float *shotRow = shotC->data + (y + ty) * sw + x;
                const float *tplRow = tplC->data + ty * tw;
                for (NSInteger tx = 0; tx < tw; tx++) {
                    cross += (double)shotRow[tx] * (double)tplRow[tx];
                }
            }
            double score = (cross - sumI * tplMean) / (tplStd * sqrt(varI));
            [all addObject:@{@"x": @(x), @"y": @(y), @"score": @(score)}];
        }
    }
    [all sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
        return [rhs[@"score"] compare:lhs[@"score"]];
    }];
    NSInteger limit = MIN((NSInteger)all.count, ADTCandidateCount);
    for (NSInteger i = 0; i < limit; i++) {
        NSDictionary *entry = all[i];
        [candidates addObject:[NSValue valueWithCGPoint:CGPointMake([entry[@"x"] doubleValue], [entry[@"y"] doubleValue])]];
        scores[@(candidates.count - 1)] = entry[@"score"];
    }
    *outScores = scores;
    return candidates;
}

@implementation ADTImageTools

+ (void)initialize {
    if (self == ADTImageTools.class) {
        gImageHandles = [NSMutableDictionary dictionary];
        gImageLock = [[NSLock alloc] init];
    }
}

#pragma mark - 句柄注册表

+ (NSInteger)registerImage:(UIImage *)image {
    if (image == nil) {
        return 0;
    }
    [gImageLock lock];
    NSInteger handle = gNextImageHandle++;
    gImageHandles[@(handle)] = image;
    [gImageLock unlock];
    return handle;
}

+ (nullable UIImage *)imageForHandle:(NSInteger)handle {
    if (handle <= 0) {
        return nil;
    }
    [gImageLock lock];
    UIImage *image = gImageHandles[@(handle)];
    [gImageLock unlock];
    return image;
}

+ (CGSize)pixelSizeForHandle:(NSInteger)handle {
    UIImage *image = [self imageForHandle:handle];
    if (image == nil) {
        return CGSizeZero;
    }
    CGImageRef cgImage = image.CGImage;
    if (cgImage != NULL) {
        return CGSizeMake((CGFloat)(size_t)CGImageGetWidth(cgImage), (CGFloat)(size_t)CGImageGetHeight(cgImage));
    }
    return CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
}

+ (void)releaseHandle:(NSInteger)handle {
    if (handle <= 0) {
        return;
    }
    [gImageLock lock];
    [gImageHandles removeObjectForKey:@(handle)];
    [gImageLock unlock];
}

+ (void)resetHandles {
    [gImageLock lock];
    [gImageHandles removeAllObjects];
    gNextImageHandle = 1;
    [gImageLock unlock];
}

#pragma mark - 基础操作

+ (nullable UIImage *)grayscaleImage:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    if (cgImage == NULL) {
        return nil;
    }
    NSInteger width = CGImageGetWidth(cgImage);
    NSInteger height = CGImageGetHeight(cgImage);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(NULL, (size_t)width, (size_t)height, 8, (size_t)width, colorSpace, kCGImageAlphaNone);
    if (context == NULL) {
        CGColorSpaceRelease(colorSpace);
        return nil;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGImageRef grayImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    if (grayImage == NULL) {
        return nil;
    }
    UIImage *result = [UIImage imageWithCGImage:grayImage];
    CGImageRelease(grayImage);
    return result;
}

+ (nullable UIImage *)clipImage:(UIImage *)image x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width height:(CGFloat)height {
    CGImageRef cgImage = image.CGImage;
    if (cgImage == NULL || width <= 0 || height <= 0) {
        return nil;
    }
    CGImageRef cropped = CGImageCreateWithImageInRect(cgImage, CGRectMake(x, y, width, height));
    if (cropped == NULL) {
        return nil;
    }
    UIImage *result = [UIImage imageWithCGImage:cropped scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cropped);
    return result;
}

+ (nullable UIImage *)scaleImage:(UIImage *)image sx:(CGFloat)sx sy:(CGFloat)sy {
    CGImageRef cgImage = image.CGImage;
    if (cgImage == NULL || sx <= 0 || sy <= 0) {
        return nil;
    }
    NSInteger width = (NSInteger)MAX(1.0, floor(CGImageGetWidth(cgImage) * sx));
    NSInteger height = (NSInteger)MAX(1.0, floor(CGImageGetHeight(cgImage) * sy));
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, (size_t)width, (size_t)height, 8, (size_t)width * 4, colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (context == NULL) {
        CGColorSpaceRelease(colorSpace);
        return nil;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGImageRef scaled = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    if (scaled == NULL) {
        return nil;
    }
    UIImage *result = [UIImage imageWithCGImage:scaled];
    CGImageRelease(scaled);
    return result;
}

+ (nullable NSString *)base64FromImage:(UIImage *)image format:(NSString *)format quality:(CGFloat)quality {
    NSData *data = [[format lowercaseString] isEqualToString:@"png"]
        ? UIImagePNGRepresentation(image)
        : UIImageJPEGRepresentation(image, MAX(0.01, MIN(1.0, quality / 100.0)));
    if (data == nil) {
        return nil;
    }
    return [data base64EncodedStringWithOptions:0];
}

#pragma mark - 灰度缓冲

+ (BOOL)fillGrayBuffer:(ADTGrayBuffer *)buffer fromImage:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    if (cgImage == NULL) {
        return NO;
    }
    NSInteger width = CGImageGetWidth(cgImage);
    NSInteger height = CGImageGetHeight(cgImage);
    if (width <= 0 || height <= 0) {
        return NO;
    }
    uint8_t *raw = calloc((size_t)(width * height), sizeof(uint8_t));
    if (raw == NULL) {
        return NO;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(raw, (size_t)width, (size_t)height, 8, (size_t)width, colorSpace, kCGImageAlphaNone);
    if (context == NULL) {
        free(raw);
        CGColorSpaceRelease(colorSpace);
        return NO;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);

    float *data = malloc((size_t)(width * height) * sizeof(float));
    if (data == NULL) {
        free(raw);
        return NO;
    }
    for (NSInteger i = 0; i < width * height; i++) {
        data[i] = (float)raw[i];
    }
    free(raw);
    buffer->width = width;
    buffer->height = height;
    buffer->data = data;
    return YES;
}

+ (void)freeGrayBuffer:(ADTGrayBuffer *)buffer {
    free(buffer->data);
    buffer->data = NULL;
}

#pragma mark - 模板匹配

+ (nullable NSDictionary *)matchTemplate:(UIImage *)screenshot template:(UIImage *)template threshold:(CGFloat)threshold {
    ADTGrayBuffer shot = {0, 0, NULL};
    ADTGrayBuffer tpl = {0, 0, NULL};
    if (![self fillGrayBuffer:&shot fromImage:screenshot] || ![self fillGrayBuffer:&tpl fromImage:template]) {
        [self freeGrayBuffer:&shot];
        [self freeGrayBuffer:&tpl];
        return nil;
    }
    NSDictionary *result = nil;
    if (tpl.width <= 0 || tpl.height <= 0 || tpl.width > shot.width || tpl.height > shot.height) {
        [self freeGrayBuffer:&shot];
        [self freeGrayBuffer:&tpl];
        return nil;
    }

    // 1) 粗筛
    NSInteger factor = 1;
    NSInteger maxDimension = MAX(shot.width, shot.height);
    while (factor < 16 && maxDimension / (factor * 2) >= ADTCoarseMaxDimension) {
        factor *= 2;
    }

    NSInteger seedX = 0;
    NSInteger seedY = 0;
    BOOL hasSeed = NO;
    double coarseScore = 0.0;

    if (factor > 1) {
        ADTGrayBuffer shotC = {0, 0, NULL};
        ADTGrayBuffer tplC = {0, 0, NULL};
        if (ADTDownsample(&shot, factor, &shotC) && ADTDownsample(&tpl, factor, &tplC)) {
            ADTIntegralImage integral = {NULL, NULL, 0, 0};
            ADTIntegralImage integral2 = {NULL, NULL, 0, 0};
            if (ADTBuildIntegral(&shotC, &integral) && ADTBuildIntegral(&shotC, &integral2)) {
                NSDictionary<NSNumber *, NSNumber *> *scores = nil;
                NSArray<NSValue *> *candidates = ADTCoarseCandidates(&shotC, &tplC, &integral, &integral2, &scores);
                if (candidates.count > 0) {
                    hasSeed = YES;
                    CGPoint point = candidates.firstObject.CGPointValue;
                    seedX = (NSInteger)point.x;
                    seedY = (NSInteger)point.y;
                    coarseScore = 0.0;
                }
            }
            ADTFreeIntegral(&integral);
            ADTFreeIntegral(&integral2);
            [self freeGrayBuffer:&shotC];
            [self freeGrayBuffer:&tplC];
        }
    }

    // 2) 全分辨率精修（有粗筛种子则在邻域内搜索，否则全图搜索）
    ADTIntegralImage shotIntegral = {NULL, NULL, 0, 0};
    ADTIntegralImage shotIntegral2 = {NULL, NULL, 0, 0};
    if (ADTBuildIntegral(&shot, &shotIntegral) && ADTBuildIntegral(&shot, &shotIntegral2)) {
        double bestScore = -2.0;
        NSInteger bestX = -1;
        NSInteger bestY = -1;
        if (hasSeed) {
            NSInteger centerX = seedX * factor;
            NSInteger centerY = seedY * factor;
            NSInteger radius = MAX(2 * factor, 4);
            double score = 0.0;
            NSInteger x = 0;
            NSInteger y = 0;
            if (ADTBestNCCOffset(&shot, &tpl, &shotIntegral, &shotIntegral2,
                                 centerX - radius, centerY - radius, centerX + radius, centerY + radius,
                                 &score, &x, &y)) {
                bestScore = score;
                bestX = x;
                bestY = y;
            }
        } else {
            double score = 0.0;
            NSInteger x = 0;
            NSInteger y = 0;
            if (ADTBestNCCOffset(&shot, &tpl, &shotIntegral, &shotIntegral2, 0, 0, shot.width, shot.height,
                                 &score, &x, &y)) {
                bestScore = score;
                bestX = x;
                bestY = y;
            }
        }
        if (bestX >= 0 && bestScore >= (double)threshold) {
            // Auto.js 的 point 为左上角，点中心由 JS 侧换算
            result = @{
                @"similarity": @(bestScore),
                @"x": @(bestX),
                @"y": @(bestY),
                @"width": @(tpl.width),
                @"height": @(tpl.height),
                @"coarse_factor": @(factor),
                @"coarse_score": @(coarseScore),
            };
        }
    }
    ADTFreeIntegral(&shotIntegral);
    ADTFreeIntegral(&shotIntegral2);
    [self freeGrayBuffer:&shot];
    [self freeGrayBuffer:&tpl];
    return result;
}

#pragma mark - SSIM

+ (CGFloat)ssimBetween:(UIImage *)a second:(UIImage *)b {
    ADTGrayBuffer bufA = {0, 0, NULL};
    ADTGrayBuffer bufB = {0, 0, NULL};
    if (![self fillGrayBuffer:&bufA fromImage:a] || ![self fillGrayBuffer:&bufB fromImage:b]) {
        [self freeGrayBuffer:&bufA];
        [self freeGrayBuffer:&bufB];
        return 0.0;
    }
    if (bufA.width != bufB.width || bufA.height != bufB.height || bufA.width < 2 || bufA.height < 2) {
        [self freeGrayBuffer:&bufA];
        [self freeGrayBuffer:&bufB];
        return 0.0;
    }
    ADTIntegralImage sumA = {NULL, NULL, 0, 0};
    ADTIntegralImage sumA2 = {NULL, NULL, 0, 0};
    ADTIntegralImage sumB = {NULL, NULL, 0, 0};
    ADTIntegralImage sumB2 = {NULL, NULL, 0, 0};
    CGFloat result = 0.0;
    if (ADTBuildIntegral(&bufA, &sumA) && ADTBuildIntegral(&bufA, &sumA2)
        && ADTBuildIntegral(&bufB, &sumB) && ADTBuildIntegral(&bufB, &sumB2)) {
        NSInteger win = 4;
        double stride = sumA.width + 1;
        double c1 = 6.5025;    // (0.01 * 255)^2
        double c2 = 58.5225;   // (0.03 * 255)^2
        double total = 0.0;
        NSInteger count = 0;
        for (NSInteger y = 0; y + win <= bufA.height; y += win) {
            for (NSInteger x = 0; x + win <= bufA.width; x += win) {
                double n = (double)(win * win);
                double sa = ADTIntegralRectSum(sumA.sum, (NSInteger)stride, x, y, win, win);
                double sa2 = ADTIntegralRectSum(sumA2.sum, (NSInteger)stride, x, y, win, win);
                double sb = ADTIntegralRectSum(sumB.sum, (NSInteger)stride, x, y, win, win);
                double sb2 = ADTIntegralRectSum(sumB2.sum, (NSInteger)stride, x, y, win, win);
                double cross = 0.0;
                for (NSInteger dy = 0; dy < win; dy++) {
                    const float *rowA = bufA.data + (y + dy) * bufA.width + x;
                    const float *rowB = bufB.data + (y + dy) * bufB.width + x;
                    for (NSInteger dx = 0; dx < win; dx++) {
                        cross += (double)rowA[dx] * (double)rowB[dx];
                    }
                }
                double meanA = sa / n;
                double meanB = sb / n;
                double varA = sa2 / n - meanA * meanA;
                double varB = sb2 / n - meanB * meanB;
                double cov = cross / n - meanA * meanB;
                double numerator = (2.0 * meanA * meanB + c1) * (2.0 * cov + c2);
                double denominator = (meanA * meanA + meanB * meanB + c1) * (varA + varB + c2);
                if (denominator != 0.0) {
                    total += numerator / denominator;
                    count++;
                }
            }
        }
        result = count > 0 ? (CGFloat)(total / (double)count) : 0.0;
    }
    ADTFreeIntegral(&sumA);
    ADTFreeIntegral(&sumA2);
    ADTFreeIntegral(&sumB);
    ADTFreeIntegral(&sumB2);
    [self freeGrayBuffer:&bufA];
    [self freeGrayBuffer:&bufB];
    return result;
}

#pragma mark - OCR

+ (NSArray<NSString *> *)recognizeText:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    if (cgImage == NULL) {
        return @[];
    }
    __block NSMutableArray<NSString *> *lines = [NSMutableArray array];
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *req, NSError *error) {
        if (error != nil) {
            return;
        }
        for (VNRecognizedTextObservation *observation in req.results) {
            VNRecognizedText *candidate = [observation topCandidates:1].firstObject;
            if (candidate.string.length > 0) {
                [lines addObject:candidate.string];
            }
        }
    }];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = YES;
    request.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
    NSError *performError = nil;
    if (![handler performRequests:@[request] error:&performError]) {
        return @[];
    }
    return lines;
}

@end
