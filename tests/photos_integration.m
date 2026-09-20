#ifdef GS_TEST_LEGACY
#define PHSOneUpInfoPanelBackupStatusData GSFixtureLegacyContentModel
#define getBackupStatusModelData modelForBackedupStatus
#endif
#import "host_profile.h"
#import "../Shared/GSLocalization.h"
#import "../UI/GSPhotosIntegration.h"
#import <objc/runtime.h>
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
@interface PHSServerPhoto : NSObject
@property(nonatomic) unsigned char hasOriginalBytes;
@property(nonatomic) unsigned char storagePolicy;
@property(nonatomic) _Bool isPartialBackup;
@end
@implementation PHSServerPhoto @end
@interface ExtendedPhoto : NSObject
@property(nonatomic,strong) PHSServerPhoto *serverPhoto;
@end
@implementation ExtendedPhoto @end
@interface PHSOneUpInfoPanelBackupStatusData : NSObject
@property(nonatomic,strong) NSString *backupStatus;
@property(nonatomic,strong) NSString *backupStatusSubtitle;
@property(nonatomic,strong) NSString *learnMoreLink;
- (instancetype)initWithBackupStatus:(NSString *)status backupStatusSubtitle:(NSString *)subtitle learnMoreLink:(NSString *)link;
@end
@implementation PHSOneUpInfoPanelBackupStatusData
- (instancetype)initWithBackupStatus:(NSString *)status backupStatusSubtitle:(NSString *)subtitle learnMoreLink:(NSString *)link{if((self=[super init])){self.backupStatus=status;self.backupStatusSubtitle=subtitle;self.learnMoreLink=link;}return self;}
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
@interface PHSOneUpInfoPanelDetailsViewController : GSDetailsSuperclass
@property(nonatomic) _Bool isBackedUp;
@property(nonatomic,strong) ExtendedPhoto *extendedPhoto;
@property(nonatomic,strong) PHSOneUpInfoPanelBackupStatusData *original;
- (id)getBackupStatusModelData;
@end
@implementation PHSOneUpInfoPanelDetailsViewController
- (id)getBackupStatusModelData{
#ifdef GS_TEST_LEGACY
 return [self contentViewModelWithTitle:self.original.backupStatus subtitle:self.original.backupStatusSubtitle subtitleContainsHTML:YES image:@"native-icon"];
#else
 return self.original;
#endif
}
@end
static void Drain(BOOL(^finished)(void)){
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:4];
 while(!finished()&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
 assert(finished());
}
int main(void){@autoreleasepool{
 method_setImplementation(class_getClassMethod(NSBundle.class,@selector(mainBundle)),(IMP)Bundle);
 GSInstallPhotosIntegration();assert([GSPhotosIntegrationSnapshot()[@"qualityAvailable"]boolValue]&&[GSPhotosIntegrationSnapshot()[@"syncAvailable"]boolValue]);
 PHSOneUpInfoPanelDetailsViewController *details=[PHSOneUpInfoPanelDetailsViewController new];details.isBackedUp=YES;
 details.original=[[PHSOneUpInfoPanelBackupStatusData alloc]initWithBackupStatus:@"保存容量を使用しません" backupStatusSubtitle:@"保存容量の節約" learnMoreLink:@"native-link"];
 details.extendedPhoto=[ExtendedPhoto new];PHSServerPhoto *photo=[PHSServerPhoto new];details.extendedPhoto.serverPhoto=photo;photo.storagePolicy=1;
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
 assert([details.original.backupStatusSubtitle isEqual:@"保存容量の節約"]); // No mutation of native state.
#ifdef GS_TEST_LEGACY
 assert([details contentViewModelWithTitle:details.original.backupStatus subtitle:details.original.backupStatusSubtitle subtitleContainsHTML:YES image:@"native-icon"]==details.original);
 assert(![details respondsToSelector:NSSelectorFromString(@"getBackupStatusModelData")]);
 assert(!NSClassFromString(@"PHSOneUpInfoPanelBackupStatusData"));
#endif
 PHSUserItemsSynchronizer *other=[PHSUserItemsSynchronizer new];other.accountID=@"other";[other fetchData];
 GSRefreshNativeLibrary(); // Queue before the viewing account's sync object is observed.
 PHSUserItemsSynchronizer *current=[PHSUserItemsSynchronizer new];current.accountID=viewingAccount;[current fetchDataSoft];
 GSRefreshNativeLibrary();GSRefreshNativeLibrary();
 Drain(^BOOL{return current.fetches==2;});assert(other.fetches==1); // Coalesced and account-bound.
 viewingAccount=@"other";GSRefreshNativeLibrary();Drain(^BOOL{return other.fetches==2;});assert(current.fetches==2);
 NSLog(@"PASS server-confirmed original label for every storage policy, Unknown/No/Maybe/partial safeguards, quota preservation, account-bound coalesced native delta sync");
 return 0;
}}
