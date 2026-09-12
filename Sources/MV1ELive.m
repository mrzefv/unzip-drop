//
//  MV1ELive.m  —  mv1E Live companion (inject into the TARGET app, sign, install).
//
//  Raw Objective-C runtime swizzle (no Theos/Logos). Compiles with plain clang:
//      clang -dynamiclib -fobjc-arc -framework Foundation -framework UIKit
//
//  On first foreground it adds a draggable floating "mv1E" button. Tapping it
//  captures the LIVE UIView hierarchy (real frames, z-order, class names) + a
//  per-view screenshot and ships it to mSign via the VPS relay (apii.zefv.dev/flex).
//  Foreground-only (iOS kills background daemons). For apps you own / are authorized
//  to modify.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *kToken  = @"zefv-ota-2026";
static NSString *kPushURL = @"https://apii.zefv.dev/flex/push.php";

// ---- capture ------------------------------------------------------------

static NSString *hexPtr(id o){ return [NSString stringWithFormat:@"%p", o]; }

static NSString *b64Snapshot(UIView *v){
    if (v.bounds.size.width < 1 || v.bounds.size.height < 1) return @"";
    if (v.bounds.size.width * v.bounds.size.height > 1200*1200) return @"";
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithBounds:v.bounds format:fmt];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx){
        [v drawViewHierarchyInRect:v.bounds afterScreenUpdates:NO];
    }];
    NSData *png = UIImagePNGRepresentation(img);
    if (png.length > 400*1024) return @"";
    return [png base64EncodedStringWithOptions:0];
}

static NSDictionary *dumpView(UIView *v, int depth){
    NSMutableArray *kids = [NSMutableArray array];
    for (UIView *sub in v.subviews) if (depth < 40) [kids addObject:dumpView(sub, depth+1)];
    CGRect f = v.frame;
    NSMutableDictionary *d = [@{
        @"class": NSStringFromClass(v.class) ?: @"UIView",
        @"ptr": hexPtr(v),
        @"x": @(f.origin.x), @"y": @(f.origin.y), @"w": @(f.size.width), @"h": @(f.size.height),
        @"alpha": @(v.alpha), @"hidden": @(v.hidden), @"depth": @(depth), @"children": kids,
    } mutableCopy];
    if ([v isKindOfClass:UILabel.class]) d[@"text"] = ((UILabel*)v).text ?: @"";
    NSString *s = b64Snapshot(v); if (s.length) d[@"png"] = s;
    return d;
}

static NSDictionary *captureTree(void){
    UIWindow *key = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) if (w.isKeyWindow) { key = w; break; }
    if (!key) key = UIApplication.sharedApplication.windows.firstObject;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
    return @{
        @"bundle": bundle,
        @"app": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: bundle,
        @"ts": @([NSDate date].timeIntervalSince1970),
        @"screen": @{ @"w": @(UIScreen.mainScreen.bounds.size.width), @"h": @(UIScreen.mainScreen.bounds.size.height) },
        @"root": key ? dumpView(key, 0) : @{},
    };
}

static void pushVPS(NSData *json){
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kPushURL]];
    req.HTTPMethod = @"POST";
    [req setValue:kToken forHTTPHeaderField:@"X-OTA-Token"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = json;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){}] resume];
}

// ---- floating button (added via associated target on a shared handler) ---

@interface MV1ELiveHandler : NSObject
+ (instancetype)shared;
- (void)tap;
- (void)pan:(UIPanGestureRecognizer *)g;
@end

static UIButton *gBtn;

@implementation MV1ELiveHandler
+ (instancetype)shared { static MV1ELiveHandler *h; static dispatch_once_t t; dispatch_once(&t, ^{ h = [MV1ELiveHandler new]; }); return h; }
- (void)tap {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSData *json = [NSJSONSerialization dataWithJSONObject:captureTree() options:0 error:nil];
        if (!json) return;
        pushVPS(json);
        gBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.5 alpha:0.95];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.4*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            gBtn.backgroundColor = [UIColor colorWithRed:0.25 green:0.55 blue:1.0 alpha:0.9];
        });
    });
}
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view; CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x+t.x, v.center.y+t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
@end

static void addButton(UIWindow *w){
    if (gBtn || !w) return;
    gBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gBtn.frame = CGRectMake(w.bounds.size.width-64, w.bounds.size.height/2, 52, 52);
    gBtn.layer.cornerRadius = 26;
    gBtn.backgroundColor = [UIColor colorWithRed:0.25 green:0.55 blue:1.0 alpha:0.9];
    [gBtn setTitle:@"mv1E" forState:UIControlStateNormal];
    [gBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    gBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [gBtn addTarget:MV1ELiveHandler.shared action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
    [gBtn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:MV1ELiveHandler.shared action:@selector(pan:)]];
    [w addSubview:gBtn];
}

// ---- swizzle -[UIApplication _applicationDidBecomeActive:] --------------

static void (*orig_didBecomeActive)(id, SEL, id);
static void my_didBecomeActive(id self, SEL _cmd, id note){
    if (orig_didBecomeActive) orig_didBecomeActive(self, _cmd, note);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.8*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        for (UIWindow *w in UIApplication.sharedApplication.windows) if (w.isKeyWindow) { addButton(w); break; }
    });
}

__attribute__((constructor))
static void mv1e_init(void){
    // Only the TARGET app gets the button. mSign ships this file as a bundled
    // resource (it hands the source to Actions to build the dylib), so if the
    // resource is present we are running inside mSign itself → do nothing.
    if ([NSBundle.mainBundle pathForResource:@"MV1ELive" ofType:@"m"]) return;
    NSString *host = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if ([host containsString:@"mrvek"] || [host containsString:@"msign"] || [host containsString:@"unzip"]) return;

    Class cls = objc_getClass("UIApplication");
    SEL sel = NSSelectorFromString(@"_applicationDidBecomeActive:");
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        orig_didBecomeActive = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)my_didBecomeActive);
    } else {
        // Fallback: observe the notification if the private selector is unavailable.
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.8*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                for (UIWindow *w in UIApplication.sharedApplication.windows) if (w.isKeyWindow) { addButton(w); break; }
            });
        }];
    }
}
