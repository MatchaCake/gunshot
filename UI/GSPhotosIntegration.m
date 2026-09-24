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
// on this thread, PHSServerPhoto.storagePolicy reads the original-quality
// policy for a photo whose server model confirms original bytes, so the native
// wording and localization are used. Our own diagnostic reads stay native;
// nothing is stored.
static _Thread_local NSUInteger GSDisplayScope, GSNativeReads;
// Probe value + 1 for PHSServerPhoto.storagePolicy while the native subtitle is
// rebuilt per policy to learn this build's localized quality wordings.
static _Thread_local NSUInteger GSForcedPolicy;
// Server storagePolicy (PHSServerPhoto, from quotaInfo): 1 is "Standard", the
// policy photosConvertToStandardStoragePolicyRPC compresses originals into,
// i.e. Storage saver. Device 2026-09-24 (6th diagnostics): a quota-free Pixel
// original reads 2 and its native subtitle is "Original quality", while the
// subtitle rebuilt with policy 1 differs from it by exactly those words.
// Earlier builds forced 1 inside the row factories, producing saver wording.
static const unsigned char GSServerOriginalPolicy=2;
static const int GSClientOriginalPolicy=3;
static unsigned char (*GSOriginalStoragePolicy)(id,SEL), (*GSOriginalQuotaChargeable)(id,SEL);
static int (*GSOriginalServerStoragePolicy)(id,SEL);
static id (*GSOriginalStatusModel)(id,SEL), (*GSOriginalBackupRow)(id,SEL,id,id,id,id,id), (*GSOriginalStackModels)(id,SEL,id,id);
static void (*GSOriginalBackupStatusUI)(id,SEL), (*GSOriginalSetStackModels)(id,SEL,id);
// Probed wordings keyed by the native subtitle they were derived from.
static NSMutableDictionary<NSString *,NSArray<NSString *> *> *GSSaverWordingCache;
// The photo of the details controller that last opened the display scope
// (backed up); main-thread reads outside the scope are corrected only for it.
static __weak id GSActiveExtendedPhoto;
// The details controller whose display scope is open on this thread. Read only
// while GSDisplayScope is non-zero, when the factory that opened it still holds
// the controller.
static _Thread_local void *GSScopeController;
static _Thread_local BOOL GSCorrectingInit;
static id (*GSOriginalRowInitSubtitle)(id,SEL,id,id), (*GSOriginalRowInitSubtitleIcon)(id,SEL,id,id,id);
static const NSUInteger GSRowTextLimit=128;
static NSMutableOrderedSet *GSObservedRowClasses;
static NSMutableOrderedSet *GSPanelTexts, *GSRowTexts, *GSPanelViewClasses;
static void GSRecordQualityCandidates(NSArray<NSString *> *candidates);
static void GSRecordRowShape(id object,NSString *path,NSUInteger depth);
static NSString *GSMaskedText(NSString *text);
static void GSRecordIn(NSMutableOrderedSet *set,NSString *text,NSUInteger limit);
static void (*GSOriginalPanelLayout)(id,SEL);
static void GSSchedulePanelCorrection(id controller);
static BOOL GSMethod(id object,NSString *name,const char *encoding){
 Method m=class_getInstanceMethod(object_getClass(object),NSSelectorFromString(name));
 return m&&!strcmp(method_getTypeEncoding(m),encoding);
}
static id GSGet(id object,NSString *name){return GSMethod(object,name,"@16@0:8")?((id(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name)):nil;}
static void GSCount(NSString *key){@synchronized(GSLock){GSCounts[key]=@([GSCounts[key]unsignedIntegerValue]+1);}}
NSDictionary *GSPhotosIntegrationSnapshot(void){
 if(!GSInstalled)return @{@"qualityAvailable":@NO,@"syncAvailable":@NO};
 @synchronized(GSLock){NSMutableDictionary *d=[GSCounts mutableCopy];d[@"qualityAvailable"]=GSQualityAvailable?@YES:@NO;d[@"syncAvailable"]=GSSyncAvailable?@YES:@NO;
  d[@"stackQualityAvailable"]=GSStackAvailable?@YES:@NO;d[@"stackRowClasses"]=GSObservedRowClasses.array?:@[];
  d[@"panelTexts"]=GSPanelTexts.array?:@[];d[@"rowTexts"]=GSRowTexts.array?:@[];d[@"panelViewClasses"]=GSPanelViewClasses.array?:@[];d[@"panelLayoutAvailable"]=GSOriginalPanelLayout?@YES:@NO;return d;}
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
 if(GSForcedPolicy)return (unsigned char)(GSForcedPolicy-1);
 unsigned char native=GSOriginalStoragePolicy(photo,selector);
 if(!GSDisplayScope&&!GSNativeReads)GSCount(NSThread.isMainThread?@"displayPolicyReadsOutside":@"displayPolicyReadsOffMain");
 if(!GSDisplayScope||GSNativeReads)return native;
 GSCount(@"displayPolicyReads");
 if(native==GSServerOriginalPolicy||!GSPhotoConfirmsOriginal(photo))return native;
 GSCount(@"displayPolicyOverrides");return GSServerOriginalPolicy;
}
// PHSExtendedPhoto.serverStoragePolicy is the client enum (the value the upload
// commit carries: 1 saver, 3 original) and is stored at load, so it does not
// follow the getter above. Device counters (2026-09-24) show the details row
// reads it once per build and it returned 1 while storagePolicy was overridden.
// Device counters (2026-09-24, 4th build) show 51 in-scope reads overridden and
// the panel still reading Storage saver: the SwiftUI details stack renders
// after the factories return. The 6th diagnostics (336 in-scope reads, all
// overridden, no counted read outside the scope, panel still saver) leave only
// readers the previous rule excluded without counting: another PHSExtendedPhoto
// instance of the same photo, or another thread. It is the sole saver-valued
// datum observed, and hasOriginalBytes is the server's own original model, so
// every instance whose server photo confirms original reads 3 on every thread.
// The read site is counted so the device can name the reader.
static int GSDisplayServerStoragePolicy(id extended,SEL selector){
 int value=GSOriginalServerStoragePolicy(extended,selector);
 if(GSNativeReads)return value;
 NSString *site=GSDisplayScope?@"":!NSThread.isMainThread?@"OffMain":extended&&extended==GSActiveExtendedPhoto?@"Outside":@"OtherInstance";
 GSCount([@"displayServerPolicyReads" stringByAppendingString:site]);
 if(GSDisplayScope)GSCount([NSString stringWithFormat:@"displayServerPolicy%d",value]);
 if(value==GSClientOriginalPolicy||!GSPhotoConfirmsOriginal(GSGet(extended,@"serverPhoto")))return value;
 GSCount([NSString stringWithFormat:@"displayServerPolicy%@Overrides",site]);return GSClientOriginalPolicy;
}
// Diagnostics only: whether the panel consults the derived flag. Never altered.
static BOOL (*GSOriginalNeedsFullBackup)(id,SEL);
static BOOL GSCountedNeedsFullBackup(id extended,SEL selector){
 BOOL value=GSOriginalNeedsFullBackup(extended,selector);
 if(!GSNativeReads){
  BOOL original=GSPhotoConfirmsOriginal(GSGet(extended,@"serverPhoto"));
  GSCount([NSString stringWithFormat:@"needsFullBackup%@%@",original?@"Original":@"",value?@"Yes":@"No"]);
 }
 return value;
}
static unsigned char GSDisplayQuotaChargeable(id photo,SEL selector){
 if(GSDisplayScope&&!GSNativeReads)GSCount(@"displayQuotaReads");
 return GSOriginalQuotaChargeable(photo,selector);
}
// Fallback for a row whose quality text is not derived from storagePolicy: the
// native subtitle for this controller identifies the wording to replace, so no
// Google string key or hardcoded language is needed.
static NSString *GSStatusSubtitle(id controller,BOOL native){
 if(!GSOriginalStatusModel)return nil;id status=nil;void *previous=GSScopeController;
 if(native)GSNativeReads++;else{GSDisplayScope++;GSScopeController=(__bridge void *)controller;}
 @try{status=GSOriginalStatusModel(controller,NSSelectorFromString(@"getBackupStatusModelData"));}@finally{if(native)GSNativeReads--;else{GSDisplayScope--;GSScopeController=previous;}}
 NSString *text=GSGet(status,@"backupStatusSubtitle");
 return [text isKindOfClass:NSString.class]&&text.length?text:nil;
}
static NSString *GSNativeQualityText(id controller){return GSStatusSubtitle(controller,YES);}
// The subtitle is HTML (device 2026-09-24: its diagnostic entry was dropped for
// containing "/", i.e. a link), so it never occurs verbatim in rendered text.
static NSString *GSCollapse(NSString *text){
 text=[text stringByReplacingOccurrencesOfString:@"\\s+" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0,text.length)];
 return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static NSString *GSPlainText(NSString *html,BOOL keepLinks){
 if(![html isKindOfClass:NSString.class])return nil;NSString *text=html;
 if(!keepLinks)text=[text stringByReplacingOccurrencesOfString:@"<a\\b[^>]*>.*?</a>" withString:@" " options:NSRegularExpressionSearch|NSCaseInsensitiveSearch range:NSMakeRange(0,text.length)];
 text=[text stringByReplacingOccurrencesOfString:@"<br\\s*/?>" withString:@" " options:NSRegularExpressionSearch|NSCaseInsensitiveSearch range:NSMakeRange(0,text.length)];
 text=[text stringByReplacingOccurrencesOfString:@"<[^>]*>" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0,text.length)];
 for(NSArray *entity in @[@[@"&nbsp;",@" "],@[@"&quot;",@"\""],@[@"&#39;",@"'"],@[@"&apos;",@"'"],@[@"&lt;",@"<"],@[@"&gt;",@">"],@[@"&amp;",@"&"]])
  text=[text stringByReplacingOccurrencesOfString:entity[0] withString:entity[1]];
 return GSCollapse(text);
}
static BOOL GSBoundary(NSString *text,NSUInteger index){
 if(!index||index>=text.length)return YES;
 NSCharacterSet *breaks=[NSCharacterSet characterSetWithCharactersInString:@"  　.,;:!?()[]·•|-–—。、，；：！？（）「」"];
 return [breaks characterIsMember:[text characterAtIndex:index-1]]||[breaks characterIsMember:[text characterAtIndex:index]];
}
static NSString *GSTrimmedPhrase(NSString *text){
 NSMutableCharacterSet *edge=[NSMutableCharacterSet whitespaceAndNewlineCharacterSet];[edge addCharactersInString:@".,;:·•|-–—。、，；：()（）"];
 return [text stringByTrimmingCharactersInSet:edge];
}
// Wording to look for in the rendered row, most specific first:
// 1. the part of the native subtitle that differs from the same subtitle built
//    with the display policy (the quality words themselves, native language);
// 2. the subtitle without its link text, then with it, as plain text.
// Link text alone ("Learn more") is never a candidate.
// The whole-word part of `text` that differs from `other`, or nil.
static NSString *GSDiffCore(NSString *text,NSString *other){
 if(!text.length||!other.length||[text isEqual:other])return nil;
 NSUInteger prefix=0,suffix=0,limit=MIN(text.length,other.length);
 while(prefix<limit&&[text characterAtIndex:prefix]==[other characterAtIndex:prefix])prefix++;
 while(suffix<limit-prefix&&[text characterAtIndex:text.length-1-suffix]==[other characterAtIndex:other.length-1-suffix])suffix++;
 // Only whole words: a cut inside a word would splice the replacement into it.
 if(!GSBoundary(text,prefix)||!GSBoundary(text,text.length-suffix)||!GSBoundary(other,prefix)||!GSBoundary(other,other.length-suffix))return nil;
 NSString *core=GSTrimmedPhrase([text substringWithRange:NSMakeRange(prefix,text.length-prefix-suffix)]);
 return core.length>1?core:nil;
}
static NSArray<NSString *> *GSQualityCandidates(id controller){
 NSString *native=GSNativeQualityText(controller);if(!native)return @[];
 NSMutableOrderedSet *candidates=[NSMutableOrderedSet orderedSet];
 NSString *plain=GSPlainText(native,NO),*display=GSPlainText(GSStatusSubtitle(controller,NO),NO);
 NSString *core=GSDiffCore(plain,display);if(core)[candidates addObject:core];
 for(NSString *text in @[plain?:@"",GSTrimmedPhrase(plain?:@""),GSPlainText(native,YES)?:@"",native])if(text.length>1)[candidates addObject:text];
 return candidates.array;
}
// Device diagnostics (2026-09-24, 4th build): for a quota-free Pixel upload the
// native subtitle already reads "Original quality", so every candidate above
// named the original wording and the Storage saver text was never searched
// for. The saver wording is learned from the app itself: the native subtitle is
// rebuilt with each storage policy value, and the words that differ from the
// original-quality subtitle are this build's localized non-original wordings.
// A few known Google wordings back this up when the probe yields nothing.
static NSArray<NSString *> *GSSaverWordings(id controller){
 // Known match-only wordings (en, ja, zh-Hans), escaped: never displayed.
 NSArray *known=@[@"Storage saver",@"Storage Saver",@"\u4fdd\u5b58\u5bb9\u91cf\u306e\u7bc0\u7d04",@"\u8282\u7701\u7a7a\u95f4",@"\u5b58\u50a8\u7a7a\u95f4\u8282\u7701\u7a0b\u5e8f"];
 NSString *original=GSPlainText(GSNativeQualityText(controller),NO);
 if(!GSOriginalStatusModel||!GSOriginalStoragePolicy||!original.length)return known;
 @synchronized(GSLock){NSArray *cached=GSSaverWordingCache[original];if(cached)return cached;}
 NSString *standard=nil;NSMutableOrderedSet *plains=[NSMutableOrderedSet orderedSet];
 for(NSUInteger policy=0;policy<=6;policy++){
  id status=nil;GSForcedPolicy=policy+1;GSNativeReads++;
  @try{status=GSOriginalStatusModel(controller,NSSelectorFromString(@"getBackupStatusModelData"));}@catch(__unused id e){}@finally{GSForcedPolicy=0;GSNativeReads--;}
  NSString *text=GSPlainText(GSGet(status,@"backupStatusSubtitle"),NO);if(!text.length)continue;
  if(policy==GSServerOriginalPolicy)standard=text;[plains addObject:text];
 }
 NSMutableOrderedSet *words=[NSMutableOrderedSet orderedSet];
 // Baseline: the original-quality subtitle (device: identical to the native
 // subtitle of a confirmed original). With policy 1 as the baseline the probe
 // reported "Original quality" itself as a differing word, which is how the
 // policy mapping was found.
 for(NSString *text in plains){NSString *core=GSDiffCore(text,standard);if(core)[words addObject:core];}
 BOOL probed=words.count>0;GSCount(probed?@"saverWordingsProbed":@"saverWordingsFallback");
 [words addObjectsFromArray:known];
 NSArray *result=words.array;
 // A probe that found nothing (view not ready) is retried on the next pass.
 if(!probed)return result;
 @synchronized(GSLock){if(!GSSaverWordingCache)GSSaverWordingCache=[NSMutableDictionary dictionary];if(GSSaverWordingCache.count<16)GSSaverWordingCache[original]=result;}
 for(NSString *word in result){NSString *masked=GSMaskedText(word);GSRecordIn(GSRowTexts,[@"saver: " stringByAppendingString:masked?:@"<dropped>"],GSRowTextLimit);}
 return result;
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
// Text-bearing properties of the row and of objects nested in it (attribute
// models, expanded content). Each is written back through its own setter.
static NSArray<NSString *> *GSTextKeys(void){return @[@"title",@"subtitle",@"text",@"attributedText",@"attributedTitle",@"attributes",@"expandedContent"];}
static id GSReplacedValue(id value,NSString *from,NSString *to,NSUInteger depth,BOOL *changed);
static BOOL GSReplaceInObject(id object,NSString *from,NSString *to,NSUInteger depth){
 if(!object||depth>3||[object isKindOfClass:NSClassFromString(@"UIView")])return NO;BOOL changed=NO;
 for(NSString *key in GSTextKeys()){
  NSString *setter=[NSString stringWithFormat:@"set%@%@:",[[key substringToIndex:1]uppercaseString],[key substringFromIndex:1]];
  if(!GSMethod(object,key,"@16@0:8"))continue;
  id value=GSGet(object,key);if(!value)continue;BOOL replaced=NO;
  id updated=GSReplacedValue(value,from,to,depth+1,&replaced);if(!replaced)continue;
  // Nested models edited in place need no setter; a new value does.
  if(updated!=value){if(!GSMethod(object,setter,"v24@0:8@16"))continue;((void(*)(id,SEL,id))objc_msgSend)(object,NSSelectorFromString(setter),updated);}
  changed=YES;
 }
 return changed;
}
static id GSReplacedValue(id value,NSString *from,NSString *to,NSUInteger depth,BOOL *changed){
 if([value isKindOfClass:NSString.class]||[value isKindOfClass:NSAttributedString.class])return GSReplacedText(value,from,to,changed);
 if([value isKindOfClass:NSArray.class]){
  BOOL replaced=NO;NSMutableArray *values=[NSMutableArray arrayWithCapacity:[value count]];
  for(id item in value)[values addObject:GSReplacedValue(item,from,to,depth,&replaced)?:item];
  if(!replaced)return value;*changed=YES;return [value isKindOfClass:NSMutableArray.class]?values:[values copy];
 }
 if(GSReplaceInObject(value,from,to,depth))*changed=YES;
 return value;
}
// Rows of the details stack, and the controller's other content models
// (infoContentViewModels, localAssetInfoModel) whose class is not fixed.
static BOOL GSCorrectRow(id row,NSArray<NSString *> *candidates){
 if(!candidates.count||!row||[row isKindOfClass:NSClassFromString(@"UIView")])return NO;
 NSString *to=GSL(@"Original quality (original data available)");
 // The first candidate that occurs wins, so a broader one never re-edits it.
 // A candidate inside the replacement ("Original quality") would grow on
 // every pass, so it is skipped.
 for(NSString *from in candidates)if(![to containsString:from]&&GSReplaceInObject(row,from,to,0))return YES;
 return NO;
}
static BOOL GSControllerConfirmsOriginal(id controller){
 return GSControllerBackedUp(controller)&&GSPhotoConfirmsOriginal(GSGet(GSGet(controller,@"extendedPhoto"),@"serverPhoto"));
}
// Non-original wordings first: the native subtitle may already read original.
static NSArray<NSString *> *GSAllCandidates(id controller){
 NSMutableOrderedSet *all=[NSMutableOrderedSet orderedSetWithArray:GSSaverWordings(controller)];
 [all addObjectsFromArray:GSQualityCandidates(controller)];return all.array;
}
// The row model's subtitle has no Objective-C getter in 7.92.0: the archived
// index lists id / title / attributes / expandedContent and the initializers
// initWithTitle:subtitle:(icon:) only, so the value is Swift-side storage the
// details stack renders directly. The 7th diagnostics (23 rows, every policy
// getter reading original, no row property holding the words, panel still
// Storage saver) leave the value the factory passes to that initializer as the
// only entry point for the words. Inside the display scope of a confirmed
// original the saver wording is replaced on the way in; the value is recorded
// so the device names the wording. Probes and nested reads pass through.
static id GSCorrectedInitText(id text,NSString *key){
 if(!text||!GSDisplayScope||GSNativeReads||GSCorrectingInit||!GSScopeController)return text;
 if(![text isKindOfClass:NSString.class]&&![text isKindOfClass:NSAttributedString.class])return text;
 id controller=(__bridge id)GSScopeController;GSCorrectingInit=YES;
 @try{
  NSString *plain=[text isKindOfClass:NSAttributedString.class]?[(NSAttributedString *)text string]:text;
  if(plain.length){NSString *masked=GSMaskedText(plain);
   GSRecordIn(GSRowTexts,[NSString stringWithFormat:@"init.%@<%@>: %@",key,[text isKindOfClass:NSString.class]?@"str":@"attr",masked?:@"<dropped>"],GSRowTextLimit);}
  if(!plain.length||!GSControllerConfirmsOriginal(controller))return text;
  NSString *to=GSL(@"Original quality (original data available)");
  for(NSString *from in GSAllCandidates(controller)){
   if([to containsString:from])continue;BOOL changed=NO;id updated=GSReplacedText(text,from,to,&changed);
   if(changed){GSCount([@"initCorrected." stringByAppendingString:key]);return updated;}
  }
  return text;
 }@finally{GSCorrectingInit=NO;}
}
static id GSRowInitSubtitle(id row,SEL selector,id title,id subtitle){
 return GSOriginalRowInitSubtitle(row,selector,GSCorrectedInitText(title,@"title"),GSCorrectedInitText(subtitle,@"subtitle"));
}
static id GSRowInitSubtitleIcon(id row,SEL selector,id title,id subtitle,id icon){
 return GSOriginalRowInitSubtitleIcon(row,selector,GSCorrectedInitText(title,@"title"),GSCorrectedInitText(subtitle,@"subtitle"),icon);
}
// Every row of the details stack, not only the backup row: the quality words
// may sit in any row the SwiftUI stack renders.
static void GSCorrectModels(id controller,NSArray *rows,NSString *recordAs){
 if(![rows isKindOfClass:NSArray.class]||!rows.count||!GSControllerConfirmsOriginal(controller))return;
 NSArray *candidates=GSAllCandidates(controller);NSUInteger index=0;
 for(id row in rows){
  if(recordAs&&index<8)GSRecordRowShape(row,[NSString stringWithFormat:@"%@[%lu]",recordAs,(unsigned long)index],0);
  index++;if(GSCorrectRow(row,candidates))GSCount(@"stackRowCorrected");
 }
}
static void GSCorrectRows(id controller,NSArray *rows,BOOL record){GSCorrectModels(controller,rows,record?@"rows":nil);}
static void GSSetStackModels(id controller,SEL selector,id rows){
 GSCount(@"stackModelAssignments");GSCorrectRows(controller,rows,YES);GSOriginalSetStackModels(controller,selector,rows);
}
static void GSObserveRow(id row){
 if(!row)return;NSString *name=NSStringFromClass(object_getClass(row));
 @synchronized(GSLock){if(GSObservedRowClasses.count<8)[GSObservedRowClasses addObject:name];}
}
// Only a controller that already shows the photo as backed up opens the scope.
static NSUInteger GSEnterDisplay(id controller){
 id photo=GSGet(controller,@"extendedPhoto");
 if(!GSControllerBackedUp(controller)){if(NSThread.isMainThread&&photo&&photo==GSActiveExtendedPhoto)GSActiveExtendedPhoto=nil;return 0;}
 if(NSThread.isMainThread)GSActiveExtendedPhoto=photo;
 GSScopeController=(__bridge void *)controller;GSDisplayScope++;return 1;
}
// createBackupViewModel:mediaItem:serverPhoto:localAsset:storeResult: (five object arguments)
static id GSBackupRow(id controller,SEL selector,id model,id item,id serverPhoto,id localAsset,id storeResult){
 GSCount(@"stackBackupRows");id row=nil;NSUInteger entered=GSEnterDisplay(controller);
 @try{row=GSOriginalBackupRow(controller,selector,model,item,serverPhoto,localAsset,storeResult);}@finally{GSDisplayScope-=entered;}
 GSObserveRow(row);
 id photo=[serverPhoto isKindOfClass:NSClassFromString(@"PHSServerPhoto")]?serverPhoto:GSGet(GSGet(controller,@"extendedPhoto"),@"serverPhoto");
 if(row&&entered&&GSPhotoConfirmsOriginal(photo)){
  NSArray *candidates=GSAllCandidates(controller);GSRecordQualityCandidates(GSQualityCandidates(controller));GSRecordRowShape(row,@"row",0);
  if(GSCorrectRow(row,candidates))GSCount(@"stackRowCorrected");
 }
 if(entered)GSSchedulePanelCorrection(controller);
 return row;
}
static id GSStackModels(id controller,SEL selector,id photo,id item){
 NSUInteger entered=GSEnterDisplay(controller);id rows=nil;
 @try{rows=GSOriginalStackModels(controller,selector,photo,item);}@finally{GSDisplayScope-=entered;}
 if(entered)GSCorrectRows(controller,rows,YES);
 return rows;
}
static void GSBackupStatusUI(id controller,SEL selector){
 GSCount(@"stackBackupUpdates");NSUInteger entered=GSEnterDisplay(controller);
 @try{GSOriginalBackupStatusUI(controller,selector);}@finally{GSDisplayScope-=entered;}
 GSSchedulePanelCorrection(controller);
 GSCorrectRows(controller,GSGet(controller,@"detailsStackViewModels"),NO);
}
// Layout-time correction. Device counters (2026-09-24, 10 rows) show every
// policy getter overridden in the row factory while the panel still read
// Storage saver, and the row model held no plain-string copy of the native
// wording. The visible labels are the last common point, so after the
// details view lays out, label text equal to this controller's native
// quality wording is replaced. Only confirmed originals are touched; a label
// that no longer contains the wording is left alone, so the pass converges.
static _Thread_local BOOL GSWalkingPanel;
static NSString *GSMaskedText(NSString *text){
 if(![text isKindOfClass:NSString.class]||!text.length)return nil;
 // Links and markup are redacted rather than dropping the whole entry, so the
 // native HTML subtitle shows up; any remaining "/" (paths) is still dropped.
 text=[text stringByReplacingOccurrencesOfString:@"<a\\b[^>]*>" withString:@"<a>" options:NSRegularExpressionSearch|NSCaseInsensitiveSearch range:NSMakeRange(0,text.length)];
 text=[text stringByReplacingOccurrencesOfString:@"https?://\\S+" withString:@"<url>" options:NSRegularExpressionSearch|NSCaseInsensitiveSearch range:NSMakeRange(0,text.length)];
 text=[text stringByReplacingOccurrencesOfString:@"</" withString:@"<" options:0 range:NSMakeRange(0,text.length)];
 text=[text stringByReplacingOccurrencesOfString:@"\\s*/>" withString:@">" options:NSRegularExpressionSearch range:NSMakeRange(0,text.length)];
 // Row ids (device: one learn-more link entry per built row) collapse to one
 // diagnostic entry instead of filling the list.
 text=[text stringByReplacingOccurrencesOfString:@"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}" withString:@"<uuid>" options:NSRegularExpressionSearch range:NSMakeRange(0,text.length)];
 if([text containsString:@"/"])return nil;
 if([text rangeOfString:@"\\.[A-Za-z0-9]{2,5}$" options:NSRegularExpressionSearch].location!=NSNotFound)return nil; // File names.
 NSString *masked=[text stringByReplacingOccurrencesOfString:@"[0-9]" withString:@"#" options:NSRegularExpressionSearch range:NSMakeRange(0,text.length)];
 return masked.length>80?[masked substringToIndex:80]:masked;
}
static void GSRecordIn(NSMutableOrderedSet *set,NSString *text,NSUInteger limit){
 if(!text)return;@synchronized(GSLock){if(set.count<limit)[set addObject:text];}
}
static void GSRecordPanelText(NSString *text){GSRecordIn(GSPanelTexts,GSMaskedText(text),32);}
static void GSRecordQualityCandidates(NSArray<NSString *> *candidates){
 if(!candidates.count){GSRecordIn(GSRowTexts,@"candidates: <none>",GSRowTextLimit);return;}
 for(NSString *text in candidates){NSString *masked=GSMaskedText(text);GSRecordIn(GSRowTexts,[@"candidate: " stringByAppendingString:masked?:@"<dropped>"],GSRowTextLimit);}
}
// The details rows are SwiftUI; their text is not in UILabels (device: 104
// labels seen, only "Details"). The hosting view's accessibility elements carry
// the rendered strings, so they are recorded (masked) to name the visible text.
static void GSRecordAccessibility(id element,NSUInteger depth,NSUInteger *budget){
 if(!element||depth>2||!*budget)return;(*budget)--;
 NSString *label=GSGet(element,@"accessibilityLabel"),*value=GSGet(element,@"accessibilityValue");
 if([label isKindOfClass:NSString.class]&&label.length){GSCount(@"panelA11yElements");GSRecordPanelText([@"a11y: " stringByAppendingString:label]);}
 if([value isKindOfClass:NSString.class]&&value.length)GSRecordPanelText([@"a11y-value: " stringByAppendingString:value]);
 NSArray *children=GSGet(element,@"accessibilityElements");
 if([children isKindOfClass:NSArray.class])for(id child in [children copy])GSRecordAccessibility(child,depth+1,budget);
}
// The backup row before correction: where the quality words actually live.
static void GSRecordRowShape(id object,NSString *path,NSUInteger depth){
 if(!object||depth>3)return;
 if([object isKindOfClass:NSString.class]||[object isKindOfClass:NSAttributedString.class]){
  NSString *text=[object isKindOfClass:NSString.class]?object:[object string];NSString *masked=GSMaskedText(text);
  GSRecordIn(GSRowTexts,[NSString stringWithFormat:@"%@<%@>: %@",path,[object isKindOfClass:NSString.class]?@"str":@"attr",masked?:@"<dropped>"],GSRowTextLimit);return;
 }
 if([object isKindOfClass:NSArray.class]){NSUInteger i=0;for(id item in object){if(i>=6)break;GSRecordRowShape(item,[NSString stringWithFormat:@"%@[%lu]",path,(unsigned long)i++],depth+1);}return;}
 if([object isKindOfClass:NSDictionary.class]){NSUInteger i=0;for(id key in object){if(i>=6)break;GSRecordRowShape(((NSDictionary *)object)[key],[NSString stringWithFormat:@"%@{%@}",path,GSMaskedText([key description])?:@"?"],depth+1);i++;}return;}
 if(depth)GSRecordIn(GSRowTexts,[NSString stringWithFormat:@"%@<%@>",path,NSStringFromClass(object_getClass(object))],GSRowTextLimit);
 if([object isKindOfClass:NSClassFromString(@"UIView")])return;
 for(NSString *key in GSTextKeys())if(GSMethod(object,key,"@16@0:8"))GSRecordRowShape(GSGet(object,key),[NSString stringWithFormat:@"%@.%@",path,key],depth+1);
}
static BOOL GSIsTextView(id view){
 return [view isKindOfClass:NSClassFromString(@"UILabel")]||[view isKindOfClass:NSClassFromString(@"UITextView")];
}
static void GSCorrectPanelView(id view,NSArray<NSString *> *candidates,NSString *to,NSUInteger depth,NSUInteger *budget){
 if(!view||depth>48||!*budget)return;(*budget)--;
 GSRecordIn(GSPanelViewClasses,NSStringFromClass(object_getClass(view)),24);
 if(GSIsTextView(view)){
  GSCount(@"panelLabelsSeen");
  id attributed=GSGet(view,@"attributedText");NSString *text=GSGet(view,@"text");
  GSRecordPanelText(text);
  for(NSString *from in candidates){
   if(![text isKindOfClass:NSString.class]||![text containsString:from]||[to containsString:from])continue;
   BOOL replaced=NO;
   if([attributed isKindOfClass:NSAttributedString.class]&&GSMethod(view,@"setAttributedText:","v24@0:8@16")){
    id value=GSReplacedText(attributed,from,to,&replaced);
    if(replaced)((void(*)(id,SEL,id))objc_msgSend)(view,NSSelectorFromString(@"setAttributedText:"),value);
   }
   if(!replaced&&GSMethod(view,@"setText:","v24@0:8@16")){
    ((void(*)(id,SEL,id))objc_msgSend)(view,NSSelectorFromString(@"setText:"),[text stringByReplacingOccurrencesOfString:from withString:to]);replaced=YES;
   }
   if(replaced){GSCount(@"panelLabelCorrected");break;}
  }
 }else if([NSStringFromClass(object_getClass(view)) containsString:@"Hosting"]){
  NSUInteger elements=48;GSRecordAccessibility(view,0,&elements);
 }
 NSArray *subviews=GSGet(view,@"subviews");
 if([subviews isKindOfClass:NSArray.class])for(id child in [subviews copy])GSCorrectPanelView(child,candidates,to,depth+1,budget);
}
static void GSCorrectPanel(id controller){
 if(GSWalkingPanel||!GSControllerBackedUp(controller)||!GSPhotoConfirmsOriginal(GSGet(GSGet(controller,@"extendedPhoto"),@"serverPhoto")))return;
 // The SwiftUI stack re-reads its row models, so they are corrected first. The
 // rows are recorded again here: content set after the factories (device: the
 // backup row had no expandedContent at build time) is only visible now, as
 // are the controller's other content models and its learn-more link table.
 GSCorrectModels(controller,GSGet(controller,@"detailsStackViewModels"),@"layout-rows");
 GSCorrectModels(controller,GSGet(controller,@"infoContentViewModels"),@"info");
 GSRecordRowShape(GSGet(controller,@"localAssetInfoModel"),@"localAssetInfo",1);
 GSRecordRowShape(GSGet(controller,@"stackViewLearnMoreLinks"),@"learnMoreLinks",1);
 id view=GSGet(controller,@"viewIfLoaded");if(!view)return;
 NSString *from=GSNativeQualityText(controller);
 GSRecordPanelText(from?[@"native-quality: " stringByAppendingString:from]:@"native-quality: <none>");
 NSArray *candidates=GSAllCandidates(controller);
 if(!candidates.count)return;
 GSWalkingPanel=YES;GSCount(@"panelWalks");NSUInteger budget=600;
 @try{GSCorrectPanelView(view,candidates,GSL(@"Original quality (original data available)"),0,&budget);}@finally{GSWalkingPanel=NO;}
}
static void GSPanelLayout(id controller,SEL selector){
 GSOriginalPanelLayout(controller,selector);GSCorrectPanel(controller);
}
static void GSSchedulePanelCorrection(id controller){
 __weak id weak=controller;dispatch_async(dispatch_get_main_queue(),^{GSCorrectPanel(weak);});
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
 GSObservedRowClasses=[NSMutableOrderedSet orderedSet];GSPanelTexts=[NSMutableOrderedSet orderedSet];GSRowTexts=[NSMutableOrderedSet orderedSet];GSPanelViewClasses=[NSMutableOrderedSet orderedSet];
 // Inherited from UIViewController; GSReplace shadows it on the details class only.
 if(GSPhotosHasMethod(details,@"viewDidLayoutSubviews","v16@0:8"))GSOriginalPanelLayout=(void *)GSReplace(details,@"viewDidLayoutSubviews",(IMP)GSPanelLayout);
 GSOriginalBackupRow=(void *)GSReplace(details,factory,(IMP)GSBackupRow);
 // The row subtitle enters through these initializers only (no getter exists).
 Class rowModel=NSClassFromString(@"PHSOneUpInfoPanelDetailsStackViewModel");
 if(GSPhotosHasMethod(rowModel,@"initWithTitle:subtitle:","@32@0:8@16@24"))GSOriginalRowInitSubtitle=(void *)GSReplace(rowModel,@"initWithTitle:subtitle:",(IMP)GSRowInitSubtitle);
 if(GSPhotosHasMethod(rowModel,@"initWithTitle:subtitle:icon:","@40@0:8@16@24@32"))GSOriginalRowInitSubtitleIcon=(void *)GSReplace(rowModel,@"initWithTitle:subtitle:icon:",(IMP)GSRowInitSubtitleIcon);
 // Optional: the policy getter is the display source; the rest identify the path.
 if(GSPhotosHasMethod(photo,@"storagePolicy","C16@0:8"))GSOriginalStoragePolicy=(void *)GSReplace(photo,@"storagePolicy",(IMP)GSDisplayStoragePolicy);
 if(GSPhotosHasMethod(photo,@"quotaChargeable","C16@0:8"))GSOriginalQuotaChargeable=(void *)GSReplace(photo,@"quotaChargeable",(IMP)GSDisplayQuotaChargeable);
 if(GSPhotosHasMethod(extended,@"serverStoragePolicy","i16@0:8"))GSOriginalServerStoragePolicy=(void *)GSReplace(extended,@"serverStoragePolicy",(IMP)GSDisplayServerStoragePolicy);
 if(GSPhotosHasMethod(extended,@"needsFullBackup","B16@0:8"))GSOriginalNeedsFullBackup=(void *)GSReplace(extended,@"needsFullBackup",(IMP)GSCountedNeedsFullBackup);
 if(GSPhotosHasMethod(details,@"setDetailsStackViewModels:","v24@0:8@16"))GSOriginalSetStackModels=(void *)GSReplace(details,@"setDetailsStackViewModels:",(IMP)GSSetStackModels);
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
