#import "GSPanel.h"
#import <objc/runtime.h>

static const void *GSDeveloperProfileURLKey = &GSDeveloperProfileURLKey;

@interface GSPanel (GSDeveloperLinks)
- (void)gs_developer_viewDidLoad;
- (void)gs_openDeveloperProfile:(UIControl *)sender;
@end

static UILabel *GSDeveloperLabel(NSString *text, UIFontTextStyle style, UIColor *color) {
 UILabel *label=[UILabel new];
 label.translatesAutoresizingMaskIntoConstraints=NO;
 label.text=text;
 label.font=[UIFont preferredFontForTextStyle:style];
 label.textColor=color;
 label.adjustsFontForContentSizeCategory=YES;
 return label;
}

static void GSLoadDeveloperAvatar(UIImageView *imageView, NSString *urlString) {
 UIImageSymbolConfiguration *configuration=[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
 imageView.image=[[UIImage systemImageNamed:@"person.crop.circle.fill"] imageWithConfiguration:configuration];
 imageView.tintColor=UIColor.secondaryLabelColor;
 NSURL *url=[NSURL URLWithString:urlString];
 if(!url)return;
 NSURLRequest *request=[NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:8];
 [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error){
  if(error||!data.length)return;
  UIImage *avatar=[UIImage imageWithData:data];
  if(!avatar)return;
  dispatch_async(dispatch_get_main_queue(),^{
   imageView.image=avatar;
   imageView.tintColor=nil;
  });
 }] resume];
}

static UIControl *GSDeveloperRow(NSString *title, NSString *handle, NSString *profileURL, NSString *avatarURL, id target) {
 UIControl *row=[UIControl new];
 row.translatesAutoresizingMaskIntoConstraints=NO;
 row.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;
 row.layer.cornerRadius=12;
 row.layer.cornerCurve=kCACornerCurveContinuous;
 row.accessibilityTraits=UIAccessibilityTraitButton;
 row.accessibilityLabel=[NSString stringWithFormat:@"%@ %@",title,handle];
 objc_setAssociatedObject(row,GSDeveloperProfileURLKey,profileURL,OBJC_ASSOCIATION_COPY_NONATOMIC);
 [row addTarget:target action:@selector(gs_openDeveloperProfile:) forControlEvents:UIControlEventTouchUpInside];

 UIImageView *avatar=[UIImageView new];
 avatar.translatesAutoresizingMaskIntoConstraints=NO;
 avatar.contentMode=UIViewContentModeScaleAspectFill;
 avatar.clipsToBounds=YES;
 avatar.layer.cornerRadius=20;
 [row addSubview:avatar];

 UILabel *titleLabel=GSDeveloperLabel(title,UIFontTextStyleBody,UIColor.labelColor);
 titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
 UILabel *handleLabel=GSDeveloperLabel(handle,UIFontTextStyleSubheadline,UIColor.secondaryLabelColor);
 UIStackView *labels=[[UIStackView alloc]initWithArrangedSubviews:@[titleLabel,handleLabel]];
 labels.translatesAutoresizingMaskIntoConstraints=NO;
 labels.axis=UILayoutConstraintAxisVertical;
 labels.spacing=1;
 [row addSubview:labels];

 UIImageView *chevron=[[UIImageView alloc]initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
 chevron.translatesAutoresizingMaskIntoConstraints=NO;
 chevron.tintColor=UIColor.tertiaryLabelColor;
 chevron.contentMode=UIViewContentModeScaleAspectFit;
 [row addSubview:chevron];

 [NSLayoutConstraint activateConstraints:@[
  [row.heightAnchor constraintGreaterThanOrEqualToConstant:60],
  [avatar.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
  [avatar.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
  [avatar.widthAnchor constraintEqualToConstant:40],
  [avatar.heightAnchor constraintEqualToConstant:40],
  [labels.leadingAnchor constraintEqualToAnchor:avatar.trailingAnchor constant:12],
  [labels.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
  [labels.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-10],
  [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
  [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
  [chevron.widthAnchor constraintEqualToConstant:10]
 ]];
 GSLoadDeveloperAvatar(avatar,avatarURL);
 return row;
}

@implementation GSPanel (GSDeveloperLinks)

+ (void)load {
 static dispatch_once_t onceToken;
 dispatch_once(&onceToken,^{
  Method original=class_getInstanceMethod(self,@selector(viewDidLoad));
  Method replacement=class_getInstanceMethod(self,@selector(gs_developer_viewDidLoad));
  method_exchangeImplementations(original,replacement);
 });
}

- (void)gs_developer_viewDidLoad {
 [self gs_developer_viewDidLoad];
 if(!self.settingsMode)return;

 UIView *footer=[[UIView alloc]initWithFrame:CGRectMake(0,0,MAX(self.tableView.bounds.size.width,320),166)];
 footer.backgroundColor=UIColor.clearColor;

 UILabel *header=GSDeveloperLabel(@"Developer",UIFontTextStyleFootnote,UIColor.secondaryLabelColor);
 header.text=[header.text uppercaseStringWithLocale:NSLocale.currentLocale];
 [footer addSubview:header];

 UIControl *github=GSDeveloperRow(@"GitHub",@"@tqmane",@"https://github.com/tqmane",@"https://github.com/tqmane.png?size=128",self);
 UIControl *x=GSDeveloperRow(@"X",@"@t2aman1e",@"https://x.com/t2aman1e",@"https://unavatar.io/x/t2aman1e?size=128",self);
 UIStackView *rows=[[UIStackView alloc]initWithArrangedSubviews:@[github,x]];
 rows.translatesAutoresizingMaskIntoConstraints=NO;
 rows.axis=UILayoutConstraintAxisVertical;
 rows.spacing=8;
 [footer addSubview:rows];

 [NSLayoutConstraint activateConstraints:@[
  [header.topAnchor constraintEqualToAnchor:footer.topAnchor constant:8],
  [header.leadingAnchor constraintEqualToAnchor:footer.layoutMarginsGuide.leadingAnchor constant:4],
  [rows.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:6],
  [rows.leadingAnchor constraintEqualToAnchor:footer.layoutMarginsGuide.leadingAnchor],
  [rows.trailingAnchor constraintEqualToAnchor:footer.layoutMarginsGuide.trailingAnchor],
  [rows.bottomAnchor constraintLessThanOrEqualToAnchor:footer.bottomAnchor constant:-8]
 ]];
 self.tableView.tableFooterView=footer;
}

- (void)gs_openDeveloperProfile:(UIControl *)sender {
 NSString *urlString=objc_getAssociatedObject(sender,GSDeveloperProfileURLKey);
 NSURL *url=[NSURL URLWithString:urlString];
 if(!url)return;
 [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

@end
