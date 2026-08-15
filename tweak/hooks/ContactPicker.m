#import "ContactPicker.h"
#import "Contacts.h"
#import "../Settings.h"

@interface WXIngestContactPickerController () <UISearchBarDelegate>
@property(nonatomic, copy) NSString *kind;
@property(nonatomic, copy) NSArray<WXIngestContact *> *allItems;
@property(nonatomic, copy) NSArray<WXIngestContact *> *visibleItems;
@property(nonatomic, strong) NSMutableSet<NSString *> *selected;
@property(nonatomic, strong) UISearchBar *searchBar;
@property(nonatomic, assign) BOOL excludeMode;
@end

@implementation WXIngestContactPickerController

- (instancetype)initWithKind:(NSString *)kind {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _kind = [kind copy];
        _selected = [NSMutableSet set];
        BOOL isDM = [kind isEqualToString:@"dm"];
        _excludeMode = isDM ? [WXIngestSettings recordAllDMs] : [WXIngestSettings recordAllGroups];
        NSArray *seed = _excludeMode
            ? (isDM ? [WXIngestSettings dmExclude] : [WXIngestSettings groupExclude])
            : (isDM ? [WXIngestSettings dmList] : [WXIngestSettings groupList]);
        if (seed.count) {
            [_selected addObjectsFromArray:seed];
        }
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    BOOL isDM = [self.kind isEqualToString:@"dm"];
    if (self.excludeMode) {
        self.title = isDM ? @"排除的私聊" : @"排除的群";
    } else {
        self.title = isDM ? @"选择私聊" : @"选择群聊";
    }
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(wxSave)];
    UIColor *paper = [UIColor colorWithRed:0.996 green:0.973 blue:0.953 alpha:1];
    UIColor *red = [UIColor colorWithRed:0.93 green:0.32 blue:0.30 alpha:1];
    self.tableView.backgroundColor = paper;
    self.view.backgroundColor = paper;
    self.navigationController.navigationBar.tintColor = red;

    UIToolbar *bar = [[UIToolbar alloc] init];
    [bar sizeToFit];
    UIBarButtonItem *all = [[UIBarButtonItem alloc] initWithTitle:@"全选"
                                                            style:UIBarButtonItemStylePlain
                                                           target:self
                                                           action:@selector(wxSelectAll)];
    UIBarButtonItem *none = [[UIBarButtonItem alloc] initWithTitle:@"全不选"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(wxSelectNone)];
    UIBarButtonItem *search = [[UIBarButtonItem alloc] initWithTitle:@"搜索"
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(wxFocusSearch)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                          target:nil
                                                                          action:nil];
    bar.items = @[all, search, flex, none];
    self.tableView.tableFooterView = [[UIView alloc] init];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 56)];
    self.searchBar.placeholder = isDM ? @"搜索好友备注 / 昵称 / wxid" : @"搜索群名 / 群 id";
    self.searchBar.delegate = self;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 100)];
    self.searchBar.frame = CGRectMake(0, 0, header.bounds.size.width, 56);
    bar.frame = CGRectMake(0, 56, header.bounds.size.width, 44);
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:self.searchBar];
    [header addSubview:bar];
    self.tableView.tableHeaderView = header;

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectZero];
    tip.textAlignment = NSTextAlignmentCenter;
    tip.numberOfLines = 0;
    if ([UIColor respondsToSelector:@selector(secondaryLabelColor)]) {
        tip.textColor = [UIColor secondaryLabelColor];
    }
    tip.font = [UIFont systemFontOfSize:14];
    tip.text = @"正在读取微信通讯录…";
    self.tableView.backgroundView = tip;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *items = [WXIngestContacts contactsOfKind:self.kind];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.allItems = items;
            self.visibleItems = items;
            self.tableView.backgroundView = items.count ? nil : tip;
            if (items.count == 0) {
                tip.text = @"没有读到会话。请确认微信已登录，然后返回再进一次。";
            }
            [self wxUpdateTitle];
            [self.tableView reloadData];
        });
    });
}

- (void)wxUpdateTitle {
    NSString *base = self.excludeMode
        ? ([self.kind isEqualToString:@"dm"] ? @"排除的私聊" : @"排除的群")
        : ([self.kind isEqualToString:@"dm"] ? @"选择私聊" : @"选择群聊");
    self.title = [NSString stringWithFormat:@"%@ · %lu", base, (unsigned long)self.selected.count];
}

- (void)wxFocusSearch {
    [self.searchBar becomeFirstResponder];
}

- (void)wxSelectAll {
    for (WXIngestContact *item in self.visibleItems) {
        [self.selected addObject:item.username];
    }
    [self wxUpdateTitle];
    [self.tableView reloadData];
}

- (void)wxSelectNone {
    for (WXIngestContact *item in self.visibleItems) {
        [self.selected removeObject:item.username];
    }
    [self wxUpdateTitle];
    [self.tableView reloadData];
}

- (void)wxSave {
    NSArray *list = [[self.selected allObjects] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    BOOL isDM = [self.kind isEqualToString:@"dm"];
    if (self.excludeMode) {
        if (isDM) {
            [WXIngestSettings setDmExclude:list];
        } else {
            [WXIngestSettings setGroupExclude:list];
        }
    } else {
        if (isDM) {
            [WXIngestSettings setDmList:list];
            [WXIngestSettings setRecordAllDMs:NO];
        } else {
            [WXIngestSettings setGroupList:list];
            [WXIngestSettings setRecordAllGroups:NO];
        }
    }
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    NSString *q = [searchText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    if (q.length == 0) {
        self.visibleItems = self.allItems;
    } else {
        NSMutableArray *out = [NSMutableArray array];
        for (WXIngestContact *item in self.allItems) {
            if ([item.displayName.lowercaseString containsString:q] ||
                [item.username.lowercaseString containsString:q]) {
                [out addObject:item];
            }
        }
        self.visibleItems = out;
    }
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)self.visibleItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
        cell.textLabel.numberOfLines = 1;
        cell.detailTextLabel.numberOfLines = 1;
        if ([UIColor respondsToSelector:@selector(secondaryLabelColor)]) {
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }
    }
    WXIngestContact *item = self.visibleItems[(NSUInteger)indexPath.row];
    cell.textLabel.text = item.displayName;
    cell.detailTextLabel.text = item.username;
    cell.accessoryType = [self.selected containsObject:item.username]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    WXIngestContact *item = self.visibleItems[(NSUInteger)indexPath.row];
    if ([self.selected containsObject:item.username]) {
        [self.selected removeObject:item.username];
    } else {
        [self.selected addObject:item.username];
    }
    [self wxUpdateTitle];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
