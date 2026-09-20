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
static BOOL GSInstalled, GSQualityAvailable, GSSyncAvailable, GSPending, GSScheduled;
static BOOL GSMethod(id object,NSString *name,const char *encoding){
 Method m=class_getInstanceMethod(object_getClass(object),NSSelectorFromString(name));
 return m&&!strcmp(method_getTypeEncoding(m),encoding);
}
static id GSGet(id object,NSString *name){return GSMethod(object,name,"@16@0:8")?((id(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name)):nil;}
static void GSCount(NSString *key){@synchronized(GSLock){GSCounts[key]=@([GSCounts[key]unsignedIntegerValue]+1);}}
NSDictionary *GSPhotosIntegrationSnapshot(void){
 if(!GSInstalled)return @{@"qualityAvailable":@NO,@"syncAvailable":@NO};
 @synchronized(GSLock){NSMutableDictionary *d=[GSCounts mutableCopy];d[@"qualityAvailable"]=GSQualityAvailable?@YES:@NO;d[@"syncAvailable"]=GSSyncAvailable?@YES:@NO;return d;}
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
static BOOL GSHasConfirmedOriginal(id controller){
 if(!GSMethod(controller,@"isBackedUp","B16@0:8")||!((BOOL(*)(id,SEL))objc_msgSend)(controller,NSSelectorFromString(@"isBackedUp")))return NO;
 id photo=GSGet(GSGet(controller,@"extendedPhoto"),@"serverPhoto");
 if(![photo isKindOfClass:NSClassFromString(@"PHSServerPhoto")]||!GSMethod(photo,@"hasOriginalBytes","C16@0:8")||!GSMethod(photo,@"isPartialBackup","B16@0:8"))return NO;
 unsigned char originals=((unsigned char(*)(id,SEL))objc_msgSend)(photo,NSSelectorFromString(@"hasOriginalBytes"));
 // Enum descriptor: Unknown=0, Yes=1, No=2, Maybe=3. Maybe is not Yes.
 GSCount(originals==1?@"serverOriginal":originals==2?@"serverNotOriginal":@"serverOriginalUnknown");
 if(originals!=1||((BOOL(*)(id,SEL))objc_msgSend)(photo,NSSelectorFromString(@"isPartialBackup")))return NO;
 // hasOriginalBytes is the server's own original-bytes model. Quota-free Pixel
 // uploads report Yes with a non-Standard storagePolicy, so the policy value is
 // recorded for diagnostics but does not gate the correction.
 if(GSMethod(photo,@"storagePolicy","C16@0:8")){
  unsigned char policy=((unsigned char(*)(id,SEL))objc_msgSend)(photo,NSSelectorFromString(@"storagePolicy"));
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
  IMP old=method_getImplementation(m);method_setImplementation(m,imp_implementationWithBlock(^id(id controller){return GSBackupStatus(controller,s,old);}));GSQualityAvailable=YES;
 }
}
