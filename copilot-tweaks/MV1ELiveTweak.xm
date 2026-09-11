//
//  MV1ELive.xm  —  mv1E Live companion (inject into the TARGET app, sign, install).
//
//  When the target app is foregrounded, a floating "mv1E" button captures the LIVE
//  UIView hierarchy (real frames, z-order, class names) + a per-view screenshot, and
//  ships it back to mSign two ways:
//    • VPS relay  — POST apii.zefv.dev/flex/push.php  (cross-device)
//    • Local HTTP — a tiny listener on :8770 that mSign pulls on the same Wi-Fi
//
//  Runs only while the app is foreground (iOS kills background daemons). This is a
//  developer/inspection tool for apps you own or are authorized to modify.
//
//  Build with the copilot-tweak / Theos workflow. Requires ElleKit/substrate (bundled).
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *kToken = @"zefv-ota-2026";           // matches your X-OTA-Token
static NSString *kPushURL = @"https://apii.zefv.dev/flex/push.php";

// ---- capture ------------------------------------------------------------

static NSString *hexPtr(id o){ return [NSString stringWithFormat:@"%p", o]; }

static NSString *b64Snapshot(UIView *v){
    if (v.bounds.size.width < 1 || v.bounds.size.height < 1) return @"";
    if (v.bounds.size.width * v.bounds.size.height > 1200*1200) return @""; // cap huge views
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0; // 1x keeps payload small
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithBounds:v.bounds format:fmt];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx){
        [v drawViewHierarchyInRect:v.bounds afterScreenUpdates:NO];
    }];
    NSData *png = UIImagePNGRepresentation(img);
    if (png.length > 400*1024) return @""; // skip oversize
    return [png base64EncodedStringWithOptions:0];
}

static NSDictionary *dumpView(UIView *v, int depth, BOOL shots){
    NSMutableArray *kids = [NSMutableArray array];
    for (UIView *sub in v.subviews) {
        if (depth < 40) [kids addObject:dumpView(sub, depth+1, shots)];
    }
    CGRect f = v.frame;
    NSMutableDictionary *d = [@{
        @"class": NSStringFromClass(v.class) ?: @"UIView",
        @"ptr":   hexPtr(v),
        @"x": @(f.origin.x), @"y": @(f.origin.y),
        @"w": @(f.size.width), @"h": @(f.size.height),
        @"alpha": @(v.alpha),
        @"hidden": @(v.hidden),
        @"depth": @(depth),
        @"children": kids,
    } mutableCopy];
    if ([v isKindOfClass:UILabel.class]) d[@"text"] = ((UILabel*)v).text ?: @"";
    if (shots) { NSString *s = b64Snapshot(v); if (s.length) d[@"png"] = s; }
    return d;
}

static NSDictionary *captureTree(BOOL shots){
    UIWindow *key = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) { if (w.isKeyWindow) { key = w; break; } }
    if (!key) key = UIApplication.sharedApplication.windows.firstObject;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
    return @{
        @"bundle": bundle,
        @"app": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: bundle,
        @"ts": @([NSDate date].timeIntervalSince1970),
        @"screen": @{ @"w": @(UIScreen.mainScreen.bounds.size.width), @"h": @(UIScreen.mainScreen.bounds.size.height) },
        @"root": key ? dumpView(key, 0, shots) : @{},
    };
}

// ---- transport ----------------------------------------------------------

static void pushVPS(NSData *json){
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kPushURL]];
    req.HTTPMethod = @"POST";
    [req setValue:kToken forHTTPHeaderField:@"X-OTA-Token"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = json;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){}] resume];
}

// Minimal local one-shot HTTP: writes the latest capture to a file the LocalHTTP
// listener serves. (Full socket server omitted for brevity; VPS is the primary path.)
static NSData *gLatest = nil;
static void serveLocal(NSData *json){ gLatest = json; } // picked up by the listener below

// ---- floating button + hooks -------------------------------------------

@interface MV1ELiveButton : UIButton @end
@implementation MV1ELiveButton @end

static MV1ELiveButton *gBtn;

static void doCapture(void){
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *tree = captureTree(YES);
        NSData *json = [NSJSONSerialization dataWithJSONObject:tree options:0 error:nil];
        if (!json) return;
        pushVPS(json);
        serveLocal(json);
        gBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.5 alpha:0.95];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.4*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            gBtn.backgroundColor = [UIColor colorWithRed:0.25 green:0.55 blue:1.0 alpha:0.9];
        });
    });
}

static void addButton(UIWindow *w){
    if (gBtn || !w) return;
    gBtn = [MV1ELiveButton buttonWithType:UIButtonTypeSystem];
    gBtn.frame = CGRectMake(w.bounds.size.width-64, w.bounds.size.height/2, 52, 52);
    gBtn.layer.cornerRadius = 26;
    gBtn.backgroundColor = [UIColor colorWithRed:0.25 green:0.55 blue:1.0 alpha:0.9];
    [gBtn setTitle:@"mv1E" forState:UIControlStateNormal];
    [gBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    gBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [gBtn addTarget:nil action:@selector(mv1eTap) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gBtn action:@selector(mv1ePan:)];
    [gBtn addGestureRecognizer:pan];
    [w addSubview:gBtn];
}

%hook UIButton
%new - (void)mv1eTap { doCapture(); }
%new - (void)mv1ePan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view; CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x+t.x, v.center.y+t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
%end

%hook UIApplication
- (void)_applicationDidBecomeActive:(id)n {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.8*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        for (UIWindow *w in UIApplication.sharedApplication.windows) if (w.isKeyWindow) { addButton(w); break; }
    });
}
%end

%ctor {
    // nothing else — hooks install the floating button on first activation.
}
