#import "../Shared/GSPhotosCompatibility.h"
#import "../Shared/GSLocalization.h"
#import "GSPhotosIntegration.h"
#import "GSNativeAccount.h"
#import "GSNativeRouting.h"
#import <objc/runtime.h>
#import <objc/message.h>

@interface PHSOneUpInfoPanelBackupStatusData : NSObject
- (instancetype)initWithBackupStatus:(NSString *)status backupStatusSubtitle:(NSString *)subtitle learnMoreLink:(NSString *)link;
@end

// Exact runtime ABI checks. Never set backup flags or edit the native database.
static NSObject *GSLock;
static NSMapTable *GSSynchronizers;
static NSMutableDictionary *GSCounts;
static BOOL GSInstalled, GSQualityAvailable, GSStackAvailable, GSSyncAvailable, GSPending, GSScheduled;
// The details stack builds its own quality text in the row factories below and
// never reads the BackupStatusData subtitle. While one of those factories runs
// on this thread, PHSServerPhoto.storagePolicy reads Standard for a photo whose
// server model confirms original bytes, so the native wording and localization
// are used. Our own diagnostic reads stay native; nothing is stored.
static _Thread_local NSUInteger GSDisplayScope, GSNativeReads;
static const unsigned char GSStandardStoragePolicy=1;
static unsigned char (*GSOriginalStoragePolicy)(id,SEL), (*GSOriginalQuotaChargeable)(id,SEL);
static int (*GSOriginalServerStoragePolicy)(id,SEL);
static id (*GSOriginalStatusModel)(id,SEL), (*GSOriginalBackupRow)(id,SEL,id,id,id,id,id), (*GSOriginalStackModels)(id,SEL,id,id);
static void (*GSOriginalBackupStatusUI)(id,SEL);
static NSMutableOrderedSet *GSObservedRowClasses;
static BOOL GSMethod(id object,NSString *name,const char *encoding){
 Method m=class_getInstanceMethod(object_getClass(object),NSSelectorFromString(name));
 return m&&!strcmp(method_getTypeEncoding(m),encoding);
}
static id GSGet(id object,NSString *name){return GSMethod(object,name,"@16@0:8")?((id(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name)):nil;}
static void GSCount(NSString *key){@synchronized(GSLock){GSCounts[key]=@([GSCounts[key]unsignedIntegerValue]+1);}}
NSDictionary *GSPhotosIntegrationSnapshot(void){
 if(!GSInstalled)return @{@"qualityAvailable":@NO,@"syncAvailable":@NO};
 @synchronized(GSLock){NSMutableDictionary *d=[GSCounts mutableCopy];d[@"qualityAvailable"]=GSQualityAvailable?@YES:@NO;d[@"syncAvailable"]=GSSyncAvailable?@YES:@NO;
  d[@"stackQualityAvailable"]=GSStackAvailable?@YES:@NO;d[@"stackRowClasses"]=GSObservedRowClasses.array?:@[];return d;}
}
static void GSFlushRefresh(void){
 if(!GSPending||GSScheduled)return;GSScheduled=YES;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
  GSScheduled=NO;if(!GSPending)return;
  id target=nil;
  @synchronized(GSLock){for(id account in GSSynchronizers.keyEnumerator)if(GSNativeAccountMatches(account)){target=[GSSynchronizers objectForKey:account];break;}}
  if(!target){GSCount(@"syncWaitingForAccount");return;}
  GSPending=NO;GSCount(@"syncRequested");
  // fetchData -> fetchWithType:0 enters the app's existing sync queue and
  // publishes real server-store changes to its grid and details subscribers.
  ((void(*)(id,SEL))objc_msgSend)(target,NSSelectorFromString(@"fetchData"));
 });
}
void GSRefreshNativeLibrary(void){
 if(!GSSyncAvailable)return;
 dispatch_async(dispatch_get_main_queue(),^{GSPending=YES;GSFlushRefresh();});
}
static void GSCaptureSynchronizer(id object){
 id account=GSGet(object,@"accountID");if(!account)return;
 // The app releases synchronizers between its own syncs, so only the newest
 // capture per account is kept alive as the entry into the app's sync queue.
 @synchronized(GSLock){[GSSynchronizers setObject:object forKey:account];}
 // Fetch entry is not completion; keep the coalesced refresh pending.
 dispatch_async(dispatch_get_main_queue(),^{GSFlushRefresh();});
}
static BOOL GSControllerBackedUp(id controller){
 return GSMethod(controller,@"isBackedUp","B16@0:8")&&((BOOL(*)(id,SEL))objc_msgSend)(controller,NSSelectorFromString(@"isBackedUp"));
}
static BOOL GSPhotoModelReadable(id photo){
 return [photo isKindOfClass:NSClassFromString(@"PHSServerPhoto")]&&GSMethod(photo,@"hasOriginalBytes","C16@0:8")&&GSMethod(photo,@"isPartialBackup","B16@0:8");
}
// Enum descriptor: Unknown=0, Yes=1, No=2, Maybe=3. Maybe is not Yes.
static BOOL GSPhotoConfirmsOriginal(id photo){
 return GSPhotoModelReadable(photo)&&((unsigned char(*)(id,SEL))objc_msgSend)(photo,NSSelectorFromString(@"hasOriginalBytes"))==1&&
  !((BOOL(*)(id,SEL))objc_msgSend)(photo,NSSelectorFromString(@"isPartialBackup"));
}
static BOOL GSHasConfirmedOriginal(id controller){
 if(!GSControllerBackedUp(controller))return NO;
 id photo=GSGet(GSGet(controller,@"extendedPhoto"),@"serverPhoto");
 if(!GSPhotoModelReadable(photo))return NO;
 unsigned char originals=((unsigned char(*)(id,SEL))objc_msgSend)(photo,NSSelectorFromString(@"hasOriginalBytes"));
 GSCount(originals==1?@"serverOriginal":originals==2?@"serverNotOriginal":@"serverOriginalUnknown");
 if(originals!=1||((BOOL(*)(id,SEL))objc_msgSend)(photo,NSSelectorFromString(@"isPartialBackup")))return NO;
 // hasOriginalBytes is the server's own original-bytes model. Quota-free Pixel
 // uploads report Yes with a non-Standard storagePolicy, so the policy value is
 // recorded for diagnostics but does not gate the correction. The read is
 // native even when a row factory has the display override active.
 if(GSMethod(photo,@"storagePolicy","C16@0:8")){
  GSNativeReads++;unsigned char policy=((unsigned char(*)(id,SEL))objc_msgSend)(photo,NSSelectorFromString(@"storagePolicy"));GSNativeReads--;
  GSCount([NSString stringWithFormat:@"serverStoragePolicy%u",(unsigned)policy]);
 }
 return YES;
}
// 7.20.2 builds a native label/image content model instead of BackupStatusData.
// Scope the inherited factory override to this controller's backup-status call.
static _Thread_local void *GSLegacyStatusController;
static id GSBackupStatus(id controller,SEL selector,IMP original){
 id status=((id(*)(id,SEL))original)(controller,selector);
 if(!status||!GSHasConfirmedOriginal(controller))return status;
 NSString *backup=GSGet(status,@"backupStatus");if(![backup isKindOfClass:NSString.class])return status;
 id replacement=[(PHSOneUpInfoPanelBackupStatusData *)[NSClassFromString(@"PHSOneUpInfoPanelBackupStatusData") alloc] initWithBackupStatus:backup backupStatusSubtitle:GSL(@"Original quality (original data available)") learnMoreLink:@"https://support.google.com/photos/answer/6220791"];
 if(replacement){GSCount(@"qualityLabelCorrected");return replacement;}
 return status;
}
// Display-scoped reads of the server model. Outside a row factory, and for our
// own checks, every getter returns the stored value unchanged.
static unsigned char GSDisplayStoragePolicy(id photo,SEL selector){
 unsigned char native=GSOriginalStoragePolicy(photo,selector);
 if(!GSDisplayScope||GSNativeReads)return native;
 GSCount(@"displayPolicyReads");
 if(native==GSStandardStoragePolicy||!GSPhotoConfirmsOriginal(photo))return native;
 GSCount(@"displayPolicyOverrides");return GSStandardStoragePolicy;
}
static int GSDisplayServerStoragePolicy(id photo,SEL selector){
 int value=GSOriginalServerStoragePolicy(photo,selector);
 if(GSDisplayScope&&!GSNativeReads){GSCount(@"displayServerPolicyReads");GSCount([NSString stringWithFormat:@"displayServerPolicy%d",value]);}
 return value;
}
static unsigned char GSDisplayQuotaChargeable(id photo,SEL selector){
 if(GSDisplayScope&&!GSNativeReads)GSCount(@"displayQuotaReads");
 return GSOriginalQuotaChargeable(photo,selector);
}
// Fallback for a row whose quality text is not derived from storagePolicy: the
// native subtitle for this controller identifies the wording to replace, so no
// Google string key or hardcoded language is needed.
static NSString *GSNativeQualityText(id controller){
 if(!GSOriginalStatusModel)return nil;
 GSNativeReads++;id status=nil;@try{status=GSOriginalStatusModel(controller,NSSelectorFromString(@"getBackupStatusModelData"));}@finally{GSNativeReads--;}
 NSString *text=GSGet(status,@"backupStatusSubtitle");
 return [text isKindOfClass:NSString.class]&&text.length?text:nil;
}
static id GSReplacedText(id value,NSString *from,NSString *to,BOOL *changed){
 if([value isKindOfClass:NSString.class]){
  if(![value containsString:from])return value;
  *changed=YES;return [value stringByReplacingOccurrencesOfString:from withString:to];
 }
 if([value isKindOfClass:NSAttributedString.class]){
  NSMutableAttributedString *text=[value mutableCopy];NSRange range=[text.string rangeOfString:from];
  if(range.location==NSNotFound)return value;
  while(range.location!=NSNotFound){
   [text replaceCharactersInRange:range withString:to];NSUInteger next=range.location+to.length;
   range=next<text.length?[text.string rangeOfString:from options:0 range:NSMakeRange(next,text.length-next)]:NSMakeRange(NSNotFound,0);
  }
  *changed=YES;return text;
 }
 return value;
}
static BOOL GSCorrectRow(id row,NSString *from){
 if(!from||![row isKindOfClass:NSClassFromString(@"PHSOneUpInfoPanelDetailsStackViewModel")])return NO;
 NSString *to=GSL(@"Original quality (original data available)");BOOL changed=NO;
 if(GSMethod(row,@"title","@16@0:8")&&GSMethod(row,@"setTitle:","v24@0:8@16")){
  BOOL replaced=NO;id title=GSReplacedText(GSGet(row,@"title"),from,to,&replaced);
  if(replaced){((void(*)(id,SEL,id))objc_msgSend)(row,NSSelectorFromString(@"setTitle:"),title);changed=YES;}
 }
 if(GSMethod(row,@"attributes","@16@0:8")&&GSMethod(row,@"setAttributes:","v24@0:8@16")){
  id attributes=GSGet(row,@"attributes");
  if([attributes isKindOfClass:NSArray.class]){
   BOOL replaced=NO;NSMutableArray *values=[NSMutableArray arrayWithCapacity:[attributes count]];
   for(id value in attributes)[values addObject:GSReplacedText(value,from,to,&replaced)];
   if(replaced){((void(*)(id,SEL,id))objc_msgSend)(row,NSSelectorFromString(@"setAttributes:"),values);changed=YES;}
  }
 }
 return changed;
}
static void GSObserveRow(id row){
 if(!row)return;NSString *name=NSStringFromClass(object_getClass(row));
 @synchronized(GSLock){if(GSObservedRowClasses.count<8)[GSObservedRowClasses addObject:name];}
}
// Only a controller that already shows the photo as backed up opens the scope.
static NSUInteger GSEnterDisplay(id controller){if(!GSControllerBackedUp(controller))return 0;GSDisplayScope++;return 1;}
// createBackupViewModel:mediaItem:serverPhoto:localAsset:storeResult: (five object arguments)
static id GSBackupRow(id controller,SEL selector,id model,id item,id serverPhoto,id localAsset,id storeResult){
 GSCount(@"stackBackupRows");id row=nil;NSUInteger entered=GSEnterDisplay(controller);
 @try{row=GSOriginalBackupRow(controller,selector,model,item,serverPhoto,localAsset,storeResult);}@finally{GSDisplayScope-=entered;}
 GSObserveRow(row);
 id photo=[serverPhoto isKindOfClass:NSClassFromString(@"PHSServerPhoto")]?serverPhoto:GSGet(GSGet(controller,@"extendedPhoto"),@"serverPhoto");
 if(row&&entered&&GSPhotoConfirmsOriginal(photo)&&GSCorrectRow(row,GSNativeQualityText(controller)))GSCount(@"stackRowCorrected");
 return row;
}
static id GSStackModels(id controller,SEL selector,id photo,id item){
 NSUInteger entered=GSEnterDisplay(controller);
 @try{return GSOriginalStackModels(controller,selector,photo,item);}@finally{GSDisplayScope-=entered;}
}
static void GSBackupStatusUI(id controller,SEL selector){
 GSCount(@"stackBackupUpdates");NSUInteger entered=GSEnterDisplay(controller);
 @try{GSOriginalBackupStatusUI(controller,selector);}@finally{GSDisplayScope-=entered;}
 if(!GSControllerBackedUp(controller)||!GSPhotoConfirmsOriginal(GSGet(GSGet(controller,@"extendedPhoto"),@"serverPhoto")))return;
 id rowID=GSGet(controller,@"backupStatusViewModelID");NSArray *rows=GSGet(controller,@"detailsStackViewModels");
 if(!rowID||![rows isKindOfClass:NSArray.class])return;
 NSString *from=GSNativeQualityText(controller);
 for(id row in rows)if([GSGet(row,@"id")isEqual:rowID]&&GSCorrectRow(row,from))GSCount(@"stackRowCorrected");
}
static IMP GSReplace(Class cls,NSString *name,IMP replacement){
 Method method=class_getInstanceMethod(cls,NSSelectorFromString(name));IMP original=method_getImplementation(method);
 // An inherited method is shadowed on this class only.
 if(!class_addMethod(cls,NSSelectorFromString(name),replacement,method_getTypeEncoding(method)))method_setImplementation(method,replacement);
 return original;
}
static void GSInstallStackQuality(Class details){
 Class photo=NSClassFromString(@"PHSServerPhoto"),extended=NSClassFromString(@"PHSExtendedPhoto");
 NSString *factory=@"createBackupViewModel:mediaItem:serverPhoto:localAsset:storeResult:";
 if(!NSClassFromString(@"PHSOneUpInfoPanelDetailsStackViewModel")||!GSPhotosHasMethod(details,factory,"@56@0:8@16@24@32@40@48")||
    !GSPhotosHasMethod(photo,@"hasOriginalBytes","C16@0:8")||!GSPhotosHasMethod(photo,@"isPartialBackup","B16@0:8"))return;
 GSObservedRowClasses=[NSMutableOrderedSet orderedSet];
 GSOriginalBackupRow=(void *)GSReplace(details,factory,(IMP)GSBackupRow);
 // Optional: the policy getter is the display source; the rest identify the path.
 if(GSPhotosHasMethod(photo,@"storagePolicy","C16@0:8"))GSOriginalStoragePolicy=(void *)GSReplace(photo,@"storagePolicy",(IMP)GSDisplayStoragePolicy);
 if(GSPhotosHasMethod(photo,@"quotaChargeable","C16@0:8"))GSOriginalQuotaChargeable=(void *)GSReplace(photo,@"quotaChargeable",(IMP)GSDisplayQuotaChargeable);
 if(GSPhotosHasMethod(extended,@"serverStoragePolicy","i16@0:8"))GSOriginalServerStoragePolicy=(void *)GSReplace(extended,@"serverStoragePolicy",(IMP)GSDisplayServerStoragePolicy);
 if(GSPhotosHasMethod(details,@"updateBackupStatusUI","v16@0:8"))GSOriginalBackupStatusUI=(void *)GSReplace(details,@"updateBackupStatusUI",(IMP)GSBackupStatusUI);
 if(GSPhotosHasMethod(details,@"createStackViewModelsForExtendedPhoto:preferredMediaItem:","@32@0:8@16@24"))GSOriginalStackModels=(void *)GSReplace(details,@"createStackViewModelsForExtendedPhoto:preferredMediaItem:",(IMP)GSStackModels);
 GSStackAvailable=YES;
}
void GSInstallPhotosIntegration(void){
 if(GSInstalled||!GSIsGooglePhotos()||!GSPhotosHostSupported())return;
 // Strong values: a weak table loses the per-sync synchronizer before the
 // coalescing window ends, stranding the pending refresh (syncWaitingForAccount
 // with no live requester on device). One object per account, newest wins.
 GSLock=[NSObject new];GSCounts=[NSMutableDictionary dictionary];GSSynchronizers=[NSMapTable strongToStrongObjectsMapTable];GSInstalled=YES;
 Class sync=NSClassFromString(@"PHSUserItemsSynchronizer");
 Method fetch=class_getInstanceMethod(sync,NSSelectorFromString(@"fetchData"));
 Method account=class_getInstanceMethod(sync,NSSelectorFromString(@"accountID"));
 if(fetch&&account&&!strcmp(method_getTypeEncoding(fetch),"v16@0:8")&&!strcmp(method_getTypeEncoding(account),"@16@0:8")){
  for(NSString *name in @[@"fetchData",@"fetchDataSoft"]){SEL s=NSSelectorFromString(name);Method m=class_getInstanceMethod(sync,s);if(!m||strcmp(method_getTypeEncoding(m),"v16@0:8"))continue;
   IMP old=method_getImplementation(m);method_setImplementation(m,imp_implementationWithBlock(^(id object){GSCaptureSynchronizer(object);((void(*)(id,SEL))old)(object,s);}));
  }
  GSSyncAvailable=YES;
 }
 BOOL modern=GSPhotosHasMethod(NSClassFromString(@"PHSOneUpInfoPanelDetailsViewController"),@"getBackupStatusModelData","@16@0:8")&&
  GSPhotosHasMethod(NSClassFromString(@"PHSOneUpInfoPanelBackupStatusData"),@"initWithBackupStatus:backupStatusSubtitle:learnMoreLink:","@40@0:8@16@24@32");
 if(!modern){
  Class details=NSClassFromString(@"PHSOneUpInfoPanelDetailsViewController");
  SEL status=NSSelectorFromString(@"modelForBackedupStatus"),factory=NSSelectorFromString(@"contentViewModelWithTitle:subtitle:subtitleContainsHTML:image:");
  Method sm=class_getInstanceMethod(details,status),fm=class_getInstanceMethod(details,factory);
  if(sm&&fm&&!strcmp(method_getTypeEncoding(sm),"@16@0:8")&&!strcmp(method_getTypeEncoding(fm),"@44@0:8@16@24B32@36")){
   IMP oldStatus=method_getImplementation(sm),oldFactory=method_getImplementation(fm);
   IMP replacement=imp_implementationWithBlock(^id(id controller,id title,id subtitle,BOOL html,id image){
    if(GSLegacyStatusController==(__bridge void *)controller&&GSHasConfirmedOriginal(controller)){
     subtitle=GSL(@"Original quality (original data available)");html=NO;GSCount(@"qualityLabelCorrected");
    }
    return ((id(*)(id,SEL,id,id,BOOL,id))oldFactory)(controller,factory,title,subtitle,html,image);
   });
   // Do not alter the shared section superclass or unrelated detail content.
   if(class_addMethod(details,factory,replacement,method_getTypeEncoding(fm))){
    method_setImplementation(sm,imp_implementationWithBlock(^id(id controller){
     void *previous=GSLegacyStatusController;GSLegacyStatusController=(__bridge void *)controller;
     @try{return ((id(*)(id,SEL))oldStatus)(controller,status);}@finally{GSLegacyStatusController=previous;}
    }));GSQualityAvailable=YES;
   }else imp_removeBlock(replacement);
  }
  return;
 }
 Class details=NSClassFromString(@"PHSOneUpInfoPanelDetailsViewController"),model=NSClassFromString(@"PHSOneUpInfoPanelBackupStatusData");
 SEL s=NSSelectorFromString(@"getBackupStatusModelData");Method m=class_getInstanceMethod(details,s),init=class_getInstanceMethod(model,NSSelectorFromString(@"initWithBackupStatus:backupStatusSubtitle:learnMoreLink:"));
 if(m&&init&&!strcmp(method_getTypeEncoding(m),"@16@0:8")&&!strcmp(method_getTypeEncoding(init),"@40@0:8@16@24@32")){
  IMP old=method_getImplementation(m);GSOriginalStatusModel=(void *)old;
  method_setImplementation(m,imp_implementationWithBlock(^id(id controller){return GSBackupStatus(controller,s,old);}));GSQualityAvailable=YES;
  GSInstallStackQuality(details);
 }
}
