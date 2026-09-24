#import "../Shared/GSPhotosCompatibility.h"
#import "GSUnlimitedStorage.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <stdatomic.h>

static NSString *const GSStoragePreference=@"GSShowUnlimitedStorage";
static const NSInteger GSNativeUnlimitedState=2;
static BOOL GSStorageInstalled, GSLegacyInstalled, GSBentoObserved;
static NSString *GSStorageStatus=@"not-installed";
static NSInteger (*GSOriginalModelState)(id,SEL);
static id (*GSOriginalModelTitle)(id,SEL), (*GSOriginalStorageTitle)(id,SEL,id), (*GSOriginalBentoController)(id,SEL);
static void (*GSOriginalModelEncode)(id,SEL,id), (*GSOriginalCellUpdate)(id,SEL,id);
static atomic_ulong GSModelStateReads, GSModelTitleReads, GSDisplayOverrides, GSArchiveCalls, GSBentoControllers, GSCellUpdates, GSTitleCalls;
static atomic_long GSNativeState=-1, GSDisplayState=-1, GSRenderedState=-1;
static atomic_bool GSStringsReady;
// Nested NSCoder calls must read native values; restored in @finally.
static _Thread_local NSUInteger GSStorageOriginalReads;
static NSObject *GSStorageLock;
static NSMutableOrderedSet *GSObservedCardClasses, *GSObservedControllerClasses, *GSObservedMenuCards;
// Passive card-source probes: which source (if any) supplies the storage card.
static BOOL (*GSOriginalShouldShow)(id,SEL), (*GSOriginalBentoEnabled)(id,SEL);
static id (*GSOriginalStorageCardData)(id,SEL), (*GSOriginalPhotosCards)(id,SEL), (*GSOriginalAggregatorCards)(id,SEL);
static atomic_ulong GSShouldShowCalls, GSShouldShowYes, GSStorageCardCalls, GSStorageCardNonNil, GSQuotaPresent, GSPhotosCardReads, GSAggregatorCardReads;
static atomic_long GSBentoEnabled=-1;
// Passive Google One storage-service probes: the Bento aggregator drops the
// Photos storage card, so the visible card depends on this native service.
static void (*GSOriginalFlowStatus)(id,SEL,int,id), (*GSOriginalUsageRatio)(id,SEL,id,double,BOOL), (*GSOriginalUpdateRatio)(id,SEL,double), (*GSOriginalAggregatorRefresh)(id,SEL);
static id (*GSOriginalServiceInit)(id,SEL);
static atomic_ulong GSServiceInits, GSFlowStatusCalls, GSFlowErrors, GSUsageRatioCalls, GSUpdateRatioCalls, GSAggregatorRefreshes;
static atomic_long GSLastFlowStatus=-1;
static NSString *GSLastFlowError;

BOOL GSUnlimitedStorageEnabled(void){
 id value=[NSUserDefaults.standardUserDefaults objectForKey:GSStoragePreference];
 return value==nil?YES:[value boolValue];
}
void GSSetUnlimitedStorage(BOOL enabled){[NSUserDefaults.standardUserDefaults setBool:enabled forKey:GSStoragePreference];}
BOOL GSUnlimitedStorageAvailable(void){return GSStorageInstalled;}
NSDictionary *GSUnlimitedStorageSnapshot(void){
 @synchronized(GSStorageLock){return @{@"implementation":@"native-display-model-v4",
  @"available":@(GSStorageInstalled),@"enabled":@(GSUnlimitedStorageEnabled()),@"status":GSStorageStatus,
  @"legacyObserver":@(GSLegacyInstalled),@"bentoObserver":@(GSBentoObserved),
  @"stringsReady":@(atomic_load(&GSStringsReady)),@"modelStateReads":@(atomic_load(&GSModelStateReads)),
  @"modelTitleReads":@(atomic_load(&GSModelTitleReads)),@"displayOverrides":@(atomic_load(&GSDisplayOverrides)),
  @"archiveCalls":@(atomic_load(&GSArchiveCalls)),@"bentoControllers":@(atomic_load(&GSBentoControllers)),
  @"cellUpdates":@(atomic_load(&GSCellUpdates)),@"titleCalls":@(atomic_load(&GSTitleCalls)),
  @"nativeStorageState":@(atomic_load(&GSNativeState)),@"displayStorageState":@(atomic_load(&GSDisplayState)),
  @"renderedStorageState":@(atomic_load(&GSRenderedState)),
  @"cardClasses":GSObservedCardClasses.array?:@[],@"controllerClasses":GSObservedControllerClasses.array?:@[],
  @"cardSource":@{@"shouldShowCalls":@(atomic_load(&GSShouldShowCalls)),@"shouldShowYes":@(atomic_load(&GSShouldShowYes)),
   @"storageCardCalls":@(atomic_load(&GSStorageCardCalls)),@"storageCardNonNil":@(atomic_load(&GSStorageCardNonNil)),
   @"quotaPresent":@(atomic_load(&GSQuotaPresent)),@"photosCardReads":@(atomic_load(&GSPhotosCardReads)),
   @"aggregatorCardReads":@(atomic_load(&GSAggregatorCardReads)),@"bentoEnabled":@(atomic_load(&GSBentoEnabled)),
   @"menuCards":GSObservedMenuCards.array?:@[],@"aggregatorRefreshes":@(atomic_load(&GSAggregatorRefreshes))},
  @"googleOne":@{@"serviceInits":@(atomic_load(&GSServiceInits)),@"flowStatusCalls":@(atomic_load(&GSFlowStatusCalls)),
   @"lastFlowStatus":@(atomic_load(&GSLastFlowStatus)),@"flowErrors":@(atomic_load(&GSFlowErrors)),@"lastFlowError":GSLastFlowError?:NSNull.null,
   @"usageRatioCalls":@(atomic_load(&GSUsageRatioCalls)),@"updateRatioCalls":@(atomic_load(&GSUpdateRatioCalls))}};}
}
static void GSStorageObserve(id object,NSMutableOrderedSet *classes){
 if(!object)return;NSString *name=NSStringFromClass(object_getClass(object));
 @synchronized(GSStorageLock){if(classes.count<16)[classes addObject:name];}
}
static BOOL GSStorageMethod(Class cls,NSString *name,const char *encoding){
 Method method=class_getInstanceMethod(cls,NSSelectorFromString(name));
 return method&&!strcmp(method_getTypeEncoding(method),encoding);
}
static BOOL GSStorageItem(id item){
 return [item isKindOfClass:NSClassFromString(@"OGLAccountSelectorStorageCardItem")]&&
  GSStorageMethod(object_getClass(item),@"storageState","q16@0:8");
}
static NSString *GSUnlimitedTitle(void){
 // Use the stable native key, not a numeric table index that can move in
 // later releases. OGLBundle is Google's own resolver in both audited IPAs.
 id bundle=((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"OGLBundle"),NSSelectorFromString(@"oneGoogleResourceBundle"));
 NSString *key=@"OneGoogleStorageCardUnlimitedTitle";
 id title=[bundle isKindOfClass:NSBundle.class]?[bundle localizedStringForKey:key value:key table:@"OneGoogle"]:nil;
 BOOL valid=[title isKindOfClass:NSString.class]&&[title length]&&![title isEqual:@"OneGoogleStorageCardUnlimitedTitle"];
 atomic_store(&GSStringsReady,valid);return valid?title:nil;
}
static NSInteger GSStorageModelState(id object,SEL selector){
 NSInteger original=GSOriginalModelState(object,selector);
 if(GSStorageOriginalReads)return original;
 atomic_fetch_add(&GSModelStateReads,1);GSStorageObserve(object,GSObservedCardClasses);
 atomic_store(&GSNativeState,original);
 NSInteger display=original;
 if(GSUnlimitedStorageEnabled()&&GSUnlimitedTitle()){display=GSNativeUnlimitedState;atomic_fetch_add(&GSDisplayOverrides,1);}
 atomic_store(&GSDisplayState,display);return display;
}
static id GSStorageModelTitle(id object,SEL selector){
 if(GSStorageOriginalReads)return GSOriginalModelTitle(object,selector);
 atomic_fetch_add(&GSModelTitleReads,1);GSStorageObserve(object,GSObservedCardClasses);
 if(GSUnlimitedStorageEnabled()){NSString *title=GSUnlimitedTitle();if(title)return title;}
 return GSOriginalModelTitle(object,selector);
}
static void GSStorageModelEncode(id object,SEL selector,id coder){
 atomic_fetch_add(&GSArchiveCalls,1);GSStorageOriginalReads++;
 @try{GSOriginalModelEncode(object,selector,coder);}@finally{GSStorageOriginalReads--;}
}
static id GSStorageBentoController(id object,SEL selector){
 id controller=GSOriginalBentoController(object,selector);
 atomic_fetch_add(&GSBentoControllers,1);GSStorageObserve(controller,GSObservedControllerClasses);return controller;
}
static void GSStorageObserveCards(id cards,NSString *source){
 if(![cards isKindOfClass:NSArray.class])return;
 @synchronized(GSStorageLock){
  if(![cards count])[GSObservedMenuCards addObject:[source stringByAppendingString:@":empty"]];
  for(id card in cards)if(GSObservedMenuCards.count<24)[GSObservedMenuCards addObject:[NSString stringWithFormat:@"%@:%@",source,NSStringFromClass(object_getClass(card))]];
 }
}
static BOOL GSStorageShouldShow(id object,SEL selector){
 BOOL show=GSOriginalShouldShow(object,selector);
 atomic_fetch_add(&GSShouldShowCalls,1);if(show)atomic_fetch_add(&GSShouldShowYes,1);return show;
}
static id GSStorageCardData(id object,SEL selector){
 id card=GSOriginalStorageCardData(object,selector);
 atomic_fetch_add(&GSStorageCardCalls,1);if(card)atomic_fetch_add(&GSStorageCardNonNil,1);
 if(GSStorageMethod(object_getClass(object),@"quota","@16@0:8")&&((id(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(@"quota")))atomic_fetch_add(&GSQuotaPresent,1);
 return card;
}
static id GSStoragePhotosCards(id object,SEL selector){
 id cards=GSOriginalPhotosCards(object,selector);
 atomic_fetch_add(&GSPhotosCardReads,1);GSStorageObserveCards(cards,@"photos");return cards;
}
static id GSStorageAggregatorCards(id object,SEL selector){
 id cards=GSOriginalAggregatorCards(object,selector);
 atomic_fetch_add(&GSAggregatorCardReads,1);GSStorageObserveCards(cards,@"aggregator");return cards;
}
static BOOL GSStorageBentoEnabled(id object,SEL selector){
 BOOL enabled=GSOriginalBentoEnabled(object,selector);atomic_store(&GSBentoEnabled,enabled);return enabled;
}
static id GSStorageServiceInit(id object,SEL selector){
 atomic_fetch_add(&GSServiceInits,1);return GSOriginalServiceInit(object,selector);
}
static void GSStorageFlowStatus(id object,SEL selector,int status,id error){
 atomic_fetch_add(&GSFlowStatusCalls,1);atomic_store(&GSLastFlowStatus,status);
 // Domain and code only; never the description, user info or URLs.
 if([error isKindOfClass:NSError.class]){
  atomic_fetch_add(&GSFlowErrors,1);
  @synchronized(GSStorageLock){GSLastFlowError=[NSString stringWithFormat:@"%@:%ld",[(NSError *)error domain],(long)[(NSError *)error code]];}
 }
 GSOriginalFlowStatus(object,selector,status,error);
}
static void GSStorageUsageRatio(id object,SEL selector,id service,double ratio,BOOL purchase){
 atomic_fetch_add(&GSUsageRatioCalls,1);GSOriginalUsageRatio(object,selector,service,ratio,purchase);
}
static void GSStorageUpdateRatio(id object,SEL selector,double ratio){
 atomic_fetch_add(&GSUpdateRatioCalls,1);GSOriginalUpdateRatio(object,selector,ratio);
}
static void GSStorageAggregatorRefresh(id object,SEL selector){
 atomic_fetch_add(&GSAggregatorRefreshes,1);GSOriginalAggregatorRefresh(object,selector);
}
static void GSStorageCellUpdate(id object,SEL selector,id item){
 atomic_fetch_add(&GSCellUpdates,1);
 if(GSStorageItem(item))atomic_store(&GSRenderedState,((NSInteger(*)(id,SEL))objc_msgSend)(item,NSSelectorFromString(@"storageState")));
 GSOriginalCellUpdate(object,selector,item);
}
static id GSStorageTitle(id cls,SEL selector,id item){
 atomic_fetch_add(&GSTitleCalls,1);
 if(GSUnlimitedStorageEnabled()&&GSStorageItem(item)&&
    ((NSInteger(*)(id,SEL))objc_msgSend)(item,NSSelectorFromString(@"storageState"))==GSNativeUnlimitedState){
  NSString *title=GSUnlimitedTitle();if(title)return title;
 }
 return GSOriginalStorageTitle(cls,selector,item);
}
static IMP GSStorageReplace(Class cls,SEL selector,IMP replacement){
 Method method=class_getInstanceMethod(cls,selector);IMP original=method_getImplementation(method);
 if(!class_addMethod(cls,selector,replacement,method_getTypeEncoding(method)))method_setImplementation(method,replacement);
 return original;
}
void GSInstallUnlimitedStorage(void){
 if(GSStorageInstalled)return;
 if(![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleExecutable"]isEqual:@"GooglePhotos"]||
    !GSPhotosHostSupported()){GSStorageStatus=@"unsupported-host";return;}
 Class data=NSClassFromString(@"OGLAccountMenuStorageCardData"),bundle=NSClassFromString(@"OGLBundle");
 BOOL modelTitle=GSStorageMethod(data,@"title","@16@0:8");
 GSStorageStatus=@"incompatible-model-abi";
 if(!GSStorageMethod(data,@"storageState","q16@0:8")||(class_getInstanceMethod(data,NSSelectorFromString(@"title"))&&!modelTitle)||!GSStorageMethod(data,@"encodeWithCoder:","v24@0:8@16"))return;
 GSStorageStatus=@"incompatible-resources-abi";
 if(!GSStorageMethod(object_getClass(bundle),@"oneGoogleResourceBundle","@16@0:8"))return;
 // A model without a title getter requires the native UIKit title path.
 if(!modelTitle&&(!GSStorageMethod(NSClassFromString(@"OGLAccountSelectorStorageCardItem"),@"storageState","q16@0:8")||
  !GSStorageMethod(object_getClass(NSClassFromString(@"OGLAccountSelectorStorageCardCell")),@"titleTextWithStorageItem:","@24@0:8@16")||
  !GSStorageMethod(NSClassFromString(@"OGLAccountSelectorStorageCardCell"),@"updateWithItem:","v24@0:8@16"))){GSStorageStatus=@"incompatible-legacy-cell-abi";return;}
 GSStorageLock=[NSObject new];GSObservedCardClasses=[NSMutableOrderedSet orderedSet];GSObservedControllerClasses=[NSMutableOrderedSet orderedSet];GSObservedMenuCards=[NSMutableOrderedSet orderedSet];
 // UIKit and Bento share these display getters. Preserve the stored model,
 // account quota and callback identities.
 GSOriginalModelState=(void *)GSStorageReplace(data,NSSelectorFromString(@"storageState"),(IMP)GSStorageModelState);
 if(modelTitle)GSOriginalModelTitle=(void *)GSStorageReplace(data,NSSelectorFromString(@"title"),(IMP)GSStorageModelTitle);
 GSOriginalModelEncode=(void *)GSStorageReplace(data,NSSelectorFromString(@"encodeWithCoder:"),(IMP)GSStorageModelEncode);
 // Optional: Bento does not use the legacy UIKit converter or cell.
 Class item=NSClassFromString(@"OGLAccountSelectorStorageCardItem"),cell=NSClassFromString(@"OGLAccountSelectorStorageCardCell");
 if(GSStorageMethod(item,@"storageState","q16@0:8")&&GSStorageMethod(object_getClass(cell),@"titleTextWithStorageItem:","@24@0:8@16")&&GSStorageMethod(cell,@"updateWithItem:","v24@0:8@16")){
  GSOriginalStorageTitle=(void *)GSStorageReplace(object_getClass(cell),NSSelectorFromString(@"titleTextWithStorageItem:"),(IMP)GSStorageTitle);
  GSOriginalCellUpdate=(void *)GSStorageReplace(cell,NSSelectorFromString(@"updateWithItem:"),(IMP)GSStorageCellUpdate);GSLegacyInstalled=YES;
 }
 Class bento=NSClassFromString(@"OGLBentoAccountMenuFactory");
 if(GSStorageMethod(bento,@"makeBentoAccountMenuViewController","@16@0:8")){
  GSOriginalBentoController=(void *)GSStorageReplace(bento,NSSelectorFromString(@"makeBentoAccountMenuViewController"),(IMP)GSStorageBentoController);GSBentoObserved=YES;
 }
 // Optional passive probes; each returns the native value unchanged.
 Class photos=NSClassFromString(@"PHSMyAccountMenuDataSource");
 if(GSStorageMethod(photos,@"shouldShowStorageCard","B16@0:8"))GSOriginalShouldShow=(void *)GSStorageReplace(photos,NSSelectorFromString(@"shouldShowStorageCard"),(IMP)GSStorageShouldShow);
 if(GSStorageMethod(photos,@"storageCardData","@16@0:8"))GSOriginalStorageCardData=(void *)GSStorageReplace(photos,NSSelectorFromString(@"storageCardData"),(IMP)GSStorageCardData);
 if(GSStorageMethod(photos,@"accountMenuCardData","@16@0:8"))GSOriginalPhotosCards=(void *)GSStorageReplace(photos,NSSelectorFromString(@"accountMenuCardData"),(IMP)GSStoragePhotosCards);
 Class aggregator=NSClassFromString(@"_TtC102googlemac_iPhone_Shared_OneGoogle_AccountSelector_Cards_Implementation_OGLAggregatorCardDataSourceImpl31OGLAggregatorCardDataSourceImpl");
 if(GSStorageMethod(aggregator,@"accountMenuCardData","@16@0:8"))GSOriginalAggregatorCards=(void *)GSStorageReplace(aggregator,NSSelectorFromString(@"accountMenuCardData"),(IMP)GSStorageAggregatorCards);
 if(GSStorageMethod(aggregator,@"refreshAccountMenuCardData","v16@0:8"))GSOriginalAggregatorRefresh=(void *)GSStorageReplace(aggregator,NSSelectorFromString(@"refreshAccountMenuCardData"),(IMP)GSStorageAggregatorRefresh);
 Class service=NSClassFromString(@"OGLGStorageCardServiceImpl");
 if(GSStorageMethod(service,@"init","@16@0:8"))GSOriginalServiceInit=(void *)GSStorageReplace(service,@selector(init),(IMP)GSStorageServiceInit);
 if(GSStorageMethod(service,@"didReceiveGoogleOneFlowStatus:error:","v28@0:8i16@20"))GSOriginalFlowStatus=(void *)GSStorageReplace(service,NSSelectorFromString(@"didReceiveGoogleOneFlowStatus:error:"),(IMP)GSStorageFlowStatus);
 if(GSStorageMethod(service,@"googleOneService:didReceiveStorageUsageRatio:onPurchase:","v36@0:8@16d24B32"))GSOriginalUsageRatio=(void *)GSStorageReplace(service,NSSelectorFromString(@"googleOneService:didReceiveStorageUsageRatio:onPurchase:"),(IMP)GSStorageUsageRatio);
 if(GSStorageMethod(service,@"updateStorageUsageRatio:","v24@0:8d16"))GSOriginalUpdateRatio=(void *)GSStorageReplace(service,NSSelectorFromString(@"updateStorageUsageRatio:"),(IMP)GSStorageUpdateRatio);
 Class bentoService=NSClassFromString(@"OGLBentoServiceImpl");
 if(GSStorageMethod(bentoService,@"bentoAccountMenuEnabled","B16@0:8"))GSOriginalBentoEnabled=(void *)GSStorageReplace(bentoService,NSSelectorFromString(@"bentoAccountMenuEnabled"),(IMP)GSStorageBentoEnabled);
 GSStorageInstalled=YES;GSStorageStatus=@"installed";
}
