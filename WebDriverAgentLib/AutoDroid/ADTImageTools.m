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
#import <Accelerate/Accelerate.h>
#import <CommonCrypto/CommonDigest.h>

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
            double sumI2 = ADTIntegralRectSum(shotSum2->sum2, stride, x, y, tw, th);
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
            double sumI2 = ADTIntegralRectSum(shotSum2->sum2, stride, x, y, tw, th);
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
    for (NSDictionary *entry in all) {
        CGPoint point = CGPointMake([entry[@"x"] doubleValue], [entry[@"y"] doubleValue]);
        BOOL nearby = NO;
        for (NSValue *other in candidates) {
            if (fabs(other.CGPointValue.x - point.x) < MAX(2, tw / 2)
                && fabs(other.CGPointValue.y - point.y) < MAX(2, th / 2)) { nearby = YES; break; }
        }
        if (nearby) { continue; }
        [candidates addObject:[NSValue valueWithCGPoint:point]];
        scores[@(candidates.count - 1)] = entry[@"score"];
        if (candidates.count >= ADTCandidateCount) { break; }
    }
    *outScores = scores;
    return candidates;
}

// Strict-v1 intentionally keeps colour pixels beside the NCC luminance plane.
// Histogram similarity is insufficient: a red icon swapped with a green icon
// must fail at the same foreground pixels even if its silhouette is unchanged.
typedef struct {
    NSInteger width, height;
    uint8_t *rgba;
    ADTGrayBuffer gray;
} ADTStrictPixels;
typedef struct {
    uint8_t *edge, *foreground;
    NSInteger count;
    double std, density;
    BOOL colorful;
} ADTStrictFeatures;

static double ADTStrictNow(void) { return NSProcessInfo.processInfo.systemUptime; }
static void ADTStrictFree(ADTStrictPixels *p) {
    free(p->rgba); free(p->gray.data); p->rgba = NULL; p->gray.data = NULL;
}
static BOOL ADTStrictRead(UIImage *image, ADTStrictPixels *p) {
    CGImageRef cg = image.CGImage;
    if (cg == NULL) return NO;
    p->width = CGImageGetWidth(cg); p->height = CGImageGetHeight(cg);
    if (p->width <= 0 || p->height <= 0 || p->width > 16384 || p->height > 16384) return NO;
    size_t count = (size_t)p->width * p->height;
    p->rgba = calloc(count, 4); p->gray = (ADTGrayBuffer){p->width, p->height, malloc(count * sizeof(float))};
    if (!p->rgba || !p->gray.data) { ADTStrictFree(p); return NO; }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(p->rgba, p->width, p->height, 8, p->width * 4,
                                            space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (ctx == NULL) { ADTStrictFree(p); return NO; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, p->width, p->height), cg); CGContextRelease(ctx);
    for (size_t i = 0; i < count; i++) {
        uint8_t *c = p->rgba + i * 4;
        // Pixels with alpha were premultiplied by CoreGraphics; compare their
        // actual composited spatial colour rather than untrusted hidden RGB.
        p->gray.data[i] = (float)round(.299*c[0] + .587*c[1] + .114*c[2]);
    }
    return YES;
}
static BOOL ADTStrictCrop(const ADTStrictPixels *source, NSInteger x, NSInteger y, NSInteger w, NSInteger h, ADTStrictPixels *out) {
    if (w <= 0 || h <= 0 || x < 0 || y < 0 || x+w > source->width || y+h > source->height) return NO;
    size_t count = (size_t)w*h;
    out->width = w; out->height = h; out->rgba = malloc(count*4);
    out->gray = (ADTGrayBuffer){w,h,malloc(count*sizeof(float))};
    if (!out->rgba || !out->gray.data) { ADTStrictFree(out); return NO; }
    for (NSInteger row=0;row<h;row++) {
        memcpy(out->rgba+row*w*4,source->rgba+((y+row)*source->width+x)*4,(size_t)w*4);
        memcpy(out->gray.data+row*w,source->gray.data+(y+row)*source->width+x,(size_t)w*sizeof(float));
    }
    return YES;
}
static int ADTStrictDoubleCompare(const void *a,const void *b) {
    double x=*(const double *)a,y=*(const double *)b; return (x>y)-(x<y);
}
static void ADTStrictFreeFeatures(ADTStrictFeatures *f) { free(f->edge);free(f->foreground);f->edge=NULL;f->foreground=NULL; }
static BOOL ADTStrictExtract(const ADTStrictPixels *p,ADTStrictFeatures *f) {
    NSInteger w=p->width,h=p->height,n=w*h;
    double *mag=calloc((size_t)n,sizeof(double));double *ordered=malloc((size_t)n*sizeof(double));
    f->edge=calloc((size_t)n,1);f->foreground=calloc((size_t)n,1);
    if(!mag||!ordered||!f->edge||!f->foreground) { free(mag);free(ordered);ADTStrictFreeFeatures(f);return NO; }
    double sum=0,sum2=0;NSInteger saturated=0;
    for(NSInteger i=0;i<n;i++) {
        double v=p->gray.data[i];sum+=v;sum2+=v*v;
        const uint8_t *c=p->rgba+i*4;if(MAX(c[0],MAX(c[1],c[2]))-MIN(c[0],MIN(c[1],c[2]))>=32)saturated++;
    }
    f->std=sqrt(MAX(0,sum2/n-(sum/n)*(sum/n)));f->colorful=(double)saturated/n>=.1;
    for(NSInteger y=1;y<h-1;y++)for(NSInteger x=1;x<w-1;x++) {
        NSInteger i=y*w+x;const float *g=p->gray.data;
        double gx=-g[i-w-1]+g[i-w+1]-2*g[i-1]+2*g[i+1]-g[i+w-1]+g[i+w+1];
        double gy=-g[i-w-1]-2*g[i-w]-g[i-w+1]+g[i+w-1]+2*g[i+w]+g[i+w+1];mag[i]=hypot(gx,gy);
    }
    NSInteger signals=0;for(NSInteger i=0;i<n;i++)if(mag[i]>=8)ordered[signals++]=mag[i];
    qsort(ordered,(size_t)signals,sizeof(double),ADTStrictDoubleCompare);
    double threshold=8;
    if(signals){double percentile=(signals-1)*.9;NSInteger lower=(NSInteger)floor(percentile),upper=(NSInteger)ceil(percentile);threshold=MAX(8,(ordered[lower]+(ordered[upper]-ordered[lower])*(percentile-lower))*.25);}
    f->count=0;
    for(NSInteger y=1;y<h-1;y++)for(NSInteger x=1;x<w-1;x++)if(mag[y*w+x]>=threshold) {
        f->edge[y*w+x]=1;f->count++;
        for(NSInteger dy=-1;dy<=1;dy++)for(NSInteger dx=-1;dx<=1;dx++)f->foreground[(y+dy)*w+x+dx]=1;
    }
    f->density=(double)f->count/n;free(mag);free(ordered);return YES;
}
static double ADTStrictCoverage(const uint8_t *a,const uint8_t *b,NSInteger w,NSInteger h) {
    NSInteger count=0,found=0;
    for(NSInteger y=0;y<h;y++)for(NSInteger x=0;x<w;x++)if(a[y*w+x]) {
        count++;BOOL near=NO;
        // All eight adjacent pixel centres are within the 1.5px tolerance.
        for(NSInteger dy=-1;dy<=1;dy++)for(NSInteger dx=-1;dx<=1;dx++)
            if(x+dx>=0&&x+dx<w&&y+dy>=0&&y+dy<h&&b[(y+dy)*w+x+dx])near=YES;
        if(near)found++;
    }
    return count>0?(double)found/count:0;
}
static NSDictionary *ADTStrictVerify(const ADTStrictPixels *t,const ADTStrictPixels *c,double score) {
    ADTStrictFeatures a={0},b={0};
    if(!ADTStrictExtract(t,&a)||!ADTStrictExtract(c,&b)) { ADTStrictFreeFeatures(&a);ADTStrictFreeFeatures(&b);return nil; }
    double recall=ADTStrictCoverage(a.edge,b.edge,t->width,t->height),precision=ADTStrictCoverage(b.edge,a.edge,t->width,t->height);
    double gray=0,color=0,tiles[16]={0};NSInteger count=0,counts[16]={0};
    for(NSInteger i=0;i<t->width*t->height;i++)if(a.foreground[i]||b.foreground[i]) {
        double error=fabs(t->gray.data[i]-c->gray.data[i])/255.;gray+=error;
        for(NSInteger ch=0;ch<3;ch++)color+=fabs(t->rgba[i*4+ch]-c->rgba[i*4+ch])/(3.*255);
        NSInteger tile=MIN(3,(i/t->width)*4/t->height)*4+MIN(3,(i%t->width)*4/t->width);tiles[tile]+=error;counts[tile]++;count++;
    }
    gray=count?gray/count:1;color=count?color/count:1;double worst=gray;
    for(NSInteger i=0;i<16;i++)if(counts[i]>=8)worst=MAX(worst,tiles[i]/counts[i]);
    // Overlapping windows preserve a changed character within a shared label.
    double localError=0;
    for(NSInteger y=0;y<t->height;y+=8)for(NSInteger x=0;x<t->width;x+=8) {
        double sum=0;NSInteger samples=0;
        for(NSInteger yy=y;yy<MIN(y+16,t->height);yy++)for(NSInteger xx=x;xx<MIN(x+16,t->width);xx++) {
            NSInteger i=yy*t->width+xx;
            if(a.foreground[i]||b.foreground[i]) { sum+=fabs(t->gray.data[i]-c->gray.data[i])/255.;samples++; }
        }
        if(samples>=8)localError=MAX(localError,sum/samples);
    }
    double coverage=MIN(recall,precision);BOOL colorActive=a.colorful||b.colorful;
    BOOL accepted=a.count>0&&b.count>0&&b.std>.5&&score>=.92&&coverage>=.88&&gray<=.12&&MAX(worst,localError)<=.22&&(!colorActive||color<=.08);
    NSDictionary *result=@{@"ncc":@(score),@"edge_recall":@(recall),@"edge_precision":@(precision),@"edge_coverage":@(coverage),
                          @"foreground_error":@(gray),@"tile_error":@(worst),@"local_error":@(localError),@"color_active":@(colorActive),
                          @"color_error":colorActive?@(color):NSNull.null,@"accepted":@(accepted),@"reason":accepted?@"accepted":@"verification_failed"};
    ADTStrictFreeFeatures(&a);ADTStrictFreeFeatures(&b);return result;
}
static BOOL ADTStrictSameRect(NSArray *a,NSArray *b) {
    double ax=[a[0] doubleValue],ay=[a[1] doubleValue],aw=[a[2] doubleValue],ah=[a[3] doubleValue];
    double bx=[b[0] doubleValue],by=[b[1] doubleValue],bw=[b[2] doubleValue],bh=[b[3] doubleValue];
    double intersection=MAX(0,MIN(ax+aw,bx+bw)-MAX(ax,bx))*MAX(0,MIN(ay+ah,by+bh)-MAX(ay,by));
    return intersection/MAX(1,aw*ah+bw*bh-intersection)>.35||hypot(ax+aw/2-bx-bw/2,ay+ah/2-by-bh/2)<=.25*MIN(MIN(aw,ah),MIN(bw,bh));
}
// Explicit zero-mean normalized cross correlation, equivalent to CCOEFF_NORMED.
// Precomputed centred template and integral sums keep normalization independent
// of image brightness. Time is checked on each scan row, including refinement.
static BOOL ADTStrictNCC(const ADTGrayBuffer *s,const ADTGrayBuffer *t,const ADTIntegralImage *integral,
                         NSInteger x0,NSInteger y0,NSInteger x1,NSInteger y1,double deadline,
                         double *best,NSInteger *bx,NSInteger *by,float *response) {
    NSInteger w=t->width,h=t->height;
    if(w<=0||h<=0||w>s->width||h>s->height||w>16384||h>16384||!t->data||!s->data)return NO;
    NSInteger n=w*h,stride=integral->width+1;
    double mean=0,var=0;for(NSInteger i=0;i<n;i++)mean+=t->data[i];mean/=n;
    float *centered=calloc((size_t)n,sizeof(float));if(!centered)return NO;
    for(NSInteger i=0;i<n;i++){centered[i]=t->data[i]-mean;var+=centered[i]*centered[i];}
    if(var<=1e-6){free(centered);return NO;}
    *best=-2;*bx=-1;*by=-1;
    NSInteger startX=MAX(0,x0),startY=MAX(0,y0),endX=MIN(s->width-w,x1),endY=MIN(s->height-h,y1),rw=s->width-w+1;
    for(NSInteger y=startY;y<=endY;y++) {
        if(ADTStrictNow()>=deadline){free(centered);return NO;}
        for(NSInteger x=startX;x<=endX;x++) {
            double sum=ADTIntegralRectSum(integral->sum,stride,x,y,w,h),sum2=ADTIntegralRectSum(integral->sum2,stride,x,y,w,h);
            double ivar=sum2-sum*sum/n,score=-2;
            if(ivar>1e-6) {
                double cross=0;
                for(NSInteger ty=0;ty<h;ty++) {
                    const float *shot=s->data+(y+ty)*s->width+x,*tpl=centered+ty*w;
                    float rowDot=0;
                    vDSP_dotpr(shot,1,tpl,1,&rowDot,(vDSP_Length)w);
                    cross+=(double)rowDot;
                }
                score=MAX(-1,MIN(1,cross/sqrt(var*ivar)));
            }
            if(response)response[y*rw+x]=(float)score;
            if(score>*best){*best=score;*bx=x;*by=y;}
        }
    }
    free(centered);return *bx>=0;
}
static NSArray<NSDictionary *> *ADTStrictSeeds(const ADTGrayBuffer *s,const ADTGrayBuffer *t,double threshold,NSInteger limit,double deadline,BOOL *overflow) {
    NSInteger w=s->width-t->width+1,h=s->height-t->height+1;if(w<=0||h<=0)return @[];
    float *response=malloc((size_t)w*h*sizeof(float));ADTIntegralImage integral={0};
    if(!response||!ADTBuildIntegral(s,&integral)){free(response);ADTFreeIntegral(&integral);return @[];}
    double score;NSInteger x,y;
    if(!ADTStrictNCC(s,t,&integral,0,0,w-1,h-1,deadline,&score,&x,&y,response)) {free(response);ADTFreeIntegral(&integral);return @[];}
    NSMutableArray *out=[NSMutableArray array];
    for(NSInteger index=0;limit<=0||index<=limit;index++) {
        if(ADTStrictNow()>=deadline)break;
        score=-2;x=-1;y=-1;
        for(NSInteger i=0;i<w*h;i++)if(response[i]>score){score=response[i];x=i%w;y=i/w;}
        if(score<threshold||x<0)break;
        if(limit>0&&index==limit){if(overflow)*overflow=YES;break;}
        [out addObject:@{@"x":@(x),@"y":@(y),@"score":@(score)}];
        NSInteger rx=MAX(1,t->width/3),ry=MAX(1,t->height/3);
        for(NSInteger yy=MAX(0,y-ry);yy<=MIN(h-1,y+ry);yy++)for(NSInteger xx=MAX(0,x-rx);xx<=MIN(w-1,x+rx);xx++)response[yy*w+xx]=-2;
    }
    free(response);ADTFreeIntegral(&integral);return out;
}
static BOOL ADTStrictNumbers(NSDictionary *options,NSString *key,NSInteger length,double *out) {
    id value=options[key];if(value==nil||value==NSNull.null)return YES;
    if(![value isKindOfClass:NSArray.class]||[value count]!=(NSUInteger)length)return NO;
    for(NSInteger i=0;i<length;i++) {
        if(![value[i] isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value[i])==CFBooleanGetTypeID())return NO;
        out[i]=[value[i] doubleValue];if(!isfinite(out[i]))return NO;
    }
    return YES;
}

static NSString *ADTAdaptiveSHA(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    NSMutableString *hex=[NSMutableString string];for(NSUInteger i=0;i<sizeof(bytes);i++)[hex appendFormat:@"%02x",bytes[i]];
    return hex;
}
static BOOL ADTAdaptiveNumber(id value) {return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()&&isfinite([value doubleValue]);}
static NSString *ADTAdaptiveText(NSString *text) {
    NSArray *parts=[[text precomposedStringWithCanonicalMapping] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[parts filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *item,NSDictionary *bindings){return item.length>0;}]] componentsJoinedByString:@" "];
}
static BOOL ADTAdaptiveResize(const ADTStrictPixels *input,NSInteger width,NSInteger height,ADTStrictPixels *out) {
    if(width<1||height<1||width>16384||height>16384)return NO;
    out->width=width;out->height=height;size_t count=(size_t)width*height;
    out->rgba=malloc(count*4);out->gray=(ADTGrayBuffer){width,height,malloc(count*sizeof(float))};
    if(!out->rgba||!out->gray.data){ADTStrictFree(out);return NO;}
    for(NSInteger y=0;y<height;y++) {
        double fy=MAX(0,MIN(input->height-1,(y+.5)*input->height/height-.5));NSInteger y0=floor(fy),y1=MIN(input->height-1,y0+1);fy-=y0;
        for(NSInteger x=0;x<width;x++) {
            double fx=MAX(0,MIN(input->width-1,(x+.5)*input->width/width-.5));NSInteger x0=floor(fx),x1=MIN(input->width-1,x0+1);fx-=x0;
            uint8_t *pixel=out->rgba+(y*width+x)*4;
            for(NSInteger ch=0;ch<4;ch++) {
                double top=input->rgba[(y0*input->width+x0)*4+ch]*(1-fx)+input->rgba[(y0*input->width+x1)*4+ch]*fx;
                double bottom=input->rgba[(y1*input->width+x0)*4+ch]*(1-fx)+input->rgba[(y1*input->width+x1)*4+ch]*fx;
                pixel[ch]=(uint8_t)floor(top*(1-fy)+bottom*fy+.5);
            }
            out->gray.data[y*width+x]=(float)floor(.299*pixel[0]+.587*pixel[1]+.114*pixel[2]+.5);
        }
    }
    return YES;
}
static UIImage *ADTAdaptiveImage(const ADTStrictPixels *pixels) {
    NSData *data=[NSData dataWithBytes:pixels->rgba length:(NSUInteger)(pixels->width*pixels->height*4)];
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image=CGImageCreate(pixels->width,pixels->height,8,32,pixels->width*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big,provider,NULL,NO,kCGRenderingIntentDefault);
    UIImage *result=image?[UIImage imageWithCGImage:image]:nil;
    if(image)CGImageRelease(image);CGColorSpaceRelease(space);CGDataProviderRelease(provider);return result;
}
static NSArray *ADTAdaptiveRect(CGRect rect) {return @[@(rect.origin.x),@(rect.origin.y),@(rect.size.width),@(rect.size.height)];}
static CGRect ADTAdaptiveCGRect(NSArray *r) {return CGRectMake([r[0] doubleValue],[r[1] doubleValue],[r[2] doubleValue],[r[3] doubleValue]);}
static BOOL ADTAdaptiveSameCandidate(NSDictionary *a,NSDictionary *b) {
    if(!ADTStrictSameRect(a[@"rect"],b[@"rect"]))return NO;
    if([a[@"branch"] isEqual:@"composed"]&&[b[@"branch"] isEqual:@"composed"]) {
        NSDictionary *left=a[@"region_matches"],*right=b[@"region_matches"];
        if(left.count!=right.count)return NO;
        for(NSString *key in left)if(!right[key]||!ADTStrictSameRect(left[key][@"rect"],right[key][@"rect"]))return NO;
    }
    return YES;
}

@interface ADTAdaptiveLayer : NSObject {
@public
    ADTGrayBuffer gray;
    ADTIntegralImage integral;
    float *fftReal,*fftImag;
    FFTSetup setup;
    vDSP_Length logW,logH;
    NSInteger fftWidth,fftHeight;
    BOOL ownsGray;
}
- (instancetype)initWithPixels:(const ADTStrictPixels *)pixels factor:(NSInteger)factor;
- (BOOL)prepareFFT;
@end
@implementation ADTAdaptiveLayer
- (instancetype)initWithPixels:(const ADTStrictPixels *)pixels factor:(NSInteger)factor {
    self=[super init];if(!self)return nil;
    ownsGray=factor>1;if(ownsGray){if(!ADTDownsample(&pixels->gray,factor,&gray))return nil;}else gray=pixels->gray;
    if(!ADTBuildIntegral(&gray,&integral))return nil;return self;
}
- (BOOL)prepareFFT {
    if(fftReal&&fftImag)return YES;
    while((1UL<<logW)<(NSUInteger)gray.width)logW++;while((1UL<<logH)<(NSUInteger)gray.height)logH++;
    fftWidth=1UL<<logW;fftHeight=1UL<<logH;size_t count=(size_t)fftWidth*fftHeight;
    fftReal=calloc(count,sizeof(float));fftImag=calloc(count,sizeof(float));setup=vDSP_create_fftsetup(MAX(logW,logH),kFFTRadix2);
    if(!fftReal||!fftImag||!setup)return NO;
    for(NSInteger y=0;y<gray.height;y++)memcpy(fftReal+y*fftWidth,gray.data+y*gray.width,gray.width*sizeof(float));
    DSPSplitComplex frequency={fftReal,fftImag};vDSP_fft2d_zip(setup,&frequency,1,fftWidth,logW,logH,FFT_FORWARD);return YES;
}
- (void)dealloc {if(ownsGray)free(gray.data);ADTFreeIntegral(&integral);free(fftReal);free(fftImag);if(setup)vDSP_destroy_fftsetup(setup);}
@end

// Accelerate's complex FFT supplies proposal correlation without a quadratic
// pixel-by-pixel scan. Only strict original-resolution NCC can accept a result.
static NSArray *ADTAdaptiveSeeds(ADTAdaptiveLayer *layer,const ADTGrayBuffer *tpl,double threshold,double deadline,BOOL *overflow) {
    const ADTGrayBuffer *shot=&layer->gray;
    NSInteger rw=shot->width-tpl->width+1,rh=shot->height-tpl->height+1;if(rw<1||rh<1)return @[];
    vDSP_Length logW=0,logH=0;while((1UL<<logW)<(NSUInteger)shot->width)logW++;while((1UL<<logH)<(NSUInteger)shot->height)logH++;
    NSInteger width=1UL<<logW,height=1UL<<logH;size_t count=(size_t)width*height;
    BOOL spatial=tpl->width*tpl->height<=256;
    float *ar=spatial?NULL:calloc(count,sizeof(float)),*ai=spatial?NULL:calloc(count,sizeof(float)),*br=spatial?NULL:calloc(count,sizeof(float)),*bi=spatial?NULL:calloc(count,sizeof(float)),*response=malloc((size_t)rw*rh*sizeof(float)),*denominators=malloc((size_t)rw*rh*sizeof(float));
    FFTSetup setup=spatial?NULL:([layer prepareFFT]?vDSP_create_fftsetup(MAX(logW,logH),kFFTRadix2):NULL);ADTIntegralImage integral=layer->integral;NSMutableArray *out=[NSMutableArray array];
    @try {
        if(!response||!denominators||(!spatial&&(!ar||!ai||!br||!bi||!setup)))return nil;
        double mean=0,var=0;NSInteger n=tpl->width*tpl->height;for(NSInteger i=0;i<n;i++)mean+=tpl->data[i];mean/=n;
        for(NSInteger i=0;i<n;i++){double value=tpl->data[i]-mean;var+=value*value;}
        if(var<=1e-6)return @[];
        if(spatial) {
            float *centered=malloc((size_t)n*sizeof(float)),*row=malloc((size_t)rw*sizeof(float));if(!centered||!row){free(centered);free(row);return nil;}
            for(NSInteger i=0;i<n;i++)centered[i]=tpl->data[i]-mean;memset(response,0,(size_t)rw*rh*sizeof(float));
            for(NSInteger y=0;y<rh;y++) {
                if(ADTStrictNow()>=deadline){free(centered);free(row);return nil;}
                for(NSInteger ty=0;ty<tpl->height;ty++){vDSP_conv(shot->data+(y+ty)*shot->width,1,centered+ty*tpl->width,1,row,1,rw,tpl->width);vDSP_vadd(response+y*rw,1,row,1,response+y*rw,1,rw);}
            }
            free(centered);free(row);
        } else {
            for(NSInteger y=0;y<tpl->height;y++)for(NSInteger x=0;x<tpl->width;x++)br[y*width+x]=tpl->data[y*tpl->width+x]-mean;
            DSPSplitComplex a={ar,ai},b={br,bi};vDSP_fft2d_zip(setup,&b,1,width,logW,logH,FFT_FORWARD);
            for(size_t i=0;i<count;i++){double real=layer->fftReal[i]*br[i]+layer->fftImag[i]*bi[i],imag=layer->fftImag[i]*br[i]-layer->fftReal[i]*bi[i];ar[i]=real;ai[i]=imag;}
            vDSP_fft2d_zip(setup,&a,1,width,logW,logH,FFT_INVERSE);
        }
        double norm=spatial?1.:1./count;NSInteger stride=shot->width+1;
        for(NSInteger y=0;y<rh;y++) {
            if(ADTStrictNow()>=deadline)return nil;
            for(NSInteger x=0;x<rw;x++){double sum=ADTIntegralRectSum(integral.sum,stride,x,y,tpl->width,tpl->height),sum2=ADTIntegralRectSum(integral.sum2,stride,x,y,tpl->width,tpl->height),variance=sum2-sum*sum/n;double cross=spatial?response[y*rw+x]:ar[y*width+x]*norm;response[y*rw+x]=variance>1e-6?cross:-2;denominators[y*rw+x]=variance>1e-6?var*variance:1;}
        }
        int values=(int)(rw*rh);vvsqrtf(denominators,denominators,&values);vDSP_vdiv(denominators,1,response,1,response,1,values);float low=-1,high=1;vDSP_vclip(response,1,&low,&high,response,1,values);
        for(NSInteger index=0;index<=64;index++) {
            if(ADTStrictNow()>=deadline)return nil;float maximum=-2;vDSP_Length offset=0;vDSP_maxvi(response,1,&maximum,&offset,rw*rh);double score=maximum;NSInteger bx=offset%rw,by=offset/rw;
            if(bx<0||score<threshold)break;if(index==64){*overflow=YES;break;}
            [out addObject:@{@"x":@(bx),@"y":@(by),@"score":@(score)}];NSInteger rx=MAX(1,tpl->width/3),ry=MAX(1,tpl->height/3);
            for(NSInteger y=MAX(0,by-ry);y<=MIN(rh-1,by+ry);y++)for(NSInteger x=MAX(0,bx-rx);x<=MIN(rw-1,bx+rx);x++)response[y*rw+x]=-2;
        }
        return out;
    } @finally {free(ar);free(ai);free(br);free(bi);free(response);free(denominators);if(setup)vDSP_destroy_fftsetup(setup);}
}

// Pixel identity is verified only at original resolution. Pyramid scores are
// recall evidence; they never become an accepted candidate on their own.
static NSDictionary *ADTAdaptiveVisual(const ADTStrictPixels *screen,const ADTStrictPixels *original,double deadline,NSMutableDictionary *layers) {
    double started=ADTStrictNow();
    NSMutableArray *objects=[NSMutableArray array];NSMutableSet *sizes=[NSMutableSet set];BOOL overflow=NO;
    double minimum=8./MIN(original->width,original->height),maximum=MIN((double)screen->width/original->width,(double)screen->height/original->height);
    if(maximum<minimum)return @{@"status":@"ok",@"candidates":@[]};
    NSMutableArray *scales=[NSMutableArray arrayWithArray:@[@1,@.95,@1.05,@.9,@1.1,@.85,@1.15,@.8,@1.2]];
    for(double scale=1.12;scale<=maximum*1.001;scale*=1.12)[scales addObject:@(scale)];
    for(double scale=1/1.12;scale>=minimum*.999;scale/=1.12)[scales addObject:@(scale)];
    [scales addObject:@(minimum)];[scales addObject:@(maximum)];
    [scales sortUsingComparator:^NSComparisonResult(NSNumber *a,NSNumber *b){double x=fabs(log(a.doubleValue)),y=fabs(log(b.doubleValue));return x<y?NSOrderedAscending:x>y?NSOrderedDescending:NSOrderedSame;}];
    for(NSNumber *number in scales) {
        if(ADTStrictNow()>=deadline)return @{@"status":@"unsupported",@"reason":@"deadline_exceeded",@"candidates":@[]};
        NSInteger w=floor(original->width*number.doubleValue+.5),h=floor(original->height*number.doubleValue+.5);
        NSString *key=[NSString stringWithFormat:@"%ld:%ld",(long)w,(long)h];
        if(MIN(w,h)<8||w>screen->width||h>screen->height||[sizes containsObject:key])continue;[sizes addObject:key];
        ADTStrictPixels scaled={0};ADTGrayBuffer tplSmall={0};
        @try {
            if(!ADTAdaptiveResize(original,w,h,&scaled))return @{@"status":@"unsupported",@"reason":@"allocation_failed",@"candidates":@[]};
            NSInteger factor=MAX(1,MIN((NSInteger)ceil(MAX(screen->width,screen->height)/960.),MIN(w,h)/32));
            ADTAdaptiveLayer *layer=layers[@(factor)];if(!layer){layer=[[ADTAdaptiveLayer alloc] initWithPixels:screen factor:factor];if(!layer)return @{@"status":@"unsupported",@"reason":@"allocation_failed",@"candidates":@[]};layers[@(factor)]=layer;}
            const ADTGrayBuffer *tpl=&scaled.gray;
            if(factor>1){if(!ADTDownsample(&scaled.gray,factor,&tplSmall))return @{@"status":@"unsupported",@"reason":@"allocation_failed",@"candidates":@[]};tpl=&tplSmall;}
            BOOL seedOverflow=NO;
            NSArray *seeds=ADTAdaptiveSeeds(layer,tpl,factor==1?.82:.65,deadline,&seedOverflow);
            if(!seeds)return @{@"status":@"unsupported",@"reason":ADTStrictNow()>=deadline?@"deadline_exceeded":@"allocation_failed",@"candidates":@[]};
            if(seedOverflow)overflow=YES;
            for(NSDictionary *seed in seeds) {
                NSArray *rect=@[@([seed[@"x"] integerValue]*factor),@([seed[@"y"] integerValue]*factor),@(w),@(h)];
                NSMutableDictionary *object=nil;
                for(NSMutableDictionary *other in objects)if(ADTStrictSameRect(rect,other[@"rect"])){object=other;break;}
                NSDictionary *entry=@{@"rect":rect,@"similarity":seed[@"score"],@"factor":@(factor)};
                if(!object){object=[@{@"rect":rect,@"seeds":[NSMutableArray array]} mutableCopy];[objects addObject:object];}
                [object[@"seeds"] addObject:entry];
                if(objects.count>64){overflow=YES;break;}
            }
            if(overflow)break;
        } @finally {ADTStrictFree(&scaled);[ADTImageTools freeGrayBuffer:&tplSmall];}
    }
    if(ADTStrictNow()>=deadline)return @{@"status":@"unsupported",@"reason":@"deadline_exceeded",@"candidates":@[]};
    if(overflow)return @{@"status":@"unsupported",@"reason":@"candidate_overflow",@"candidates":@[]};
    double searchMS=(ADTStrictNow()-started)*1000;NSMutableArray *verified=[NSMutableArray array];ADTIntegralImage fullIntegral={0};
    if(!ADTBuildIntegral(&screen->gray,&fullIntegral))return @{@"status":@"unsupported",@"reason":@"allocation_failed",@"candidates":@[]};
    @try {
        for(NSDictionary *object in objects) {
            NSArray *ranked=[object[@"seeds"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [b[@"similarity"] compare:a[@"similarity"]];}];
            NSMutableArray *dimensionScores=[NSMutableArray array];NSMutableSet *tested=[NSMutableSet set];
            // Every integer width near the two strongest pyramid hypotheses is
            // evaluated in a local pyramid. Exact original-pixel NCC follows.
            for(NSDictionary *seed in [ranked subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)1,ranked.count))]) {
                NSArray *r=seed[@"rect"];double centerX=[r[0] doubleValue]+[r[2] doubleValue]/2,centerY=[r[1] doubleValue]+[r[3] doubleValue]/2;
                NSInteger baseW=[r[2] integerValue],baseH=[r[3] integerValue],factor=MAX(1,MIN(baseW,baseH)/48);
                ADTGrayBuffer shotSmall={0};ADTIntegralImage smallIntegral={0};
                @try {
                    const ADTGrayBuffer *shot=&screen->gray;
                    if(factor>1){if(!ADTDownsample(&screen->gray,factor,&shotSmall))return @{@"status":@"unsupported",@"reason":@"allocation_failed",@"candidates":@[]};shot=&shotSmall;}
                    if(!ADTBuildIntegral(shot,&smallIntegral))return @{@"status":@"unsupported",@"reason":@"allocation_failed",@"candidates":@[]};
                    NSInteger lower=MAX(8,(NSInteger)floor(baseW/1.065)),upper=MIN(screen->width,(NSInteger)ceil(baseW*1.065));
                    for(NSInteger w=lower;w<=upper;w++) {
                        if(ADTStrictNow()>=deadline)return @{@"status":@"unsupported",@"reason":@"deadline_exceeded",@"candidates":@[]};
                        NSInteger h=floor((double)original->height*w/original->width+.5);
                        NSString *key=[NSString stringWithFormat:@"%ld:%ld",(long)w,(long)h];
                        if([tested containsObject:key]||MIN(w,h)<8||h>screen->height)continue;[tested addObject:key];
                        ADTStrictPixels resized={0};ADTGrayBuffer small={0};
                        @try {
                            if(!ADTAdaptiveResize(original,w,h,&resized))return @{@"status":@"unsupported",@"reason":@"allocation_failed",@"candidates":@[]};
                            const ADTGrayBuffer *tpl=&resized.gray;
                            if(factor>1){if(!ADTDownsample(&resized.gray,factor,&small))return @{@"status":@"unsupported",@"reason":@"allocation_failed",@"candidates":@[]};tpl=&small;}
                            NSInteger cx=floor((centerX-w/2.)/factor+.5),cy=floor((centerY-h/2.)/factor+.5),radius=MAX(2,[seed[@"factor"] integerValue]/factor+1),x=-1,y=-1;double score=-2;
                            if(ADTStrictNCC(shot,tpl,&smallIntegral,cx-radius,cy-radius,cx+radius,cy+radius,deadline,&score,&x,&y,NULL))
                                [dimensionScores addObject:@{@"rect":@[@(x*factor),@(y*factor),@(w),@(h)],@"similarity":@(score),@"factor":@(factor)}];
                        } @finally {ADTStrictFree(&resized);[ADTImageTools freeGrayBuffer:&small];}
                    }
                } @finally {[ADTImageTools freeGrayBuffer:&shotSmall];ADTFreeIntegral(&smallIntegral);}
            }
            [dimensionScores sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [b[@"similarity"] compare:a[@"similarity"]];}];
            if(!dimensionScores.count||[dimensionScores.firstObject[@"similarity"] doubleValue]<.82)continue;
            NSMutableDictionary *best=nil;NSMutableSet *originalSizes=[NSMutableSet set];
            for(NSDictionary *entry in [dimensionScores subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)3,dimensionScores.count))]) {
                NSArray *r=entry[@"rect"];NSInteger baseW=[r[2] integerValue],baseH=[r[3] integerValue];
                NSArray *offsets=@[@0,@(-1),@1];
                for(NSNumber *widthOffset in offsets)for(NSNumber *heightOffset in offsets) {
                    if([best[@"accepted"] boolValue])continue;
                    NSInteger dw=widthOffset.integerValue,dh=heightOffset.integerValue;
                    if(ADTStrictNow()>=deadline)return @{@"status":@"unsupported",@"reason":@"deadline_exceeded",@"candidates":verified};
                    NSInteger w=baseW+dw,h=baseH+dh;NSString *key=[NSString stringWithFormat:@"%ld:%ld",(long)w,(long)h];
                    if([originalSizes containsObject:key]||MIN(w,h)<8||w>screen->width||h>screen->height)continue;[originalSizes addObject:key];
                    ADTStrictPixels resized={0},crop={0};
                    @try {
                        if(!ADTAdaptiveResize(original,w,h,&resized))return @{@"status":@"unsupported",@"reason":@"allocation_failed",@"candidates":verified};
                        NSInteger radius=MAX(2,[entry[@"factor"] integerValue]/2+1),cx=[r[0] integerValue]-dw/2,cy=[r[1] integerValue]-dh/2,x=-1,y=-1;double score=-2;
                        if(!ADTStrictNCC(&screen->gray,&resized.gray,&fullIntegral,cx-radius,cy-radius,cx+radius,cy+radius,deadline,&score,&x,&y,NULL))continue;
                        if(score<.82)continue;
                        if(!ADTStrictCrop(screen,x,y,w,h,&crop))continue;
                        NSDictionary *metrics=ADTStrictVerify(&resized,&crop,score);if(!metrics)return @{@"status":@"unsupported",@"reason":@"allocation_failed",@"candidates":verified};
                        BOOL accepted=[metrics[@"accepted"] boolValue];
                        if(!best||accepted>[best[@"accepted"] boolValue]||(accepted==[best[@"accepted"] boolValue]&&score>[best[@"similarity"] doubleValue]))
                            best=[@{@"rect":@[@(x),@(y),@(w),@(h)],@"similarity":@(score),@"metrics":metrics,@"accepted":@(accepted)} mutableCopy];
                    } @finally {ADTStrictFree(&resized);ADTStrictFree(&crop);}
                }
                if([best[@"accepted"] boolValue])break;
            }
            if(best)[verified addObject:best];
        }
    } @finally {ADTFreeIntegral(&fullIntegral);}
    return @{@"status":@"ok",@"candidates":verified,@"timings":@{@"search_ms":@(searchMS),@"refine_ms":@((ADTStrictNow()-started)*1000-searchMS),@"objects":@(objects.count),@"scales":@(sizes.count)}};
}

static BOOL ADTAdaptiveRelation(CGRect visual,CGRect text,NSDictionary *relation) {
    double overlap=CGRectGetWidth(CGRectIntersection(visual,text))*CGRectGetHeight(CGRectIntersection(visual,text));
    if(!isfinite(overlap))overlap=0;
    if(overlap/MAX(1,text.size.width*text.size.height)>=.5)return NO;
    double gap=0,alignment=0,unit=MAX(1,MIN(visual.size.width,visual.size.height));NSString *direction=relation[@"direction"];
    if([direction isEqual:@"right"]||[direction isEqual:@"left"]){gap=([direction isEqual:@"right"]?CGRectGetMinX(text)-CGRectGetMaxX(visual):CGRectGetMinX(visual)-CGRectGetMaxX(text))/unit;alignment=fabs(CGRectGetMidY(text)-CGRectGetMidY(visual))/MAX(visual.size.height,text.size.height);}
    else if([direction isEqual:@"above"]||[direction isEqual:@"below"]){gap=([direction isEqual:@"below"]?CGRectGetMinY(text)-CGRectGetMaxY(visual):CGRectGetMinY(visual)-CGRectGetMaxY(text))/unit;alignment=fabs(CGRectGetMidX(text)-CGRectGetMidX(visual))/MAX(visual.size.width,text.size.width);}
    else return NO;
    double maxGap=relation[@"max_gap"]?[relation[@"max_gap"] doubleValue]:2.,maxAlignment=relation[@"max_alignment"]?[relation[@"max_alignment"] doubleValue]:.5;
    return isfinite(maxGap)&&isfinite(maxAlignment)&&gap>=-.05&&gap<=maxGap&&alignment<=maxAlignment;
}

static BOOL ADTAdaptiveForegroundCovered(const ADTStrictPixels *template,NSArray *regions) {
    NSMutableArray *channels=[NSMutableArray arrayWithObjects:[NSMutableArray array],[NSMutableArray array],[NSMutableArray array],nil];
    for(NSInteger y=0;y<template->height;y++)for(NSInteger x=0;x<template->width;x++)if(y==0||x==0||y==template->height-1||x==template->width-1) {
        const uint8_t *pixel=template->rgba+(y*template->width+x)*4;for(NSInteger ch=0;ch<3;ch++)[channels[ch] addObject:@(pixel[ch])];
    }
    double background[3];for(NSInteger ch=0;ch<3;ch++){NSArray *sorted=[channels[ch] sortedArrayUsingSelector:@selector(compare:)];background[ch]=[sorted[sorted.count/2] doubleValue];}
    NSInteger foreground=0,missing=0;
    for(NSInteger y=0;y<template->height;y++)for(NSInteger x=0;x<template->width;x++) {
        const uint8_t *pixel=template->rgba+(y*template->width+x)*4;double difference=0;for(NSInteger ch=0;ch<3;ch++)difference=MAX(difference,fabs(pixel[ch]-background[ch]));if(difference<48)continue;foreground++;
        BOOL covered=NO;for(NSDictionary *region in regions){NSArray *r=region[@"rect"];double x0=[r[0] doubleValue]*template->width-2,y0=[r[1] doubleValue]*template->height-2,x1=[r[2] doubleValue]*template->width+2,y1=[r[3] doubleValue]*template->height+2;if(x>=x0&&x<x1&&y>=y0&&y<y1){covered=YES;break;}}if(!covered)missing++;
    }
    return missing<=MAX(8,foreground*.01);
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

    NSArray<NSValue *> *seeds = @[];

    if (factor > 1) {
        ADTGrayBuffer shotC = {0, 0, NULL};
        ADTGrayBuffer tplC = {0, 0, NULL};
        if (ADTDownsample(&shot, factor, &shotC) && ADTDownsample(&tpl, factor, &tplC)) {
            ADTIntegralImage integral = {NULL, NULL, 0, 0};
            ADTIntegralImage integral2 = {NULL, NULL, 0, 0};
            if (ADTBuildIntegral(&shotC, &integral) && ADTBuildIntegral(&shotC, &integral2)) {
                NSDictionary<NSNumber *, NSNumber *> *scores = nil;
                NSArray<NSValue *> *candidates = ADTCoarseCandidates(&shotC, &tplC, &integral, &integral2, &scores);
                seeds = candidates;
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
        if (seeds.count > 0) {
          for (NSValue *seed in seeds) {
            NSInteger centerX = (NSInteger)seed.CGPointValue.x * factor;
            NSInteger centerY = (NSInteger)seed.CGPointValue.y * factor;
            NSInteger radius = MAX(2 * factor, 4);
            double score = 0.0;
            NSInteger x = 0;
            NSInteger y = 0;
            if (ADTBestNCCOffset(&shot, &tpl, &shotIntegral, &shotIntegral2,
                                 centerX - radius, centerY - radius, centerX + radius, centerY + radius,
                                 &score, &x, &y)) {
                if (score > bestScore) {
                    bestScore = score;
                    bestX = x;
                    bestY = y;
                }
            }
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
            };
        }
    }
    ADTFreeIntegral(&shotIntegral);
    ADTFreeIntegral(&shotIntegral2);
    [self freeGrayBuffer:&shot];
    [self freeGrayBuffer:&tpl];
    return result;
}

+ (NSDictionary *)matchImageStrict:(UIImage *)screenshot template:(UIImage *)template options:(NSDictionary *)options {
    id profile=[options[@"image_match"] isKindOfClass:NSDictionary.class]?options[@"image_match"][@"profile"]:nil;
    if([profile isEqual:@"adaptive-v2"])return [self matchImageAdaptive:screenshot template:template options:options];
    if(profile&&![profile isEqual:@"strict-v1"])return @{@"status":@"unsupported",@"reason":@"unsupported_profile",@"matcher_version":@"strict-v1",@"point":NSNull.null,@"candidates":@[]};
    double started=ADTStrictNow(),timeout=5000,epoch=NSDate.date.timeIntervalSince1970*1000;
    if([options[@"timeout_ms"] isKindOfClass:NSNumber.class])timeout=[options[@"timeout_ms"] doubleValue];
    timeout=MAX(1,MIN(15000,timeout));
    if([options[@"deadline_ms"] isKindOfClass:NSNumber.class])timeout=MIN(timeout,[options[@"deadline_ms"] doubleValue]-epoch);
    double deadline=started+timeout/1000.;
    NSMutableArray *candidates=[NSMutableArray array];NSMutableDictionary *quality=[NSMutableDictionary dictionary];
    NSDictionary *(^finish)(NSString *,NSString *,NSDictionary *)=^NSDictionary *(NSString *status,NSString *reason,NSDictionary *best) {
        NSMutableDictionary *result=[@{@"status":status,@"reason":reason,@"matcher_version":@"strict-v1",@"candidates":candidates,
                                      @"point":NSNull.null,@"quality":quality,@"timings":@{@"total_ms":@((ADTStrictNow()-started)*1000)}} mutableCopy];
        if(best){result[@"point"]=best[@"point"];result[@"rect"]=best[@"rect"];}
        return result;
    };
    ADTStrictPixels full={0},shot={0},original={0};ADTStrictFeatures feature={0};
    @try {
        if(!isfinite(timeout)||ADTStrictNow()>=deadline)return finish(@"unstable",@"deadline_exceeded",nil);
        double anchor[2]={.5,.5},source[2]={0,0},region[4]={0,0,1,1};
        if(!ADTStrictNumbers(options,@"tap_anchor",2,anchor)||anchor[0]<0||anchor[0]>1||anchor[1]<0||anchor[1]>1)
            return finish(@"invalid_template",@"invalid_tap_anchor",nil);
        if(!ADTStrictNumbers(options,@"source_size",2,source)||
           (options[@"source_size"]&&options[@"source_size"]!=NSNull.null&&(source[0]<=0||source[1]<=0||floor(source[0])!=source[0]||floor(source[1])!=source[1])))
            return finish(@"invalid_template",@"invalid_source_size",nil);
        if(!ADTStrictNumbers(options,@"search_region",4,region)||!(0<=region[0]&&region[0]<region[2]&&region[2]<=1&&0<=region[1]&&region[1]<region[3]&&region[3]<=1))
            return finish(@"invalid_template",@"invalid_search_region",nil);
        if(!ADTStrictRead(screenshot,&full)||!ADTStrictRead(template,&original)||!ADTStrictExtract(&original,&feature))
            return finish(@"invalid_template",@"invalid_image",nil);
        NSString *qualityReason=MIN(original.width,original.height)<8?@"template_too_small":feature.std<=.5?@"constant_template":feature.count==0?@"no_foreground":@"ok";
        NSMutableArray *warnings=[NSMutableArray array];
        if(feature.std<10)[warnings addObject:@"low_contrast"];
        if(feature.density<.02)[warnings addObject:@"sparse_features"];
        if(feature.density>.6)[warnings addObject:@"dense_texture"];
        [quality addEntriesFromDictionary:@{@"gray_std":@(feature.std),@"edge_count":@(feature.count),@"edge_density":@(feature.density),
                                           @"colorful":@(feature.colorful),@"size":@[@(original.width),@(original.height)],
                                           @"valid":@([qualityReason isEqualToString:@"ok"]),@"reason":qualityReason,@"warnings":warnings}];
        if(![qualityReason isEqualToString:@"ok"])return finish(@"invalid_template",qualityReason,nil);
        double base=1;
        if(source[0]>0) {
            double sx=full.width/source[0],sy=full.height/source[1];
            if(fabs(sx/sy-1)>.03)return finish(@"unsupported",@"aspect_ratio_changed",nil);
            base=(sx+sy)/2;
        }
        NSInteger left=(NSInteger)floor(region[0]*full.width),top=(NSInteger)floor(region[1]*full.height);
        NSInteger right=MIN(full.width,(NSInteger)ceil(region[2]*full.width)),bottom=MIN(full.height,(NSInteger)ceil(region[3]*full.height));
        if(!ADTStrictCrop(&full,left,top,right-left,bottom-top,&shot))return finish(@"not_found",@"empty_search_region",nil);
        NSArray *scales=@[@1,@.95,@1.05,@.9,@1.1,@.85,@1.15,@.8,@1.2];
        NSMutableSet *sizes=[NSMutableSet set];NSMutableArray *proposals=[NSMutableArray array];BOOL overflow=NO;
        double searchStarted=ADTStrictNow();
        for(NSNumber *scale in scales) {
            if(ADTStrictNow()>=deadline)return finish(@"unstable",@"deadline_exceeded",nil);
            NSInteger w=(NSInteger)round(original.width*base*scale.doubleValue),h=(NSInteger)round(original.height*base*scale.doubleValue);
            NSString *sizeKey=[NSString stringWithFormat:@"%ldx%ld",(long)w,(long)h];
            if(MIN(w,h)<8||w>shot.width||h>shot.height||[sizes containsObject:sizeKey])continue;
            [sizes addObject:sizeKey];
            UIImage *scaled=(w==original.width&&h==original.height)?template:[self scaleImage:template sx:(double)w/original.width sy:(double)h/original.height];
            ADTStrictPixels tpl={0};ADTGrayBuffer coarseShot={0},coarseTpl={0};ADTIntegralImage fullIntegral={0};
            @try {
                if(!scaled||!ADTStrictRead(scaled,&tpl))continue;
                // Preserve at least eight pixels on the short template side.
                // In particular, a small icon can never collapse into a 1px template.
                NSInteger factor=MAX(1,MIN((NSInteger)ceil(MAX(shot.width,shot.height)/320.),MIN(w,h)/8));
                const ADTGrayBuffer *searchGray=&shot.gray,*templateGray=&tpl.gray;
                if(factor>1) {
                    if(!ADTDownsample(&shot.gray,factor,&coarseShot)||!ADTDownsample(&tpl.gray,factor,&coarseTpl))continue;
                    searchGray=&coarseShot;templateGray=&coarseTpl;
                }
                BOOL scaleOverflow=NO;
                // Coarse peaks are proposals, not verified independent objects.
                // Enumerate every coarse peak within the deadline; only original
                // pixel NCC >= .82 can consume the 20-candidate safety limit.
                NSArray *seeds=ADTStrictSeeds(searchGray,templateGray,factor==1?.82:.45,factor==1?20:0,deadline,factor==1?&scaleOverflow:NULL);
                if(factor>1&&!ADTBuildIntegral(&shot.gray,&fullIntegral))return finish(@"unsupported",@"allocation_failed",nil);
                NSMutableArray *scaleProposals=[NSMutableArray array];
                for(NSDictionary *seed in seeds) {
                    if(ADTStrictNow()>=deadline)return finish(@"unstable",@"deadline_exceeded",nil);
                    double score=[seed[@"score"] doubleValue];NSInteger x=[seed[@"x"] integerValue],y=[seed[@"y"] integerValue];
                    if(factor>1) {
                        NSInteger radius=factor+1,cx=x*factor,cy=y*factor;
                        if(!ADTStrictNCC(&shot.gray,&tpl.gray,&fullIntegral,cx-radius,cy-radius,cx+radius,cy+radius,deadline,&score,&x,&y,NULL))continue;
                    }
                    if(score<.82)continue;
                    NSArray *rect=@[@(x+left),@(y+top),@(w),@(h)];BOOL duplicate=NO;
                    for(NSDictionary *previous in scaleProposals)if(ADTStrictSameRect(previous[@"rect"],rect)){duplicate=YES;break;}
                    if(duplicate)continue;
                    [scaleProposals addObject:@{@"rect":rect,@"similarity":@(score),@"image":scaled}];
                    if(scaleProposals.count>20){scaleOverflow=YES;break;}
                }
                overflow=overflow||scaleOverflow;
                [proposals addObjectsFromArray:scaleProposals];
            } @finally {
                ADTStrictFree(&tpl);[self freeGrayBuffer:&coarseShot];[self freeGrayBuffer:&coarseTpl];ADTFreeIntegral(&fullIntegral);
            }
        }
        double searchMS=(ADTStrictNow()-searchStarted)*1000,verifyStarted=ADTStrictNow();NSMutableArray *verified=[NSMutableArray array];
        for(NSDictionary *p in proposals) {
            if(ADTStrictNow()>=deadline)return finish(@"unstable",@"deadline_exceeded",nil);
            NSArray *r=p[@"rect"];NSInteger x=[r[0] integerValue],y=[r[1] integerValue],w=[r[2] integerValue],h=[r[3] integerValue];
            ADTStrictPixels tpl={0},crop={0};
            @try {
                if(!ADTStrictRead(p[@"image"],&tpl)||!ADTStrictCrop(&full,x,y,w,h,&crop))return finish(@"unsupported",@"allocation_failed",nil);
                NSDictionary *metrics=ADTStrictVerify(&tpl,&crop,[p[@"similarity"] doubleValue]);
                if(!metrics)return finish(@"unsupported",@"allocation_failed",nil);
                [verified addObject:@{@"rect":r,@"point":@[@(MIN(full.width-1,x+MIN(w-1,anchor[0]*w))),@(MIN(full.height-1,y+MIN(h-1,anchor[1]*h)))],
                                      @"similarity":p[@"similarity"],@"metrics":metrics,@"accepted":metrics[@"accepted"]}];
            } @finally { ADTStrictFree(&tpl);ADTStrictFree(&crop); }
        }
        [verified sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
            NSComparisonResult accepted=[b[@"accepted"] compare:a[@"accepted"]];return accepted!=NSOrderedSame?accepted:[b[@"similarity"] compare:a[@"similarity"]];
        }];
        for(NSDictionary *candidate in verified) {
            BOOL duplicate=NO;for(NSDictionary *other in candidates)if(ADTStrictSameRect(candidate[@"rect"],other[@"rect"])){duplicate=YES;break;}
            if(!duplicate)[candidates addObject:candidate];
            if(candidates.count>64){overflow=YES;[candidates removeLastObject];break;}
        }
        NSMutableArray *accepted=[NSMutableArray array];for(NSDictionary *candidate in candidates)if([candidate[@"accepted"] boolValue])[accepted addObject:candidate];
        NSDictionary *best=accepted.firstObject;NSString *status=@"not_found",*reason=@"no_verified_candidate";
        if(overflow){status=@"ambiguous";reason=@"candidate_overflow";}
        else if(accepted.count>1){status=@"ambiguous";reason=@"multiple_verified_targets";}
        else if(best) {
            status=@"matched";reason=@"unique_verified_target";
            for(NSDictionary *other in candidates)if(other!=best&&[other[@"similarity"] doubleValue]>=.90&&
                [best[@"similarity"] doubleValue]-[other[@"similarity"] doubleValue]<.03&&[other[@"metrics"][@"edge_coverage"] doubleValue]>=.80&&
                [other[@"metrics"][@"foreground_error"] doubleValue]<=.16){status=@"ambiguous";reason=@"insufficient_margin";break;}
        }
        if(ADTStrictNow()>=deadline)return finish(@"unstable",@"deadline_exceeded",nil);
        NSMutableDictionary *result=[finish(status,reason,[status isEqualToString:@"matched"]?best:nil) mutableCopy];
        result[@"timings"]=@{@"total_ms":@((ADTStrictNow()-started)*1000),@"search_ms":@(searchMS),@"verification_ms":@((ADTStrictNow()-verifyStarted)*1000)};
        return result;
    } @finally { ADTStrictFree(&full);ADTStrictFree(&shot);ADTStrictFree(&original);ADTStrictFreeFeatures(&feature); }
}

+ (nullable UIImage *)adaptiveResizeImage:(UIImage *)image width:(NSInteger)width height:(NSInteger)height {
    ADTStrictPixels source={0},output={0};
    @try {if(!ADTStrictRead(image,&source)||!ADTAdaptiveResize(&source,width,height,&output))return nil;return ADTAdaptiveImage(&output);}
    @finally {ADTStrictFree(&source);ADTStrictFree(&output);}
}

+ (NSDictionary *)matchImageAdaptive:(UIImage *)screenshot template:(UIImage *)template options:(NSDictionary *)options {
    double started=ADTStrictNow(),epoch=NSDate.date.timeIntervalSince1970*1000,timeout=[options[@"timeout_ms"] isKindOfClass:NSNumber.class]?[options[@"timeout_ms"] doubleValue]:10000;
    timeout=MAX(1,MIN(10000,timeout));if([options[@"deadline_ms"] isKindOfClass:NSNumber.class])timeout=MIN(timeout,[options[@"deadline_ms"] doubleValue]-epoch);
    double deadline=started+timeout/1000.;NSMutableArray *candidates=[NSMutableArray array];NSMutableDictionary *quality=[NSMutableDictionary dictionary];
    NSDictionary *(^finish)(NSString *,NSString *,NSDictionary *)=^NSDictionary *(NSString *status,NSString *reason,NSDictionary *best){
        if([reason isEqual:@"deadline_exceeded"])status=@"unstable";
        NSMutableDictionary *result=[@{@"status":status,@"reason":reason,@"matcher_version":@"adaptive-v2",@"candidates":candidates,@"quality":quality,@"point":NSNull.null,@"timings":@{@"total_ms":@((ADTStrictNow()-started)*1000)}} mutableCopy];
        if(best){result[@"rect"]=best[@"rect"];result[@"point"]=best[@"point"];result[@"region_matches"]=best[@"region_matches"]?:@{};}return result;
    };
    for(NSString *key in @[@"timeout_ms",@"deadline_ms"])if(options[key]&&!ADTAdaptiveNumber(options[key]))return finish(@"unsupported",@"invalid_deadline",nil);
    if(!isfinite(timeout)||timeout<=0)return finish(@"unsupported",@"deadline_exceeded",nil);
    NSDictionary *contract=[options[@"image_match"] isKindOfClass:NSDictionary.class]?options[@"image_match"]:@{};
    NSString *canonical=[contract[@"descriptor_canonical"] isKindOfClass:NSString.class]?contract[@"descriptor_canonical"]:nil;
    NSDictionary *descriptor=nil;
    if(canonical) {
        NSData *data=[canonical dataUsingEncoding:NSUTF8StringEncoding];
        if(![ADTAdaptiveSHA(data) isEqual:contract[@"descriptor_sha256"]])return finish(@"unsupported",@"descriptor_digest_mismatch",nil);
        id parsed=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if(![parsed isKindOfClass:NSDictionary.class])return finish(@"unsupported",@"invalid_descriptor",nil);descriptor=parsed;
        if(contract[@"descriptor"]&&![descriptor isEqual:contract[@"descriptor"]])return finish(@"unsupported",@"descriptor_mismatch",nil);
        NSString *templateSHA=[contract[@"template_sha256"] isKindOfClass:NSString.class]?contract[@"template_sha256"]:nil;
        NSCharacterSet *hex=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
        if(templateSHA.length!=64||[templateSHA rangeOfCharacterFromSet:hex.invertedSet].location!=NSNotFound||![templateSHA isEqual:options[@"template_sha256"]])return finish(@"unsupported",@"template_digest_mismatch",nil);
    } else if(contract[@"descriptor"]||contract[@"descriptor_sha256"])return finish(@"unsupported",@"descriptor_canonical_missing",nil);
    ADTStrictPixels full={0},original={0},visualPixels={0},searchPixels={0};ADTStrictFeatures features={0};
    @try {
        if(!ADTStrictRead(screenshot,&full)||!ADTStrictRead(template,&original)||!ADTStrictExtract(&original,&features))return finish(@"unsupported",@"invalid_image",nil);
        if(MIN(original.width,original.height)<8||features.std<=.5||features.count==0)return finish(@"invalid_template",@"invalid_visual_template",nil);
        [quality addEntriesFromDictionary:@{@"valid":@YES,@"size":@[@(original.width),@(original.height)],@"gray_std":@(features.std),@"reason":@"ok"}];
        double search[4]={0,0,1,1};if(!ADTStrictNumbers(options,@"search_region",4,search)||!(0<=search[0]&&search[0]<search[2]&&search[2]<=1&&0<=search[1]&&search[1]<search[3]&&search[3]<=1))return finish(@"unsupported",@"invalid_search_region",nil);
        NSInteger left=floor(search[0]*full.width),top=floor(search[1]*full.height),right=ceil(search[2]*full.width),bottom=ceil(search[3]*full.height);
        CGRect searchBox=CGRectMake(left,top,right-left,bottom-top);
        if(!ADTStrictCrop(&full,left,top,right-left,bottom-top,&searchPixels))return finish(@"unsupported",@"allocation_failed",nil);
        NSDictionary *visual=nil;NSMutableArray *texts=[NSMutableArray array];NSArray *relations=@[];double anchor[2]={.5,.5};NSString *visualID=@"whole";CGRect visualRect=CGRectMake(0,0,original.width,original.height);
        if(descriptor) {
            if(!ADTAdaptiveNumber(descriptor[@"schema_version"])||![descriptor[@"schema_version"] isEqual:@1]||![descriptor[@"regions"] isKindOfClass:NSArray.class]||![descriptor[@"relations"] isKindOfClass:NSArray.class])return finish(@"unsupported",@"unsupported_descriptor",nil);
            double size[2]={0,0};if(!ADTStrictNumbers(descriptor,@"template_size",2,size)||size[0]!=original.width||size[1]!=original.height)return finish(@"unsupported",@"descriptor_template_size_mismatch",nil);
            NSMutableSet *ids=[NSMutableSet set];
            for(id region in descriptor[@"regions"]) {
                if(![region isKindOfClass:NSDictionary.class]||![region[@"id"] isKindOfClass:NSString.class]||![region[@"id"] length]||[ids containsObject:region[@"id"]]||![region[@"required"] isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)region[@"required"])!=CFBooleanGetTypeID()||![region[@"required"] boolValue])return finish(@"unsupported",@"invalid_descriptor_region",nil);[ids addObject:region[@"id"]];
                double rect[4]={0};if(!ADTStrictNumbers(region,@"rect",4,rect)||!(0<=rect[0]&&rect[0]<rect[2]&&rect[2]<=1&&0<=rect[1]&&rect[1]<rect[3]&&rect[3]<=1))return finish(@"unsupported",@"invalid_descriptor_region",nil);
                if([region[@"kind"] isEqual:@"visual"]){if(visual)return finish(@"unsupported",@"unsupported_multiple_visual_regions",nil);visual=region;visualID=region[@"id"];visualRect=CGRectMake(floor(rect[0]*original.width+.5),floor(rect[1]*original.height+.5),floor(rect[2]*original.width+.5)-floor(rect[0]*original.width+.5),floor(rect[3]*original.height+.5)-floor(rect[1]*original.height+.5));}
                else if([region[@"kind"] isEqual:@"text"]&&[region[@"text"] isKindOfClass:NSString.class]&&ADTAdaptiveText(region[@"text"]).length)[texts addObject:region];
                else return finish(@"unsupported",@"invalid_descriptor_region",nil);
            }
            if(!visual)return finish(@"unsupported",@"visual_region_missing",nil);
            if(!ADTAdaptiveForegroundCovered(&original,descriptor[@"regions"]))return finish(@"unsupported",@"descriptor_uncovered_foreground",nil);
            if(!texts.count&&!CGRectEqualToRect(visualRect,CGRectMake(0,0,original.width,original.height)))return finish(@"unsupported",@"partial_visual_requires_text",nil);
            relations=descriptor[@"relations"];
            for(id relation in relations) {
                if(![relation isKindOfClass:NSDictionary.class]||![relation[@"visual"] isEqual:visualID]||![ids containsObject:relation[@"text"]]||![@[@"right",@"left",@"above",@"below"] containsObject:relation[@"direction"]])return finish(@"unsupported",@"invalid_descriptor_relation",nil);
                for(NSString *key in @[@"max_gap",@"max_alignment"])if(relation[key]&&(!ADTAdaptiveNumber(relation[key])||[relation[key] doubleValue]<0))return finish(@"unsupported",@"invalid_descriptor_relation",nil);
            }
            for(NSDictionary *text in texts){BOOL connected=NO;for(NSDictionary *relation in relations)if([relation[@"visual"] isEqual:visualID]&&[relation[@"text"] isEqual:text[@"id"]])connected=YES;if(!connected)return finish(@"unsupported",@"missing_text_relation",nil);}
            NSDictionary *tap=descriptor[@"tap"];if(![tap isKindOfClass:NSDictionary.class]||![ids containsObject:tap[@"region_id"]]||!ADTStrictNumbers(tap,@"anchor",2,anchor))return finish(@"unsupported",@"invalid_descriptor_tap",nil);
        } else if(!ADTStrictNumbers(options,@"tap_anchor",2,anchor))return finish(@"unsupported",@"invalid_tap_anchor",nil);
        if(anchor[0]<0||anchor[0]>1||anchor[1]<0||anchor[1]>1)return finish(@"unsupported",@"invalid_tap_anchor",nil);
        if(!ADTStrictCrop(&original,visualRect.origin.x,visualRect.origin.y,visualRect.size.width,visualRect.size.height,&visualPixels))return finish(@"unsupported",@"invalid_visual_region",nil);
        NSMutableDictionary *layers=[NSMutableDictionary dictionary];NSMutableArray *all=[NSMutableArray array];NSDictionary *visualResult=nil;
        if(texts.count) {
            // Precompute immutable screenshot layers once; both complete recall
            // branches then run in parallel without mutating shared FFT buffers.
            NSInteger maximumFactor=MAX(1,(NSInteger)ceil(MAX(searchPixels.width,searchPixels.height)/960.));
            for(NSInteger factor=1;factor<=maximumFactor;factor++){ADTAdaptiveLayer *layer=[[ADTAdaptiveLayer alloc] initWithPixels:&searchPixels factor:factor];if(!layer||![layer prepareFFT])return finish(@"unsupported",@"allocation_failed",nil);layers[@(factor)]=layer;}
            __block NSDictionary *wholeResult=nil,*composedResult=nil;const ADTStrictPixels *screenPointer=&searchPixels,*wholePointer=&original,*visualPointer=&visualPixels;
            dispatch_group_t group=dispatch_group_create();dispatch_queue_t queue=dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0);
            dispatch_group_async(group,queue,^{@autoreleasepool{wholeResult=ADTAdaptiveVisual(screenPointer,wholePointer,deadline,[layers mutableCopy]);}});
            dispatch_group_async(group,queue,^{@autoreleasepool{composedResult=ADTAdaptiveVisual(screenPointer,visualPointer,deadline,[layers mutableCopy]);}});
            dispatch_group_wait(group,DISPATCH_TIME_FOREVER);visualResult=composedResult;
            if(![wholeResult[@"status"] isEqual:@"ok"])return finish(@"unsupported",wholeResult[@"reason"]?:@"whole_search_incomplete",nil);
            quality[@"whole_timings"]=wholeResult[@"timings"]?:@{};
            for(NSDictionary *raw in wholeResult[@"candidates"]) {
                if(![raw[@"accepted"] boolValue])continue;
                CGRect wholeBox=ADTAdaptiveCGRect(raw[@"rect"]);wholeBox.origin.x+=left;wholeBox.origin.y+=top;
                NSMutableDictionary *matches=[NSMutableDictionary dictionary];
                for(NSDictionary *region in descriptor[@"regions"]) {
                    NSArray *r=region[@"rect"];CGRect box=CGRectMake(wholeBox.origin.x+[r[0] doubleValue]*wholeBox.size.width,wholeBox.origin.y+[r[1] doubleValue]*wholeBox.size.height,([r[2] doubleValue]-[r[0] doubleValue])*wholeBox.size.width,([r[3] doubleValue]-[r[1] doubleValue])*wholeBox.size.height);
                    matches[region[@"id"]]=@{@"rect":ADTAdaptiveRect(box),@"accepted":@YES,@"evidence":@"whole_image_strict"};
                }
                NSString *tapID=descriptor[@"tap"][@"region_id"];CGRect tapBox=ADTAdaptiveCGRect(matches[tapID][@"rect"]);
                NSMutableDictionary *candidate=[raw mutableCopy];candidate[@"rect"]=ADTAdaptiveRect(wholeBox);candidate[@"region_matches"]=matches;candidate[@"branch"]=@"whole";
                candidate[@"scale"]=@(wholeBox.size.width/original.width);
                candidate[@"point"]=@[@(tapBox.origin.x+MIN(tapBox.size.width-1,anchor[0]*tapBox.size.width)),@(tapBox.origin.y+MIN(tapBox.size.height-1,anchor[1]*tapBox.size.height))];
                [all addObject:candidate];
            }
        } else visualResult=ADTAdaptiveVisual(&searchPixels,&visualPixels,deadline,layers);
        if(visualResult[@"timings"])quality[@"visual_timings"]=visualResult[@"timings"];
        if(![visualResult[@"status"] isEqual:@"ok"]){[candidates addObjectsFromArray:all];return finish(@"unsupported",visualResult[@"reason"]?:@"visual_search_incomplete",nil);}
        BOOL uncertain=NO;
        for(NSDictionary *raw in visualResult[@"candidates"]) {
            NSMutableDictionary *candidate=[raw mutableCopy];CGRect visualBox=ADTAdaptiveCGRect(raw[@"rect"]);visualBox.origin.x+=left;visualBox.origin.y+=top;candidate[@"rect"]=ADTAdaptiveRect(visualBox);
            candidate[@"branch"]=texts.count?@"composed":@"whole";candidate[@"scale"]=@(visualBox.size.width/visualPixels.width);
            NSMutableDictionary *matches=[@{visualID:@{@"rect":candidate[@"rect"],@"accepted":raw[@"accepted"],@"metrics":raw[@"metrics"]}} mutableCopy];
            if(![raw[@"accepted"] boolValue]){candidate[@"region_matches"]=matches;[all addObject:candidate];continue;}
            BOOL alreadyProven=NO;
            if(texts.count)for(NSDictionary *other in all)if([other[@"accepted"] boolValue]&&[other[@"branch"] isEqual:@"whole"]&&ADTStrictSameRect(other[@"region_matches"][visualID][@"rect"],candidate[@"rect"])){alreadyProven=YES;break;}
            if(alreadyProven)continue;
            NSMutableArray *assemblies=[NSMutableArray arrayWithObject:@{@"rect":candidate[@"rect"],@"region_matches":matches}];
            if(texts.count) {
                double gap=2.;for(NSDictionary *relation in relations)gap=MAX(gap,[relation[@"max_gap"] doubleValue]);double expand=(gap+1)*MAX(visualBox.size.width,visualBox.size.height);
                CGRect cropBox=CGRectIntersection(searchBox,CGRectInset(visualBox,-expand,-expand));
                UIImage *crop=[self clipImage:screenshot x:floor(cropBox.origin.x) y:floor(cropBox.origin.y) width:ceil(cropBox.size.width) height:ceil(cropBox.size.height)];
                NSDictionary *ocr=[self recognizeTextItems:crop deadline:epoch+(deadline-started)*1000];
                if(![ocr[@"status"] isEqual:@"ok"]){uncertain=YES;continue;}
                if(![ocr[@"items"] count]){uncertain=YES;continue;}
                for(NSDictionary *text in texts) {
                    NSMutableArray *next=[NSMutableArray array];BOOL neighborEvidence=NO;
                    for(NSDictionary *item in ocr[@"items"]) {
                        NSArray *box=item[@"box"];double coordinates[4]={0};
                        if(![item[@"text"] isKindOfClass:NSString.class]||!ADTAdaptiveNumber(item[@"score"])||[item[@"score"] doubleValue]<0||[item[@"score"] doubleValue]>1||![box isKindOfClass:NSArray.class]||box.count!=4||!ADTStrictNumbers(item,@"box",4,coordinates)||coordinates[2]<=coordinates[0]||coordinates[3]<=coordinates[1])return finish(@"unsupported",@"invalid_ocr_contract",nil);
                        CGRect textBox=CGRectMake([box[0] doubleValue]+floor(cropBox.origin.x),[box[1] doubleValue]+floor(cropBox.origin.y),[box[2] doubleValue]-[box[0] doubleValue],[box[3] doubleValue]-[box[1] doubleValue]);BOOL satisfies=YES;
                        if(!CGRectContainsRect(cropBox,textBox)||!CGRectContainsRect(searchBox,textBox))continue;
                        for(NSDictionary *relation in relations)if([relation[@"text"] isEqual:text[@"id"]]&&(![relation[@"visual"] isEqual:visualID]||!ADTAdaptiveRelation(visualBox,textBox,relation)))satisfies=NO;
                        if(!satisfies)continue;
                        if([item[@"score"] doubleValue]<.90){uncertain=YES;continue;}
                        neighborEvidence=YES;
                        if(![ADTAdaptiveText(item[@"text"]) isEqual:ADTAdaptiveText(text[@"text"])])continue;
                        for(NSDictionary *assembly in assemblies){NSMutableDictionary *regionMatches=[assembly[@"region_matches"] mutableCopy];regionMatches[text[@"id"]]=@{@"rect":ADTAdaptiveRect(textBox),@"text":item[@"text"],@"score":item[@"score"],@"accepted":@YES};CGRect unionBox=CGRectUnion(ADTAdaptiveCGRect(assembly[@"rect"]),textBox);[next addObject:@{@"rect":ADTAdaptiveRect(unionBox),@"region_matches":regionMatches}];if(next.count>64)return finish(@"unsupported",@"candidate_overflow",nil);}
                    }
                    if(!neighborEvidence)uncertain=YES;
                    assemblies=next;
                }
            }
            for(NSDictionary *assembly in assemblies) {
                NSMutableDictionary *logical=[candidate mutableCopy];logical[@"rect"]=assembly[@"rect"];logical[@"region_matches"]=assembly[@"region_matches"];
                NSString *tapID=descriptor?descriptor[@"tap"][@"region_id"]:visualID;NSArray *tapRect=logical[@"region_matches"][tapID][@"rect"];if(!tapRect)return finish(@"unsupported",@"invalid_descriptor_tap",nil);
                CGRect tapBox=ADTAdaptiveCGRect(tapRect);CGPoint tapPoint=CGPointMake(tapBox.origin.x+MIN(tapBox.size.width-1,anchor[0]*tapBox.size.width),tapBox.origin.y+MIN(tapBox.size.height-1,anchor[1]*tapBox.size.height));
                if(!CGRectContainsRect(searchBox,ADTAdaptiveCGRect(logical[@"rect"]))||!CGRectContainsRect(searchBox,tapBox)||!CGRectContainsPoint(searchBox,tapPoint))return finish(@"unsupported",@"target_outside_search_region",nil);
                logical[@"point"]=@[@(tapPoint.x),@(tapPoint.y)];[all addObject:logical];
            }
        }
        if(uncertain||ADTStrictNow()>=deadline){[candidates addObjectsFromArray:all];return finish(@"unsupported",uncertain?@"ocr_incomplete":@"deadline_exceeded",nil);}
        [all sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){NSComparisonResult flag=[b[@"accepted"] compare:a[@"accepted"]];return flag==NSOrderedSame?[b[@"similarity"] compare:a[@"similarity"]]:flag;}];
        for(NSDictionary *candidate in all){BOOL duplicate=NO;for(NSDictionary *other in candidates)if(ADTAdaptiveSameCandidate(candidate,other))duplicate=YES;if(!duplicate)[candidates addObject:candidate];if(candidates.count>64)return finish(@"unsupported",@"candidate_overflow",nil);}
        NSMutableArray *accepted=[NSMutableArray array];for(NSDictionary *candidate in candidates)if([candidate[@"accepted"] boolValue])[accepted addObject:candidate];
        if(accepted.count>1)return finish(@"ambiguous",@"multiple_verified_targets",nil);
        if(!accepted.count)return finish(@"not_found",@"no_verified_candidate",nil);
        NSDictionary *best=accepted.firstObject;
        for(NSDictionary *other in candidates)if(other!=best&&[other[@"similarity"] doubleValue]>=.90&&[best[@"similarity"] doubleValue]-[other[@"similarity"] doubleValue]<.03&&[other[@"metrics"][@"edge_coverage"] doubleValue]>=.80&&[other[@"metrics"][@"foreground_error"] doubleValue]<=.16)return finish(@"ambiguous",@"insufficient_margin",nil);
        return finish(@"matched",@"unique_verified_target",best);
    } @finally {ADTStrictFree(&full);ADTStrictFree(&original);ADTStrictFree(&visualPixels);ADTStrictFree(&searchPixels);ADTStrictFreeFeatures(&features);}
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
                double sa2 = ADTIntegralRectSum(sumA2.sum2, (NSInteger)stride, x, y, win, win);
                double sb = ADTIntegralRectSum(sumB.sum, (NSInteger)stride, x, y, win, win);
                double sb2 = ADTIntegralRectSum(sumB2.sum2, (NSInteger)stride, x, y, win, win);
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

+ (NSDictionary *)recognizeTextItems:(UIImage *)image deadline:(double)deadlineMS {
    double now=NSDate.date.timeIntervalSince1970*1000;
    if(!isfinite(deadlineMS)||deadlineMS<=0)deadlineMS=now+10000;
    if(now>=deadlineMS)return @{@"status":@"unsupported",@"reason":@"deadline_exceeded",@"items":@[]};
    CGImageRef cg=image.CGImage;if(!cg)return @{@"status":@"unsupported",@"reason":@"invalid_image",@"items":@[]};
    CGFloat width=CGImageGetWidth(cg),height=CGImageGetHeight(cg);NSMutableArray *items=[NSMutableArray array];
    VNRecognizeTextRequest *request=[VNRecognizeTextRequest new];request.recognitionLevel=VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection=NO;request.recognitionLanguages=@[@"zh-Hans",@"en-US"];
    // No expected text, custom words, or alternate-candidate cherry-picking.
    VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];NSError *error=nil;
    if(![handler performRequests:@[request] error:&error])return @{@"status":@"unsupported",@"reason":@"ocr_failed",@"items":@[]};
    if(NSDate.date.timeIntervalSince1970*1000>=deadlineMS)return @{@"status":@"unsupported",@"reason":@"deadline_exceeded",@"items":@[]};
    for(VNRecognizedTextObservation *observation in request.results) {
        VNRecognizedText *candidate=[observation topCandidates:1].firstObject;if(!candidate.string.length)continue;
        CGRect box=observation.boundingBox;
        [items addObject:@{@"text":candidate.string,@"score":@(candidate.confidence),@"box":@[@(box.origin.x*width),@((1-CGRectGetMaxY(box))*height),@(CGRectGetMaxX(box)*width),@((1-box.origin.y)*height)]}];
    }
    return @{@"status":@"ok",@"items":items};
}

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
