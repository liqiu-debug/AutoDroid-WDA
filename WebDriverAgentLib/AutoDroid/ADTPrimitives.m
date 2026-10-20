/**
 * AutoDroid-WDA 原生原语实现
 *
 * 设计要点：
 *   - 元素查询复用 WebDriverAgent 自己的查询实现（XCUIElement+FBFind），
 *     保证与平台 PC 侧驱动（facebook-wda）语义一致；
 *   - 元素句柄保存在本地注册表里，XCUIElement 本身是惰性查询对象，
 *     页面变化后会自动重新解析，因此句柄可跨步骤继续使用；
 *   - 页面签名（用于 back / 点击无反馈判定）用一次 XML dump 计算，
 *     避免逐元素属性查询带来的大量 XPC 往返。
 */

#import "ADTPrimitives.h"
#import "ADTImageTools.h"

#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <sys/utsname.h>

#import "FBConfiguration.h"
#import "FBMathUtils.h"
#import "FBElement.h"
#import "FBKeyboard.h"
#import "FBSession.h"
#import "FBUnattachedAppLauncher.h"
#import "NSPredicate+FBFormat.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIApplication+FBQuiescence.h"
#import "XCUIApplication.h"
#import "XCUIElement+FBFind.h"
#import "XCUIElement+FBTyping.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBWebDriverAttributes.h"

// XCTest application creation, screenshots and lifecycle calls must use the
// main thread. AutoDroid scripts run on ADTRunner's serial background queue,
// unlike the normal WDA HTTP route queue. Keep script waits on the worker and
// marshal these native calls explicitly.
static void ADTPerformOnMainThread(dispatch_block_t block)
{
    if ([NSThread isMainThread]) {
        block();
    } else {
        // Exceptions must be caught on the executing thread, not allowed to
        // unwind through libdispatch. Report them back to the script caller.
        __block NSException *failure = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try {
                block();
            } @catch (NSException *exception) {
                failure = exception;
            }
        });
        if (failure != nil) {
            @throw failure;
        }
    }
}

#pragma mark - XML 节点解析（页面签名 / sourceNodes）

@interface ADTSourceXMLParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *nodes;
@property (nonatomic, assign) NSUInteger limit;
@end

@implementation ADTSourceXMLParser

- (instancetype)initWithLimit:(NSUInteger)limit
{
    if ((self = [super init])) {
        _nodes = [NSMutableArray array];
        _limit = limit;
    }
    return self;
}

- (void)parser:(NSXMLParser *)parser
didStartElement:(NSString *)elementName
  namespaceURI:(nullable NSString *)namespaceURI
 qualifiedName:(nullable NSString *)qName
    attributes:(NSDictionary<NSString *, NSString *> *)attributeDict
{
    if (self.nodes.count >= self.limit) {
        return;
    }
    NSString *type = attributeDict[@"type"];
    NSString *name = attributeDict[@"name"];
    NSString *label = attributeDict[@"label"];
    NSString *value = attributeDict[@"value"];
    CGRect rect = CGRectZero;
    NSString *rectText = attributeDict[@"rect"];
    if (rectText.length > 0) {
        NSArray<NSNumber *> *numbers = [self.class extractNumbers:rectText];
        if (numbers.count >= 4) {
            CGFloat x = numbers[0].doubleValue;
            CGFloat y = numbers[1].doubleValue;
            CGFloat w = numbers[2].doubleValue;
            CGFloat h = numbers[3].doubleValue;
            rect = CGRectMake(x, y, w, h);
        }
    }
    NSString *text = label.length > 0 ? label : (value.length > 0 ? value : name);
    BOOL hasText = (text.length > 0);
    if (!hasText && rect.size.width <= 0) {
        return;
    }
    [self.nodes addObject:@{
        @"type": type ?: @"",
        @"text": text ?: @"",
        @"desc": name ?: @"",
        @"bounds": @{@"x": @(rect.origin.x), @"y": @(rect.origin.y), @"width": @(rect.size.width), @"height": @(rect.size.height)},
    }];
}

+ (NSArray<NSNumber *> *)extractNumbers:(NSString *)text
{
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar character = [text characterAtIndex:i];
        if ((character >= '0' && character <= '9') || character == '-' || character == '.') {
            [current appendFormat:@"%C", character];
        } else if (current.length > 0) {
            [numbers addObject:@(current.doubleValue)];
            current = [NSMutableString string];
        }
    }
    if (current.length > 0) {
        [numbers addObject:@(current.doubleValue)];
    }
    return numbers;
}

@end

#pragma mark - 原语实现

@interface ADTPrimitives ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, XCUIElement *> *elementRegistry;
@property (nonatomic, assign) NSInteger nextElementId;
@property (nonatomic, strong) NSMutableDictionary<NSString *, XCUIApplication *> *applicationCache;
@property (nonatomic, strong) NSMutableArray<NSString *> *logs;
@property (nonatomic, assign) BOOL screenCapturePrepared;
@end

@implementation ADTPrimitives

- (instancetype)init
{
    if ((self = [super init])) {
        _elementRegistry = [NSMutableDictionary dictionary];
        _applicationCache = [NSMutableDictionary dictionary];
        _logs = [NSMutableArray array];
        _nextElementId = 1;
    }
    return self;
}

#pragma mark - 日志

- (void)appendLog:(NSString *)level message:(NSString *)message
{
    NSString *line = [NSString stringWithFormat:@"[%@] %@", level, message ?: @""];
    @synchronized (self.logs) {
        [self.logs addObject:line];
        if (self.logs.count > 4000) {
            [self.logs removeObjectsInRange:NSMakeRange(0, 1000)];
        }
    }
    if (self.logHandler != nil) {
        self.logHandler(level, message ?: @"");
    }
}

- (void)jsLog:(NSString *)level message:(NSString *)message
{
    [self appendLog:level ?: @"log" message:message];
}

- (void)jsSleep:(double)milliseconds
{
    NSTimeInterval seconds = MAX(0.0, milliseconds / 1000.0);
    if (seconds > 0) {
        [NSThread sleepForTimeInterval:seconds];
    }
}

#pragma mark - 设备信息与截图

- (XCUIApplication *)targetApplication
{
    if (![NSThread isMainThread]) {
        __block XCUIApplication *application = nil;
        ADTPerformOnMainThread(^{ application = [self targetApplication]; });
        return application;
    }
    if (self.activeBundleID.length > 0) {
        XCUIApplication *cached = self.applicationCache[self.activeBundleID];
        if (cached != nil) {
            return cached;
        }
        XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:self.activeBundleID];
        self.applicationCache[self.activeBundleID] = app;
        return app;
    }
    XCUIApplication *sessionApp = FBSession.activeSession.activeApplication;
    if (sessionApp != nil) {
        return sessionApp;
    }
    return [XCUIApplication fb_activeApplication];
}

- (CGFloat)screenScale
{
    if (![NSThread isMainThread]) {
        __block CGFloat scale = 1.0;
        ADTPerformOnMainThread(^{ scale = [self screenScale]; });
        return scale;
    }
    UIImage *image = [self rawScreenshot];
    CGFloat pixelWidth = 0;
    if (image != nil) {
        CGImageRef cgImage = image.CGImage;
        pixelWidth = cgImage != NULL ? (CGFloat)(size_t)CGImageGetWidth(cgImage) : image.size.width * image.scale;
    }
    CGFloat pointWidth = 0;
    XCUIApplication *app = [self targetApplication];
    if (app != nil) {
        CGRect frame = app.frame;
        pointWidth = frame.size.width;
    }
    if (pointWidth <= 0) {
        pointWidth = UIScreen.mainScreen.bounds.size.width;
    }
    if (pixelWidth <= 0 || pointWidth <= 0) {
        return MAX(1.0, UIScreen.mainScreen.scale);
    }
    return MAX(1.0, pixelWidth / pointWidth);
}

- (nullable UIImage *)rawScreenshot
{
    if (![NSThread isMainThread]) {
        __block UIImage *image = nil;
        ADTPerformOnMainThread(^{ image = [self rawScreenshot]; });
        return image;
    }
    XCUIScreen *screen = XCUIScreen.mainScreen;
    if (screen == nil) {
        return nil;
    }
    XCUIScreenshot *screenshot = screen.screenshot;
    if (screenshot == nil) {
        return nil;
    }
    return screenshot.image;
}

- (NSDictionary *)deviceInfo
{
    if (![NSThread isMainThread]) {
        __block NSDictionary * result = nil;
        ADTPerformOnMainThread(^{ result = [self deviceInfo]; });
        return result;
    }
    UIImage *image = [self rawScreenshot];
    CGFloat pixelWidth = 0;
    CGFloat pixelHeight = 0;
    if (image != nil) {
        CGImageRef cgImage = image.CGImage;
        if (cgImage != NULL) {
            pixelWidth = (CGFloat)(size_t)CGImageGetWidth(cgImage);
            pixelHeight = (CGFloat)(size_t)CGImageGetHeight(cgImage);
        } else {
            pixelWidth = image.size.width * image.scale;
            pixelHeight = image.size.height * image.scale;
        }
    }
    if (pixelWidth <= 0) {
        pixelWidth = 0;
        pixelHeight = 0;
    }
    struct utsname systemInfo;
    NSString *machine = @"iPhone";
    if (uname(&systemInfo) == 0) {
        machine = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding] ?: @"iPhone";
    }
    NSString *systemVersion = UIDevice.currentDevice.systemVersion ?: @"";
    NSInteger majorVersion = 0;
    NSArray<NSString *> *parts = [systemVersion componentsSeparatedByString:@"."];
    if (parts.count > 0) {
        majorVersion = parts.firstObject.integerValue;
    }
    NSString *serial = self.deviceSerial.length > 0
        ? self.deviceSerial
        : (UIDevice.currentDevice.identifierForVendor.UUIDString ?: @"unknown");
    return @{
        // runtime.js 约定：width/height 为截图像素，与 Android 侧同一坐标系
        @"width": @(pixelWidth),
        @"height": @(pixelHeight),
        @"scale": @([self screenScale]),
        @"model": machine,
        @"brand": @"Apple",
        @"release": systemVersion,
        @"sdkInt": @(majorVersion),
        @"serial": serial,
        @"androidId": serial,
    };
}

- (nullable NSDictionary *)screenshot
{
    UIImage *image = [self rawScreenshot];
    if (image == nil) {
        return nil;
    }
    NSInteger handle = [ADTImageTools registerImage:image];
    CGSize size = [ADTImageTools pixelSizeForHandle:handle];
    return @{@"id": @(handle), @"width": @(size.width), @"height": @(size.height)};
}

#pragma mark - 图像

- (nullable NSDictionary *)wrapHandle:(NSInteger)handle
{
    if (handle <= 0) {
        return nil;
    }
    CGSize size = [ADTImageTools pixelSizeForHandle:handle];
    if (CGSizeEqualToSize(size, CGSizeZero)) {
        return nil;
    }
    return @{@"id": @(handle), @"width": @(size.width), @"height": @(size.height)};
}

- (nullable NSDictionary *)imageFromFile:(NSString *)path
{
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (image == nil) {
        return nil;
    }
    return [self wrapHandle:[ADTImageTools registerImage:image]];
}

- (nullable NSDictionary *)imageFromBase64:(NSString *)base64
{
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (data == nil) {
        return nil;
    }
    UIImage *image = [UIImage imageWithData:data];
    if (image == nil) {
        return nil;
    }
    return [self wrapHandle:[ADTImageTools registerImage:image]];
}

- (nullable NSDictionary *)imageGrayscale:(double)handle
{
    UIImage *image = [ADTImageTools imageForHandle:(NSInteger)handle];
    if (image == nil) {
        return nil;
    }
    UIImage *gray = [ADTImageTools grayscaleImage:image];
    return gray != nil ? [self wrapHandle:[ADTImageTools registerImage:gray]] : nil;
}

- (nullable NSDictionary *)jsImageClip:(double)handle x:(double)x y:(double)y width:(double)width height:(double)height
{
    UIImage *image = [ADTImageTools imageForHandle:(NSInteger)handle];
    if (image == nil) {
        return nil;
    }
    UIImage *clipped = [ADTImageTools clipImage:image x:x y:y width:width height:height];
    return clipped != nil ? [self wrapHandle:[ADTImageTools registerImage:clipped]] : nil;
}

- (nullable NSDictionary *)jsImageScale:(double)handle sx:(double)sx sy:(double)sy
{
    UIImage *image = [ADTImageTools imageForHandle:(NSInteger)handle];
    if (image == nil) {
        return nil;
    }
    UIImage *scaled = [ADTImageTools scaleImage:image sx:sx sy:sy];
    return scaled != nil ? [self wrapHandle:[ADTImageTools registerImage:scaled]] : nil;
}

- (NSString *)jsImageToBase64:(double)handle format:(NSString *)format quality:(double)quality
{
    UIImage *image = [ADTImageTools imageForHandle:(NSInteger)handle];
    if (image == nil) {
        return @"";
    }
    return [ADTImageTools base64FromImage:image format:format ?: @"jpeg" quality:quality] ?: @"";
}

- (BOOL)jsImageSave:(double)handle path:(NSString *)path overwrite:(BOOL)overwrite
{
    UIImage *image = [ADTImageTools imageForHandle:(NSInteger)handle];
    if (image == nil || path.length == 0) {
        return NO;
    }
    NSString *fullPath = [self resolvePath:path];
    NSData *data = UIImagePNGRepresentation(image);
    if (data == nil) {
        return NO;
    }
    [self ensureParentDirectory:fullPath];
    return [data writeToFile:fullPath atomically:YES];
}

- (void)releaseImage:(double)handle
{
    [ADTImageTools releaseHandle:(NSInteger)handle];
}

- (nullable NSDictionary *)jsMatchTemplate:(double)shotHandle template:(double)templateHandle threshold:(double)threshold max:(double)maxCount
{
    UIImage *shot = [ADTImageTools imageForHandle:(NSInteger)shotHandle];
    UIImage *template = [ADTImageTools imageForHandle:(NSInteger)templateHandle];
    if (shot == nil || template == nil) {
        return nil;
    }
    return [ADTImageTools matchTemplate:shot template:template threshold:threshold];
}

- (double)jsSsim:(double)firstHandle second:(double)secondHandle
{
    UIImage *first = [ADTImageTools imageForHandle:(NSInteger)firstHandle];
    UIImage *second = [ADTImageTools imageForHandle:(NSInteger)secondHandle];
    if (first == nil || second == nil) {
        return 0.0;
    }
    return (double)[ADTImageTools ssimBetween:first second:second];
}

- (NSArray<NSString *> *)ocr:(double)handle
{
    UIImage *image = [ADTImageTools imageForHandle:(NSInteger)handle];
    if (image == nil) {
        return @[];
    }
    return [ADTImageTools recognizeText:image];
}

#pragma mark - 元素

- (nullable NSDictionary *)parseSpec:(NSString *)specJson
{
    NSData *data = [specJson dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

- (NSArray<NSNumber *> *)findElements:(NSString *)specJson
{
    if (![NSThread isMainThread]) {
        __block NSArray<NSNumber *> * result = nil;
        ADTPerformOnMainThread(^{ result = [self findElements:specJson]; });
        return result;
    }
    NSDictionary *spec = [self parseSpec:specJson];
    if (spec == nil) {
        return @[];
    }
    NSString *kind = [spec[@"kind"] isKindOfClass:NSString.class] ? spec[@"kind"] : @"";
    NSString *value = [spec[@"value"] isKindOfClass:NSString.class] ? spec[@"value"] : @"";
    BOOL firstOnly = [spec[@"first"] boolValue];
    if (value.length == 0) {
        return @[];
    }
    XCUIApplication *app = [self targetApplication];
    if (app == nil) {
        return @[];
    }

    NSArray<XCUIElement *> *found = @[];
    @try {
        if ([kind isEqualToString:@"predicate"]) {
            NSPredicate *predicate = [NSPredicate fb_snapshotBlockPredicateWithPredicate:[NSPredicate predicateWithFormat:value]];
            found = [app fb_descendantsMatchingPredicate:predicate shouldReturnAfterFirstMatch:firstOnly] ?: @[];
        } else if ([kind isEqualToString:@"accessibility id"]) {
            found = [app fb_descendantsMatchingIdentifier:value shouldReturnAfterFirstMatch:firstOnly] ?: @[];
        } else if ([kind isEqualToString:@"class name"]) {
            found = [app fb_descendantsMatchingClassName:value shouldReturnAfterFirstMatch:firstOnly] ?: @[];
        } else if ([kind isEqualToString:@"xpath"]) {
            found = [app fb_descendantsMatchingXPathQuery:value shouldReturnAfterFirstMatch:firstOnly] ?: @[];
        }
    } @catch (NSException *exception) {
        [self appendLog:@"warn" message:[NSString stringWithFormat:@"元素查询失败: %@ (%@)", value, exception.reason ?: @""]];
        return @[];
    }

    NSMutableArray<NSNumber *> *handles = [NSMutableArray array];
    for (XCUIElement *element in found) {
        NSInteger elementId = self.nextElementId++;
        self.elementRegistry[@(elementId)] = element;
        [handles addObject:@(elementId)];
    }
    return handles;
}

- (nullable XCUIElement *)elementForId:(double)elementId
{
    return self.elementRegistry[@((NSInteger)elementId)];
}

- (NSString *)jsElementAttribute:(double)elementId name:(NSString *)name
{
    if (![NSThread isMainThread]) {
        __block NSString * result = nil;
        ADTPerformOnMainThread(^{ result = [self jsElementAttribute:elementId name:name]; });
        return result;
    }
    XCUIElement *element = [self elementForId:elementId];
    if (element == nil) {
        return @"";
    }
    NSString *key = [name lowercaseString] ?: @"";
    @try {
        if ([key isEqualToString:@"text"]) {
            NSString *label = element.wdLabel;
            if (label.length > 0) {
                return label;
            }
            NSString *name = element.wdName;
            if (name.length > 0) {
                return name;
            }
            return element.wdValue ?: @"";
        }
        if ([key isEqualToString:@"desc"] || [key isEqualToString:@"name"]) {
            NSString *name = element.wdName;
            return name.length > 0 ? name : (element.wdLabel ?: @"");
        }
        if ([key isEqualToString:@"identifier"] || [key isEqualToString:@"id"]) {
            return element.identifier ?: @"";
        }
        if ([key isEqualToString:@"value"]) {
            return element.wdValue ?: @"";
        }
        if ([key isEqualToString:@"type"] || [key isEqualToString:@"class"]) {
            return element.wdType ?: @"";
        }
        if ([key isEqualToString:@"visible"]) {
            return element.wdVisible ? @"1" : @"0";
        }
        if ([key isEqualToString:@"enabled"]) {
            return element.wdEnabled ? @"1" : @"0";
        }
        if ([key isEqualToString:@"selected"]) {
            return element.wdSelected ? @"1" : @"0";
        }
    } @catch (NSException *exception) {
        return @"";
    }
    return @"";
}

- (nullable NSDictionary *)elementRect:(double)elementId
{
    if (![NSThread isMainThread]) {
        __block NSDictionary * result = nil;
        ADTPerformOnMainThread(^{ result = [self elementRect:elementId]; });
        return result;
    }
    XCUIElement *element = [self elementForId:elementId];
    if (element == nil) {
        return nil;
    }
    @try {
        CGRect frame = element.wdFrame;
        return @{@"x": @(frame.origin.x), @"y": @(frame.origin.y), @"width": @(frame.size.width), @"height": @(frame.size.height)};
    } @catch (NSException *exception) {
        return nil;
    }
}

- (BOOL)elementClick:(double)elementId
{
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        ADTPerformOnMainThread(^{ result = [self elementClick:elementId]; });
        return result;
    }
    XCUIElement *element = [self elementForId:elementId];
    if (element == nil) {
        return NO;
    }
    @try {
        if (!element.exists) {
            return NO;
        }
        [element tap];
        return YES;
    } @catch (NSException *exception) {
        [self appendLog:@"warn" message:[NSString stringWithFormat:@"点击失败: %@", exception.reason ?: @""]];
        return NO;
    }
}

- (BOOL)elementLongClick:(double)elementId
{
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        ADTPerformOnMainThread(^{ result = [self elementLongClick:elementId]; });
        return result;
    }
    XCUIElement *element = [self elementForId:elementId];
    if (element == nil) {
        return NO;
    }
    @try {
        if (!element.exists) {
            return NO;
        }
        [element pressForDuration:1.0];
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

- (BOOL)jsElementSetText:(double)elementId text:(NSString *)text
{
    XCUIElement *element = [self elementForId:elementId];
    if (element == nil) {
        return NO;
    }
    @try {
        __block BOOL exists = NO;
        ADTPerformOnMainThread(^{
            exists = element.exists;
            if (exists) {
                [element tap];
            }
        });
        if (!exists) {
            return NO;
        }
        [NSThread sleepForTimeInterval:0.4];
        __block NSError *error = nil;
        __block BOOL ok = NO;
        ADTPerformOnMainThread(^{ ok = [element fb_typeText:text shouldClear:YES error:&error]; });
        if (!ok) {
            [self appendLog:@"warn" message:[NSString stringWithFormat:@"setText 失败: %@", error.localizedDescription ?: @""]];
        }
        return ok;
    } @catch (NSException *exception) {
        return NO;
    }
}

- (NSArray<NSDictionary *> *)sourceNodes
{
    if (![NSThread isMainThread]) {
        __block NSArray<NSDictionary *> * result = nil;
        ADTPerformOnMainThread(^{ result = [self sourceNodes]; });
        return result;
    }
    XCUIApplication *app = [self targetApplication];
    if (app == nil) {
        return @[];
    }
    NSString *xml = nil;
    @try {
        xml = [app fb_xmlRepresentation];
    } @catch (NSException *exception) {
        return @[];
    }
    if (xml.length == 0) {
        return @[];
    }
    ADTSourceXMLParser *parser = [[ADTSourceXMLParser alloc] initWithLimit:600];
    NSXMLParser *xmlParser = [[NSXMLParser alloc] initWithData:[xml dataUsingEncoding:NSUTF8StringEncoding]];
    xmlParser.delegate = parser;
    [xmlParser parse];
    return parser.nodes;
}

/// 页面签名：文本 + 位置的结构指纹，用于 back / 点击无反馈判定
- (NSString *)pageSignatureHash
{
    NSArray<NSDictionary *> *nodes = [self sourceNodes];
    NSMutableString *joined = [NSMutableString string];
    NSUInteger limit = MIN(nodes.count, (NSUInteger)400);
    for (NSUInteger i = 0; i < limit; i++) {
        NSDictionary *node = nodes[i];
        NSDictionary *bounds = node[@"bounds"];
        [joined appendFormat:@"%@@%.0f,%.0f,%.0f,%.0f|",
         node[@"text"] ?: @"",
         [bounds[@"x"] doubleValue], [bounds[@"y"] doubleValue],
         [bounds[@"width"] doubleValue], [bounds[@"height"] doubleValue]];
    }
    // Java String.hashCode 语义，便于与 Android 侧日志对齐阅读
    int32_t hash = 0;
    for (NSUInteger i = 0; i < joined.length; i++) {
        hash = (int32_t)(31 * hash + (int32_t)[joined characterAtIndex:i]);
    }
    return [NSString stringWithFormat:@"%d", hash];
}

#pragma mark - 手势

- (nullable XCUICoordinate *)pixelCoordinate:(CGFloat)pixelX y:(CGFloat)pixelY
{
    if (![NSThread isMainThread]) {
        __block XCUICoordinate * result = nil;
        ADTPerformOnMainThread(^{ result = [self pixelCoordinate:pixelX y:pixelY]; });
        return result;
    }
    XCUIApplication *app = [self targetApplication];
    if (app == nil) {
        return nil;
    }
    CGFloat scale = [self screenScale];
    NSError *error = nil;
    XCUICoordinate *coordinate = FBCoordinateWithAnchorOffset(app, CGVectorMake(0, 0),
                                                             CGVectorMake(pixelX / scale, pixelY / scale),
                                                             &error);
    if (coordinate == nil) {
        [self appendLog:@"warn" message:[NSString stringWithFormat:@"坐标换算失败: %@", error.localizedDescription ?: @""]];
    }
    return coordinate;
}

- (BOOL)jsTap:(double)x y:(double)y
{
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        ADTPerformOnMainThread(^{ result = [self jsTap:x y:y]; });
        return result;
    }
    XCUICoordinate *coordinate = [self pixelCoordinate:x y:y];
    if (coordinate == nil) {
        return NO;
    }
    @try {
        [coordinate tap];
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

- (BOOL)jsLongPress:(double)x y:(double)y duration:(double)duration
{
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        ADTPerformOnMainThread(^{ result = [self jsLongPress:x y:y duration:duration]; });
        return result;
    }
    XCUICoordinate *coordinate = [self pixelCoordinate:x y:y];
    if (coordinate == nil) {
        return NO;
    }
    @try {
        [coordinate pressForDuration:MAX(0.3, duration / 1000.0)];
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

- (BOOL)jsDrag:(double)x1 y1:(double)y1 x2:(double)x2 y2:(double)y2 duration:(double)duration
{
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        ADTPerformOnMainThread(^{ result = [self jsDrag:x1 y1:y1 x2:x2 y2:y2 duration:duration]; });
        return result;
    }
    XCUICoordinate *from = [self pixelCoordinate:x1 y:y1];
    XCUICoordinate *to = [self pixelCoordinate:x2 y:y2];
    if (from == nil || to == nil) {
        return NO;
    }
    @try {
        [from pressForDuration:0.05 thenDragToCoordinate:to];
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

- (BOOL)pressHome
{
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        ADTPerformOnMainThread(^{ result = [self pressHome]; });
        return result;
    }
    @try {
        [XCUIDevice.sharedDevice pressButton:XCUIDeviceButtonHome];
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

/// iOS 无系统返回键：左缘右滑 → 常见返回按钮，均以页面签名变化判定是否生效
- (BOOL)pressBack
{
    NSString *before = [self pageSignatureHash];
    NSArray<NSNumber *> *ratios = @[@0.2, @0.5, @0.8];
    CGFloat pixelWidth = [self deviceInfo][@"width"] ? [[self deviceInfo][@"width"] doubleValue] : 0;
    CGFloat pixelHeight = [self deviceInfo][@"height"] ? [[self deviceInfo][@"height"] doubleValue] : 0;
    for (NSNumber *ratio in ratios) {
        CGFloat y = pixelHeight * ratio.doubleValue;
        [self jsDrag:2 y1:y x2:pixelWidth * 0.55 y2:y duration:250];
        if ([self waitForPageChangeFrom:before timeout:0.9]) {
            return YES;
        }
    }
    if ([self tapCommonBackButton]) {
        if ([self waitForPageChangeFrom:before timeout:1.2]) {
            return YES;
        }
    }
    [self appendLog:@"warn" message:@"back 未检测到页面变化"];
    return NO;
}

- (BOOL)tapCommonBackButton
{
    NSArray<NSString *> *labels = @[@"返回", @"返回上一页", @"Back", @"back", @"Close", @"Cancel"];
    NSArray<NSNumber *> *handles = [self findElements:[self jsonForSpec:@{@"kind": @"predicate",
                                                                        @"value": [NSString stringWithFormat:@"(label IN {'%@'})", [labels componentsJoinedByString:@"','"]]}]];
    for (NSNumber *handle in handles) {
        if ([self elementClick:handle.doubleValue]) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)jsonForSpec:(NSDictionary *)spec
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:spec options:0 error:NULL];
    return data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

- (BOOL)waitForPageChangeFrom:(NSString *)before timeout:(NSTimeInterval)timeout
{
    if (before.length == 0) {
        return NO;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.15];
        NSString *now = [self pageSignatureHash];
        if (now.length > 0 && ![now isEqualToString:before]) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)activeApp
{
    if (![NSThread isMainThread]) {
        __block NSString * result = nil;
        ADTPerformOnMainThread(^{ result = [self activeApp]; });
        return result;
    }
    XCUIApplication *app = [XCUIApplication fb_activeApplication];
    @try {
        return app.bundleID ?: @"";
    } @catch (NSException *exception) {
        return @"";
    }
}

- (BOOL)launchApp:(NSString *)bundleId
{
    if (bundleId.length == 0) {
        return NO;
    }
    @try {
        __block BOOL launched = NO;
        ADTPerformOnMainThread(^{
            XCUIApplication *app = self.applicationCache[bundleId];
            if (app == nil) {
                app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
                self.applicationCache[bundleId] = app;
            }
            // Reuse WDA's session launcher so startup follows the same lifecycle
            // as the normal iOS driver. Direct XCUIApplication launch is
            // unreliable for a non-AUT app in a long-lived WDA session.
            FBSession *session = FBSession.activeSession;
            if (session != nil) {
                app = [session launchApplicationWithBundleId:bundleId
                                      shouldWaitForQuiescence:@NO
                                                    arguments:nil
                                                  environment:nil];
                self.applicationCache[bundleId] = app;
            } else {
                app.fb_shouldWaitForQuiescence = NO;
                [app launch];
            }
            // Fall back to the system launcher while WDA is attaching.
            launched = app.running || [FBUnattachedAppLauncher launchAppWithBundleId:bundleId];
        });
        if (!launched) {
            return NO;
        }
        self.activeBundleID = bundleId;
        [NSThread sleepForTimeInterval:0.6];
        return YES;
    } @catch (NSException *exception) {
        [self appendLog:@"warn" message:[NSString stringWithFormat:@"启动应用失败: %@ (%@)", bundleId, exception.reason ?: @""]];
        return NO;
    }
}

- (BOOL)terminateApp:(NSString *)bundleId
{
    if (bundleId.length == 0) {
        return NO;
    }
    @try {
        __block BOOL stopped = NO;
        ADTPerformOnMainThread(^{
            XCUIApplication *app = self.applicationCache[bundleId];
            if (app == nil) {
                app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
                self.applicationCache[bundleId] = app;
            }
            [app terminate];
            stopped = app.state == XCUIApplicationStateNotRunning;
        });
        if (stopped && [self.activeBundleID isEqual:bundleId]) { self.activeBundleID = nil; }
        return stopped;
    } @catch (NSException *exception) {
        return NO;
    }
}

- (BOOL)typeText:(NSString *)text
{
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        ADTPerformOnMainThread(^{ result = [self typeText:text]; });
        return result;
    }
    if (text.length == 0) {
        return YES;
    }
    NSError *error = nil;
    BOOL ok = FBTypeText(text, 60, &error);
    if (!ok) {
        [self appendLog:@"warn" message:[NSString stringWithFormat:@"输入失败: %@", error.localizedDescription ?: @""]];
    }
    return ok;
}

#pragma mark - 网络

- (NSDictionary *)jsHttpRequest:(NSString *)method url:(NSString *)url body:(nullable NSString *)body headers:(nullable NSString *)headersJson timeout:(double)timeoutMs
{
    NSURL *requestURL = [NSURL URLWithString:url ?: @""];
    if (requestURL == nil) {
        return @{@"status": @0, @"body": @"invalid url"};
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
    request.HTTPMethod = method.uppercaseString ?: @"GET";
    request.timeoutInterval = MAX(1.0, timeoutMs / 1000.0);
    if (body.length > 0 && ![request.HTTPMethod isEqualToString:@"GET"]) {
        request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (headersJson.length > 0) {
        NSDictionary *headers = [self parseSpec:headersJson];
        for (NSString *key in headers) {
            id value = headers[key];
            if ([value isKindOfClass:NSString.class]) {
                [request setValue:value forHTTPHeaderField:key];
            }
        }
    }
    if ([request valueForHTTPHeaderField:@"Content-Type"] == nil
        && body.length > 0
        && ![request.HTTPMethod isEqualToString:@"GET"]) {
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }

    __block NSInteger status = 0;
    __block NSString *responseBody = @"";
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
                                                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            status = ((NSHTTPURLResponse *)response).statusCode;
        }
        if (data != nil) {
            responseBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        }
        if (error != nil && responseBody.length == 0) {
            responseBody = error.localizedDescription ?: @"";
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((request.timeoutInterval + 2.0) * NSEC_PER_SEC)));
    return @{@"status": @(status), @"body": responseBody};
}

#pragma mark - 文件

- (NSString *)baseDir
{
    return self.runBaseDir.length > 0 ? self.runBaseDir : NSTemporaryDirectory();
}

- (NSString *)resolvePath:(NSString *)path
{
    if (path.length == 0) {
        return [self baseDir];
    }
    if ([path hasPrefix:@"/"]) {
        return path;
    }
    return [[self baseDir] stringByAppendingPathComponent:path];
}

- (void)ensureParentDirectory:(NSString *)path
{
    NSString *parent = [path stringByDeletingLastPathComponent];
    if (parent.length > 0) {
        [NSFileManager.defaultManager createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:NULL];
    }
}

- (BOOL)fsExists:(NSString *)path
{
    return [NSFileManager.defaultManager fileExistsAtPath:[self resolvePath:path]];
}

- (NSString *)fsRead:(NSString *)path
{
    NSString *content = [NSString stringWithContentsOfFile:[self resolvePath:path] encoding:NSUTF8StringEncoding error:NULL];
    return content ?: @"";
}

- (BOOL)jsFsWrite:(NSString *)path content:(NSString *)content
{
    NSString *fullPath = [self resolvePath:path];
    [self ensureParentDirectory:fullPath];
    return [content writeToFile:fullPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

- (BOOL)jsFsAppend:(NSString *)path content:(NSString *)content
{
    NSString *fullPath = [self resolvePath:path];
    [self ensureParentDirectory:fullPath];
    NSString *existing = [NSString stringWithContentsOfFile:fullPath encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    return [[existing stringByAppendingString:content ?: @""] writeToFile:fullPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

- (BOOL)jsFsWriteBytes:(NSString *)path base64:(nullable NSString *)base64
{
    NSString *fullPath = [self resolvePath:path];
    [self ensureParentDirectory:fullPath];
    NSData *data = base64.length > 0
        ? [[NSData alloc] initWithBase64EncodedString:base64 options:NSDataBase64DecodingIgnoreUnknownCharacters]
        : [NSData data];
    if (data == nil) {
        return NO;
    }
    return [data writeToFile:fullPath atomically:YES];
}

- (BOOL)fsEnsureDir:(NSString *)path
{
    // runtime.js 传的是文件路径，这里按父目录建（与 AutoJs6 files.ensureDir 语义一致）
    NSString *fullPath = [self resolvePath:path];
    NSString *directory = [path hasSuffix:@"/"] ? fullPath : fullPath.stringByDeletingLastPathComponent;
    return [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (BOOL)fsRemove:(NSString *)path
{
    return [NSFileManager.defaultManager removeItemAtPath:[self resolvePath:path] error:NULL];
}

- (BOOL)fsIsFile:(NSString *)path
{
    BOOL isDirectory = NO;
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:[self resolvePath:path] isDirectory:&isDirectory];
    return exists && !isDirectory;
}

- (BOOL)fsIsDir:(NSString *)path
{
    BOOL isDirectory = NO;
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:[self resolvePath:path] isDirectory:&isDirectory];
    return exists && isDirectory;
}

- (NSArray<NSString *> *)fsListDir:(NSString *)path
{
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:[self resolvePath:path] error:NULL];
    return entries ?: @[];
}

- (NSString *)fsJoin:(NSArray *)components
{
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (id component in components) {
        if ([component isKindOfClass:NSString.class] && [component length] > 0) {
            [parts addObject:component];
        }
    }
    if (parts.count == 0) {
        return [self baseDir];
    }
    NSString *joined = [parts componentsJoinedByString:@"/"];
    if ([joined hasPrefix:@"/"]) {
        return joined;
    }
    return [[self baseDir] stringByAppendingPathComponent:joined];
}

@end
