# Native unlimited storage display (Google Photos iOS 7.92.0)

GoToHP settings → Appearance → **Show unlimited storage** is enabled by default.
The choice is stored in the host app's preferences (`GSShowUnlimitedStorage`). An
absent key means on; an explicit false is preserved across launches. Reopen the
profile menu after changing it. The control is independent of account connection,
upload settings and the queue. English and Japanese settings labels are included.

This is a **display preference**. It does not grant an account benefit, alter
Google's storage accounting, or select upload quality. Turn it off to see the
unmodified account storage card. The legacy UIKit and modern model-title adapters are selected automatically from their required private APIs, independently of the version number. Incompatible APIs leave the native UI unchanged and show the control as unavailable. The two supplied IPA versions are audit references, not an upper-version limit.

## Current resource lookup

The adapters use `OGLBundle.oneGoogleResourceBundle` and the native key `OneGoogleStorageCardUnlimitedTitle` in table `OneGoogle`. They no longer invoke `stringForID:` with a version-specific number. The numbered IDs below describe the original 7.92.0 audit, not a requirement imposed on later versions. If the native bundle/key is unavailable, the display falls back to the original; no translated fallback is substituted for Google's resource.

## Evidence from the supplied IPA

Addresses below are static unslid ARM64 addresses, not runtime hook offsets.
The binaries and their hashes are indexed in [objc/manifest.json](objc/manifest.json).

| Image / location | Verified behavior |
| --- | --- |
| Main `PHSMyAccountMenuDataSource.storageCardData`, `0x1000b63b4` | Returns nil when the card is hidden; otherwise allocates a fresh `OGLAccountMenuStorageCardData`, copies quota values and attaches native action callbacks. |
| Main `0x1000b642c`–`0x1000b6568` | Reads `GMUQuota.isUnlimited` and `unlimitedReason`. Reason 1 maps to storage state 2; other unlimited reasons map to state 3. |
| Framework `OGLAccountSelectorStorageCardCell.updateWithItem:`, `0x1438908` | States 2 and 3 hide the storage progress meter and its information label. Layout, colors, action chips and icons remain native. |
| Framework `+subtitleTextWithStorageItem:`, `0x14397f0` | State 2 requests OneGoogle string ID `0x82` (unlimited subtitle). |
| Framework `+titleTextWithStorageItem:`, `0x143942c` | State 2 still follows the regular/percentage title branch in this build. Merely setting `storageState` does **not** guarantee the requested unlimited title. |
| Framework string table `0x76062d0` / `0x76062d8` | References `OneGoogleStorageCardUnlimitedTitle` / `OneGoogleStorageCardUnlimitedSubtitle`. |
| Framework `OneGoogle.bundle/{ja,en}.lproj/OneGoogle.strings` | Native title: `無制限ストレージ` / `Unlimited storage`; subtitle: `無制限` / `Unlimited`. |

The class methods above are separately inspected through metaclass metadata;
the existing compressed method indices list instance methods only.

## Self-managed card path (fix after PR #13)

The device screenshot after PR #13 still showed `43% of 15 GB used`. The earlier
fixture covered only the Photos-owned source, so its passing result did not cover
the self-managed card path. Further disassembly confirms:

| Image / location | Verified behavior |
| --- | --- |
| Main `PHSMyAccountMenuDataSource.accountMenuCardData`, `0x1000b3aa4` | Adds the legacy backup and storage cards to an array. |
| Framework `OGLAggregatorCardDataSourceImpl` internal getter, `0x13713c8` | Starts with its internal provider's cards. When merging the Photos source, the type check at `0x1371500`–`0x137151c` **excludes OGLAccountMenuStorageCardData** from that source. The class reference is `0x7e1bbd8`. |
| Framework aggregator `accountMenuCardData`, `0x13715ac` | Objective-C bridge returns the final card array after the filter/merge. |
| Framework collapsible/non-collapsible menu view-model builders | Read `accountMenuCardData` through Objective-C dispatch at `0x12f5578`, `0x12f56a8`, `0x12f6c54`. |
| Framework `OGLStringResources.stringForID:`, `0x17b33a0` | Reads the resource table at `0x7605ec8`; index `0x81` references the unlimited title. Uses Google's `oneGoogleResourceBundle` resolver. The argument ABI is **int** (`@20@0:8i16`). |

The screenshot alone does not prove which runtime gate/path fired. The excluded
legacy card is a confirmed coverage gap explaining why changing only the Photos
source cannot cover this mode. The fix also removes the assumption that resources
must resolve through `bundleForClass:` at dylib initialization.

## Rendering boundary and settings jitter (second device report)

The next screenshot still showed the regular meter. The accompanying 9.7-second
recording shows the Appearance section repeatedly moving within the viewport;
it does not establish that the row is removed from the data source. `GSPanel`
unconditionally called `reloadData` after every two-second poll, invalidating its
self-sizing row estimates even when all response values were unchanged.

The settings fix compares snapshots/status before reloading, skips polls or
completions during dragging/tracking/deceleration, and preserves the first
visible row plus its pixel offset when a changed snapshot requires a reload.
Repeated identical error messages also avoid reloading. The UIKit fixture waits
through multiple real timer polls and then changes a response value, asserting
that the switch remains visible and its position is preserved.

Further binary analysis identifies a more direct display boundary:

| Image / address | Verified behavior |
| --- | --- |
| Framework `OGLGM2AccountSelectorViewController.cardSectionsWithData:`, `0x140f234` | Filters card data, then calls `+cardItemFromCardData:` for each displayed card at `0x140f2fc`. Both collapsible and non-collapsible controllers use this path. |
| Framework `OGLGM2AccountSelectorViewModelItemUtils +cardItemFromCardData:`, `0x1411620` | Checks `dataMode`, uses an `isKindOfClass:` check for native storage data, creates a native storage item and copies `storageState` unchanged at `0x14116a0`–`0x14116ac`, followed by counters, subtitle and callbacks. |

The previous exact `object_getClass` checks would reject a native data object
wrapped by a KVO subclass. This is reproducible in the Foundation fixture with a
real `NSKVONotifying_OGLAccountMenuStorageCardData` instance. No runtime diagnostic
JSON accompanied the screenshot, so the device's actual class and skipped path
are **not yet confirmed**.

## Device counters rule out the GM2 renderer (third report)

The supplied `gotohp-upload-diagnostics (1).json` reports version 7.92.0,
`implementation: native-card-renderer-v3`, `available: true`, `enabled: true`,
`status: installed`, but **mapperCalls = cellUpdates = titleCalls = 0** and both
observed class lists empty. The old hooks installed successfully but none of
those render callbacks ran during the captured session. This is not evidence of
failed credential setup, missing resources, or a rejected KVO subclass. The
v3 fixture covered a renderer that did not execute in this device session.

## Bento / SwiftUI evidence from the same IPA

| Framework location | Verified behavior |
| --- | --- |
| `OGLAccountMenuVCFactory.internalCreateAccountMenuVC:incognito:expanded:`, `0x12f237c` | At `0x12f23b8`, tests `bentoAccountMenuEnabled`. The true branch calls `OGLBentoAccountMenuFactory.makeBentoAccountMenuViewController` at `0x12f23d8`, returning before the collapsible/non-collapsible GM2 path. |
| `OGLBentoAccountMenuFactory.makeBentoAccountMenuViewController`, `0x12f476c` | Objective-C factory boundary, encoding `@16@0:8`. It can be passively observed without replacing Google's controller. |
| Swift `StorageCardContent` initializer, `0x1378b70` | Reads the ObjC card model's `storageState` at `0x1378bd8`. State 2 maps to Swift state byte `0x80` at `0x1378bf4`; state 3 maps to `0x82`. It does not call the GM2 converter. |
| Swift title computation, `0x1378d18` | Reads the same model's `title` at `0x1378d48` and uses a non-nil value before falling back to state-based native resources. |
| Swift minimized-card computation, `0x1379424` | States `0x80` and `0x82` return true at `0x137944c`. The compact/unlimited layout remains owned by the native Swift implementation. |
| Embedded source-path string, `0x517a2b0` | `googlemac/iPhone/Shared/OneGoogle/Multiplatform/Cards/StorageCardContent.swift`. |
| `OGLAccountMenuStorageCardData.encodeWithCoder:`, `0x17a3fd4` | Serializes model values through getters, including `storageState` at `0x17a4030`. Display overrides must be suppressed during encoding to avoid persisting a presentation preference as source data. |

The zero counters establish that v3's callbacks did not run. The disassembly
establishes a separate native path; v4's passive Bento factory counter is still
needed to positively identify that path on the user's device.

The attached Android APK (7.92.0.977185651) also contains `Unlimited storage` and
`無制限ストレージ` in its Android resource string pool. This was a resource check,
not a complete decompilation or proof of its runtime eligibility logic. Android
code/resources are not required for the iOS fix and are not included in the repo.

## Current implementation boundary (v4)

The display override now targets **the native ObjC presentation model's getters**
(`OGLAccountMenuStorageCardData.storageState` and `title`). Both the legacy
converter and the Swift `StorageCardContent` initializer read this model, so
support no longer depends on the legacy converter or cell executing.

With the preference enabled and native resources available, reads return state 2
and the native `OGLStringResources` unlimited title. With the preference disabled,
reads immediately return the original implementation's current values. Setters,
backing fields, counters, callbacks, data sources, account quota and upload
behavior are not changed. Native updates to the same cached model are preserved.
No Swift ABI calls, hardcoded runtime offsets, substitute controller, or custom
unlimited label are introduced. The one flag read changed is the self-managed
storage card flag described below, and only while the preference is enabled.

Because the native model supports coding, `encodeWithCoder:` calls the original
implementation with thread-local suppression of these getter overrides. Nested
encodes and exceptions restore that suppression correctly. This prevents an
archive created while enabled from containing the synthetic display state/title.

The legacy title formatter remains an optional compatibility hook. A passive
legacy cell observer and an optional Bento factory observer identify which menu
actually runs. Neither observer controls availability of the common model hook.
Version and method ABIs are checked before installing the model hooks.

Diagnostics use `implementation: native-display-model-v4` and report model read /
display override counts, native/display states, archive calls, Bento controller
creation, legacy cell/title calls, native resource readiness, and bounded class
names. They do not include titles, storage amounts, accounts, tokens, object
descriptions or media. In the Bento path, zero legacy-cell calls is expected;
model reads and the Bento observer are the relevant counters.

## Validation and remaining device check

`tests/unlimited_storage.swift` is compiled against an imported Objective-C
fixture model, exercising **Swift-to-ObjC getter dispatch** without any GM2
converter. The Foundation fixture runs with legacy classes present and with
both legacy classes absent (`bento-only`). It also checks real KVO subclasses,
late resource availability, unchanged backing fields/callbacks/counters,
secure archive round trips, exception-safe coder suppression, and native updates
followed by on/off restoration. A separate invocation checks incompatible ABI
rejection. The existing UIKit polling test and all package builds remain enabled.

These fixtures do not execute Google's proprietary SwiftUI view. On device,
reopen the profile menu after toggling and check both title/layout and native
actions. If unchanged, export fresh diagnostics **after opening the menu**;
`modelStateReads`, `modelTitleReads`, `bentoControllers` and resource readiness
will distinguish the next failure without relying on another screenshot guess.

## User-confirmed device display (2026-09-13)

After installing v4, the user confirmed that the unlimited card appeared and
provided the [native card screenshot](../images/unlimited-storage.png) and
[enabled appearance setting](../images/appearance-settings.png), now included in
the READMEs. This confirms the displayed result in that user's setup. It does not
establish account entitlement, quota treatment, all signing environments, or a
complete on/off and native-action device test matrix.

## Self-managed flag and the missing Bento card (device report, 7.92.0)

On the reporting device the Photos source builds the card
(`storageCardCalls = storageCardNonNil = 3`, `menuCards` contains
`photos:OGLAccountMenuStorageCardData`) and the Bento aggregator refreshes
(`aggregatorRefreshes = 2`), yet nothing renders (`modelStateReads = 0`,
`cardClasses = []`). The Google One storage service never initializes
(`serviceInits = 0`), and the aggregator's ObjC `accountMenuCardData` bridge is
not read (`aggregatorCardReads = 0`): Bento reads the Swift getter that excludes
the Photos storage card (see "Self-managed card path" above). The menu is left
with no storage card from either source.

The framework exposes `PhenotypeDeviceFlagBaseImpl.enableSelfManagedStorageCard`
(`0x1da208`) and the Phenotype getter
`OGLPHTDeviceDynamicImpl.StorageCard__enable_self_managed_storage_card`. The
working hypothesis is that this flag selects the Google One card and gates the
exclusion. While the preference is enabled both getters return NO, keeping the
native Photos card so the model getters above can display it. Disabling the
preference returns the native value. The link between the flag and the filter is
**not yet confirmed on a device**; `selfManagedCard` in diagnostics records read
counts, native values and overrides for both getters so the next report either
confirms it or rules it out.
