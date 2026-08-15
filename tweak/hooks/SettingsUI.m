#import "SettingsUI.h"
#import "ContactPicker.h"
#import "Contacts.h"
#import "StatusSync.h"
#import "SftpInboxClient.h"
#import "DebugLog.h"
#import "NetworkPath.h"
#import "UploadStats.h"
#import "UploadHUD.h"
#import "../Settings.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>

static NSString * const WXIngestPluginTitle = @"微信记忆";
static NSString * const WXIngestPluginVersion = @"1.5.31";

static BOOL WXAtLeast(NSInteger major) {
    static NSInteger ver = -1;
    if (ver < 0) {
        ver = [[[[UIDevice currentDevice] systemVersion] componentsSeparatedByString:@"."] firstObject].integerValue;
    }
    return ver >= major;
}

static void WeChatIngestPresentSettingsFrom(UIViewController *from);
static void WeChatIngestCleanupHost(UIViewController *vc);

@interface WXIngestSettingsController : UITableViewController <UITextFieldDelegate>
@property(nonatomic, copy) NSString *page;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *sections;
@property(nonatomic, strong) NSTimer *statusTimer;
@property(nonatomic, strong) UILabel *statusLine;
@property(nonatomic, strong) UILabel *statusSub;
@property(nonatomic, strong) UIView *statusDot;
@property(nonatomic, strong) UILabel *statusMeta;
@end

@implementation WXIngestSettingsController

- (instancetype)initWithPage:(NSString *)page {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _page = page.length ? [page copy] : @"main";
    }
    return self;
}

- (instancetype)init {
    return [self initWithPage:@"main"];
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    (void)style;
    return [self initWithPage:@"main"];
}

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    (void)nibNameOrNil;
    (void)nibBundleOrNil;
    return [self initWithPage:@"main"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.page.length == 0) {
        self.page = @"main";
    }
    if (self.title.length == 0) {
        self.title = @"微信记忆";
    }
    self.sections = [WXIngestSettings sectionsForPage:self.page];
    if ([self.page isEqualToString:@"main"]) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                             style:UIBarButtonItemStyleDone
                                            target:self
                                            action:@selector(wxClose)];
        [self wxInstallStatusHeader];
    } else {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                             style:UIBarButtonItemStyleDone
                                            target:self
                                            action:@selector(wxSave)];
    }
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
    self.tableView.backgroundColor = [self mangaPaper];
    self.view.backgroundColor = [self mangaPaper];
    self.tableView.separatorColor = [[self mangaInk] colorWithAlphaComponent:0.12];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 14, 0, 14);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 44;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.sectionFooterHeight = 8;
    if (WXAtLeast(15)) {
        self.tableView.sectionHeaderTopPadding = 4;
    }
    [self wxPaintChrome];
}

- (UIColor *)mangaRed {
    return [UIColor colorWithRed:0.93 green:0.32 blue:0.30 alpha:1];
}

- (UIColor *)mangaInk {
    return [UIColor colorWithRed:0.18 green:0.09 blue:0.08 alpha:1];
}

- (UIColor *)mangaPaper {
    return [UIColor colorWithRed:0.996 green:0.973 blue:0.953 alpha:1];
}

- (UIColor *)mangaCard {
    return [UIColor colorWithRed:1.0 green:0.992 blue:0.984 alpha:1];
}

- (UIColor *)wxGreen {
    return [self mangaRed];
}

- (void)wxPaintChrome {
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (bar == nil) {
        return;
    }
    bar.tintColor = [self mangaRed];
    bar.barTintColor = [self mangaPaper];
    bar.translucent = NO;
    NSDictionary *title = @{
        NSForegroundColorAttributeName: [self mangaInk],
        NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightHeavy],
    };
    bar.titleTextAttributes = title;
    if (WXAtLeast(13)) {
        UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
        [ap configureWithOpaqueBackground];
        ap.backgroundColor = [self mangaPaper];
        ap.shadowColor = [[self mangaInk] colorWithAlphaComponent:0.18];
        ap.titleTextAttributes = title;
        bar.standardAppearance = ap;
        bar.scrollEdgeAppearance = ap;
    }
}

- (NSArray *)wxRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return [NSArray array];
    }
    NSArray *rows = self.sections[(NSUInteger)section][@"rows"];
    return [rows isKindOfClass:[NSArray class]] ? rows : [NSArray array];
}

- (NSDictionary *)wxRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *rows = [self wxRowsInSection:indexPath.section];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)rows.count) {
        return [NSDictionary dictionary];
    }
    return rows[(NSUInteger)indexPath.row];
}

- (void)wxInstallStatusHeader {
    UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 92)];
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 14;
    card.layer.masksToBounds = YES;
    card.layer.borderWidth = 1.6;
    card.layer.borderColor = [self mangaInk].CGColor;
    [wrap addSubview:card];

    UIView *red = [[UIView alloc] init];
    red.translatesAutoresizingMaskIntoConstraints = NO;
    red.backgroundColor = [self mangaRed];
    [card addSubview:red];

    UIView *shine = [[UIView alloc] init];
    shine.translatesAutoresizingMaskIntoConstraints = NO;
    shine.userInteractionEnabled = NO;
    shine.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    [red addSubview:shine];

    UIView *white = [[UIView alloc] init];
    white.translatesAutoresizingMaskIntoConstraints = NO;
    white.backgroundColor = [self mangaCard];
    [card addSubview:white];

    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.backgroundColor = [UIColor whiteColor];
    dot.layer.cornerRadius = 3.5;
    dot.layer.borderWidth = 1.0;
    dot.layer.borderColor = [self mangaInk].CGColor;
    [red addSubview:dot];
    self.statusDot = dot;

    UILabel *line = [[UILabel alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.font = [UIFont systemFontOfSize:16 weight:UIFontWeightHeavy];
    line.textColor = [UIColor colorWithRed:1 green:0.98 blue:0.96 alpha:1];
    line.text = @"微信记忆";
    [red addSubview:line];
    self.statusLine = line;

    UILabel *sub = [[UILabel alloc] init];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    sub.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    sub.textColor = [UIColor colorWithRed:1 green:0.94 blue:0.92 alpha:0.95];
    sub.text = @"采集关";
    [red addSubview:sub];
    self.statusSub = sub;

    UILabel *meta = [[UILabel alloc] init];
    meta.translatesAutoresizingMaskIntoConstraints = NO;
    meta.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    meta.textColor = [self mangaInk];
    meta.numberOfLines = 3;
    meta.text = @"今日 0 B";
    [white addSubview:meta];
    self.statusMeta = meta;

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:12],
        [card.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-12],
        [card.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-6],
        [red.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [red.topAnchor constraintEqualToAnchor:card.topAnchor],
        [red.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [red.widthAnchor constraintEqualToAnchor:card.widthAnchor multiplier:0.42],
        [white.leadingAnchor constraintEqualToAnchor:red.trailingAnchor],
        [white.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [white.topAnchor constraintEqualToAnchor:card.topAnchor],
        [white.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [shine.leadingAnchor constraintEqualToAnchor:red.leadingAnchor],
        [shine.trailingAnchor constraintEqualToAnchor:red.trailingAnchor],
        [shine.topAnchor constraintEqualToAnchor:red.topAnchor],
        [shine.heightAnchor constraintEqualToConstant:18],
        [dot.leadingAnchor constraintEqualToAnchor:red.leadingAnchor constant:10],
        [dot.topAnchor constraintEqualToAnchor:red.topAnchor constant:14],
        [dot.widthAnchor constraintEqualToConstant:7],
        [dot.heightAnchor constraintEqualToConstant:7],
        [line.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:5],
        [line.centerYAnchor constraintEqualToAnchor:dot.centerYAnchor],
        [line.trailingAnchor constraintEqualToAnchor:red.trailingAnchor constant:-8],
        [sub.leadingAnchor constraintEqualToAnchor:red.leadingAnchor constant:10],
        [sub.trailingAnchor constraintEqualToAnchor:red.trailingAnchor constant:-8],
        [sub.topAnchor constraintEqualToAnchor:line.bottomAnchor constant:4],
        [meta.leadingAnchor constraintEqualToAnchor:white.leadingAnchor constant:12],
        [meta.trailingAnchor constraintEqualToAnchor:white.trailingAnchor constant:-10],
        [meta.centerYAnchor constraintEqualToAnchor:white.centerYAnchor],
    ]];
    self.tableView.tableHeaderView = wrap;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    if (header == nil) {
        return;
    }
    header.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 92);
}

- (NSString *)wxInfoDetailForKey:(NSString *)key {
    NSDictionary *plugin = WeChatIngestPluginStatusSnapshot();
    NSDictionary *server = WeChatIngestServerStatusCached();
    NSInteger serverTs = [server[@"ts"] integerValue];
    BOOL consoleLive = serverTs > 0 && ([[NSDate date] timeIntervalSince1970] - serverTs) < 90;
    if ([key isEqualToString:@"status.plugin"]) {
        return [NSString stringWithFormat:@"%@ · 已上传 %@ 条",
                [plugin[@"enabled"] boolValue] ? @"采集中" : @"未开启",
                plugin[@"uploaded"] ?: @0];
    }
    if ([key isEqualToString:@"status.debug"]) {
        return [NSString stringWithFormat:@"%lu 行", (unsigned long)WeChatIngestDebugLogCount()];
    }
    if ([key isEqualToString:@"status.ssh"]) {
        NSString *msg = [WXIngestSettings lastSSHMessage];
        if (msg.length == 0) {
            return @"未测";
        }
        return [WXIngestSettings lastSSHOK] ? @"已连通" : @"失败";
    }
    if ([key isEqualToString:@"status.console"]) {
        if (server.count == 0) {
            return @"未读到";
        }
        return [NSString stringWithFormat:@"%@ · %@ 条",
                consoleLive ? @"在线" : @"离线",
                server[@"messages"] ?: @"-"];
    }
    if ([key isEqualToString:@"status.media"]) {
        return [NSString stringWithFormat:@"找到 %@ / 未找到 %@",
                plugin[@"media_found"] ?: @0, plugin[@"media_missed"] ?: @0];
    }
    if ([key isEqualToString:@"status.url"]) {
        NSString *url = server[@"public_url"] ?: server[@"url"];
        return url.length ? url : @"http://192.168.1.10:18791";
    }
    if ([key isEqualToString:@"hint.gateway"]) {
        return @"本机探测用，上传不走它";
    }
    if ([key isEqualToString:@"hint.token"]) {
        return @"对接 OpenClaw 时才需要";
    }
    if ([key isEqualToString:@"hint.prefix"]) {
        return @"群里触发指令的开头，默认 /";
    }
    if ([key isEqualToString:@"cfg.sshHost"]) {
        NSString *host = [WXIngestSettings sshHost];
        return host.length ? host : @"未填，去连接飞牛";
    }
    if ([key isEqualToString:@"cfg.sshPort"]) {
        NSInteger port = [WXIngestSettings sshPort];
        return port > 0 ? [NSString stringWithFormat:@"%ld", (long)port] : @"未填";
    }
    if ([key isEqualToString:@"cfg.sshUser"]) {
        NSString *user = [WXIngestSettings sshUser];
        return user.length ? user : @"未填";
    }
    if ([key isEqualToString:@"cfg.sshPass"]) {
        return [WXIngestSettings sshPassword].length ? @"已填写" : @"未填，去连接飞牛";
    }
    if ([key isEqualToString:@"cfg.openclawUrl"]) {
        return @"hj.wwszxc.tax:31630（PKC 用）";
    }
    if ([key isEqualToString:@"status.route"]) {
        return [NSString stringWithFormat:@"%@ · %@  %@:%ld",
                [WXIngestNetwork pathLabel],
                [WXIngestNetwork routeLabel],
                [WXIngestSettings sshHost],
                (long)[WXIngestSettings sshPort]];
    }
    if ([key hasPrefix:@"stats."]) {
        NSDictionary *pack = [WXIngestUploadStats today];
        if ([key hasPrefix:@"stats.week"]) {
            pack = [WXIngestUploadStats week];
        } else if ([key hasPrefix:@"stats.year"]) {
            pack = [WXIngestUploadStats year];
        }
        NSString *field = [[key componentsSeparatedByString:@"."] lastObject];
        if ([field isEqualToString:@"today"] || [field isEqualToString:@"week"] || [field isEqualToString:@"year"]) {
            return [NSString stringWithFormat:@"%@ · %@ 条",
                    [WXIngestUploadStats prettyBytes:[pack[@"bytes"] unsignedLongLongValue]],
                    pack[@"count"] ?: @0];
        }
        return [WXIngestUploadStats prettyBytes:[pack[field] unsignedLongLongValue]];
    }
    return @"";
}

- (void)wxReloadStatus {
    self.sections = [WXIngestSettings sectionsForPage:self.page];
    NSDictionary *plugin = WeChatIngestPluginStatusSnapshot();
    NSDictionary *server = WeChatIngestServerStatusCached();
    BOOL on = [plugin[@"enabled"] boolValue];
    NSInteger serverTs = [server[@"ts"] integerValue];
    BOOL consoleLive = serverTs > 0 && ([[NSDate date] timeIntervalSince1970] - serverTs) < 90;
    NSString *ssh = [WXIngestSettings lastSSHMessage].length
        ? ([WXIngestSettings lastSSHOK] ? @"SSH 已连通" : @"SSH 失败")
        : @"SSH 未测";
    NSString *con = server.count ? (consoleLive ? @"控制台在线" : @"控制台离线") : @"控制台未读到";
    self.statusLine.text = @"微信记忆";
    self.statusDot.backgroundColor = on ? [UIColor whiteColor]
        : [[UIColor whiteColor] colorWithAlphaComponent:0.45];
    NSString *who = nil;
    if ([WXIngestSettings recordAllGroups] && [WXIngestSettings recordAllDMs]) {
        who = @"全部会话";
    } else {
        who = [NSString stringWithFormat:@"群 %lu · 私聊 %lu",
               (unsigned long)[WXIngestSettings groupList].count,
               (unsigned long)[WXIngestSettings dmList].count];
    }
    NSDictionary *today = [WXIngestUploadStats today];
    self.statusSub.text = on ? @"采集开" : @"采集关";
    if (self.statusMeta) {
        self.statusMeta.text = [NSString stringWithFormat:@"今日 %@\n%@ · %@\n%@ · %@",
                                [WXIngestUploadStats prettyBytes:[today[@"bytes"] unsignedLongLongValue]],
                                [WXIngestNetwork routeLabel],
                                ssh,
                                who,
                                con];
    }
    for (NSInteger s = 0; s < (NSInteger)self.sections.count; s++) {
        NSArray *rows = [self wxRowsInSection:s];
        for (NSInteger i = 0; i < (NSInteger)rows.count; i++) {
            if ([rows[(NSUInteger)i][@"kind"] integerValue] != WXIngestRowKindInfo) {
                continue;
            }
            NSIndexPath *path = [NSIndexPath indexPathForRow:i inSection:s];
            UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
            if (cell.detailTextLabel) {
                cell.detailTextLabel.text = [self wxInfoDetailForKey:rows[(NSUInteger)i][@"key"]];
            }
        }
    }
}

- (void)wxPullRemoteStatus {
    [[WeChatIngestSftpInboxClient sharedClientWithDefaults] enqueueStatus:WeChatIngestPluginStatusSnapshot()];
    [[WeChatIngestSftpInboxClient sharedClientWithDefaults] fetchServerStatusWithCompletion:^(NSDictionary *status) {
        (void)status;
        [self wxReloadStatus];
    }];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self wxPaintChrome];
    self.sections = [WXIngestSettings sectionsForPage:self.page];
    [self.tableView reloadData];
    [self.statusTimer invalidate];
    if ([self.page isEqualToString:@"main"] || [self.page isEqualToString:@"connection"] ||
        [self.page isEqualToString:@"record"] || [self.page isEqualToString:@"stats"]) {
        [self wxPullRemoteStatus];
        self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                            target:self
                                                          selector:@selector(wxReloadStatus)
                                                          userInfo:nil
                                                           repeats:YES];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.statusTimer invalidate];
    self.statusTimer = nil;
    [self wxFlushTextViews];
    [[WXIngestSettings sharedDefaults] synchronize];
}

- (void)wxClose {
    [self wxFlushTextViews];
    if (self.navigationController.presentingViewController &&
        self.navigationController.viewControllers.firstObject == self) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

- (void)wxSave {
    [self.view endEditing:YES];
    [self wxFlushTextViews];
    [[WXIngestSettings sharedDefaults] synchronize];
    [self wxShowToast:@"已保存"];
}

- (void)wxDismissKeyboard {
    [self.view endEditing:YES];
    [self wxFlushTextViews];
}

- (UIToolbar *)wxKeyboardDoneBar {
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    [bar sizeToFit];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                          target:nil
                                                                          action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                             style:UIBarButtonItemStyleDone
                                                            target:self
                                                            action:@selector(wxDismissKeyboard)];
    done.tintColor = [self wxGreen];
    bar.items = @[flex, done];
    return bar;
}

- (void)wxShowToast:(NSString *)text {
    UILabel *lab = [[UILabel alloc] init];
    lab.text = text;
    lab.textColor = [UIColor colorWithRed:1 green:0.98 blue:0.96 alpha:1];
    lab.font = [UIFont systemFontOfSize:13 weight:UIFontWeightHeavy];
    lab.textAlignment = NSTextAlignmentCenter;
    lab.backgroundColor = [self mangaRed];
    lab.layer.cornerRadius = 16;
    lab.layer.borderWidth = 1.4;
    lab.layer.borderColor = [self mangaInk].CGColor;
    lab.layer.masksToBounds = YES;
    [lab sizeToFit];
    CGFloat width = lab.bounds.size.width + 40;
    CGFloat height = 40;
    lab.frame = CGRectMake((self.view.bounds.size.width - width) / 2.0,
                           self.view.bounds.size.height * 0.42,
                           width, height);
    lab.alpha = 0;
    [self.navigationController.view addSubview:lab];
    [UIView animateWithDuration:0.18 animations:^{
        lab.alpha = 1;
    } completion:^(BOOL finished) {
        (void)finished;
        [UIView animateWithDuration:0.22 delay:0.9 options:0 animations:^{
            lab.alpha = 0;
        } completion:^(BOOL done) {
            (void)done;
            [lab removeFromSuperview];
        }];
    }];
}

- (void)wxFlushTextViews {
    for (NSInteger s = 0; s < (NSInteger)self.sections.count; s++) {
        NSArray *rows = [self wxRowsInSection:s];
        for (NSInteger i = 0; i < (NSInteger)rows.count; i++) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:s]];
        if (cell == nil) {
            continue;
        }
        for (UIView *sub in cell.contentView.subviews) {
            if (![sub isKindOfClass:[UITextView class]]) {
                continue;
            }
            UITextView *tv = (UITextView *)sub;
            NSString *key = objc_getAssociatedObject(tv, "wx.key");
            NSMutableArray *lines = [NSMutableArray array];
            for (NSString *line in [tv.text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trim.length > 0) {
                    [lines addObject:trim];
                }
            }
            if ([key isEqualToString:WXIngestKeyGroupList]) {
                [WXIngestSettings setGroupList:lines];
            } else if ([key isEqualToString:WXIngestKeyDMList]) {
                [WXIngestSettings setDmList:lines];
            } else if ([key isEqualToString:WXIngestKeyGroupExclude]) {
                [WXIngestSettings setGroupExclude:lines];
            } else if ([key isEqualToString:WXIngestKeyDMExclude]) {
                [WXIngestSettings setDmExclude:lines];
            }
        }
        for (UIView *sub in cell.contentView.subviews) {
            if ([sub isKindOfClass:[UITextField class]]) {
                [self wxFieldChanged:(UITextField *)sub];
            }
        }
        }
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return (NSInteger)[self wxRowsInSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView;
    NSString *title = self.sections[(NSUInteger)section][@"header"];
    if (title.length == 0) {
        return [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 6)];
    }
    UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 26)];
    wrap.backgroundColor = [self mangaPaper];
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, 280, 16)];
    lab.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    lab.font = [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy];
    lab.textColor = [self mangaRed];
    lab.text = title;
    [wrap addSubview:lab];
    UIView *tick = [[UIView alloc] initWithFrame:CGRectMake(12, 12, 2, 9)];
    tick.backgroundColor = [self mangaRed];
    [wrap addSubview:tick];
    return wrap;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    NSString *title = self.sections[(NSUInteger)section][@"header"];
    return title.length ? 26 : 8;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    (void)tableView;
    NSString *footer = self.sections[(NSUInteger)section][@"footer"];
    if (footer.length == 0) {
        UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 6)];
        v.backgroundColor = [self mangaPaper];
        return v;
    }
    UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 22)];
    wrap.backgroundColor = [self mangaPaper];
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(16, 2, 288, 18)];
    lab.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    lab.font = [UIFont systemFontOfSize:10];
    lab.textColor = [[self mangaInk] colorWithAlphaComponent:0.45];
    lab.text = footer;
    lab.numberOfLines = 2;
    [wrap addSubview:lab];
    return wrap;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    (void)tableView;
    NSString *footer = self.sections[(NSUInteger)section][@"footer"];
    return footer.length ? 22 : 6;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary *row = [self wxRowAtIndexPath:indexPath];
    NSInteger kind = [row[@"kind"] integerValue];
    if (kind == WXIngestRowKindTextArea) {
        return 88.0;
    }
    if (kind == WXIngestRowKindTextField && [row[@"stacked"] boolValue]) {
        return 64.0;
    }
    if (kind == WXIngestRowKindTextField) {
        return 46.0;
    }
    return 42.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = [self wxRowAtIndexPath:indexPath];
    NSInteger kind = [row[@"kind"] integerValue];
    NSString *reuse = [NSString stringWithFormat:@"k%ld", (long)kind];
    UITableViewCellStyle style = (kind == WXIngestRowKindInfo || kind == WXIngestRowKindPage || kind == WXIngestRowKindButton)
        ? UITableViewCellStyleValue1
        : UITableViewCellStyleDefault;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:reuse];
    }
    for (UIView *sub in cell.contentView.subviews) {
        if (sub != cell.textLabel && sub != cell.detailTextLabel && sub != cell.imageView) {
            [sub removeFromSuperview];
        }
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.backgroundColor = [self mangaCard];
    cell.contentView.backgroundColor = [self mangaCard];
    cell.textLabel.text = nil;
    cell.textLabel.textColor = [self mangaInk];
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    cell.detailTextLabel.text = nil;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    cell.detailTextLabel.textColor = [[self mangaInk] colorWithAlphaComponent:0.48];
    cell.textLabel.numberOfLines = 1;

    NSString *title = row[@"title"] ?: @"";
    NSString *key = row[@"key"];

    if (kind == WXIngestRowKindInfo) {
        cell.textLabel.text = title;
        NSString *fixed = row[@"detail"];
        cell.detailTextLabel.text = fixed.length ? fixed : [self wxInfoDetailForKey:key];
        cell.detailTextLabel.numberOfLines = 2;
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        cell.detailTextLabel.minimumScaleFactor = 0.75;
        return cell;
    }
    if (kind == WXIngestRowKindPage) {
        cell.textLabel.text = title;
        cell.detailTextLabel.text = row[@"detail"] ?: @"";
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (kind == WXIngestRowKindSwitch) {
        cell.textLabel.text = title;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [self wxBoolForKey:key];
        sw.onTintColor = [self mangaRed];
        sw.transform = CGAffineTransformMakeScale(0.82, 0.82);
        sw.tag = indexPath.row;
        objc_setAssociatedObject(sw, "wx.key", key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [sw addTarget:self action:@selector(wxToggle:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }
    if (kind == WXIngestRowKindButton) {
        cell.textLabel.text = title;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        NSString *action = row[@"action"];
        if ([action isEqualToString:@"pickGroups"]) {
            BOOL all = [WXIngestSettings recordAllGroups];
            NSUInteger n = all ? [WXIngestSettings groupExclude].count : [WXIngestSettings groupList].count;
            cell.detailTextLabel.text = all
                ? [NSString stringWithFormat:@"全部 · 排除 %lu", (unsigned long)n]
                : [NSString stringWithFormat:@"已选 %lu 个", (unsigned long)n];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if ([action isEqualToString:@"pickDMs"]) {
            BOOL all = [WXIngestSettings recordAllDMs];
            NSUInteger n = all ? [WXIngestSettings dmExclude].count : [WXIngestSettings dmList].count;
            cell.detailTextLabel.text = all
                ? [NSString stringWithFormat:@"全部 · 排除 %lu", (unsigned long)n]
                : [NSString stringWithFormat:@"已选 %lu 人", (unsigned long)n];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.textColor = [self mangaRed];
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
            cell.textLabel.textAlignment = NSTextAlignmentLeft;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
        return cell;
    }

    [self wxAttachInputToCell:cell row:row];
    return cell;
}

- (void)wxAttachInputToCell:(UITableViewCell *)cell row:(NSDictionary *)row {
    NSString *title = row[@"title"] ?: @"";
    NSString *key = row[@"key"];
    BOOL stacked = [row[@"stacked"] boolValue];
    NSString *suffixText = row[@"suffix"];
    BOOL secure = [row[@"secure"] boolValue];
    BOOL number = [row[@"keyboard"] isEqualToString:@"number"];

    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;

    UILabel *titleLab = [[UILabel alloc] init];
    titleLab.translatesAutoresizingMaskIntoConstraints = NO;
    titleLab.text = title;
    titleLab.font = stacked
        ? [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy]
        : [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    titleLab.textColor = stacked ? [self mangaRed] : [self mangaInk];
    [titleLab setContentCompressionResistancePriority:UILayoutPriorityRequired
                                              forAxis:UILayoutConstraintAxisHorizontal];
    [cell.contentView addSubview:titleLab];

    UIView *box = [[UIView alloc] init];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.layer.cornerRadius = 8;
    box.layer.masksToBounds = YES;
    box.layer.borderWidth = 1.2;
    box.layer.borderColor = [[self mangaInk] colorWithAlphaComponent:0.22].CGColor;
    box.backgroundColor = [self mangaPaper];
    [cell.contentView addSubview:box];

    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    field.textAlignment = (stacked || !number) ? NSTextAlignmentLeft : NSTextAlignmentRight;
    if (!stacked && !secure) {
        field.textAlignment = NSTextAlignmentRight;
    }
    field.placeholder = row[@"placeholder"];
    field.delegate = self;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.secureTextEntry = secure;
    field.clearButtonMode = number ? UITextFieldViewModeNever : UITextFieldViewModeWhileEditing;
    field.returnKeyType = UIReturnKeyDone;
    field.text = [self wxValueForKey:key];
    if (WXAtLeast(13)) {
        field.textColor = [self mangaInk];
    } else {
        field.textColor = [self mangaInk];
    }
    if (number) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.inputAccessoryView = [self wxKeyboardDoneBar];
        field.textAlignment = NSTextAlignmentRight;
    }
    objc_setAssociatedObject(field, "wx.key", key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [field addTarget:self action:@selector(wxFieldChanged:) forControlEvents:UIControlEventEditingDidEnd];
    [box addSubview:field];

    UILabel *suffix = nil;
    if (suffixText.length) {
        suffix = [[UILabel alloc] init];
        suffix.translatesAutoresizingMaskIntoConstraints = NO;
        suffix.text = suffixText;
        suffix.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        if (WXAtLeast(13)) {
            suffix.textColor = [UIColor secondaryLabelColor];
        } else {
            suffix.textColor = [UIColor grayColor];
        }
        [suffix setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                forAxis:UILayoutConstraintAxisHorizontal];
        [box addSubview:suffix];
    }

    UILayoutGuide *guide = cell.contentView.layoutMarginsGuide;
    if (stacked) {
        [NSLayoutConstraint activateConstraints:@[
            [titleLab.topAnchor constraintEqualToAnchor:guide.topAnchor constant:2],
            [titleLab.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
            [titleLab.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
            [box.topAnchor constraintEqualToAnchor:titleLab.bottomAnchor constant:8],
            [box.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
            [box.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
            [box.heightAnchor constraintEqualToConstant:30],
            [box.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-2],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [titleLab.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
            [titleLab.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [box.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLab.trailingAnchor constant:8],
            [box.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
            [box.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [box.heightAnchor constraintEqualToConstant:30],
            [box.widthAnchor constraintGreaterThanOrEqualToConstant:secure ? 140 : 108],
        ]];
    }

    if (suffix != nil) {
        [NSLayoutConstraint activateConstraints:@[
            [field.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10],
            [field.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
            [field.trailingAnchor constraintEqualToAnchor:suffix.leadingAnchor constant:-6],
            [suffix.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-10],
            [suffix.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [field.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10],
            [field.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-10],
            [field.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
            [field.heightAnchor constraintEqualToAnchor:box.heightAnchor],
        ]];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = [self wxRowAtIndexPath:indexPath];
    NSInteger kind = [row[@"kind"] integerValue];
    if (kind == WXIngestRowKindPage) {
        WXIngestSettingsController *next = [[WXIngestSettingsController alloc] initWithPage:row[@"page"] ?: @"main"];
        next.title = row[@"title"] ?: @"设置";
        [self.navigationController pushViewController:next animated:YES];
        return;
    }
    if (kind != WXIngestRowKindButton) {
        return;
    }
    NSString *action = row[@"action"];
    if ([action isEqualToString:@"pickGroups"] || [action isEqualToString:@"pickDMs"]) {
        [self wxFlushTextViews];
        WXIngestContactPickerController *picker =
            [[WXIngestContactPickerController alloc] initWithKind:[action isEqualToString:@"pickDMs"] ? @"dm" : @"group"];
        [self.navigationController pushViewController:picker animated:YES];
        return;
    }
    if ([action isEqualToString:@"refreshStatus"]) {
        [self wxReloadStatus];
        [[WeChatIngestSftpInboxClient sharedClientWithDefaults] enqueueStatus:WeChatIngestPluginStatusSnapshot()];
        [[WeChatIngestSftpInboxClient sharedClientWithDefaults] fetchServerStatusWithCompletion:^(NSDictionary *status) {
            (void)status;
            [self wxReloadStatus];
            NSDictionary *server = WeChatIngestServerStatusCached();
            NSString *msg = server.count
                ? [NSString stringWithFormat:@"控制台 %@\n消息 %@ · 待入库 %@",
                   server[@"status"] ?: @"ok", server[@"messages"] ?: @"-", server[@"inbox_pending"] ?: @"-"]
                : @"还没读到控制台。确认飞牛上控制台已启动，SSH 能连上。";
            UIAlertController *done = [UIAlertController alertControllerWithTitle:@"控制台状态"
                                                                          message:msg
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:done animated:YES completion:nil];
        }];
        return;
    }
    if ([action isEqualToString:@"uploadDebug"]) {
        WeChatIngestDebugLog(@"manual upload debug log");
        WeChatIngestDebugLogFlushRemote();
        [[WeChatIngestSftpInboxClient sharedClientWithDefaults] enqueueStatus:WeChatIngestPluginStatusSnapshot()];
        [self wxShowToast:[NSString stringWithFormat:@"已上传 %lu 行", (unsigned long)WeChatIngestDebugLogCount()]];
        return;
    }
    if ([action isEqualToString:@"showHud"]) {
        [WXIngestSettings setHudEnabled:YES];
        [WXIngestSettings setHudHidden:NO];
        [WXIngestUploadHUD setVisible:YES];
        [self wxShowToast:@"悬浮窗已打开"];
        return;
    }
    if ([action isEqualToString:@"syncNames"]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [WXIngestContacts syncNamesToServer];
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *done = [UIAlertController alertControllerWithTitle:@"已排队同步"
                                                                              message:@"名称表已上传。等大约 10 秒刷新文件管理器，文件夹会改成群名/备注。"
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:done animated:YES completion:nil];
            });
        });
        return;
    }
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"测试中"
                                                                  message:@"正在连接 SSH，流量下可能要十几秒"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:wait animated:YES completion:nil];
    [WXIngestSettings testConnectionWithCompletion:^(BOOL reachable, NSString *message) {
        [self wxReloadStatus];
        [wait dismissViewControllerAnimated:YES completion:^{
            UIAlertController *done = [UIAlertController alertControllerWithTitle:reachable ? @"连接成功" : @"连接失败"
                                                                          message:message ?: @""
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:done animated:YES completion:nil];
        }];
    }];
}

- (BOOL)wxBoolForKey:(NSString *)key {
    if ([key isEqualToString:WXIngestKeyRecordAllGroups]) return [WXIngestSettings recordAllGroups];
    if ([key isEqualToString:WXIngestKeyRecordAllDMs]) return [WXIngestSettings recordAllDMs];
    if ([key isEqualToString:WXIngestKeyWifiOnlyMedia]) return [WXIngestSettings wifiOnlyMedia];
    if ([key isEqualToString:WXIngestKeyCollectOfficials]) return [WXIngestSettings collectOfficials];
    if ([key isEqualToString:WXIngestKeyUploadImage]) return [WXIngestSettings uploadImage];
    if ([key isEqualToString:WXIngestKeyUploadVoice]) return [WXIngestSettings uploadVoice];
    if ([key isEqualToString:WXIngestKeyUploadVideo]) return [WXIngestSettings uploadVideo];
    if ([key isEqualToString:WXIngestKeyAutoSwitch]) return [WXIngestSettings autoSwitchNetwork];
    if ([key isEqualToString:WXIngestKeyHudEnabled]) return [WXIngestSettings hudEnabled] && ![WXIngestSettings hudHidden];
    return [WXIngestSettings isEnabled];
}

- (NSArray<NSString *> *)wxListForKey:(NSString *)key {
    if ([key isEqualToString:WXIngestKeyDMList]) return [WXIngestSettings dmList];
    if ([key isEqualToString:WXIngestKeyGroupExclude]) return [WXIngestSettings groupExclude];
    if ([key isEqualToString:WXIngestKeyDMExclude]) return [WXIngestSettings dmExclude];
    return [WXIngestSettings groupList];
}

- (NSString *)wxValueForKey:(NSString *)key {
    if ([key isEqualToString:WXIngestKeySSHHost]) return [WXIngestSettings sshHost];
    if ([key isEqualToString:WXIngestKeySSHPort]) return [NSString stringWithFormat:@"%ld", (long)[WXIngestSettings sshPort]];
    if ([key isEqualToString:WXIngestKeySSHUser]) return [WXIngestSettings sshUser];
    if ([key isEqualToString:WXIngestKeySSHPassword]) return [WXIngestSettings sshPassword];
    if ([key isEqualToString:WXIngestKeyGatewayPort]) return [NSString stringWithFormat:@"%ld", (long)[WXIngestSettings gatewayPort]];
    if ([key isEqualToString:WXIngestKeyToken]) return [WXIngestSettings token];
    if ([key isEqualToString:WXIngestKeyCommandPrefix]) return [WXIngestSettings commandPrefix];
    if ([key isEqualToString:WXIngestKeyInboxPath]) return [WXIngestSettings inboxPath];
    if ([key isEqualToString:WXIngestKeyImageMaxMB]) return [NSString stringWithFormat:@"%ld", (long)[WXIngestSettings imageMaxMB]];
    if ([key isEqualToString:WXIngestKeyVideoMaxMB]) return [NSString stringWithFormat:@"%ld", (long)[WXIngestSettings videoMaxMB]];
    if ([key isEqualToString:WXIngestKeyLANHost]) return [WXIngestSettings lanHost];
    if ([key isEqualToString:WXIngestKeyLANPort]) return [NSString stringWithFormat:@"%ld", (long)[WXIngestSettings lanPort]];
    if ([key isEqualToString:WXIngestKeyWANHost]) return [WXIngestSettings wanHost];
    if ([key isEqualToString:WXIngestKeyWANPort]) return [NSString stringWithFormat:@"%ld", (long)[WXIngestSettings wanPort]];
    return @"";
}

- (void)wxToggle:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, "wx.key");
    if ([key isEqualToString:WXIngestKeyRecordAllGroups]) [WXIngestSettings setRecordAllGroups:sw.on];
    else if ([key isEqualToString:WXIngestKeyRecordAllDMs]) [WXIngestSettings setRecordAllDMs:sw.on];
    else if ([key isEqualToString:WXIngestKeyWifiOnlyMedia]) [WXIngestSettings setWifiOnlyMedia:sw.on];
    else if ([key isEqualToString:WXIngestKeyCollectOfficials]) [WXIngestSettings setCollectOfficials:sw.on];
    else if ([key isEqualToString:WXIngestKeyUploadImage]) [WXIngestSettings setUploadImage:sw.on];
    else if ([key isEqualToString:WXIngestKeyUploadVoice]) [WXIngestSettings setUploadVoice:sw.on];
    else if ([key isEqualToString:WXIngestKeyUploadVideo]) [WXIngestSettings setUploadVideo:sw.on];
    else if ([key isEqualToString:WXIngestKeyAutoSwitch]) [WXIngestSettings setAutoSwitchNetwork:sw.on];
    else if ([key isEqualToString:WXIngestKeyHudEnabled]) {
        [WXIngestSettings setHudEnabled:sw.on];
        [WXIngestSettings setHudHidden:!sw.on];
        [WXIngestUploadHUD setVisible:sw.on];
    }
    else [WXIngestSettings setEnabled:sw.on];
}

- (void)wxFieldChanged:(UITextField *)field {
    NSString *key = objc_getAssociatedObject(field, "wx.key");
    NSString *value = field.text ?: @"";
    if ([key isEqualToString:WXIngestKeySSHHost]) [WXIngestSettings setSshHost:value];
    else if ([key isEqualToString:WXIngestKeySSHPort]) [WXIngestSettings setSshPort:value.integerValue];
    else if ([key isEqualToString:WXIngestKeySSHUser]) [WXIngestSettings setSshUser:value];
    else if ([key isEqualToString:WXIngestKeySSHPassword]) [WXIngestSettings setSshPassword:value];
    else if ([key isEqualToString:WXIngestKeyGatewayPort]) [WXIngestSettings setGatewayPort:value.integerValue];
    else if ([key isEqualToString:WXIngestKeyToken]) [WXIngestSettings setToken:value];
    else if ([key isEqualToString:WXIngestKeyCommandPrefix]) [WXIngestSettings setCommandPrefix:value];
    else if ([key isEqualToString:WXIngestKeyInboxPath]) [WXIngestSettings setInboxPath:value];
    else if ([key isEqualToString:WXIngestKeyImageMaxMB]) [WXIngestSettings setImageMaxMB:value.integerValue];
    else if ([key isEqualToString:WXIngestKeyVideoMaxMB]) [WXIngestSettings setVideoMaxMB:value.integerValue];
    else if ([key isEqualToString:WXIngestKeyLANHost]) [WXIngestSettings setLanHost:value];
    else if ([key isEqualToString:WXIngestKeyLANPort]) [WXIngestSettings setLanPort:value.integerValue];
    else if ([key isEqualToString:WXIngestKeyWANHost]) [WXIngestSettings setWanHost:value];
    else if ([key isEqualToString:WXIngestKeyWANPort]) [WXIngestSettings setWanPort:value.integerValue];
    [[WXIngestSettings sharedDefaults] synchronize];
}

- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    for (UIView *sub in cell.contentView.subviews) {
        if ([sub isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)sub;
            NSString *key = objc_getAssociatedObject(tv, "wx.key");
            NSMutableArray *lines = [NSMutableArray array];
            for (NSString *line in [tv.text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trim.length > 0) {
                    [lines addObject:trim];
                }
            }
            if ([key isEqualToString:WXIngestKeyGroupList]) [WXIngestSettings setGroupList:lines];
            else if ([key isEqualToString:WXIngestKeyDMList]) [WXIngestSettings setDmList:lines];
            else if ([key isEqualToString:WXIngestKeyGroupExclude]) [WXIngestSettings setGroupExclude:lines];
            else if ([key isEqualToString:WXIngestKeyDMExclude]) [WXIngestSettings setDmExclude:lines];
        }
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    [self wxFieldChanged:textField];
    return YES;
}

@end

static UIViewController *WeChatIngestTopViewController(void) {
    UIWindow *window = nil;
    if (WXAtLeast(13)) {
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }
            for (UIWindow *candidate in scene.windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                    break;
                }
            }
            if (window) {
                break;
            }
        }
    }
    if (window == nil) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        window = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    }
    UIViewController *host = window.rootViewController;
    while (host.presentedViewController) {
        host = host.presentedViewController;
    }
    return host;
}

static void WeChatIngestPresentSettingsFrom(UIViewController *from) {
    WXIngestSettingsController *vc = [[WXIngestSettingsController alloc] initWithPage:@"main"];
    UIViewController *host = from ?: WeChatIngestTopViewController();
    if (host.navigationController) {
        [host.navigationController pushViewController:vc animated:YES];
        return;
    }
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    nav.navigationBar.tintColor = [UIColor colorWithRed:0.93 green:0.32 blue:0.30 alpha:1];
    [host presentViewController:nav animated:YES completion:nil];
}

static id WeChatIngestTableMgr(id vc) {
    for (NSString *key in @[@"tableViewMgr", @"m_tableViewMgr", @"_tableViewMgr",
                            @"tableViewInfo", @"m_tableViewInfo", @"_tableViewInfo"]) {
        @try {
            id mgr = [vc valueForKey:key];
            if (mgr) {
                return mgr;
            }
        } @catch (NSException *e) {
        }
    }
    return nil;
}

static NSArray *WeChatIngestSectionCells(id section) {
    for (NSString *key in @[@"m_cells", @"cells", @"_cells", @"m_arrCells"]) {
        @try {
            id value = [section valueForKey:key];
            if ([value isKindOfClass:[NSArray class]]) {
                return value;
            }
        } @catch (NSException *e) {
        }
    }
    return nil;
}

static BOOL WeChatIngestCellTitleIsOurs(id cell) {
    for (NSString *key in @[@"title", @"m_title", @"m_nsTitle", @"leftTitle"]) {
        @try {
            id value = [cell valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [value containsString:@"微信记忆"]) {
                return YES;
            }
        } @catch (NSException *e) {
        }
    }
    return NO;
}

static NSArray *WeChatIngestMgrSections(id mgr) {
    for (NSString *key in @[@"m_sections", @"sections", @"_sections", @"m_arrSections"]) {
        @try {
            id value = [mgr valueForKey:key];
            if ([value isKindOfClass:[NSArray class]] && [value count] > 0) {
                return value;
            }
        } @catch (NSException *e) {
        }
    }
    return nil;
}

static void WeChatIngestStripFakeOverlays(UIView *view) {
    if (view == nil) {
        return;
    }
    NSArray<UIView *> *subs = [view.subviews copy];
    for (UIView *sub in subs) {
        WeChatIngestStripFakeOverlays(sub);
        BOOL ours = (sub.tag == 0x574352 || sub.tag == 0x574346 || sub.tag == 0x5745434C);
        if (!ours && [sub isKindOfClass:[UIButton class]]) {
            NSString *title = [(UIButton *)sub titleForState:UIControlStateNormal];
            ours = [title isEqualToString:WXIngestPluginTitle];
        }
        if (ours) {
            [sub removeFromSuperview];
        }
    }
    if ([view isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)view;
        if (tv.tableFooterView.tag == 0x574346 || tv.tableFooterView.tag == 0x574352) {
            tv.tableFooterView = nil;
        }
    }
}

static void WeChatIngestStripButtonsInView(UIView *view) {
    if (view == nil) {
        return;
    }
    NSArray<UIView *> *subs = [view.subviews copy];
    for (UIView *sub in subs) {
        WeChatIngestStripButtonsInView(sub);
        if (![sub isKindOfClass:[UIButton class]]) {
            continue;
        }
        UIButton *btn = (UIButton *)sub;
        NSString *title = [btn titleForState:UIControlStateNormal];
        if (btn.tag == 0x5745434C || [title isEqualToString:WXIngestPluginTitle]) {
            [btn removeFromSuperview];
        }
    }
}

static void WeChatIngestStripLegacyChrome(UIViewController *vc) {
    WeChatIngestStripButtonsInView(vc.view);
    WeChatIngestStripFakeOverlays(vc.view);
    UIBarButtonItem *item = vc.navigationItem.rightBarButtonItem;
    if (item.tag == 0x57454D || [item.title isEqualToString:@"记忆"]) {
        vc.navigationItem.rightBarButtonItem = nil;
    }
}

static NSString *WeChatIngestSectionHeader(id section) {
    for (NSString *key in @[@"headerTitle", @"m_headerTitle", @"m_nsHeaderTitle", @"title"]) {
        @try {
            id value = [section valueForKey:key];
            if ([value isKindOfClass:[NSString class]]) {
                return value;
            }
        } @catch (NSException *e) {
        }
    }
    return @"";
}

static BOOL WeChatIngestRemoveOurCellsFromMgr(id mgr) {
    NSArray *sections = WeChatIngestMgrSections(mgr);
    if (sections.count == 0) {
        return NO;
    }
    NSMutableArray *keepSections = [NSMutableArray array];
    BOOL mutated = NO;
    for (id section in sections) {
        NSArray *cells = WeChatIngestSectionCells(section);
        NSMutableArray *keep = [NSMutableArray array];
        for (id cell in cells) {
            if (!WeChatIngestCellTitleIsOurs(cell)) {
                [keep addObject:cell];
            } else {
                mutated = YES;
            }
        }
        if ([WeChatIngestSectionHeader(section) containsString:WXIngestPluginTitle] && keep.count == 0) {
            mutated = YES;
            continue;
        }
        if (keep.count != cells.count) {
            for (NSString *key in @[@"m_cells", @"cells", @"_cells", @"m_arrCells"]) {
                @try {
                    [section setValue:keep forKey:key];
                    break;
                } @catch (NSException *e) {
                }
            }
        }
        [keepSections addObject:section];
    }
    if (mutated && keepSections.count != sections.count) {
        for (NSString *key in @[@"m_sections", @"sections", @"_sections", @"m_arrSections"]) {
            @try {
                [mgr setValue:keepSections forKey:key];
                break;
            } @catch (NSException *e) {
            }
        }
    }
    return mutated;
}

static void WeChatIngestCleanupHost(UIViewController *vc) {
    if (vc == nil) {
        return;
    }
    WeChatIngestStripLegacyChrome(vc);
    id mgr = WeChatIngestTableMgr(vc);
    BOOL removed = WeChatIngestRemoveOurCellsFromMgr(mgr);
    if (removed && [mgr respondsToSelector:@selector(reloadTableView)]) {
        ((void (*)(id, SEL))objc_msgSend)(mgr, @selector(reloadTableView));
    }
}

#pragma mark - WCPluginsMgr registration (same path as PKC)

static void WeChatIngestRegisterPluginEntry(void) {
    static BOOL registered = NO;
    if (registered) {
        return;
    }
    Class mgrClass = objc_getClass("WCPluginsMgr");
    if (mgrClass == NULL) {
        NSLog(@"[WeChatIngest] WCPluginsMgr not loaded yet");
        return;
    }
    id mgr = nil;
    for (NSString *selName in @[@"sharedInstance", @"shareInstance", @"sharedManager", @"shared"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([mgrClass respondsToSelector:sel]) {
            mgr = ((id (*)(id, SEL))objc_msgSend)(mgrClass, sel);
            if (mgr) {
                break;
            }
        }
    }
    SEL reg = @selector(registerControllerWithTitle:version:controller:);
    NSString *clsName = NSStringFromClass([WXIngestSettingsController class]);
    id target = nil;
    if (mgr && [mgr respondsToSelector:reg]) {
        target = mgr;
    } else if ([mgrClass respondsToSelector:reg]) {
        target = mgrClass;
    }
    if (target == nil) {
        NSLog(@"[WeChatIngest] WCPluginsMgr has no registerController");
        return;
    }
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(
        target, reg, WXIngestPluginTitle, WXIngestPluginVersion, clsName);
    registered = YES;
    NSLog(@"[WeChatIngest] registered in WCPluginsMgr as %@ %@", WXIngestPluginTitle, WXIngestPluginVersion);
}

static void WeChatIngestHookClassAppear(Class cls) {
    if (cls == NULL) {
        return;
    }
    static const char *guard = "wx.appear.hooked";
    if (objc_getAssociatedObject(cls, guard)) {
        return;
    }
    objc_setAssociatedObject(cls, guard, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SEL sel = @selector(viewDidAppear:);
    Method own = NULL;
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(list[i]) == sel) {
            own = list[i];
            break;
        }
    }
    free(list);

    if (own != NULL) {
        IMP orig = method_getImplementation(own);
        IMP hook = imp_implementationWithBlock(^void(UIViewController *self, BOOL animated) {
            ((void (*)(id, SEL, BOOL))orig)(self, sel, animated);
            WeChatIngestCleanupHost(self);
        });
        method_setImplementation(own, hook);
        return;
    }

    IMP hook = imp_implementationWithBlock(^void(UIViewController *self, BOOL animated) {
        struct objc_super superInfo = { self, class_getSuperclass(cls) };
        ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&superInfo, sel, animated);
        WeChatIngestCleanupHost(self);
    });
    class_addMethod(cls, sel, hook, "v@:B");
}

void WeChatIngestInstallSettingsHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WeChatIngestRegisterPluginEntry();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WeChatIngestRegisterPluginEntry();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WeChatIngestRegisterPluginEntry();
        });
        const char *cleanup[] = {
            "NewSettingViewController",
            "MoreViewController",
            "MMTabBarMoreViewController",
            NULL
        };
        for (const char **p = cleanup; *p; ++p) {
            WeChatIngestHookClassAppear(objc_getClass(*p));
        }
    });
}

static BOOL WeChatIngestIsLegacyLaunchAlert(UIViewController *vc) {
    if (![vc isKindOfClass:[UIAlertController class]]) {
        return NO;
    }
    UIAlertController *alert = (UIAlertController *)vc;
    NSString *title = alert.title ?: @"";
    NSString *msg = alert.message ?: @"";
    if (![title isEqualToString:@"微信记忆"]) {
        return NO;
    }
    return [msg containsString:@"入口在"] ||
           [msg containsString:@"首次使用"] ||
           [msg containsString:@"启用全量记录"] ||
           [msg containsString:@"批量勾选"] ||
           [msg containsString:@"打开设置"];
}

void WeChatIngestInstallAlertBlocker(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [UIViewController class];
        SEL sel = @selector(presentViewController:animated:completion:);
        Method m = class_getInstanceMethod(cls, sel);
        if (m == NULL) {
            return;
        }
        IMP orig = method_getImplementation(m);
        IMP hook = imp_implementationWithBlock(^void(id self, UIViewController *presented, BOOL animated, id completion) {
            if (WeChatIngestIsLegacyLaunchAlert(presented)) {
                NSLog(@"[WeChatIngest] blocked leftover launch alert");
                return;
            }
            ((void (*)(id, SEL, id, BOOL, id))orig)(self, sel, presented, animated, completion);
        });
        method_setImplementation(m, hook);

        void (^dismissIfNeeded)(void) = ^{
            UIViewController *host = WeChatIngestTopViewController();
            if (WeChatIngestIsLegacyLaunchAlert(host)) {
                [host dismissViewControllerAnimated:NO completion:nil];
            }
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), dismissIfNeeded);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), dismissIfNeeded);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), dismissIfNeeded);
    });
}
