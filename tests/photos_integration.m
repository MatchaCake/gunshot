#ifdef GS_TEST_LEGACY
#define PHSOneUpInfoPanelBackupStatusData GSFixtureLegacyContentModel
#define getBackupStatusModelData modelForBackedupStatus
#endif
#import "host_profile.h"
#import "../Shared/GSLocalization.h"
#import "../UI/GSPhotosIntegration.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <assert.h>
static NSString *viewingAccount=@"current";
BOOL GSIsGooglePhotos(void){return YES;}
BOOL GSNativeAccountMatches(id account){assert(NSThread.isMainThread);return [viewingAccount isEqual:account];}
@interface FixtureBundle : NSBundle @end
@implementation FixtureBundle
- (id)objectForInfoDictionaryKey:(NSString *)key{return [key isEqual:@"CFBundleExecutable"]?@"GooglePhotos":GSFixtureVersion;}
@end
static id Bundle(id object,SEL selector){return [FixtureBundle new];}
@interface PHSUserItemsSynchronizer : NSObject
@property(nonatomic,strong) NSString *accountID;
@property(nonatomic) NSUInteger fetches;
- (void)fetchData;
- (void)fetchDataSoft;
@end
@implementation PHSUserItemsSynchronizer
- (void)fetchData{self.fetches++;}
- (void)fetchDataSoft{self.fetches++;}
@end
// GS_TEST_POLICY_ON_BASE mirrors the audited 7.92.0 model, where storagePolicy is
// declared on PHSServerPhoto itself. The default build keeps it off the base class
// so the optional-diagnostic and missing-selector guarantees stay covered.
@interface PHSServerPhoto : NSObject
@property(nonatomic) unsigned char hasOriginalBytes;
@property(nonatomic) _Bool isPartialBackup;
#ifdef GS_TEST_POLICY_ON_BASE
@property(nonatomic) unsigned char storagePolicy;
#endif
@end
@implementation PHSServerPhoto @end
#ifdef GS_TEST_POLICY_ON_BASE
@interface PhotoWithStoragePolicy : PHSServerPhoto @end
@implementation PhotoWithStoragePolicy @end
@interface PhotoWithIncompatibleStoragePolicy : PHSServerPhoto @end
@implementation PhotoWithIncompatibleStoragePolicy @end
static id IncompatiblePolicy(id object,SEL selector){assert(0 && "Incompatible diagnostic ABI must not be called");return nil;}
#else
@interface PhotoWithStoragePolicy : PHSServerPhoto
@property(nonatomic) unsigned char storagePolicy;
@end
@implementation PhotoWithStoragePolicy @end
@interface PhotoWithIncompatibleStoragePolicy : PHSServerPhoto
- (id)storagePolicy;
@end
@implementation PhotoWithIncompatibleStoragePolicy
- (id)storagePolicy{assert(0 && "Incompatible diagnostic ABI must not be called");return nil;}
@end
#endif
static unsigned char NativePolicy(PHSServerPhoto *photo){
 Method m=class_getInstanceMethod(object_getClass(photo),NSSelectorFromString(@"storagePolicy"));
 if(!m||strcmp(method_getTypeEncoding(m),"C16@0:8"))return 0;
 return ((unsigned char(*)(id,SEL))objc_msgSend)(photo,NSSelectorFromString(@"storagePolicy"));
}
@interface PHSExtendedPhoto : NSObject
@property(nonatomic,strong) PHSServerPhoto *serverPhoto;
// The client enum (1 saver, 3 original) is stored when the photo loads; it does
// not re-derive from the server policy getter, as the device counters showed.
@property(nonatomic) int serverStoragePolicy;
@end
@implementation PHSExtendedPhoto @end
@interface PHSOneUpInfoPanelBackupStatusData : NSObject
@property(nonatomic,strong) NSString *backupStatus;
@property(nonatomic,strong) NSString *backupStatusSubtitle;
@property(nonatomic,strong) NSString *learnMoreLink;
- (instancetype)initWithBackupStatus:(NSString *)status backupStatusSubtitle:(NSString *)subtitle learnMoreLink:(NSString *)link;
@end
@implementation PHSOneUpInfoPanelBackupStatusData
- (instancetype)initWithBackupStatus:(NSString *)status backupStatusSubtitle:(NSString *)subtitle learnMoreLink:(NSString *)link{if((self=[super init])){self.backupStatus=status;self.backupStatusSubtitle=subtitle;self.learnMoreLink=link;}return self;}
@end
// 7.92.0 index: id / title / attributes / expandedContent getters and the
// initWithTitle:subtitle:(icon:) initializers; the subtitle has no getter (Swift
// storage). The fixture keeps it behind a name the integration never reads.
@interface PHSOneUpInfoPanelDetailsStackViewModel : NSObject{NSString *_swiftSubtitle;}
@property(nonatomic,strong) NSString *id;
@property(nonatomic,strong) NSString *title;
@property(nonatomic,strong) NSArray *attributes;
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle;
- (NSString *)renderedSubtitle;
@end
@implementation PHSOneUpInfoPanelDetailsStackViewModel
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle{if((self=[super init])){self.id=NSUUID.UUID.UUIDString;self.title=title;_swiftSubtitle=subtitle;}return self;}
- (NSString *)renderedSubtitle{return _swiftSubtitle;}
@end
#ifdef GS_TEST_LEGACY
@interface PHSOneUpInfoPanelSectionViewController : NSObject
- (id)contentViewModelWithTitle:(id)title subtitle:(id)subtitle subtitleContainsHTML:(_Bool)html image:(id)image;
@end
@implementation PHSOneUpInfoPanelSectionViewController
- (id)contentViewModelWithTitle:(id)title subtitle:(id)subtitle subtitleContainsHTML:(_Bool)html image:(id)image{
 assert([image isEqual:@"native-icon"]);
 id original=[self valueForKey:@"original"];
 if([subtitle isEqual:[original backupStatusSubtitle]])return original;
 assert(!html);
 return [[PHSOneUpInfoPanelBackupStatusData alloc]initWithBackupStatus:title backupStatusSubtitle:subtitle learnMoreLink:@"native-link"];
}
@end
#define GSDetailsSuperclass PHSOneUpInfoPanelSectionViewController
#else
#define GSDetailsSuperclass NSObject
#endif
@interface UIView : NSObject
@property(nonatomic,strong) NSArray *subviews;
@end
@implementation UIView @end
@interface UILabel : UIView
@property(nonatomic,copy) NSString *text;
@property(nonatomic,copy) NSAttributedString *attributedText;
@end
@implementation UILabel
- (void)setText:(NSString *)text{_text=[text copy];_attributedText=text?[[NSAttributedString alloc]initWithString:text]:nil;}
- (void)setAttributedText:(NSAttributedString *)text{_attributedText=[text copy];_text=text.string;}
@end
static NSString *const SaverText=@"保存容量の節約",*const OriginalText=@"オリジナル画質";
// Wording only the probe can learn (not in the built-in fallback list).
static NSString *const DeviceSaverText=@"節約モード";
typedef NS_ENUM(NSInteger,LabelSource){LabelFromServerPhoto,LabelFromExtendedPhoto,LabelFromNativeSubtitle,LabelFromHTMLSubtitle,LabelFromDeviceStack,LabelFromInitSubtitle};
// A row attribute rendered outside UIKit: only its model carries the words.
@interface GSFixtureAttribute : NSObject
@property(nonatomic,copy) NSString *text;
@end
@implementation GSFixtureAttribute @end
@interface PHSOneUpInfoPanelDetailsViewController : GSDetailsSuperclass
@property(nonatomic) _Bool isBackedUp;
@property(nonatomic,strong) PHSExtendedPhoto *extendedPhoto;
@property(nonatomic,strong) PHSOneUpInfoPanelBackupStatusData *original;
@property(nonatomic) LabelSource labelSource;
@property(nonatomic,strong) NSMutableArray *detailsStackViewModels;
@property(nonatomic,strong) NSString *backupStatusViewModelID;
@property(nonatomic) NSUInteger rowBuilds;
@property(nonatomic) BOOL frozenWords; // Words cached at load, like serverStoragePolicy.
@property(nonatomic,strong) UIView *viewIfLoaded;
@property(nonatomic) NSUInteger layouts;
- (void)viewDidLayoutSubviews;
- (id)getBackupStatusModelData;
- (id)createBackupViewModel:(id)item mediaItem:(id)media serverPhoto:(id)photo localAsset:(id)asset storeResult:(id)store;
- (id)createStackViewModelsForExtendedPhoto:(id)photo preferredMediaItem:(id)item;
- (void)updateBackupStatusUI;
@end
@implementation PHSOneUpInfoPanelDetailsViewController
- (id)getBackupStatusModelData{
 // 7.92.0 on device: the subtitle is HTML with a help link, and its quality
 // words follow the storage policy read while it is built.
 if(self.labelSource==LabelFromHTMLSubtitle||self.labelSource==LabelFromDeviceStack){
  // Device: server policy 2 is the original-quality policy and a quota-free
  // Pixel upload already reads original here; 1 (Standard) is Storage saver.
  unsigned char policy=NativePolicy(self.extendedPhoto.serverPhoto);
  NSString *words=self.labelSource==LabelFromDeviceStack?(policy==3?DeviceSaverText:OriginalText):policy==2?OriginalText:SaverText;
  // The device-stack case is a different build with its own status wording;
  // learned saver words are cached per native subtitle.
  NSString *status=self.labelSource==LabelFromDeviceStack?@"保存済み":@"バックアップ済み";
  NSString *html=[NSString stringWithFormat:@"%@（%@） <a href=\"https://support.google.com/photos/answer/6220791\">詳細</a>",status,words];
  return [[PHSOneUpInfoPanelBackupStatusData alloc]initWithBackupStatus:self.original.backupStatus backupStatusSubtitle:html learnMoreLink:@"native-link"];
 }
#ifdef GS_TEST_LEGACY
 return [self contentViewModelWithTitle:self.original.backupStatus subtitle:self.original.backupStatusSubtitle subtitleContainsHTML:YES image:@"native-icon"];
#else
 return self.original;
#endif
}
// The 7.92.0 details stack derives the quality text itself; the fixture models
// three possible sources so each correction path is observed separately.
- (NSString *)qualityTextForPhoto:(PHSServerPhoto *)photo{
 switch(self.labelSource){
  case LabelFromExtendedPhoto:return self.extendedPhoto.serverStoragePolicy==3?OriginalText:SaverText;
  case LabelFromNativeSubtitle:return self.original.backupStatusSubtitle;
  case LabelFromHTMLSubtitle:return NativePolicy(photo)==2?OriginalText:SaverText;
  // Device (7th diagnostics): every getter reads original, the words still say
  // saver. The source is not exposed by any getter, so the fixture fixes them.
  case LabelFromInitSubtitle:return SaverText;
  default:return NativePolicy(photo)==2?OriginalText:SaverText;
 }
}
- (id)createBackupViewModel:(id)item mediaItem:(id)media serverPhoto:(id)photo localAsset:(id)asset storeResult:(id)store{
 self.rowBuilds++;
 id status=[self getBackupStatusModelData]; // The stack path reuses the quota text and link.
 // The device factory hands the words to initWithTitle:subtitle:; the other
 // sources keep them in an attribute the getters expose.
 BOOL viaInit=self.labelSource==LabelFromInitSubtitle;
 PHSOneUpInfoPanelDetailsStackViewModel *row=[[PHSOneUpInfoPanelDetailsStackViewModel alloc]initWithTitle:[status backupStatus] subtitle:viaInit?[self qualityTextForPhoto:photo]:nil];
 if(!viaInit&&self.labelSource!=LabelFromHTMLSubtitle)row.attributes=@[[self qualityTextForPhoto:photo]];
 if(self.labelSource==LabelFromHTMLSubtitle){
  // Words in a nested model, fetched while storagePolicy is still native.
  GSFixtureAttribute *words=[GSFixtureAttribute new],*link=[GSFixtureAttribute new];link.text=@"詳細";
  words.text=self.frozenWords?SaverText:[self qualityTextForPhoto:photo];
  row.attributes=@[words,link];
 }
 self.backupStatusViewModelID=row.id;[self.detailsStackViewModels addObject:row];return row;
}
- (id)createStackViewModelsForExtendedPhoto:(id)photo preferredMediaItem:(id)item{
 if(self.labelSource==LabelFromDeviceStack){
  // The backup row holds only the quota title; the saver words sit in another
  // row whose model caches them, and the rows are assigned through the setter.
  PHSOneUpInfoPanelDetailsStackViewModel *backup=[[PHSOneUpInfoPanelDetailsStackViewModel alloc]initWithTitle:@"バックアップ済み • 容量不使用" subtitle:nil];
  GSFixtureAttribute *words=[GSFixtureAttribute new];words.text=DeviceSaverText;
  PHSOneUpInfoPanelDetailsStackViewModel *quality=[[PHSOneUpInfoPanelDetailsStackViewModel alloc]initWithTitle:@"画質" subtitle:nil];quality.attributes=@[words];
  self.backupStatusViewModelID=backup.id;self.detailsStackViewModels=[NSMutableArray arrayWithObjects:backup,quality,nil];
  return [self.detailsStackViewModels copy];
 }
 self.detailsStackViewModels=[NSMutableArray array];
 return @[[self createBackupViewModel:item mediaItem:nil serverPhoto:self.extendedPhoto.serverPhoto localAsset:nil storeResult:nil]];
}
- (void)viewDidLayoutSubviews{self.layouts++;}
- (void)updateBackupStatusUI{
 for(PHSOneUpInfoPanelDetailsStackViewModel *row in self.detailsStackViewModels)
  if([row.id isEqual:self.backupStatusViewModelID])row.attributes=@[[self qualityTextForPhoto:self.extendedPhoto.serverPhoto]];
}
@end
static void Drain(BOOL(^finished)(void)){
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:4];
 // Per-iteration pools mirror the app runtime, where autoreleased references
 // from each runloop pass do not outlive it.
 while(!finished()&&deadline.timeIntervalSinceNow>0)@autoreleasepool{[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];}
 assert(finished());
}
#ifndef GS_TEST_LEGACY
static NSUInteger Count(NSString *key){return [GSPhotosIntegrationSnapshot()[key]unsignedIntegerValue];}
#endif
int main(void){@autoreleasepool{
 method_setImplementation(class_getClassMethod(NSBundle.class,@selector(mainBundle)),(IMP)Bundle);
#ifdef GS_TEST_POLICY_ON_BASE
 class_addMethod(PhotoWithIncompatibleStoragePolicy.class,NSSelectorFromString(@"storagePolicy"),(IMP)IncompatiblePolicy,"@16@0:8");
#endif
 GSInstallPhotosIntegration();assert([GSPhotosIntegrationSnapshot()[@"qualityAvailable"]boolValue]&&[GSPhotosIntegrationSnapshot()[@"syncAvailable"]boolValue]);
 PHSOneUpInfoPanelDetailsViewController *details=[PHSOneUpInfoPanelDetailsViewController new];details.isBackedUp=YES;
 details.original=[[PHSOneUpInfoPanelBackupStatusData alloc]initWithBackupStatus:@"保存容量を使用しません" backupStatusSubtitle:SaverText learnMoreLink:@"native-link"];
 details.extendedPhoto=[PHSExtendedPhoto new];details.extendedPhoto.serverStoragePolicy=1;PhotoWithStoragePolicy *photo=[PhotoWithStoragePolicy new];details.extendedPhoto.serverPhoto=photo;photo.storagePolicy=1;
 for(unsigned char value=0;value<4;value++){
  photo.hasOriginalBytes=value;id result=[details getBackupStatusModelData];
  if(value==1){assert(result!=details.original);assert([[result backupStatusSubtitle]isEqual:GSL(@"Original quality (original data available)")]);assert([[result backupStatus]isEqual:details.original.backupStatus]);}
  else assert(result==details.original); // No / Unknown / Maybe can never become Original.
 }
 photo.hasOriginalBytes=1;photo.isPartialBackup=YES;assert([details getBackupStatusModelData]==details.original);
 photo.isPartialBackup=NO;details.isBackedUp=NO;assert([details getBackupStatusModelData]==details.original);
 // Server-confirmed originals correct the label without the backup-routing toggle or its symbols.
 details.isBackedUp=YES;assert([details getBackupStatusModelData]!=details.original);
 // Quota-free uploads report hasOriginalBytes=Yes with a non-Standard storagePolicy;
 // the correction depends only on the original-bytes model, and each observed policy
 // value is counted for diagnostics.
 for(unsigned char policy=0;policy<4;policy++){
  photo.storagePolicy=policy;id result=[details getBackupStatusModelData];
  assert(result!=details.original);assert([[result backupStatusSubtitle]isEqual:GSL(@"Original quality (original data available)")]);
  NSString *policyKey=[NSString stringWithFormat:@"serverStoragePolicy%u",(unsigned)policy];
  assert([GSPhotosIntegrationSnapshot()[policyKey]unsignedIntegerValue]>=1);
 }
 photo.storagePolicy=1;
 // Optional diagnostics must not gate quality correction or call an unknown ABI.
#ifdef GS_TEST_POLICY_ON_BASE
 NSArray *optionals=@[[PhotoWithIncompatibleStoragePolicy new]];
#else
 NSArray *optionals=@[[PHSServerPhoto new],[PhotoWithIncompatibleStoragePolicy new]];
#endif
 for(PHSServerPhoto *optional in optionals){
  optional.hasOriginalBytes=1;details.extendedPhoto.serverPhoto=optional;
  NSDictionary *before=GSPhotosIntegrationSnapshot();
  id result=[details getBackupStatusModelData];
  assert(result!=details.original);
  assert([[result backupStatusSubtitle]isEqual:GSL(@"Original quality (original data available)")]);
  assert([[result backupStatus]isEqual:details.original.backupStatus]);
  for(unsigned char policy=0;policy<4;policy++){
   NSString *key=[NSString stringWithFormat:@"serverStoragePolicy%u",(unsigned)policy];
   assert([before[key]isEqual:GSPhotosIntegrationSnapshot()[key]]);
  }
  optional.isPartialBackup=YES;assert([details getBackupStatusModelData]==details.original);
  optional.isPartialBackup=NO;optional.hasOriginalBytes=2;assert([details getBackupStatusModelData]==details.original);
 }
 details.extendedPhoto.serverPhoto=photo;
 assert([details.original.backupStatusSubtitle isEqual:SaverText]); // No mutation of native state.
#ifdef GS_TEST_LEGACY
 assert([details contentViewModelWithTitle:details.original.backupStatus subtitle:details.original.backupStatusSubtitle subtitleContainsHTML:YES image:@"native-icon"]==details.original);
 assert(![details respondsToSelector:NSSelectorFromString(@"getBackupStatusModelData")]);
 assert(!NSClassFromString(@"PHSOneUpInfoPanelBackupStatusData"));
 assert(![GSPhotosIntegrationSnapshot()[@"stackQualityAvailable"]boolValue]); // 7.20.2 has no details stack.
#else
 // Details stack: the visible row is built by createBackupViewModel:..., not from
 // the BackupStatusData subtitle. A quota-free original (policy 2, Yes) must show
 // original quality on every text source, and nothing may change outside the scope.
 assert([GSPhotosIntegrationSnapshot()[@"stackQualityAvailable"]boolValue]);
 photo.storagePolicy=2;photo.hasOriginalBytes=1;photo.isPartialBackup=NO;details.isBackedUp=YES;
 PHSOneUpInfoPanelDetailsStackViewModel *row=nil;
#define BuildRow() (row=[details createStackViewModelsForExtendedPhoto:details.extendedPhoto preferredMediaItem:nil][0])
#ifdef GS_TEST_POLICY_ON_BASE
 // The factory reads PHSServerPhoto.storagePolicy. Device: 2 is the original
 // policy and is read natively; 1 (Standard, the Storage saver policy) reads as
 // 2 for a confirmed original inside the factory only. Builds 1-6 forced 1.
 details.labelSource=LabelFromServerPhoto;NSUInteger policy2=Count(@"serverStoragePolicy2"),policy1=Count(@"serverStoragePolicy1"),corrected=Count(@"stackRowCorrected"),policyOverrides=Count(@"displayPolicyOverrides");
 BuildRow();
 assert([row.attributes[0]isEqual:OriginalText]&&[row.title isEqual:details.original.backupStatus]);
 assert(Count(@"displayPolicyOverrides")==policyOverrides&&Count(@"stackBackupRows")==1&&Count(@"stackRowCorrected")==corrected);
 assert([GSPhotosIntegrationSnapshot()[@"stackRowClasses"]containsObject:@"PHSOneUpInfoPanelDetailsStackViewModel"]);
 // The nested getBackupStatusModelData diagnostic saw the native value, not the display value.
 assert(photo.storagePolicy==2&&Count(@"serverStoragePolicy2")==policy2+1&&Count(@"serverStoragePolicy1")==policy1);
 photo.storagePolicy=1;BuildRow();
 assert([row.attributes[0]isEqual:OriginalText]&&Count(@"displayPolicyOverrides")>policyOverrides&&Count(@"stackRowCorrected")==corrected);
 assert(photo.storagePolicy==1&&Count(@"serverStoragePolicy1")==policy1+1); // Stored value untouched outside the factory.
 photo.storagePolicy=2;
#endif
 // The factory reads the stored client enum through PHSExtendedPhoto.serverStoragePolicy
 // (device: displayServerPolicy1 while storagePolicy was already overridden).
 details.labelSource=LabelFromExtendedPhoto;NSUInteger textFixes=Count(@"stackRowCorrected");BuildRow();
 assert([row.attributes[0]isEqual:OriginalText]&&Count(@"displayServerPolicyReads")>=1&&Count(@"displayServerPolicyOverrides")>=1&&Count(@"stackRowCorrected")==textFixes);
 // Outside the scope (device: the SwiftUI stack renders after the factories and
 // its reads were never counted), the correction holds for every instance of a
 // confirmed original on every thread, and each read site is counted.
 assert(details.extendedPhoto.serverStoragePolicy==3&&Count(@"displayServerPolicyOutsideOverrides")>=1);
 PHSExtendedPhoto *twin=[PHSExtendedPhoto new];twin.serverPhoto=photo;twin.serverStoragePolicy=1;
 assert(twin.serverStoragePolicy==3&&Count(@"displayServerPolicyReadsOtherInstance")>=1&&Count(@"displayServerPolicyOtherInstanceOverrides")>=1);
 __block int background=0;dispatch_group_t group=dispatch_group_create();
 dispatch_group_async(group,dispatch_get_global_queue(0,0),^{background=details.extendedPhoto.serverStoragePolicy;});
 dispatch_group_wait(group,DISPATCH_TIME_FOREVER);
 assert(background==3&&Count(@"displayServerPolicyReadsOffMain")>=1&&Count(@"displayServerPolicyOffMainOverrides")>=1);
 // Not an original: native on every site.
 photo.hasOriginalBytes=2;assert(details.extendedPhoto.serverStoragePolicy==1&&twin.serverStoragePolicy==1);
 dispatch_group_async(group,dispatch_get_global_queue(0,0),^{background=details.extendedPhoto.serverStoragePolicy;});
 dispatch_group_wait(group,DISPATCH_TIME_FOREVER);assert(background==1);
 photo.hasOriginalBytes=1;
 // The factory copies the native subtitle wording: the row text is replaced, the quota title kept.
 details.labelSource=LabelFromNativeSubtitle;NSUInteger corrections=Count(@"stackRowCorrected");BuildRow();
 assert([row.attributes[0]isEqual:GSL(@"Original quality (original data available)")]&&[row.title isEqual:details.original.backupStatus]);
 assert(Count(@"stackRowCorrected")==corrections+1);
 // A later native status update on the tracked row is corrected again.
 [details updateBackupStatusUI];
 assert([row.attributes[0]isEqual:GSL(@"Original quality (original data available)")]&&Count(@"stackBackupUpdates")>=1&&Count(@"stackRowCorrected")==corrections+2);
 // Device 7th build: the factory passes the words to initWithTitle:subtitle:,
 // whose value no getter exposes (Swift storage rendered directly). It is
 // corrected on the way in, recorded, and only inside a confirmed original's scope.
 details.labelSource=LabelFromInitSubtitle;NSUInteger initFixes=Count(@"initCorrected.subtitle");BuildRow();
 assert([[row renderedSubtitle]isEqual:GSL(@"Original quality (original data available)")]&&!row.attributes&&[row.title isEqual:details.original.backupStatus]);
 assert(Count(@"initCorrected.subtitle")==initFixes+1&&[GSPhotosIntegrationSnapshot()[@"rowTexts"]containsObject:[@"init.subtitle<str>: " stringByAppendingString:SaverText]]);
 assert([GSPhotosIntegrationSnapshot()[@"rowTexts"]containsObject:[@"init.title<str>: " stringByAppendingString:details.original.backupStatus]]);
 photo.hasOriginalBytes=2;BuildRow();assert([[row renderedSubtitle]isEqual:SaverText]);
 photo.hasOriginalBytes=1;photo.isPartialBackup=YES;BuildRow();assert([[row renderedSubtitle]isEqual:SaverText]);
 photo.isPartialBackup=NO;details.isBackedUp=NO;BuildRow();assert([[row renderedSubtitle]isEqual:SaverText]);
 details.isBackedUp=YES;
 // Outside any factory the initializer is untouched.
 PHSOneUpInfoPanelDetailsStackViewModel *loose=[[PHSOneUpInfoPanelDetailsStackViewModel alloc]initWithTitle:@"x" subtitle:SaverText];
 assert([[loose renderedSubtitle]isEqual:SaverText]&&Count(@"initCorrected.subtitle")==initFixes+1);
 // No / partial / not backed up leave the native row and never override the policy.
 // The photo sits on the saver policy so the native row wording is saver.
 photo.storagePolicy=1;
 NSUInteger overrides=Count(@"displayPolicyOverrides")+Count(@"displayServerPolicyOverrides");corrections=Count(@"stackRowCorrected");
 for(LabelSource source=LabelFromServerPhoto;source<=LabelFromNativeSubtitle;source++){
  details.labelSource=source;
  photo.hasOriginalBytes=2;BuildRow();assert([row.attributes[0]isEqual:SaverText]);
  photo.hasOriginalBytes=1;photo.isPartialBackup=YES;BuildRow();assert([row.attributes[0]isEqual:SaverText]);
  // Not backed up: no scope, no text correction. The client enum follows the
  // server photo rather than the controller, so a photo the server holds in
  // original reads original wherever it is shown.
  photo.isPartialBackup=NO;details.isBackedUp=NO;BuildRow();
  NSString *expected=source==LabelFromExtendedPhoto?OriginalText:SaverText;
  assert([row.attributes[0]isEqual:expected]);
  [details updateBackupStatusUI];assert([row.attributes[0]isEqual:expected]);
  details.isBackedUp=YES;
 }
 assert(Count(@"displayPolicyOverrides")+Count(@"displayServerPolicyOverrides")==overrides&&Count(@"stackRowCorrected")==corrections);
 assert([details.original.backupStatusSubtitle isEqual:SaverText]);
 photo.storagePolicy=2;
 // Layout pass: whatever structure renders the row, a visible label holding the
 // native quality wording is corrected after the details view lays out.
 assert([GSPhotosIntegrationSnapshot()[@"panelLayoutAvailable"]boolValue]);
 UILabel *quality=[UILabel new],*name=[UILabel new],*size=[UILabel new],*styled=[UILabel new];
 name.text=@"IMG_0042.PNG";size.text=@"3.2 MB";
 UIView *cell=[UIView new];cell.subviews=@[quality,styled];
 UIView *root=[UIView new];root.subviews=@[cell,name,size];details.viewIfLoaded=root;
 NSDictionary *bold=@{@"GSFixtureWeight":@"bold"};
 void(^resetLabels)(void)=^{quality.text=[@"バックアップ済み · " stringByAppendingString:SaverText];
  styled.attributedText=[[NSAttributedString alloc]initWithString:SaverText attributes:bold];};
 NSString *fixed=GSL(@"Original quality (original data available)");
 resetLabels();NSUInteger labelFixes=Count(@"panelLabelCorrected");
 [details viewDidLayoutSubviews];
 assert(details.layouts==1); // Native layout still runs first.
 assert([quality.text isEqual:[@"バックアップ済み · " stringByAppendingString:fixed]]);
 assert([styled.text isEqual:fixed]&&[[styled.attributedText attribute:@"GSFixtureWeight" atIndex:0 effectiveRange:NULL]isEqual:@"bold"]);
 assert([name.text isEqual:@"IMG_0042.PNG"]&&[size.text isEqual:@"3.2 MB"]&&Count(@"panelLabelCorrected")==labelFixes+2);
 NSArray *texts=GSPhotosIntegrationSnapshot()[@"panelTexts"];
 assert([texts containsObject:@"#.# MB"]&&![texts containsObject:@"IMG_####.PNG"]); // Digits masked, file names dropped.
 assert([texts containsObject:[@"native-quality: " stringByAppendingString:SaverText]]);
 // A second pass finds nothing left to replace, so layout converges.
 [details viewDidLayoutSubviews];assert(Count(@"panelLabelCorrected")==labelFixes+2);
 // Not original / partial / not backed up: labels stay native.
 photo.hasOriginalBytes=2;resetLabels();[details viewDidLayoutSubviews];assert([styled.text isEqual:SaverText]);
 photo.hasOriginalBytes=1;photo.isPartialBackup=YES;[details viewDidLayoutSubviews];assert([styled.text isEqual:SaverText]);
 photo.isPartialBackup=NO;details.isBackedUp=NO;[details viewDidLayoutSubviews];assert([styled.text isEqual:SaverText]);
 details.isBackedUp=YES;details.viewIfLoaded=nil;
#ifdef GS_TEST_POLICY_ON_BASE
 // HTML subtitle (device 2026-09-24): the verbatim subtitle never occurs in the
 // row, whose words sit in a nested model cached at load. The native subtitle
 // already reads original (policy 2); the saver words are learned by rebuilding
 // it with the other policies, and the link text stays.
 photo.storagePolicy=2;photo.hasOriginalBytes=1;details.labelSource=LabelFromHTMLSubtitle;details.frozenWords=YES;
 corrections=Count(@"stackRowCorrected");BuildRow();
 GSFixtureAttribute *words=row.attributes[0],*link=row.attributes[1];
 assert([words.text isEqual:fixed]&&[link.text isEqual:@"詳細"]&&Count(@"stackRowCorrected")==corrections+1);
 NSArray *rowTexts=GSPhotosIntegrationSnapshot()[@"rowTexts"];
 assert([rowTexts containsObject:[@"saver: " stringByAppendingString:SaverText]]);
 assert(![rowTexts containsObject:[@"saver: " stringByAppendingString:OriginalText]]); // The baseline is the original policy.
 assert([rowTexts containsObject:[@"row.attributes[0].text<str>: " stringByAppendingString:SaverText]]);
 for(NSString *entry in rowTexts)assert(![entry containsString:@"support.google.com"]);
 [details updateBackupStatusUI];assert([words.text isEqual:fixed]&&[link.text isEqual:@"詳細"]);
 // The HTML native subtitle is recorded with its link redacted, not dropped.
 NSString *nativeLine=[NSString stringWithFormat:@"バックアップ済み（%@）",SaverText],*fixedLine=[NSString stringWithFormat:@"バックアップ済み（%@）",fixed];
 UILabel *htmlLabel=[UILabel new];htmlLabel.text=nativeLine;
 root.subviews=@[htmlLabel];details.viewIfLoaded=root;[details viewDidLayoutSubviews];
 assert([htmlLabel.text isEqual:fixedLine]);
 BOOL recorded=NO;for(NSString *entry in GSPhotosIntegrationSnapshot()[@"rowTexts"])if([entry hasPrefix:@"candidate: "]&&[entry containsString:@"<a>詳細<a>"])recorded=YES;
 assert(recorded&&[GSPhotosIntegrationSnapshot()[@"panelViewClasses"]containsObject:@"UILabel"]);
 // Not an original on the saver policy: the nested words stay native.
 photo.hasOriginalBytes=2;photo.storagePolicy=1;details.frozenWords=NO;BuildRow();assert([[row.attributes[0] text]isEqual:SaverText]);
 photo.hasOriginalBytes=1;photo.storagePolicy=2;details.labelSource=LabelFromServerPhoto;details.viewIfLoaded=nil;
 // Device 4th build: the native subtitle already reads original, and the saver
 // words are in a non-backup row. The probe learns them from the app's own
 // subtitle for another policy, and every assigned row is corrected.
 photo.storagePolicy=2;details.labelSource=LabelFromDeviceStack;details.frozenWords=NO;
 NSUInteger assigned=Count(@"stackModelAssignments");corrections=Count(@"stackRowCorrected");
 NSArray *stack=[details createStackViewModelsForExtendedPhoto:details.extendedPhoto preferredMediaItem:nil];
 GSFixtureAttribute *deviceWords=[stack[1] attributes][0];
 assert([deviceWords.text isEqual:fixed]&&[[stack[0] title]isEqual:@"バックアップ済み • 容量不使用"]);
 assert(Count(@"stackModelAssignments")==assigned+1&&Count(@"stackRowCorrected")>=corrections+1&&Count(@"saverWordingsProbed")>=1);
 rowTexts=GSPhotosIntegrationSnapshot()[@"rowTexts"];
 assert([rowTexts containsObject:[@"saver: " stringByAppendingString:DeviceSaverText]]);
 assert([rowTexts containsObject:[@"rows[1].attributes[0].text<str>: " stringByAppendingString:DeviceSaverText]]);
 // A row model refreshed after assignment is corrected on the next layout,
 // and the replacement is never re-edited (English "Original quality" is inside it).
 deviceWords.text=DeviceSaverText;[details viewDidLayoutSubviews];assert([deviceWords.text isEqual:fixed]);
 [details viewDidLayoutSubviews];assert([deviceWords.text isEqual:fixed]);
 // Not an original: the row keeps the native words.
 photo.hasOriginalBytes=2;stack=[details createStackViewModelsForExtendedPhoto:details.extendedPhoto preferredMediaItem:nil];
 assert([[(GSFixtureAttribute *)[stack[1] attributes][0] text]isEqual:DeviceSaverText]);
 photo.hasOriginalBytes=1;details.labelSource=LabelFromServerPhoto;
#endif
 photo.storagePolicy=1;
#endif
 PHSUserItemsSynchronizer *other=[PHSUserItemsSynchronizer new];other.accountID=@"other";[other fetchData];
 GSRefreshNativeLibrary(); // Queue before the viewing account's sync object is observed.
 PHSUserItemsSynchronizer *current=[PHSUserItemsSynchronizer new];current.accountID=viewingAccount;[current fetchDataSoft];
 GSRefreshNativeLibrary();GSRefreshNativeLibrary();
 Drain(^BOOL{return current.fetches==2;});assert(other.fetches==1); // Coalesced and account-bound.
 viewingAccount=@"other";GSRefreshNativeLibrary();Drain(^BOOL{return other.fetches==2;});assert(current.fetches==2);
 viewingAccount=@"current";
 // Native fetch entry does not prove fresh server state; the delayed request survives.
 GSRefreshNativeLibrary();[current fetchData];
 Drain(^BOOL{return current.fetches==4;});
 // A soft fetch must also leave the queued refresh intact.
 GSRefreshNativeLibrary();[current fetchDataSoft];
 Drain(^BOOL{return current.fetches==6;});
 // The app releases per-sync synchronizers; the newest capture per account is
 // retained so a completion signal after release still reaches the sync queue.
 __weak PHSUserItemsSynchronizer *released=current;current=nil;
 for(int i=0;i<5;i++)@autoreleasepool{[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];} // Drain pending autoreleases pinning the object.
 assert(released); // Alive through the integration's map, not this test.
 GSRefreshNativeLibrary();Drain(^BOOL{return released.fetches==7;});
 assert(other.fetches==2);
 NSLog(@"PASS server-confirmed original label for every storage policy, details-stack row correction on policy/enum/text sources, layout-time label correction with masked panel texts with native reads outside the display scope, Unknown/No/Maybe/partial safeguards, quota preservation, account-bound coalesced native delta sync, native-fetch-preserved and release-surviving refresh");
 return 0;
}}
