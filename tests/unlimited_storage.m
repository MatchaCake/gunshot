#import "host_profile.h"
#import "../UI/GSUnlimitedStorage.h"
#import "unlimited_storage_fixture.h"
#import <objc/runtime.h>
#include <assert.h>

static NSString *Version=@"unsupported",*Executable=@"OtherApp";
static BOOL ResourcesReady,ThrowDuringEncode;
static NSUInteger Actions,CellCalls;
@interface GSStorageFixtureBundle : NSObject @end
@implementation GSStorageFixtureBundle
- (id)objectForInfoDictionaryKey:(NSString *)key{return [key isEqual:@"CFBundleExecutable"]?Executable:Version;}
@end
static id MainBundle(id object,SEL selector){static id bundle;if(!bundle)bundle=[GSStorageFixtureBundle new];return bundle;}
@interface GSNativeStringsBundle : NSBundle @end
@implementation GSNativeStringsBundle
- (NSString *)localizedStringForKey:(NSString *)key value:(NSString *)value table:(NSString *)table{
 assert([key isEqual:@"OneGoogleStorageCardUnlimitedTitle"]&&[table isEqual:@"OneGoogle"]);
 return ResourcesReady?@"Unlimited storage":value;
}
@end
@interface OGLBundle : NSObject
+ (id)oneGoogleResourceBundle;
@end
@implementation OGLBundle
+ (id)oneGoogleResourceBundle{return [GSNativeStringsBundle new];}
@end
// A future numeric string ID is deliberately unusable: never call this API.
@interface OGLStringResources : NSObject @end
@implementation OGLStringResources
+ (id)sharedInstance{assert(!"numeric string-table API must not be used");return nil;}
- (id)stringForID:(int)identifier{assert(!"numeric string-table API must not be used");return nil;}
@end
@implementation GSStorageFixtureData
+ (BOOL)supportsSecureCoding{return YES;}
- (void)encodeWithCoder:(NSCoder *)coder{
 if(ThrowDuringEncode)@throw [NSException exceptionWithName:@"FixtureEncode" reason:nil userInfo:nil];
 // Deliberately use getters, matching native encodeWithCoder: at 0x17a3fd4.
 [coder encodeInteger:self.storageState forKey:@"storageState"];
 [coder encodeObject:self.title forKey:@"title"];
 [coder encodeDouble:self.usedStorage forKey:@"usedStorage"];
 [coder encodeDouble:self.totalStorage forKey:@"totalStorage"];
}
- (instancetype)initWithCoder:(NSCoder *)coder{
 if((self=[super init])){_storageState=[coder decodeIntegerForKey:@"storageState"];_title=[coder decodeObjectOfClass:NSString.class forKey:@"title"];_usedStorage=[coder decodeDoubleForKey:@"usedStorage"];_totalStorage=[coder decodeDoubleForKey:@"totalStorage"];}return self;
}
@end
@interface GSStorageFixtureItem : NSObject
@property(nonatomic) NSInteger storageState;
@end
@implementation GSStorageFixtureItem @end
@interface GSStorageFixtureCell : NSObject
+ (id)titleTextWithStorageItem:(id)item;
- (void)updateWithItem:(id)item;
@end
@implementation GSStorageFixtureCell
+ (id)titleTextWithStorageItem:(id)item{return @"Native regular title";}
- (void)updateWithItem:(id)item{CellCalls++;}
@end
@interface OGLBentoAccountMenuFactory : NSObject
- (id)makeBentoAccountMenuViewController;
@end
@implementation OGLBentoAccountMenuFactory
- (id)makeBentoAccountMenuViewController{return [NSObject new];}
@end
// Native card source that hides its storage card: probes must pass values through.
@interface PHSMyAccountMenuDataSource : NSObject
- (BOOL)shouldShowStorageCard;
- (id)storageCardData;
- (id)accountMenuCardData;
- (id)quota;
@end
@implementation PHSMyAccountMenuDataSource
- (BOOL)shouldShowStorageCard{return NO;}
- (id)storageCardData{return nil;}
- (id)accountMenuCardData{return @[[NSObject new]];}
- (id)quota{return @"quota";}
@end
@interface GSStorageObserver : NSObject @end
@implementation GSStorageObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context{}
@end
static Class RegisterClass(Class parent,const char *name){Class cls=objc_allocateClassPair(parent,name,0);objc_registerClassPair(cls);return cls;}
static GSStorageFixtureData *Card(Class cls){
 GSStorageFixtureData *data=[cls new];data.storageState=0;data.title=@"43% of 15 GB used";
 data.subtitle=@"Native subtitle";data.usedStorage=6.55;data.totalStorage=15;
 data.cardActionCallback=^{Actions++;};return data;
}
int main(int argc,const char **argv){@autoreleasepool{
 BOOL incompatible=argc>1&&!strcmp(argv[1],"incompatible-abi"),bentoOnly=argc>1&&!strcmp(argv[1],"bento-only");
 NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;[defaults removeObjectForKey:@"GSShowUnlimitedStorage"];
 assert(GSUnlimitedStorageEnabled());GSSetUnlimitedStorage(NO);assert(!GSUnlimitedStorageEnabled());GSSetUnlimitedStorage(YES);
 method_setImplementation(class_getClassMethod(NSBundle.class,@selector(mainBundle)),(IMP)MainBundle);
 Class data=objc_allocateClassPair(GSStorageFixtureData.class,"OGLAccountMenuStorageCardData",0);
 if(incompatible)class_addMethod(data,@selector(storageState),class_getMethodImplementation(GSStorageFixtureData.class,@selector(storageState)),"d16@0:8");
 objc_registerClassPair(data);
 Class itemClass=nil,cellClass=nil;
 if(!bentoOnly){itemClass=RegisterClass(GSStorageFixtureItem.class,"OGLAccountSelectorStorageCardItem");cellClass=RegisterClass(GSStorageFixtureCell.class,"OGLAccountSelectorStorageCardCell");}
 GSInstallUnlimitedStorage();assert(!GSUnlimitedStorageAvailable());
 Version=GSFixtureVersion;Executable=@"OtherApp";GSInstallUnlimitedStorage();assert(!GSUnlimitedStorageAvailable());Executable=@"GooglePhotos";
 GSInstallUnlimitedStorage();
 if(incompatible){assert(!GSUnlimitedStorageAvailable());assert([GSUnlimitedStorageSnapshot()[@"status"]isEqual:@"incompatible-model-abi"]);return 0;}
 assert(GSUnlimitedStorageAvailable());GSInstallUnlimitedStorage();
 assert([GSUnlimitedStorageSnapshot()[@"legacyObserver"]boolValue]==!bentoOnly);
 // No mapper or source class exists in either fixture. Exercise the Swift reader.
 GSStorageFixtureData *original=Card(data);const void *pointer=(__bridge const void *)original;
 assert(GSReadStorageFromSwift(pointer)==0&&!GSReadUnlimitedTitleFromSwift(pointer));
 ResourcesReady=YES;
 assert(GSReadStorageFromSwift(pointer)==2&&GSReadUnlimitedTitleFromSwift(pointer));
 // Never mutate the backing fields, callbacks, quota counters or superclass.
 NSInteger (*storedState)(id,SEL)=(void *)class_getMethodImplementation(GSStorageFixtureData.class,@selector(storageState));
 id (*storedTitle)(id,SEL)=(void *)class_getMethodImplementation(GSStorageFixtureData.class,@selector(title));
 assert(storedState(original,@selector(storageState))==0&&[storedTitle(original,@selector(title))isEqual:@"43% of 15 GB used"]);
 assert(original.usedStorage==6.55&&original.totalStorage==15&&[original.subtitle isEqual:@"Native subtitle"]);
 original.cardActionCallback();assert(Actions==1);assert([Card(GSStorageFixtureData.class) storageState]==0);
 GSStorageObserver *observer=[GSStorageObserver new];[original addObserver:observer forKeyPath:@"storageState" options:0 context:NULL];
 assert(object_getClass(original)!=data);assert(GSReadStorageFromSwift(pointer)==2&&GSReadUnlimitedTitleFromSwift(pointer));
 [original removeObserver:observer forKeyPath:@"storageState"];
 // Even with display enabled, archive/unarchive must retain the actual model.
 NSError *error=nil;NSData *archive=[NSKeyedArchiver archivedDataWithRootObject:original requiringSecureCoding:YES error:&error];assert(archive&&!error);
 GSStorageFixtureData *restored=[NSKeyedUnarchiver unarchivedObjectOfClass:data fromData:archive error:&error];assert(restored&&!error);
 assert(storedState(restored,@selector(storageState))==0&&[storedTitle(restored,@selector(title))isEqual:@"43% of 15 GB used"]);
 assert(restored.usedStorage==6.55&&restored.totalStorage==15);
 ThrowDuringEncode=YES;BOOL threw=NO;
 @try{[original encodeWithCoder:nil];}@catch(NSException *e){threw=YES;}ThrowDuringEncode=NO;assert(threw);
 assert(GSReadStorageFromSwift(pointer)==2); // Exception did not leak suppression.
 GSSetUnlimitedStorage(NO);assert(GSReadStorageFromSwift(pointer)==0&&!GSReadUnlimitedTitleFromSwift(pointer));
 // A native update while enabled/disabled remains visible after disabling again.
 original.storageState=1;original.title=@"Updated native title";
 GSSetUnlimitedStorage(YES);assert(GSReadStorageFromSwift(pointer)==2&&GSReadUnlimitedTitleFromSwift(pointer));
 GSSetUnlimitedStorage(NO);assert(GSReadStorageFromSwift(pointer)==1&&[original.title isEqual:@"Updated native title"]);GSSetUnlimitedStorage(YES);
 if(!bentoOnly){
  GSStorageFixtureItem *item=[itemClass new];item.storageState=original.storageState;
  GSStorageFixtureCell *cell=[cellClass new];[cell updateWithItem:item];assert(CellCalls==1);
  assert([[cellClass titleTextWithStorageItem:item]isEqual:@"Unlimited storage"]);
  GSSetUnlimitedStorage(NO);assert([[cellClass titleTextWithStorageItem:item]isEqual:@"Native regular title"]);GSSetUnlimitedStorage(YES);
 }
 assert([[OGLBentoAccountMenuFactory new]makeBentoAccountMenuViewController]);
 PHSMyAccountMenuDataSource *source=[PHSMyAccountMenuDataSource new];
 assert(![source shouldShowStorageCard]&&![source storageCardData]&&[[source accountMenuCardData]count]==1);
 NSDictionary *snapshot=GSUnlimitedStorageSnapshot(),*cardSource=snapshot[@"cardSource"];
 assert([cardSource[@"shouldShowCalls"]unsignedLongValue]==1&&[cardSource[@"shouldShowYes"]unsignedLongValue]==0);
 assert([cardSource[@"storageCardCalls"]unsignedLongValue]==1&&[cardSource[@"storageCardNonNil"]unsignedLongValue]==0&&[cardSource[@"quotaPresent"]unsignedLongValue]==1);
 assert([cardSource[@"photosCardReads"]unsignedLongValue]==1&&[cardSource[@"menuCards"]isEqual:@[@"photos:NSObject"]]&&[cardSource[@"bentoEnabled"]longValue]==-1);
 assert([snapshot[@"implementation"]isEqual:@"native-display-model-v4"]&&[snapshot[@"modelStateReads"]unsignedLongValue]>0&&[snapshot[@"modelTitleReads"]unsignedLongValue]>0);
 assert([snapshot[@"bentoControllers"]unsignedLongValue]==1&&[snapshot[@"archiveCalls"]unsignedLongValue]>=2);
 assert([snapshot[@"cardClasses"]containsObject:@"NSKVONotifying_OGLAccountMenuStorageCardData"]);
 assert([snapshot[@"cellUpdates"]unsignedLongValue]==(bentoOnly?0:1));
 NSSet *keys=[NSSet setWithArray:@[@"implementation",@"available",@"enabled",@"status",@"legacyObserver",@"bentoObserver",@"stringsReady",@"modelStateReads",@"modelTitleReads",@"displayOverrides",@"archiveCalls",@"bentoControllers",@"cellUpdates",@"titleCalls",@"nativeStorageState",@"displayStorageState",@"renderedStorageState",@"cardClasses",@"controllerClasses",@"cardSource"]];assert([[NSSet setWithArray:snapshot.allKeys]isEqual:keys]);
 [defaults removeObjectForKey:@"GSShowUnlimitedStorage"];
 NSLog(@"PASS Swift model reads with %@; KVO, native backing fields, coder restoration, late resources, callbacks, on/off",bentoOnly?@"no legacy renderer":@"legacy renderer");
}}
