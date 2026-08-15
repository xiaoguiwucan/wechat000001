#import "UploadHUD.h"
#import "UploadStats.h"
#import "NetworkPath.h"
#import "SftpInboxClient.h"
#import "../Settings.h"

#import <UIKit/UIKit.h>

static const CGFloat kWXHudW = 122.0;
static const CGFloat kWXHudH = 32.0;

@interface WXIngestHUDWindow : UIWindow
@end

@implementation WXIngestHUDWindow
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *root = self.rootViewController.view;
    if (root == nil) {
        return NO;
    }
    CGPoint local = [self convertPoint:point toView:root];
    for (UIView *sub in root.subviews) {
        if (!sub.hidden && CGRectContainsPoint(sub.frame, local)) {
            return YES;
        }
    }
    return NO;
}
@end

@interface WXIngestHUDController : UIViewController <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIView *clip;
@property(nonatomic, strong) UIView *redSide;
@property(nonatomic, strong) UIView *whiteSide;
@property(nonatomic, strong) UIView *shine;
@property(nonatomic, strong) UIView *spark;
@property(nonatomic, strong) UIView *dot;
@property(nonatomic, strong) UILabel *routeLab;
@property(nonatomic, strong) UILabel *bytesLab;
@property(nonatomic, strong) UILabel *speedLab;
@property(nonatomic, strong) UIStackView *numStack;
@property(nonatomic, assign) CGPoint panStart;
@property(nonatomic, assign) CGRect startFrame;
@end

@implementation WXIngestHUDController

- (UIColor *)mangaRed {
    return [UIColor colorWithRed:0.93 green:0.32 blue:0.30 alpha:0.94];
}

- (UIColor *)mangaInk {
    return [UIColor colorWithRed:0.18 green:0.09 blue:0.08 alpha:0.88];
}

- (UIColor *)mangaPaper {
    return [UIColor colorWithRed:1.0 green:0.99 blue:0.97 alpha:0.92];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.userInteractionEnabled = YES;

    UIView *clip = [[UIView alloc] initWithFrame:self.view.bounds];
    clip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    clip.layer.cornerRadius = kWXHudH / 2.0;
    clip.layer.masksToBounds = YES;
    clip.layer.borderWidth = 1.6;
    clip.layer.borderColor = [self mangaInk].CGColor;
    [self.view addSubview:clip];
    self.clip = clip;

    self.view.layer.cornerRadius = kWXHudH / 2.0;
    self.view.layer.shadowColor = [self mangaInk].CGColor;
    self.view.layer.shadowOpacity = 0.16;
    self.view.layer.shadowRadius = 6;
    self.view.layer.shadowOffset = CGSizeMake(0, 2);

    UIView *red = [[UIView alloc] init];
    red.translatesAutoresizingMaskIntoConstraints = NO;
    red.backgroundColor = [self mangaRed];
    [clip addSubview:red];
    self.redSide = red;

    UIView *shine = [[UIView alloc] init];
    shine.translatesAutoresizingMaskIntoConstraints = NO;
    shine.userInteractionEnabled = NO;
    shine.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    [red addSubview:shine];
    self.shine = shine;

    UIView *white = [[UIView alloc] init];
    white.translatesAutoresizingMaskIntoConstraints = NO;
    white.backgroundColor = [self mangaPaper];
    [clip addSubview:white];
    self.whiteSide = white;

    UIView *seam = [[UIView alloc] init];
    seam.translatesAutoresizingMaskIntoConstraints = NO;
    seam.backgroundColor = [[self mangaInk] colorWithAlphaComponent:0.18];
    [clip addSubview:seam];

    UIView *spark = [[UIView alloc] init];
    spark.translatesAutoresizingMaskIntoConstraints = NO;
    spark.userInteractionEnabled = NO;
    spark.backgroundColor = [UIColor colorWithWhite:1 alpha:0.95];
    spark.layer.cornerRadius = 2;
    spark.transform = CGAffineTransformMakeRotation(M_PI_4);
    [red addSubview:spark];
    self.spark = spark;

    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.backgroundColor = [UIColor colorWithWhite:1 alpha:0.95];
    dot.layer.cornerRadius = 3;
    dot.layer.borderWidth = 1.0;
    dot.layer.borderColor = [self mangaInk].CGColor;
    [red addSubview:dot];
    self.dot = dot;

    UILabel *route = [[UILabel alloc] init];
    route.translatesAutoresizingMaskIntoConstraints = NO;
    route.font = [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy];
    route.textColor = [UIColor colorWithRed:1 green:0.98 blue:0.96 alpha:1];
    route.text = @"局域网";
    [red addSubview:route];
    self.routeLab = route;

    UILabel *bytes = [[UILabel alloc] init];
    bytes.translatesAutoresizingMaskIntoConstraints = NO;
    bytes.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightBold];
    bytes.textAlignment = NSTextAlignmentCenter;
    bytes.textColor = [self mangaInk];
    bytes.text = @"0 B";
    self.bytesLab = bytes;

    UILabel *speed = [[UILabel alloc] init];
    speed.translatesAutoresizingMaskIntoConstraints = NO;
    speed.font = [UIFont monospacedDigitSystemFontOfSize:8 weight:UIFontWeightSemibold];
    speed.textAlignment = NSTextAlignmentCenter;
    speed.textColor = [UIColor colorWithRed:0.48 green:0.28 blue:0.26 alpha:0.92];
    speed.text = @"0 B/s";
    self.speedLab = speed;

    UIStackView *nums = [[UIStackView alloc] initWithArrangedSubviews:@[bytes, speed]];
    nums.translatesAutoresizingMaskIntoConstraints = NO;
    nums.axis = UILayoutConstraintAxisVertical;
    nums.alignment = UIStackViewAlignmentCenter;
    nums.distribution = UIStackViewDistributionEqualSpacing;
    nums.spacing = 0;
    [white addSubview:nums];
    self.numStack = nums;

    [NSLayoutConstraint activateConstraints:@[
        [red.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
        [red.topAnchor constraintEqualToAnchor:clip.topAnchor],
        [red.bottomAnchor constraintEqualToAnchor:clip.bottomAnchor],
        [red.widthAnchor constraintEqualToAnchor:clip.widthAnchor multiplier:0.46],
        [white.leadingAnchor constraintEqualToAnchor:red.trailingAnchor],
        [white.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
        [white.topAnchor constraintEqualToAnchor:clip.topAnchor],
        [white.bottomAnchor constraintEqualToAnchor:clip.bottomAnchor],
        [seam.leadingAnchor constraintEqualToAnchor:red.trailingAnchor],
        [seam.topAnchor constraintEqualToAnchor:clip.topAnchor],
        [seam.bottomAnchor constraintEqualToAnchor:clip.bottomAnchor],
        [seam.widthAnchor constraintEqualToConstant:1.0],
        [shine.leadingAnchor constraintEqualToAnchor:red.leadingAnchor],
        [shine.trailingAnchor constraintEqualToAnchor:red.trailingAnchor],
        [shine.topAnchor constraintEqualToAnchor:red.topAnchor],
        [shine.heightAnchor constraintEqualToAnchor:red.heightAnchor multiplier:0.38],
        [spark.leadingAnchor constraintEqualToAnchor:red.leadingAnchor constant:8],
        [spark.topAnchor constraintEqualToAnchor:red.topAnchor constant:5],
        [spark.widthAnchor constraintEqualToConstant:4],
        [spark.heightAnchor constraintEqualToConstant:4],
        [dot.leadingAnchor constraintEqualToAnchor:red.leadingAnchor constant:8],
        [dot.centerYAnchor constraintEqualToAnchor:red.centerYAnchor constant:1],
        [dot.widthAnchor constraintEqualToConstant:6],
        [dot.heightAnchor constraintEqualToConstant:6],
        [route.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:4],
        [route.centerYAnchor constraintEqualToAnchor:red.centerYAnchor],
        [route.trailingAnchor constraintLessThanOrEqualToAnchor:red.trailingAnchor constant:-5],
        [nums.centerXAnchor constraintEqualToAnchor:white.centerXAnchor],
        [nums.centerYAnchor constraintEqualToAnchor:white.centerYAnchor],
        [nums.leadingAnchor constraintGreaterThanOrEqualToAnchor:white.leadingAnchor constant:4],
        [nums.trailingAnchor constraintLessThanOrEqualToAnchor:white.trailingAnchor constant:-4],
    ]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    pan.delegate = self;
    [self.view addGestureRecognizer:pan];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinched:)];
    [self.view addGestureRecognizer:pinch];
    UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideTapped)];
    dbl.numberOfTapsRequired = 2;
    [self.view addGestureRecognizer:dbl];
}

- (void)hideTapped {
    [WXIngestSettings setHudHidden:YES];
    [WXIngestUploadHUD setVisible:NO];
}

- (void)panned:(UIPanGestureRecognizer *)gr {
    UIWindow *win = self.view.window;
    if (win == nil) {
        return;
    }
    if (gr.state == UIGestureRecognizerStateBegan) {
        self.panStart = win.center;
        return;
    }
    CGPoint t = [gr translationInView:win.superview ?: win];
    CGPoint next = CGPointMake(self.panStart.x + t.x, self.panStart.y + t.y);
    CGRect screen = [self screenBounds];
    CGFloat halfW = win.bounds.size.width / 2.0;
    CGFloat halfH = win.bounds.size.height / 2.0;
    next.x = MIN(MAX(next.x, screen.origin.x + halfW + 6), CGRectGetMaxX(screen) - halfW - 6);
    next.y = MIN(MAX(next.y, screen.origin.y + halfH + 6), CGRectGetMaxY(screen) - halfH - 6);
    win.center = next;
    if (gr.state == UIGestureRecognizerStateEnded || gr.state == UIGestureRecognizerStateCancelled) {
        [WXIngestSettings setHudFrame:win.frame];
    }
}

- (void)pinched:(UIPinchGestureRecognizer *)gr {
    UIWindow *win = self.view.window;
    if (win == nil) {
        return;
    }
    if (gr.state == UIGestureRecognizerStateBegan) {
        self.startFrame = win.frame;
    }
    CGFloat scale = gr.scale;
    CGRect f = self.startFrame;
    CGRect screen = [self screenBounds];
    CGFloat w = f.size.width * scale;
    CGFloat h = f.size.height * scale;
    w = MAX(64.0, MIN(screen.size.width - 10.0, w));
    h = MAX(22.0, MIN(screen.size.height * 0.45, h));
    win.frame = CGRectMake(f.origin.x, f.origin.y, w, h);
    [self applyCapsuleRadius:h];
    if (gr.state == UIGestureRecognizerStateEnded) {
        [WXIngestSettings setHudFrame:win.frame];
    }
}

- (void)applyCapsuleRadius:(CGFloat)height {
    CGFloat r = height / 2.0;
    self.view.layer.cornerRadius = r;
    self.clip.layer.cornerRadius = r;
}

- (CGRect)screenBounds {
    UIWindow *win = self.view.window;
    if (win.windowScene) {
        return win.windowScene.coordinateSpace.bounds;
    }
    return [UIScreen mainScreen].bounds;
}

- (void)reload {
    NSDictionary *today = [WXIngestUploadStats today];
    unsigned long long bytes = [today[@"bytes"] unsignedLongLongValue];
    NSUInteger pending = 0;
    @try {
        pending = [[WeChatIngestSftpInboxClient sharedClientWithDefaults] pendingCount];
    } @catch (NSException *e) {
        pending = 0;
    }
    double bps = [WXIngestUploadStats currentSpeedBps];
    BOOL busy = pending > 0 || bps > 200;
    BOOL lan = [WXIngestNetwork preferLAN] || [[WXIngestNetwork routeLabel] isEqualToString:@"内网"];
    BOOL wifi = [WXIngestNetwork wifiActive];
    BOOL cell = [WXIngestNetwork cellularActive];
    NSString *route = @"离线";
    if (lan && wifi) {
        route = @"局域网";
    } else if (cell || [[WXIngestNetwork routeLabel] isEqualToString:@"公网"]) {
        route = @"公网";
    } else if (wifi) {
        route = @"局域网";
    }
    self.dot.backgroundColor = busy
        ? [UIColor colorWithWhite:1 alpha:1]
        : [UIColor colorWithWhite:1 alpha:0.62];
    self.routeLab.text = route;
    self.bytesLab.text = [WXIngestUploadStats prettyBytes:bytes];
    if (busy) {
        self.speedLab.text = [NSString stringWithFormat:@"%@/s",
                              [WXIngestUploadStats prettyBytes:(unsigned long long)MAX(0, bps)]];
    } else {
        self.speedLab.text = @"0 B/s";
    }
}

@end

@implementation WXIngestUploadHUD

static WXIngestHUDWindow *gWindow;
static WXIngestHUDController *gVC;
static NSTimer *gTimer;

+ (CGRect)defaultFrame {
    CGRect screen = [UIScreen mainScreen].bounds;
    return CGRectMake(screen.size.width - kWXHudW - 12, 58, kWXHudW, kWXHudH);
}

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                [self rebuild];
            } @catch (NSException *e) {
                NSLog(@"[WeChatIngest] HUD start failed: %@", e);
            }
            gTimer = [NSTimer scheduledTimerWithTimeInterval:1.2
                                                      target:self
                                                    selector:@selector(refresh)
                                                    userInfo:nil
                                                     repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSDefaultRunLoopMode];
        });
    });
}

+ (UIWindowScene *)activeScene {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                return (UIWindowScene *)scene;
            }
        }
    }
    return nil;
}

+ (void)rebuild {
    if (![WXIngestSettings hudEnabled] || [WXIngestSettings hudHidden]) {
        gWindow.hidden = YES;
        return;
    }
    CGRect frame = [WXIngestSettings hudFrame];
    if (CGRectIsEmpty(frame) || frame.size.width < 48 || frame.size.height < 18) {
        frame = [self defaultFrame];
    }
    if (gWindow == nil) {
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = [self activeScene];
            if (scene) {
                gWindow = [[WXIngestHUDWindow alloc] initWithWindowScene:scene];
            }
        }
        if (gWindow == nil) {
            gWindow = [[WXIngestHUDWindow alloc] initWithFrame:frame];
        }
        gWindow.windowLevel = UIWindowLevelStatusBar + 120;
        gWindow.backgroundColor = [UIColor clearColor];
        gVC = [[WXIngestHUDController alloc] init];
        gWindow.rootViewController = gVC;
    }
    gWindow.frame = frame;
    gWindow.hidden = NO;
    @try {
        [gVC reload];
    } @catch (NSException *e) {
        NSLog(@"[WeChatIngest] HUD reload failed: %@", e);
    }
}

+ (void)setVisible:(BOOL)visible {
    if (visible) {
        [WXIngestSettings setHudHidden:NO];
        [self rebuild];
    } else {
        gWindow.hidden = YES;
    }
}

+ (BOOL)isVisible {
    return gWindow != nil && !gWindow.hidden;
}

+ (void)refresh {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refresh];
        });
        return;
    }
    if (![WXIngestSettings hudEnabled] || [WXIngestSettings hudHidden]) {
        gWindow.hidden = YES;
        return;
    }
    if (gWindow == nil) {
        return;
    }
    if (gWindow.hidden) {
        gWindow.hidden = NO;
    }
    @try {
        [gVC reload];
    } @catch (NSException *e) {
        NSLog(@"[WeChatIngest] HUD refresh failed: %@", e);
    }
}

@end
