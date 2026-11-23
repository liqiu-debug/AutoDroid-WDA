#import <XCTest/XCTest.h>
#import "ADTImageTools.h"
#import "ADTPrimitives.h"
#import "ADTImageClickTextFixtures.h"
#import <CommonCrypto/CommonDigest.h>

static NSArray *ADTFixtureOCRItems;
static NSString *const ADTFixtureTemplateSHA=@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
@interface ADTFixtureImageTools : ADTImageTools
@end
@implementation ADTFixtureImageTools
+ (NSDictionary *)recognizeTextItems:(UIImage *)image deadline:(double)deadlineMS {
    return @{@"status":@"ok",@"items":ADTFixtureOCRItems?:@[]};
}
@end

@interface ADTImageToolsTests : XCTestCase
@end

@implementation ADTImageToolsTests

- (NSDictionary *)adaptiveContract:(NSDictionary *)descriptor
{
    NSData *data=[NSJSONSerialization dataWithJSONObject:descriptor options:NSJSONWritingSortedKeys error:NULL];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);NSMutableString *hex=[NSMutableString string];
    for(NSUInteger i=0;i<sizeof(digest);i++)[hex appendFormat:@"%02x",digest[i]];
    return @{@"profile":@"adaptive-v2",@"template_sha256":ADTFixtureTemplateSHA,@"descriptor":descriptor,@"descriptor_canonical":[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding],@"descriptor_sha256":hex};
}

- (void)testAdaptiveRefinesBetweenLegacyScalesWithoutRelaxingIdentity
{
    UIImage *template=[self patternWidth:93 height:81 seed:725];
    UIImage *scaled=[ADTImageTools adaptiveResizeImage:template width:109 height:95];
    UIImage *shot=[self strictShot:scaled positions:@[[NSValue valueWithCGPoint:CGPointMake(7,3)]]];
    NSDictionary *result=[ADTImageTools matchImageStrict:shot template:template options:@{@"image_match":@{@"profile":@"adaptive-v2"},@"timeout_ms":@10000}];
    XCTAssertEqualObjects(result[@"status"],@"matched",@"%@",result);
    XCTAssertEqualObjects(result[@"rect"],(@[@7,@3,@109,@95]));
    XCTAssertEqualObjects(result[@"matcher_version"],@"adaptive-v2");
    UIImage *wrong=[self patternWidth:93 height:81 seed:1541];
    XCTAssertNotEqualObjects([ADTImageTools matchImageStrict:shot template:wrong options:@{@"image_match":@{@"profile":@"adaptive-v2"}}][@"status"],@"matched");
}

- (void)testAdaptiveRecallsUniformScaleBeyondLegacyRange
{
    UIImage *template=[self patternWidth:28 height:24 seed:725];
    UIImage *scaled=[ADTImageTools adaptiveResizeImage:template width:56 height:48];
    UIImage *shot=[self strictShot:scaled positions:@[[NSValue valueWithCGPoint:CGPointMake(47,39)]]];
    NSDictionary *result=[ADTImageTools matchImageStrict:shot template:template options:@{@"image_match":@{@"profile":@"adaptive-v2"}}];
    XCTAssertEqualObjects(result[@"status"],@"matched",@"%@",result);
    XCTAssertEqualObjects(result[@"rect"],(@[@47,@39,@56,@48]));
}

- (void)testAdaptiveDescriptorBindingAndDeadlinesFailClosed
{
    UIImage *template=[self strictIconColor:UIColor.blackColor crossed:NO];
    UIImage *shot=[self strictShot:template positions:@[[NSValue valueWithCGPoint:CGPointMake(47,39)]]];
    NSDictionary *descriptor=@{@"schema_version":@1,@"template_size":@[@24,@24],@"regions":@[@{@"id":@"whole",@"kind":@"visual",@"required":@YES,@"rect":@[@0,@0,@1,@1]}],@"relations":@[],@"tap":@{@"region_id":@"whole",@"anchor":@[@.25,@.75]}};
    NSMutableDictionary *contract=[[self adaptiveContract:descriptor] mutableCopy];
    NSDictionary *bound=@{@"image_match":contract,@"template_sha256":ADTFixtureTemplateSHA};
    NSDictionary *matched=[ADTImageTools matchImageStrict:shot template:template options:bound];
    XCTAssertEqualObjects(matched[@"status"],@"matched",@"%@",matched);
    XCTAssertEqualObjects(matched[@"point"],(@[@53,@57]));
    contract[@"descriptor_sha256"]=@"corrupt";
    XCTAssertEqualObjects([ADTImageTools matchImageStrict:shot template:template options:bound][@"reason"],@"descriptor_digest_mismatch");
    NSDictionary *expired=[ADTImageTools matchImageStrict:shot template:template options:@{@"image_match":@{@"profile":@"adaptive-v2"},@"deadline_ms":@0}];
    XCTAssertEqualObjects(expired[@"status"],@"unstable");
    XCTAssertEqualObjects(expired[@"reason"],@"deadline_exceeded");
    XCTAssertEqualObjects([[ADTPrimitives new] jsOCRItems:0 deadline:0][@"status"],@"unsupported");
}

- (void)testAdaptiveCompositionRequiresExactTextGeometryAndConfidentOCR
{
    UIImage *icon=[self strictIconColor:UIColor.redColor crossed:NO];
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=1;
    UIImage *template=[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(120,40) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context){
        [UIColor.whiteColor setFill];UIRectFill(CGRectMake(0,0,120,40));[icon drawAtPoint:CGPointMake(2,8)];
        [@"Pay" drawAtPoint:CGPointMake(34,8) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:22],NSForegroundColorAttributeName:UIColor.blackColor}];
    }];
    UIImage *shot=[self strictShot:icon positions:@[[NSValue valueWithCGPoint:CGPointMake(47,39)]]];
    NSDictionary *descriptor=@{@"schema_version":@1,@"template_size":@[@120,@40],@"regions":@[@{@"id":@"logo",@"kind":@"visual",@"required":@YES,@"rect":@[@(2./120),@.2,@(26./120),@.8]},@{@"id":@"label",@"kind":@"text",@"required":@YES,@"rect":@[@.26,@0,@1,@1],@"text":@"Pay"}],@"relations":@[@{@"visual":@"logo",@"text":@"label",@"direction":@"right",@"max_gap":@2,@"max_alignment":@.5}],@"tap":@{@"region_id":@"logo",@"anchor":@[@.5,@.5]}};
    NSDictionary *options=@{@"image_match":[self adaptiveContract:descriptor],@"template_sha256":ADTFixtureTemplateSHA};
    @try {
        ADTFixtureOCRItems=@[@{@"text":@"Pay",@"score":@.99,@"box":@[@78,@40,@118,@62]}];
        NSDictionary *result=[ADTFixtureImageTools matchImageStrict:shot template:template options:options];
        XCTAssertEqualObjects(result[@"status"],@"matched",@"%@",result);
        XCTAssertEqualObjects(result[@"region_matches"][@"label"][@"text"],@"Pay");
        ADTFixtureOCRItems=@[@{@"text":@"Pav",@"score":@.99,@"box":@[@78,@40,@118,@62]}];
        XCTAssertEqualObjects([ADTFixtureImageTools matchImageStrict:shot template:template options:options][@"status"],@"not_found");
        ADTFixtureOCRItems=@[@{@"text":@"Pay",@"score":@.70,@"box":@[@78,@40,@118,@62]}];
        XCTAssertEqualObjects([ADTFixtureImageTools matchImageStrict:shot template:template options:options][@"status"],@"unsupported");
        ADTFixtureOCRItems=@[];
        XCTAssertEqualObjects([ADTFixtureImageTools matchImageStrict:shot template:template options:options][@"status"],@"unsupported");
        ADTFixtureOCRItems=@[@{@"text":@"Pay",@"score":@.99,@"box":@[@50,@42,@68,@60]}];
        XCTAssertNotEqualObjects([ADTFixtureImageTools matchImageStrict:shot template:template options:options][@"status"],@"matched");
        ADTFixtureOCRItems=@[@{@"text":@"Pay",@"score":@.99,@"box":@[@78,@40]}];
        XCTAssertEqualObjects([ADTFixtureImageTools matchImageStrict:shot template:template options:options][@"reason"],@"invalid_ocr_contract");
    } @finally {ADTFixtureOCRItems=nil;}
}

- (void)testAdaptiveWholeAndComposedStylesStillDetectDuplicateTargets
{
    UIImage *icon=[self strictIconColor:UIColor.redColor crossed:NO];
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=1;
    UIImage *template=[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(120,40) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context){
        [UIColor.whiteColor setFill];UIRectFill(CGRectMake(0,0,120,40));[icon drawAtPoint:CGPointMake(2,8)];[@"Pay" drawAtPoint:CGPointMake(34,8) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:22],NSForegroundColorAttributeName:UIColor.blackColor}];
    }];
    UIImage *shot=[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(280,180) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context){
        [UIColor.whiteColor setFill];UIRectFill(CGRectMake(0,0,280,180));[template drawAtPoint:CGPointMake(7,9)];[icon drawAtPoint:CGPointMake(142,108)];
        [@"Pay" drawAtPoint:CGPointMake(181,109) withAttributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:21],NSForegroundColorAttributeName:UIColor.blackColor}];
    }];
    NSDictionary *descriptor=@{@"schema_version":@1,@"template_size":@[@120,@40],@"regions":@[@{@"id":@"logo",@"kind":@"visual",@"required":@YES,@"rect":@[@(2./120),@.2,@(26./120),@.8]},@{@"id":@"label",@"kind":@"text",@"required":@YES,@"rect":@[@.26,@0,@1,@1],@"text":@"Pay"}],@"relations":@[@{@"visual":@"logo",@"text":@"label",@"direction":@"right",@"max_gap":@2,@"max_alignment":@.5}],@"tap":@{@"region_id":@"logo",@"anchor":@[@.5,@.5]}};
    ADTFixtureOCRItems=@[@{@"text":@"Pay",@"score":@.99,@"box":@[@114,@74,@157,@96]}];
    NSDictionary *result=[ADTFixtureImageTools matchImageStrict:shot template:template options:@{@"image_match":[self adaptiveContract:descriptor],@"template_sha256":ADTFixtureTemplateSHA}];
    ADTFixtureOCRItems=nil;
    XCTAssertEqualObjects(result[@"status"],@"ambiguous",@"%@",result);
    XCTAssertEqualObjects(result[@"point"],NSNull.null);
}

- (void)testAdaptiveSameLogoWithTwoCompleteLabelsRemainsAmbiguous
{
    UIImage *icon=[self strictIconColor:UIColor.redColor crossed:NO];
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=1;
    UIImage *template=[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(120,40) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context){
        [UIColor.whiteColor setFill];UIRectFill(CGRectMake(0,0,120,40));[icon drawAtPoint:CGPointMake(2,8)];[@"Pay" drawAtPoint:CGPointMake(34,8) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:22],NSForegroundColorAttributeName:UIColor.blackColor}];
    }];
    UIImage *shot=[self strictShot:icon positions:@[[NSValue valueWithCGPoint:CGPointMake(47,39)]]];
    NSDictionary *descriptor=@{@"schema_version":@1,@"template_size":@[@120,@40],@"regions":@[@{@"id":@"logo",@"kind":@"visual",@"required":@YES,@"rect":@[@(2./120),@.2,@(26./120),@.8]},@{@"id":@"label",@"kind":@"text",@"required":@YES,@"rect":@[@.26,@0,@1,@1],@"text":@"Pay"}],@"relations":@[@{@"visual":@"logo",@"text":@"label",@"direction":@"right",@"max_gap":@2,@"max_alignment":@.5}],@"tap":@{@"region_id":@"label",@"anchor":@[@.5,@.5]}};
    @try {
        ADTFixtureOCRItems=@[@{@"text":@"Pay",@"score":@.99,@"box":@[@73,@40,@91,@62]},@{@"text":@"Pay",@"score":@.99,@"box":@[@99,@40,@117,@62]}];
        NSDictionary *result=[ADTFixtureImageTools matchImageStrict:shot template:template options:@{@"image_match":[self adaptiveContract:descriptor],@"template_sha256":ADTFixtureTemplateSHA}];
        XCTAssertEqualObjects(result[@"status"],@"ambiguous",@"%@",result);
        XCTAssertEqualObjects(result[@"point"],NSNull.null);
        NSArray *accepted=[result[@"candidates"] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *candidate,NSDictionary *bindings){return [candidate[@"accepted"] boolValue];}]];
        XCTAssertEqual(accepted.count,2);
    } @finally {ADTFixtureOCRItems=nil;}
}

- (void)testAdaptiveSearchRegionConstrainsRequiredLabelAndTap
{
    UIImage *icon=[self strictIconColor:UIColor.redColor crossed:NO];
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=1;
    UIImage *template=[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(120,40) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context){
        [UIColor.whiteColor setFill];UIRectFill(CGRectMake(0,0,120,40));[icon drawAtPoint:CGPointMake(2,8)];[@"Pay" drawAtPoint:CGPointMake(34,8) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:22],NSForegroundColorAttributeName:UIColor.blackColor}];
    }];
    UIImage *shot=[self strictShot:icon positions:@[[NSValue valueWithCGPoint:CGPointMake(47,39)]]];
    NSDictionary *descriptor=@{@"schema_version":@1,@"template_size":@[@120,@40],@"regions":@[@{@"id":@"logo",@"kind":@"visual",@"required":@YES,@"rect":@[@(2./120),@.2,@(26./120),@.8]},@{@"id":@"label",@"kind":@"text",@"required":@YES,@"rect":@[@.26,@0,@1,@1],@"text":@"Pay"}],@"relations":@[@{@"visual":@"logo",@"text":@"label",@"direction":@"right",@"max_gap":@2,@"max_alignment":@.5}],@"tap":@{@"region_id":@"label",@"anchor":@[@.5,@.5]}};
    NSMutableDictionary *options=[@{@"image_match":[self adaptiveContract:descriptor],@"template_sha256":ADTFixtureTemplateSHA,@"search_region":@[@.25,@.2,@.8,@.8]} mutableCopy];
    @try {
        // OCR boxes are relative to the clamped crop [30,20,96,80].
        ADTFixtureOCRItems=@[@{@"text":@"Pay",@"score":@.99,@"box":@[@48,@20,@88,@42]}];
        NSDictionary *outside=[ADTFixtureImageTools matchImageStrict:shot template:template options:options];
        XCTAssertNotEqualObjects(outside[@"status"],@"matched",@"%@",outside);
        XCTAssertEqualObjects(outside[@"point"],NSNull.null);
        ADTFixtureOCRItems=@[@{@"text":@"Pay",@"score":@.99,@"box":@[@44,@20,@64,@42]}];
        NSDictionary *inside=[ADTFixtureImageTools matchImageStrict:shot template:template options:options];
        XCTAssertEqualObjects(inside[@"status"],@"matched",@"%@",inside);
        XCTAssertTrue([inside[@"point"][0] doubleValue]>=30&&[inside[@"point"][0] doubleValue]<96);
        XCTAssertTrue([inside[@"point"][1] doubleValue]>=20&&[inside[@"point"][1] doubleValue]<80);
    } @finally {ADTFixtureOCRItems=nil;}
}

- (void)testAdaptiveResizeUsesHalfPixelHalfUpGoldenPixels
{
    uint8_t pixels[]={0,0,0,255,100,100,100,255,200,200,200,255,255,255,255,255};
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);CGContextRef context=CGBitmapContextCreate(pixels,2,2,8,8,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGImageRef cg=CGBitmapContextCreateImage(context);UIImage *source=[UIImage imageWithCGImage:cg];CGImageRelease(cg);CGContextRelease(context);CGColorSpaceRelease(space);
    UIImage *resized=[ADTImageTools adaptiveResizeImage:source width:3 height:3];
    CGImageRef result=resized.CGImage;NSData *bytes=CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(result)));const uint8_t *rgb=bytes.bytes;
    uint8_t expected[]={0,50,100,100,139,178,200,228,255};
    for(NSInteger y=0;y<3;y++)for(NSInteger x=0;x<3;x++)for(NSInteger channel=0;channel<3;channel++)XCTAssertEqual(rgb[y*CGImageGetBytesPerRow(result)+x*4+channel],expected[y*3+x]);
}

- (void)testAdaptiveHistoricalReportsWhenProvided
{
    NSString *root=NSProcessInfo.processInfo.environment[@"ADT_IMAGE_REPORT_FIXTURES"]?:@"/tmp/autodroid-image-reports";
    for(NSString *number in @[@"156",@"161"]) {
        NSString *path=[root stringByAppendingPathComponent:[number stringByAppendingString:@".png"]];
        if(![NSFileManager.defaultManager fileExistsAtPath:path])continue;
        UIImage *screen=[UIImage imageWithContentsOfFile:path];NSString *name=[number isEqual:@"156"]?@"element_3b26083c02df78c9.png":@"element_ddcefbc8a6fbc8e6.png";
        UIImage *template=[UIImage imageWithContentsOfFile:[root stringByAppendingPathComponent:name]];
        NSMutableDictionary *options=[@{@"image_match":@{@"profile":@"adaptive-v2"},@"timeout_ms":@15000} mutableCopy];
        NSString *descriptorPath=[root stringByAppendingPathComponent:[number stringByAppendingString:@"-descriptor.json"]];
        NSDictionary *descriptor=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:descriptorPath]?:[NSData data] options:0 error:NULL];
        if(descriptor){options[@"image_match"]=[self adaptiveContract:descriptor];options[@"template_sha256"]=ADTFixtureTemplateSHA;}
        double started=NSProcessInfo.processInfo.systemUptime;NSDictionary *result=[ADTImageTools matchImageStrict:screen template:template options:options];
        NSLog(@"Adaptive report %@ %.3fs %@",number,NSProcessInfo.processInfo.systemUptime-started,result);
        XCTAssertEqualObjects(result[@"status"],@"matched",@"report %@ %@",number,result);
    }
}

- (void)testTemplateCachePathCreatesParentAndRemainsAReadableImageFile
{
    ADTPrimitives *primitives = [ADTPrimitives new];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    primitives.runBaseDir = root;
    @try {
        NSString *path = [root stringByAppendingPathComponent:@"autodroid_cache/template.png"];
        XCTAssertTrue([primitives fsEnsureDir:path]);
        XCTAssertFalse([primitives fsExists:path]);
        UIImage *image = [self patternWidth:72 height:56 seed:42];
        NSString *encoded = [UIImagePNGRepresentation(image) base64EncodedStringWithOptions:0];
        XCTAssertTrue([primitives jsFsWriteBytes:path base64:encoded]);
        XCTAssertTrue([primitives fsIsFile:path]);
        NSDictionary *handle = [primitives imageFromFile:path];
        XCTAssertNotNil(handle);
        XCTAssertEqualObjects(handle[@"width"], @72);
        [primitives releaseImage:[handle[@"id"] doubleValue]];
        XCTAssertTrue([primitives fsEnsureDir:[root stringByAppendingString:@"/nested/"]]);
        XCTAssertTrue([primitives fsIsDir:[root stringByAppendingPathComponent:@"nested"]]);
    } @finally {
        [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
    }
}

- (UIImage *)patternWidth:(NSInteger)width height:(NSInteger)height seed:(uint32_t)seed
{
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)(width * height)];
    uint8_t *pixels = data.mutableBytes;
    for (NSInteger y = 0; y < height; y++) {
        for (NSInteger x = 0; x < width; x++) {
            // Broad UI-like features survive coarse downsampling.
            uint32_t value = (uint32_t)(x / 8 + (y / 8) * 7919) ^ seed;
            value ^= value >> 16; value *= 0x7feb352d;
            value ^= value >> 15; value *= 0x846ca68b;
            value ^= value >> 16;
            pixels[y * width + x] = seed == UINT32_MAX ? ((x + y) % 2 ? 255 : 0) : (uint8_t)(40 + (value >> 24) % 180);
        }
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width, space, kCGImageAlphaNone);
    CGImageRef cg = CGBitmapContextCreateImage(context);
    UIImage *image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg); CGContextRelease(context); CGColorSpaceRelease(space);
    return image;
}

- (void)assertCropMatchesWidth:(NSInteger)width height:(NSInteger)height x:(NSInteger)x y:(NSInteger)y
{
    UIImage *shot = [self patternWidth:width height:height seed:42];
    UIImage *crop = [ADTImageTools clipImage:shot x:x y:y width:72 height:56];
    NSDictionary *result = [ADTImageTools matchTemplate:shot template:crop threshold:0.99];
    XCTAssertNotNil(result);
    XCTAssertEqualWithAccuracy([result[@"similarity"] doubleValue], 1.0, 0.0001);
    // Repeated features may have multiple valid positions: compare the matched pixels.
    UIImage *matched = [ADTImageTools clipImage:shot x:[result[@"x"] doubleValue] y:[result[@"y"] doubleValue] width:72 height:56];
    XCTAssertEqualWithAccuracy([ADTImageTools ssimBetween:matched second:crop], 1.0, 0.0001);
}

- (void)testNCCUsesSquaredIntegralOnSmallImage
{
    [self assertCropMatchesWidth:200 height:180 x:67 y:83];
}
- (void)testCoarseSearchFindsUnalignedCropAtPhoneResolution
{
    [self assertCropMatchesWidth:1179 height:2556 x:331 y:1297];
}
- (void)testSSIMIsOneForIdenticalImageAndLowerForDifferentImage
{
    UIImage *a = [self patternWidth:72 height:56 seed:42];
    // Fine checkerboard has different structure in every 4x4 SSIM window.
    // Two block patterns otherwise have zero local variance in most windows.
    UIImage *b = [self patternWidth:72 height:56 seed:UINT32_MAX];
    XCTAssertEqualWithAccuracy([ADTImageTools ssimBetween:a second:a], 1.0, 0.0001);
    XCTAssertLessThan([ADTImageTools ssimBetween:a second:b], 0.8);
}
- (void)testUnrelatedTemplateIsRejected
{
    UIImage *shot = [self patternWidth:200 height:180 seed:42];
    UIImage *other = [self patternWidth:72 height:56 seed:1234567];
    XCTAssertNil([ADTImageTools matchTemplate:shot template:other threshold:0.9]);
}
- (void)testOversizedTemplateIsRejected
{
    UIImage *small = [self patternWidth:32 height:32 seed:42];
    UIImage *large = [self patternWidth:64 height:64 seed:42];
    XCTAssertNil([ADTImageTools matchTemplate:small template:large threshold:0.9]);
}

- (UIImage *)strictIconColor:(UIColor *)color crossed:(BOOL)crossed
{
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=1;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(24,24) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.whiteColor setFill];UIRectFill(CGRectMake(0,0,24,24));
        [color setStroke];UIBezierPath *path=[UIBezierPath bezierPath];path.lineWidth=3;
        if(crossed){[path moveToPoint:CGPointMake(5,5)];[path addLineToPoint:CGPointMake(19,19)];[path moveToPoint:CGPointMake(19,5)];[path addLineToPoint:CGPointMake(5,19)];}
        else {[path moveToPoint:CGPointMake(4,12)];[path addLineToPoint:CGPointMake(20,12)];[path moveToPoint:CGPointMake(12,4)];[path addLineToPoint:CGPointMake(12,20)];}
        [path stroke];
    }];
}
- (UIImage *)strictShot:(UIImage *)icon positions:(NSArray<NSValue *> *)positions
{
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=1;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(120,100) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor colorWithWhite:.92 alpha:1] setFill];UIRectFill(CGRectMake(0,0,120,100));
        for(NSValue *point in positions)[icon drawAtPoint:point.CGPointValue];
    }];
}
- (void)testStrictRejectsFlatTemplateAndExpiredDeadline
{
    UIImage *icon=[self strictIconColor:UIColor.blackColor crossed:NO];
    UIImage *shot=[self strictShot:icon positions:@[[NSValue valueWithCGPoint:CGPointMake(47,39)]]];
    UIImage *blank=[ADTImageTools clipImage:shot x:0 y:0 width:16 height:16];
    XCTAssertEqualObjects([ADTImageTools matchImageStrict:shot template:blank options:@{}][@"status"],@"invalid_template");
    NSDictionary *expired=[ADTImageTools matchImageStrict:shot template:icon options:@{@"deadline_ms":@0}];
    XCTAssertEqualObjects(expired[@"status"],@"unstable");XCTAssertEqualObjects(expired[@"reason"],@"deadline_exceeded");
    XCTAssertEqualObjects(expired[@"point"],NSNull.null);
}
- (void)testStrictUniqueTargetRetainsOriginalPixelRectAndAnchor
{
    UIImage *icon=[self strictIconColor:UIColor.blackColor crossed:NO];
    UIImage *shot=[self strictShot:icon positions:@[[NSValue valueWithCGPoint:CGPointMake(47,39)]]];
    NSDictionary *result=[ADTImageTools matchImageStrict:shot template:icon options:@{@"tap_anchor":@[@.25,@.75]}];
    XCTAssertEqualObjects(result[@"status"],@"matched",@"%@",result);
    XCTAssertEqualObjects(result[@"rect"],(@[@47,@39,@24,@24]));
    XCTAssertEqualWithAccuracy([result[@"point"][0] doubleValue],53,.01);
    XCTAssertEqualWithAccuracy([result[@"point"][1] doubleValue],57,.01);
    XCTAssertEqualObjects(result[@"matcher_version"],@"strict-v1");
}
- (void)testStrictDuplicateTargetsAreAmbiguousButExplicitRegionDisambiguates
{
    UIImage *icon=[self strictIconColor:UIColor.blackColor crossed:NO];
    UIImage *shot=[self strictShot:icon positions:@[[NSValue valueWithCGPoint:CGPointMake(9,11)],[NSValue valueWithCGPoint:CGPointMake(76,61)]]];
    NSDictionary *result=[ADTImageTools matchImageStrict:shot template:icon options:@{}];
    XCTAssertEqualObjects(result[@"status"],@"ambiguous",@"%@",result);XCTAssertEqualObjects(result[@"point"],NSNull.null);
    NSDictionary *restricted=[ADTImageTools matchImageStrict:shot template:icon options:@{@"search_region":@[@.5,@.5,@1,@1]}];
    XCTAssertEqualObjects(restricted[@"status"],@"matched",@"%@",restricted);
    XCTAssertEqualObjects(restricted[@"rect"],(@[@76,@61,@24,@24]));
}
- (void)testStrictRejectsDifferentContourAndSameContourWithDifferentColour
{
    UIImage *plus=[self strictIconColor:UIColor.blackColor crossed:NO];
    UIImage *cross=[self strictIconColor:UIColor.blackColor crossed:YES];
    UIImage *shot=[self strictShot:cross positions:@[[NSValue valueWithCGPoint:CGPointMake(47,39)]]];
    XCTAssertNotEqualObjects([ADTImageTools matchImageStrict:shot template:plus options:@{}][@"status"],@"matched");
    UIImage *red=[self strictIconColor:UIColor.redColor crossed:NO],*green=[self strictIconColor:UIColor.greenColor crossed:NO];
    UIImage *greenShot=[self strictShot:green positions:@[[NSValue valueWithCGPoint:CGPointMake(47,39)]]];
    XCTAssertNotEqualObjects([ADTImageTools matchImageStrict:greenShot template:red options:@{}][@"status"],@"matched");
}
- (void)testStrictRejectsChangedAspectRatioAndMalformedGeometry
{
    UIImage *icon=[self strictIconColor:UIColor.blackColor crossed:NO];
    UIImage *shot=[self strictShot:icon positions:@[[NSValue valueWithCGPoint:CGPointMake(47,39)]]];
    NSDictionary *ratio=[ADTImageTools matchImageStrict:shot template:icon options:@{@"source_size":@[@120,@200]}];
    XCTAssertEqualObjects(ratio[@"reason"],@"aspect_ratio_changed");XCTAssertEqualObjects(ratio[@"status"],@"unsupported");
    XCTAssertEqualObjects(([ADTImageTools matchImageStrict:shot template:icon options:@{@"tap_anchor":@[@2,@.5]}][@"status"]),@"invalid_template");
}
- (void)testStrictSharedLabelAndBorderCannotHideOneChangedDigit
{
    UIImage *one=[UIImage imageWithData:[[NSData alloc] initWithBase64EncodedString:ADTOrder1PNGBase64 options:0]];
    UIImage *two=[UIImage imageWithData:[[NSData alloc] initWithBase64EncodedString:ADTOrder2PNGBase64 options:0]];
    XCTAssertNotNil(one);XCTAssertNotNil(two);if(!one||!two)return;
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=1;
    for(NSArray<UIImage *> *pair in @[@[one,two],@[two,one]]) {
        UIImage *(^shot)(UIImage *)=^UIImage *(UIImage *image) {
            return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(220,160) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [[UIColor colorWithWhite:245./255 alpha:1] setFill];UIRectFill(CGRectMake(0,0,220,160));
                [image drawAtPoint:CGPointMake(30,40)];
            }];
        };
        XCTAssertEqualObjects([ADTImageTools matchImageStrict:shot(pair[1]) template:pair[0] options:@{}][@"status"],@"not_found");
        XCTAssertEqualObjects([ADTImageTools matchImageStrict:shot(pair[0]) template:pair[0] options:@{}][@"status"],@"matched");
    }
}
- (void)testStrictPhoneCoarseSearchRefinesUnalignedSmallIconInOriginalPixels
{
    UIImage *icon=[self strictIconColor:UIColor.blackColor crossed:NO];
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=1;
    UIImage *shot=[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1179,2556) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor colorWithWhite:.92 alpha:1] setFill];UIRectFill(CGRectMake(0,0,1179,2556));[icon drawAtPoint:CGPointMake(331,1297)];
    }];
    NSDictionary *result=[ADTImageTools matchImageStrict:shot template:icon options:@{}];
    XCTAssertEqualObjects(result[@"status"],@"matched",@"%@",result);
    XCTAssertEqualObjects(result[@"rect"],(@[@331,@1297,@24,@24]));
    XCTAssertEqualObjects(result[@"point"],(@[@343,@1309]));
}
- (void)testStrictSourceSizeScalesGeometryAndEdgeAnchorStaysInsideTarget
{
    UIImage *icon=[self strictIconColor:UIColor.blackColor crossed:NO];
    UIImage *large=[ADTImageTools scaleImage:icon sx:2 sy:2];
    UIImage *shot=[self strictShot:large positions:@[[NSValue valueWithCGPoint:CGPointMake(47,39)]]];
    NSDictionary *result=[ADTImageTools matchImageStrict:shot template:icon options:@{@"source_size":@[@60,@50],@"tap_anchor":@[@1,@1]}];
    XCTAssertEqualObjects(result[@"status"],@"matched",@"%@",result);
    XCTAssertEqualObjects(result[@"rect"],(@[@47,@39,@48,@48]));
    XCTAssertEqualObjects(result[@"point"],(@[@94,@86]));
}
- (void)testStrictCoarseAliasesDoNotCountAsOriginalPixelCandidates
{
    // Eight-pixel blocks retain their coarse average; a balanced high-frequency
    // checkerboard makes the decoys unrelated at the original resolution.
    UIImage *source=[self patternWidth:64 height:64 seed:9271];
    ADTGrayBuffer raw={0};XCTAssertTrue([ADTImageTools fillGrayBuffer:&raw fromImage:source]);
    NSMutableData *tplBytes=[NSMutableData dataWithLength:64*64],*decoyBytes=[NSMutableData dataWithLength:64*64];
    uint8_t *tpl=tplBytes.mutableBytes,*decoy=decoyBytes.mutableBytes;
    for(NSInteger y=0;y<64;y++)for(NSInteger x=0;x<64;x++) {
        NSInteger i=y*64+x;tpl[i]=(uint8_t)(110+raw.data[i]*.15);
        decoy[i]=(uint8_t)(tpl[i]+((x+y)%2?80:-80));
    }
    [ADTImageTools freeGrayBuffer:&raw];
    UIImage *(^fromBytes)(NSMutableData *)=^UIImage *(NSMutableData *bytes) {
        CGColorSpaceRef space=CGColorSpaceCreateDeviceGray();CGContextRef context=CGBitmapContextCreate(bytes.mutableBytes,64,64,8,64,space,kCGImageAlphaNone);
        CGImageRef cg=CGBitmapContextCreateImage(context);UIImage *image=[UIImage imageWithCGImage:cg];CGImageRelease(cg);CGContextRelease(context);CGColorSpaceRelease(space);return image;
    };
    UIImage *template=fromBytes(tplBytes),*alias=fromBytes(decoyBytes);
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=1;
    UIImage *shot=[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1280,2816) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.whiteColor setFill];UIRectFill(CGRectMake(0,0,1280,2816));
        for(NSInteger i=0;i<80;i++)[alias drawAtPoint:CGPointMake(16+(i%8)*144,16+(i/8)*144)];
        [template drawAtPoint:CGPointMake(1056,2400)];
    }];
    NSDictionary *result=[ADTImageTools matchImageStrict:shot template:template options:@{@"timeout_ms":@15000}];
    XCTAssertEqualObjects(result[@"status"],@"matched",@"%@",result);
    XCTAssertEqualObjects(result[@"rect"],(@[@1056,@2400,@64,@64]));
}
- (void)testNativeFileHashUsesStoredBytes
{
    ADTPrimitives *primitives=[ADTPrimitives new];NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    primitives.runBaseDir=root;
    @try {
        XCTAssertTrue([primitives jsFsWriteBytes:@"bytes.txt" base64:@"YWJj"]);
        XCTAssertEqualObjects([primitives fileSha256:@"bytes.txt"],@"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    } @finally { [NSFileManager.defaultManager removeItemAtPath:root error:NULL]; }
}

- (void)testStrictSharedAcceptanceCorpus
{
    NSString *manifestPath=NSProcessInfo.processInfo.environment[@"ADT_IMAGE_ACCEPTANCE_MANIFEST"]?:@"/tmp/autodroid-image-acceptance/manifest.json";
    XCTSkipIf(![NSFileManager.defaultManager fileExistsAtPath:manifestPath],@"Shared acceptance corpus was not supplied; native capability remains unvalidated.");
    NSError *error=nil;NSData *data=[NSData dataWithContentsOfFile:manifestPath options:0 error:&error];
    NSDictionary *manifest=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:&error]:nil;
    XCTAssertNotNil(manifest,@"%@",error);if(!manifest)return;
    NSArray *cases=manifest[@"cases"];XCTAssertTrue([cases isKindOfClass:NSArray.class]&&cases.count>0);if(!cases.count)return;
    NSString *directory=manifestPath.stringByDeletingLastPathComponent;NSMutableArray *records=[NSMutableArray array],*durations=[NSMutableArray array];
    NSInteger positives=0,negatives=0,truePositives=0,falsePositives=0,wrongGeometry=0,loadErrors=0;
    for(NSDictionary *item in cases) @autoreleasepool {
        NSString *screenPath=item[@"screen"],*templatePath=item[@"template"];
        if(!screenPath.isAbsolutePath)screenPath=[directory stringByAppendingPathComponent:screenPath?:@""];
        if(!templatePath.isAbsolutePath)templatePath=[directory stringByAppendingPathComponent:templatePath?:@""];
        UIImage *screen=[UIImage imageWithContentsOfFile:screenPath],*template=[UIImage imageWithContentsOfFile:templatePath];
        BOOL positive=[item[@"label"] isEqual:@"positive"];if(positive)positives++;else negatives++;
        double started=NSProcessInfo.processInfo.systemUptime;
        NSDictionary *result;
        if(!screen||!template){loadErrors++;result=@{@"status":@"invalid_fixture",@"reason":@"image_load_failed"};}
        else result=[ADTImageTools matchImageStrict:screen template:template options:item[@"options"]?:@{}];
        double elapsed=(NSProcessInfo.processInfo.systemUptime-started)*1000;[durations addObject:@(elapsed)];
        BOOL matched=[result[@"status"] isEqual:@"matched"],correct=NO;double iou=0;
        NSArray *expected=item[@"expected_rect"],*actual=result[@"rect"],*point=result[@"point"];
        if(matched&&positive&&[expected isKindOfClass:NSArray.class]&&expected.count==4&&[actual isKindOfClass:NSArray.class]&&actual.count==4&&[point isKindOfClass:NSArray.class]&&point.count==2) {
            double ex=[expected[0] doubleValue],ey=[expected[1] doubleValue],ew=[expected[2] doubleValue],eh=[expected[3] doubleValue];
            double ax=[actual[0] doubleValue],ay=[actual[1] doubleValue],aw=[actual[2] doubleValue],ah=[actual[3] doubleValue];
            double intersection=MAX(0,MIN(ex+ew,ax+aw)-MAX(ex,ax))*MAX(0,MIN(ey+eh,ay+ah)-MAX(ey,ay));
            iou=intersection/MAX(1,ew*eh+aw*ah-intersection);
            double px=[point[0] doubleValue],py=[point[1] doubleValue];
            double minimumIOU=item[@"min_iou"]?[item[@"min_iou"] doubleValue]:.8;
            correct=iou>=minimumIOU&&px>=ex&&px<ex+ew&&py>=ey&&py<ey+eh;
        }
        if(positive&&correct)truePositives++;
        if(matched&&!positive)falsePositives++;
        if(matched&&positive&&!correct)wrongGeometry++;
        if(!positive)correct=!matched&&![result[@"status"] isEqual:@"invalid_fixture"];
        NSMutableDictionary *record=[@{@"id":item[@"id"]?:@"",@"label":positive?@"positive":@"negative",@"correct":@(correct),@"iou":@(iou),@"elapsed_ms":@(elapsed)} mutableCopy];
        [record addEntriesFromDictionary:result];[records addObject:record];
    }
    NSArray *sorted=[durations sortedArrayUsingSelector:@selector(compare:)];
    double (^percentile)(double)=^double(double p){double at=(sorted.count-1)*p;NSUInteger lo=(NSUInteger)floor(at),hi=(NSUInteger)ceil(at);return [sorted[lo] doubleValue]+([sorted[hi] doubleValue]-[sorted[lo] doubleValue])*(at-lo);};
    NSDictionary *summary=@{@"matcher_version":@"strict-v1",@"engine":@"wda_native",@"capability_validated":@NO,@"total":@(cases.count),@"positives":@(positives),@"negatives":@(negatives),
                            @"true_positives":@(truePositives),@"false_positives":@(falsePositives),@"wrong_geometry":@(wrongGeometry),@"fixture_load_errors":@(loadErrors),
                            @"recall":@(positives?(double)truePositives/positives:0),@"p50_ms":@(percentile(.5)),@"p95_ms":@(percentile(.95)),@"cases":records};
    NSData *report=[NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingPrettyPrinted error:&error];
    NSString *reportPath=[directory stringByAppendingPathComponent:@"wda-results.json"];
    XCTAssertTrue([report writeToFile:reportPath options:NSDataWritingAtomic error:&error],@"%@",error);
    NSLog(@"Strict shared acceptance: total=%ld TP=%ld/%ld FP=%ld/%ld wrong_geometry=%ld p50=%.2fms p95=%.2fms report=%@",(long)cases.count,(long)truePositives,(long)positives,(long)falsePositives,(long)negatives,(long)wrongGeometry,percentile(.5),percentile(.95),reportPath);
    XCTAssertEqual(loadErrors,0);XCTAssertEqual(falsePositives,0);XCTAssertEqual(wrongGeometry,0);
    // Recall and latency gates are evaluated against the shared manifest by the
    // release owner; this test never silently enables the native capability.
}

- (void)testAdaptiveSharedAcceptanceCorpus
{
    NSString *manifestPath=NSProcessInfo.processInfo.environment[@"ADT_IMAGE_ACCEPTANCE_MANIFEST"]?:@"/tmp/autodroid-image-acceptance/manifest.json";
    XCTSkipIf(![NSFileManager.defaultManager fileExistsAtPath:manifestPath],@"Shared corpus not supplied.");
    NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:manifestPath] options:0 error:NULL];
    NSString *directory=manifestPath.stringByDeletingLastPathComponent;NSInteger positives=0,negatives=0,truePositives=0,falsePositives=0,wrongGeometry=0;
    NSMutableArray *records=[NSMutableArray array];
    for(NSDictionary *item in manifest[@"cases"]) @autoreleasepool {
        NSString *screenPath=item[@"screen"],*templatePath=item[@"template"];
        if(!screenPath.isAbsolutePath)screenPath=[directory stringByAppendingPathComponent:screenPath];
        if(!templatePath.isAbsolutePath)templatePath=[directory stringByAppendingPathComponent:templatePath];
        UIImage *screen=[UIImage imageWithContentsOfFile:screenPath],*template=[UIImage imageWithContentsOfFile:templatePath];
        NSMutableDictionary *options=[item[@"options"] mutableCopy]?:[NSMutableDictionary dictionary];options[@"image_match"]=@{@"profile":@"adaptive-v2"};
        NSDictionary *result=[ADTImageTools matchImageStrict:screen template:template options:options];BOOL positive=[item[@"label"] isEqual:@"positive"],matched=[result[@"status"] isEqual:@"matched"];
        if(positive)positives++;else negatives++;
        if(!positive&&matched)falsePositives++;
        BOOL correct=!matched;
        if(positive&&matched) {
            NSArray *a=result[@"rect"],*e=item[@"expected_rect"],*point=result[@"point"];CGRect actual=CGRectMake([a[0] doubleValue],[a[1] doubleValue],[a[2] doubleValue],[a[3] doubleValue]),expected=CGRectMake([e[0] doubleValue],[e[1] doubleValue],[e[2] doubleValue],[e[3] doubleValue]);CGRect overlap=CGRectIntersection(actual,expected);double intersection=CGRectIsNull(overlap)?0:overlap.size.width*overlap.size.height,iou=intersection/MAX(1,actual.size.width*actual.size.height+expected.size.width*expected.size.height-intersection);
            correct=iou>=(item[@"min_iou"]?[item[@"min_iou"] doubleValue]:.8)&&CGRectContainsPoint(expected,CGPointMake([point[0] doubleValue],[point[1] doubleValue]));
            if(correct)truePositives++;else wrongGeometry++;
        }
        if(positive&&!matched)correct=NO;
        [records addObject:@{@"id":item[@"id"],@"correct":@(correct),@"status":result[@"status"],@"reason":result[@"reason"]}];
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"profile":@"adaptive-v2",@"positive":@(positives),@"true_positive":@(truePositives),@"negative":@(negatives),@"false_positive":@(falsePositives),@"wrong_geometry":@(wrongGeometry),@"cases":records} options:NSJSONWritingPrettyPrinted error:NULL];
    [data writeToFile:[directory stringByAppendingPathComponent:@"wda-adaptive-results.json"] atomically:YES];
    NSLog(@"Adaptive shared acceptance: TP=%ld/%ld FP=%ld/%ld geometry=%ld",(long)truePositives,(long)positives,(long)falsePositives,(long)negatives,(long)wrongGeometry);
    XCTAssertEqual(truePositives,positives);XCTAssertEqual(falsePositives,0);XCTAssertEqual(wrongGeometry,0);
}
@end
