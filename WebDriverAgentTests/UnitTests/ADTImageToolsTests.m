#import <XCTest/XCTest.h>
#import "ADTImageTools.h"
#import "ADTPrimitives.h"

@interface ADTImageToolsTests : XCTestCase
@end

@implementation ADTImageToolsTests

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
@end
