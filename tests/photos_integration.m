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
- (int)serverStoragePolicy;
@end
@implementation PHSExtendedPhoto
// The client-side enum derives from the stored server policy: Standard maps to
// the original-quality value, anything else to the saver value.
- (int)serverStoragePolicy{return NativePolicy(self.serverPhoto)==1?3:1;}
@end
@interface PHSOneUpInfoPanelBackupStatusData : NSObject
@property(nonatomic,strong) NSString *backupStatus;
@property(nonatomic,strong) NSString *backupStatusSubtitle;
@property(nonatomic,strong) NSString *learnMoreLink;
- (instancetype)initWithBackupStatus:(NSString *)status backupStatusSubtitle:(NSString *)subtitle learnMoreLink:(NSString *)link;
@end
@implementation PHSOneUpInfoPanelBackupStatusData
- (instancetype)initWithBackupStatus:(NSString *)status backupStatusSubtitle:(NSString *)subtitle learnMoreLink:(NSString *)link{if((self=[super init])){self.backupStatus=status;self.backupStatusSubtitle=subtitle;self.learnMoreLink=link;}return self;}
@end
@interface PHSOneUpInfoPanelDetailsStackViewModel : NSObject
@property(nonatomic,strong) NSString *id;
@property(nonatomic,strong) NSString *title;
@property(nonatomic,strong) NSArray *attributes;
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle;
@end
@implementation PHSOneUpInfoPanelDetailsStackViewModel
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle{if((self=[super init])){self.id=NSUUID.UUID.UUIDString;self.title=title;self.attributes=@[subtitle];}return self;}
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
static NSString *const SaverText=@"保存容量の節約",*const OriginalText=@"オリジナル画質";
typedef NS_ENUM(NSInteger,LabelSource){LabelFromServerPhoto,LabelFromExtendedPhoto,LabelFromNativeSubtitle};
@interface PHSOneUpInfoPanelDetailsViewController : GSDetailsSuperclass
@property(nonatomic) _Bool isBackedUp;
@property(nonatomic,strong) PHSExtendedPhoto *extendedPhoto;
@property(nonatomic,strong) PHSOneUpInfoPanelBackupStatusData *original;
@property(nonatomic) LabelSource labelSource;
@property(nonatomic,strong) NSMutableArray *detailsStackViewModels;
@property(nonatomic,strong) NSString *backupStatusViewModelID;
@property(nonatomic) NSUInteger rowBuilds;
- (id)getBackupStatusModelData;
- (id)createBackupViewModel:(id)item mediaItem:(id)media serverPhoto:(id)photo localAsset:(id)asset storeResult:(id)store;
- (id)createStackViewModelsForExtendedPhoto:(id)photo preferredMediaItem:(id)item;
- (void)updateBackupStatusUI;
@end
@implementation PHSOneUpInfoPanelDetailsViewController
- (id)getBackupStatusModelData{
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
  default:return NativePolicy(photo)==1?OriginalText:SaverText;
 }
}
- (id)createBackupViewModel:(id)item mediaItem:(id)media serverPhoto:(id)photo localAsset:(id)asset storeResult:(id)store{
 self.rowBuilds++;
 id status=[self getBackupStatusModelData]; // The stack path reuses the quota text and link.
 PHSOneUpInfoPanelDetailsStackViewModel *row=[[PHSOneUpInfoPanelDetailsStackViewModel alloc]initWithTitle:[status backupStatus] subtitle:[self qualityTextForPhoto:photo]];
 self.backupStatusViewModelID=row.id;[self.detailsStackViewModels addObject:row];return row;
}
- (id)createStackViewModelsForExtendedPhoto:(id)photo preferredMediaItem:(id)item{
 self.detailsStackViewModels=[NSMutableArray array];
 return @[[self createBackupViewModel:item mediaItem:nil serverPhoto:self.extendedPhoto.serverPhoto localAsset:nil storeResult:nil]];
}
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
 details.extendedPhoto=[PHSExtendedPhoto new];PhotoWithStoragePolicy *photo=[PhotoWithStoragePolicy new];details.extendedPhoto.serverPhoto=photo;photo.storagePolicy=1;
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
 // The factory reads PHSServerPhoto.storagePolicy: native Standard wording, no substitution.
 details.labelSource=LabelFromServerPhoto;NSUInteger policy2=Count(@"serverStoragePolicy2"),policy1=Count(@"serverStoragePolicy1"),corrected=Count(@"stackRowCorrected");
 BuildRow();
 assert([row.attributes[0]isEqual:OriginalText]&&[row.title isEqual:details.original.backupStatus]);
 assert(Count(@"displayPolicyOverrides")>=1&&Count(@"stackBackupRows")==1&&Count(@"stackRowCorrected")==corrected);
 assert([GSPhotosIntegrationSnapshot()[@"stackRowClasses"]containsObject:@"PHSOneUpInfoPanelDetailsStackViewModel"]);
 assert(photo.storagePolicy==2); // Outside the factory the stored value is untouched.
 // The nested getBackupStatusModelData diagnostic saw the native value, not the display value.
 assert(Count(@"serverStoragePolicy2")==policy2+1&&Count(@"serverStoragePolicy1")==policy1);
 // The factory reads the client enum through PHSExtendedPhoto.serverStoragePolicy.
 details.labelSource=LabelFromExtendedPhoto;BuildRow();
 assert([row.attributes[0]isEqual:OriginalText]&&Count(@"displayServerPolicyReads")>=1&&Count(@"stackRowCorrected")==corrected);
 assert(details.extendedPhoto.serverStoragePolicy==1); // Native outside the scope.
#endif
 // The factory copies the native subtitle wording: the row text is replaced, the quota title kept.
 details.labelSource=LabelFromNativeSubtitle;NSUInteger corrections=Count(@"stackRowCorrected");BuildRow();
 assert([row.attributes[0]isEqual:GSL(@"Original quality (original data available)")]&&[row.title isEqual:details.original.backupStatus]);
 assert(Count(@"stackRowCorrected")==corrections+1);
 // A later native status update on the tracked row is corrected again.
 [details updateBackupStatusUI];
 assert([row.attributes[0]isEqual:GSL(@"Original quality (original data available)")]&&Count(@"stackBackupUpdates")>=1&&Count(@"stackRowCorrected")==corrections+2);
 // No / partial / not backed up leave the native row and never override the policy.
 NSUInteger overrides=Count(@"displayPolicyOverrides");corrections=Count(@"stackRowCorrected");
 for(LabelSource source=LabelFromServerPhoto;source<=LabelFromNativeSubtitle;source++){
  details.labelSource=source;
  photo.hasOriginalBytes=2;BuildRow();assert([row.attributes[0]isEqual:SaverText]);
  photo.hasOriginalBytes=1;photo.isPartialBackup=YES;BuildRow();assert([row.attributes[0]isEqual:SaverText]);
  photo.isPartialBackup=NO;details.isBackedUp=NO;BuildRow();assert([row.attributes[0]isEqual:SaverText]);
  [details updateBackupStatusUI];assert([row.attributes[0]isEqual:SaverText]);
  details.isBackedUp=YES;
 }
 assert(Count(@"displayPolicyOverrides")==overrides&&Count(@"stackRowCorrected")==corrections);
 assert([details.original.backupStatusSubtitle isEqual:SaverText]);
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
 NSLog(@"PASS server-confirmed original label for every storage policy, details-stack row correction on policy/enum/text sources with native reads outside the display scope, Unknown/No/Maybe/partial safeguards, quota preservation, account-bound coalesced native delta sync, native-fetch-preserved and release-surviving refresh");
 return 0;
}}
