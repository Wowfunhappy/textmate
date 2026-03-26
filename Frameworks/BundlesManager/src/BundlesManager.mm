#import "BundlesManager.h"
#import <bundles/load.h>
#import "InstallBundleItems.h"
#import <OakAppKit/NSAlert Additions.h>
#import <OakFoundation/NSDate Additions.h>
#import <OakFoundation/NSString Additions.h>
#import <network/network.h>
#import <network/download_tbz.h>
#import <bundles/locations.h>
#import <bundles/query.h> // set_index
#import <regexp/format_string.h>
#import <text/ctype.h>
#import <text/decode.h>
#import <ns/ns.h>
#import <io/path.h>
#import <io/entries.h>
#import <io/events.h>
#import <oak/debug.h>

OAK_DEBUG_VAR(BundlesManager);
OAK_DEBUG_VAR(BundlesManager_FSEvents);

static char const* kBundleAttributeUpdated = "org.textmate.bundle.updated";


@interface BundlesManager ()
{
	std::vector<std::string> bundlesPaths;
	std::string bundlesIndexPath;
	std::set<std::string> watchList;
	plist::cache_t cache;
}
@property (nonatomic) BOOL      determinateProgress;
@property (nonatomic) CGFloat   progress;
@property (nonatomic) BOOL      needsCreateBundlesIndex;
@property (nonatomic) BOOL      needsSaveBundlesIndex;

@property (nonatomic) NSArray<Bundle*>* bundles;
@property (nonatomic) NSString* installDirectory;
@property (nonatomic) NSString* localIndexPath;
@end

@implementation BundlesManager
+ (instancetype)sharedInstance
{
	static BundlesManager* sharedInstance = [self new];
	return sharedInstance;
}

- (id)init
{
	if(self = [super init])
	{
		_installDirectory = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:@"TextMate/Managed"];
		_localIndexPath   = [_installDirectory stringByAppendingPathComponent:@"LocalIndex.plist"];

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:NSApp];
	}
	return self;
}


- (void)applicationWillTerminate:(NSNotification*)aNotification
{
	D(DBF_BundlesManager, bug("\n"););
	if(self.needsSaveBundlesIndex)
		[self saveBundlesIndex:self];
}

- (void)installBundleItemsAtPaths:(NSArray*)somePaths
{
	InstallBundleItems(somePaths);
}

- (BOOL)findBundleForInstall:(bundles::item_ptr*)res
{
	oak::uuid_t defaultBundle;

	std::string const personalBundleName = format_string::expand("${TM_FULLNAME/^(\\S+).*$/$1/}’s Bundle", std::map<std::string, std::string>{ { "TM_FULLNAME", path::passwd_entry()->pw_gecos ?: "John Doe" } });
	for(auto item : bundles::query(bundles::kFieldName, personalBundleName, scope::wildcard, bundles::kItemTypeBundle))
		defaultBundle = item->uuid();

	NSPopUpButton* bundleChooser = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	[bundleChooser.menu removeAllItems];
	[bundleChooser.menu addItemWithTitle:@"Create new bundle…" action:NULL keyEquivalent:@""];
	[bundleChooser.menu addItem:[NSMenuItem separatorItem]];

	std::multimap<std::string, bundles::item_ptr, text::less_t> ordered;
	for(auto item : bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, bundles::kItemTypeBundle))
		ordered.emplace(item->name(), item);

	for(auto pair : ordered)
	{
		NSMenuItem* menuItem = [bundleChooser.menu addItemWithTitle:[NSString stringWithCxxString:pair.first] action:NULL keyEquivalent:@""];
		[menuItem setRepresentedObject:[NSString stringWithCxxString:to_s(pair.second->uuid())]];
		if(defaultBundle && defaultBundle == pair.second->uuid())
			[bundleChooser selectItem:menuItem];
	}

	[bundleChooser sizeToFit];
	NSRect frame = [bundleChooser frame];
	if(NSWidth(frame) > 200)
		[bundleChooser setFrameSize:NSMakeSize(200, NSHeight(frame))];

	NSAlert* alert = [NSAlert tmAlertWithMessageText:@"Select Bundle" informativeText:@"Select the bundle which should be used for the new item(s)." buttons:@"OK", @"Cancel", nil];
	[alert setAccessoryView:bundleChooser];
	if([alert runModal] == NSAlertFirstButtonReturn) // "OK"
	{
		if(NSString* bundleUUID = [[bundleChooser selectedItem] representedObject])
		{
			for(auto item : bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, bundles::kItemTypeBundle, to_s(bundleUUID)))
			{
				*res = item;
				return YES;
			}
		}
		else
		{
			NSAlert* alert        = [[NSAlert alloc] init];
			alert.messageText     = @"Creating bundles is not yet supported.";
			alert.informativeText = @"You can create a new bundle in the bundle editor via File → New (⌘N) and then repeat the previous action.";
			[alert addButtonWithTitle:@"OK"];
			[alert runModal];
		}
	}
	return NO;
}

- (void)installBundles:(NSArray<Bundle*>*)someBundles completionHandler:(void(^)(NSArray<Bundle*>*))callback
{
	// Remote bundle installation removed — all bundles ship pre-installed
	if(callback)
		callback(@[]);
}

- (void)uninstallBundle:(Bundle*)bundle
{
	bundle.installed = NO;
	if(!bundle.path || ![[NSFileManager defaultManager] removeItemAtPath:bundle.path error:nil])
		return;

	[self erasePath:bundle.path];

	bundle.path        = nil;
	bundle.lastUpdated = nil;

	// TODO Remove bundle’s dependencies

	[self saveLocalIndex];
}

// ===============================================
// = Creating Bundle Index and Handling FSEvents =
// ===============================================

- (void)createBundlesIndex:(id)sender
{
	D(DBF_BundlesManager, bug("%s\n", BSTR(_needsCreateBundlesIndex)););
	if(_needsCreateBundlesIndex == NO)
		return;
	_needsCreateBundlesIndex = NO;

	auto pair = create_bundle_index(bundlesPaths, cache);
	bundles::set_index(pair.first, pair.second);

	std::set<std::string> newWatchList;
	for(auto path : bundlesPaths)
		cache.copy_heads_for_path(path, std::inserter(newWatchList, newWatchList.end()));
	[self updateWatchList:newWatchList];
}

- (void)saveBundlesIndex:(id)sender
{
	D(DBF_BundlesManager, bug("\n"););
	cache.cleanup(bundlesPaths);
	if(cache.dirty())
	{
		cache.save_capnp(bundlesIndexPath);
		cache.set_dirty(false);
	}
	_needsSaveBundlesIndex = NO;
}

- (void)setNeedsCreateBundlesIndex:(BOOL)flag
{
	D(DBF_BundlesManager, bug("%s\n", BSTR(flag)););
	if(_needsCreateBundlesIndex != flag && (_needsCreateBundlesIndex = flag))
		[self performSelector:@selector(createBundlesIndex:) withObject:self afterDelay:0];
}

- (void)setNeedsSaveBundlesIndex:(BOOL)flag
{
	D(DBF_BundlesManager, bug("%s\n", BSTR(flag)););
	if(_needsSaveBundlesIndex != flag && (_needsSaveBundlesIndex = flag))
		[self performSelector:@selector(saveBundlesIndex:) withObject:self afterDelay:5];
}

- (void)setEventId:(uint64_t)anEventId forPath:(NSString*)aPath
{
	cache.set_event_id_for_path(anEventId, to_s(aPath));
	self.needsSaveBundlesIndex = YES;
}

- (void)updateWatchList:(std::set<std::string> const&)newWatchList
{
	struct callback_t : fs::event_callback_t
	{
		void set_replaying_history (bool flag, std::string const& observedPath, uint64_t eventId)
		{
			D(DBF_BundlesManager_FSEvents, bug("%s (observing ‘%s’)\n", BSTR(flag), observedPath.c_str()););
			[[BundlesManager sharedInstance] setEventId:eventId forPath:[NSString stringWithCxxString:observedPath]];
		}

		void did_change (std::string const& path, std::string const& observedPath, uint64_t eventId, bool recursive)
		{
			D(DBF_BundlesManager_FSEvents, bug("%s (observing ‘%s’)\n", path.c_str(), observedPath.c_str()););
			[[BundlesManager sharedInstance] reloadPath:[NSString stringWithCxxString:path] recursive:recursive];
			[[BundlesManager sharedInstance] setEventId:eventId forPath:[NSString stringWithCxxString:observedPath]];
		}
	};

	static callback_t callback;

	std::vector<std::string> pathsAdded, pathsRemoved;
	std::set_difference(watchList.begin(), watchList.end(), newWatchList.begin(), newWatchList.end(), back_inserter(pathsRemoved));
	std::set_difference(newWatchList.begin(), newWatchList.end(), watchList.begin(), watchList.end(), back_inserter(pathsAdded));

	watchList = newWatchList;

	for(auto path : pathsRemoved)
	{
		D(DBF_BundlesManager_FSEvents, bug("unwatch ‘%s’\n", path.c_str()););
		fs::unwatch(path, &callback);
	}

	for(auto path : pathsAdded)
	{
		D(DBF_BundlesManager_FSEvents, bug("watch ‘%s’\n", path.c_str()););
		fs::watch(path, &callback, cache.event_id_for_path(path) ?: FSEventsGetCurrentEventId(), 1);
	}
}

- (void)erasePath:(NSString*)aPath
{
	D(DBF_BundlesManager, bug("%s\n", [aPath UTF8String]););
	if(cache.erase(to_s(aPath)))
	{
		self.needsCreateBundlesIndex = YES;
		self.needsSaveBundlesIndex   = YES;
	}
	else
	{
		D(DBF_BundlesManager, bug("no changes\n"););
	}
}

- (void)reloadPath:(NSString*)aPath
{
	[self reloadPath:aPath recursive:NO];
}

- (void)reloadPath:(NSString*)aPath recursive:(BOOL)flag
{
	D(DBF_BundlesManager, bug("%s\n", [aPath UTF8String]););
	if(cache.reload(to_s(aPath), flag))
	{
		self.needsCreateBundlesIndex = YES;
		self.needsSaveBundlesIndex   = YES;
	}
	else
	{
		D(DBF_BundlesManager, bug("no changes\n"););
	}
}

namespace
{
	static std::string const kFieldChangedItems = "changed";
	static std::string const kFieldDeletedItems = "deleted";
	static std::string const kFieldMainMenu     = "mainMenu";

	static plist::dictionary_t prune_dictionary (plist::dictionary_t const& plist)
	{
		static auto const DesiredKeys = new std::set<std::string>{ bundles::kFieldName, bundles::kFieldKeyEquivalent, bundles::kFieldTabTrigger, bundles::kFieldScopeSelector, bundles::kFieldSemanticClass, bundles::kFieldContentMatch, bundles::kFieldGrammarFirstLineMatch, bundles::kFieldGrammarScope, bundles::kFieldGrammarInjectionSelector, bundles::kFieldDropExtension, bundles::kFieldGrammarExtension, bundles::kFieldSettingName, bundles::kFieldHideFromUser, bundles::kFieldIsDeleted, bundles::kFieldIsDisabled, bundles::kFieldRequiredItems, bundles::kFieldUUID, bundles::kFieldIsDelta, kFieldMainMenu, kFieldDeletedItems, kFieldChangedItems };

		plist::dictionary_t res;
		for(auto pair : plist)
		{
			if(DesiredKeys->find(pair.first) == DesiredKeys->end() && pair.first.find(bundles::kFieldSettingName) != 0)
				continue;

			if(pair.first == bundles::kFieldSettingName)
			{
				if(plist::dictionary_t const* dictionary = boost::get<plist::dictionary_t>(&pair.second))
				{
					plist::array_t settings;
					for(auto const& settingsPair : *dictionary)
						settings.push_back(settingsPair.first);
					res.emplace(pair.first, settings);
				}
			}
			else if(pair.first == kFieldChangedItems)
			{
				if(plist::dictionary_t const* dictionary = boost::get<plist::dictionary_t>(&pair.second))
					res.emplace(pair.first, prune_dictionary(*dictionary));
			}
			else
			{
				res.insert(pair);
			}
		}
		return res;
	}
}

- (void)moveAvianBundles
{
	NSFileManager* fm = [NSFileManager defaultManager];

	NSMutableArray* moves = [NSMutableArray array];
	NSMutableString* moveDescription = [NSMutableString string];

	for(NSString* path in NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask|NSLocalDomainMask, YES))
	{
		for(NSString* dir in @[ @"", @"Pristine Copy" ])
		{
			NSString* textMateFolder = [NSString pathWithComponents:@[ path, @"TextMate", dir ]];
			NSString* avianFolder    = [NSString pathWithComponents:@[ path, @"Avian", dir ]];
			NSString* src = [avianFolder stringByAppendingPathComponent:@"Bundles"];
			NSString* dst = [textMateFolder stringByAppendingPathComponent:@"Bundles"];

			if([fm fileExistsAtPath:src] == NO)
				continue;

			if([fm fileExistsAtPath:dst] == YES)
			{
				[moves addObject:@[ dst, [dst stringByAppendingString:@"-1.x"] ]];
				[moveDescription appendFormat:@"Rename “Bundles” at “%@” to “Bundles-1.x” (backup).\n", [textMateFolder stringByAbbreviatingWithTildeInPath]];
			}

			[moves addObject:@[ src, dst ]];
			[moveDescription appendFormat:@"Move “Bundles” at “%@” to “%@”.\n", [avianFolder stringByAbbreviatingWithTildeInPath], [textMateFolder stringByAbbreviatingWithTildeInPath]];
		}
	}

	if(moves.count == 0)
		return;

	NSAlert* alert = [[NSAlert alloc] init];
	alert.alertStyle      = NSAlertStyleInformational;
	alert.messageText     = @"Move Bundles?";
	alert.informativeText = [NSString stringWithFormat:@"Bundles are no longer read from the “Avian” folder. Would you like to move the following items:\n\n%@", moveDescription];
	[alert addButtonWithTitle:@"Move Bundles"];
	[alert addButtonWithTitle:@"Cancel"];
	if([alert runModal] != NSAlertFirstButtonReturn)
		return;

	for(NSArray* move in moves)
	{
		NSError* err;

		NSString* dstFolder = [move.lastObject stringByDeletingLastPathComponent];
		if([fm fileExistsAtPath:dstFolder] || [fm createDirectoryAtPath:dstFolder withIntermediateDirectories:YES attributes:nil error:&err])
		{
			if([fm moveItemAtPath:move.firstObject toPath:move.lastObject error:&err])
				continue;
		}

		[[NSAlert alertWithError:err] runModal];
		break;
	}
}

- (void)loadBundlesIndex
{
	// LEGACY locations used by 2.0-beta.12.22 and earlier
	[self moveAvianBundles];

	for(auto path : bundles::locations())
		bundlesPaths.push_back(path::join(path, "Bundles"));
	bundlesIndexPath = path::join(path::home(), "Library/Caches/com.macromates.TextMate/BundlesIndex.binary");
	cache.set_content_filter(&prune_dictionary);

	// LEGACY bundle index used prior to 2.0-alpha.9467
	std::string const oldPath = path::join(path::home(), "Library/Caches/com.macromates.TextMate/BundlesIndex.plist");
	if(access(oldPath.c_str(), R_OK) == 0)
	{
		cache.load(oldPath);
		cache.save_capnp(bundlesIndexPath);
		unlink(oldPath.c_str());
	}
	else
	{
		cache.load_capnp(bundlesIndexPath);
	}

	_needsCreateBundlesIndex = YES;
	[self createBundlesIndex:self];
}

namespace
{
	static NSArray<Bundle*>* BundlesFromIndex (NSString* localIndexPath, NSString* installDir, NSDictionary<NSUUID*, Bundle*>* cache = nil)
	{
		NSMutableDictionary* res = [NSMutableDictionary dictionary];

		// ====================
		// = Load Local Index =
		// ====================

		for(NSDictionary* item in [[NSDictionary dictionaryWithContentsOfFile:localIndexPath] objectForKey:@"bundles"])
		{
			NSUUID* identifier = [[NSUUID alloc] initWithUUIDString:item[@"uuid"]];
			Bundle* bundle = res[identifier] ?: [[Bundle alloc] initWithIdentifier:identifier];

			bundle.installed   = YES;
			bundle.path        = [installDir stringByAppendingPathComponent:item[@"path"]];
			bundle.category    = item[@"category"] ?: bundle.category ?: @"Discontinued";
			bundle.lastUpdated = item[@"updated"];
			bundle.dependency  = [item[@"isDependency"] boolValue];

			res[bundle.identifier] = bundle;
		}

		// ========================
		// = Load Bundles on Disk =
		// ========================

		NSMutableDictionary* bundlesByPath = [NSMutableDictionary dictionary];
		for(Bundle* bundle in [res allValues])
		{
			if(bundle.path)
				bundlesByPath[bundle.path] = bundle;
		}

		NSMutableSet* scannedDirs = [NSMutableSet set];
		NSMutableArray* bundlesDirs = [NSMutableArray arrayWithObject:[installDir stringByAppendingPathComponent:@"Bundles"]];
		for(auto const& location : bundles::locations())
			[bundlesDirs addObject:[NSString stringWithCxxString:path::join(location, "Bundles")]];

		for(NSString* bundlesDir in bundlesDirs)
		{
			if([scannedDirs containsObject:bundlesDir] || ![[NSFileManager defaultManager] fileExistsAtPath:bundlesDir])
				continue;
			[scannedDirs addObject:bundlesDir];

			for(auto const& entry : path::entries(to_s(bundlesDir), "*.tm[Bb]undle"))
			{
				NSString* bundlePath = [bundlesDir stringByAppendingPathComponent:to_ns(entry->d_name)];
				if(Bundle* bundle = [bundlesByPath objectForKey:bundlePath])
				{
					[bundlesByPath removeObjectForKey:bundlePath];
					if(bundle.downloadURL) // We have category, description etc. from remote index
						continue;
				}

				if(NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"info.plist"]])
				{
					NSUUID* identifier = [[NSUUID alloc] initWithUUIDString:info[@"uuid"]];
					Bundle* bundle = res[identifier] ?: [[Bundle alloc] initWithIdentifier:identifier];

					bundle.installed    = YES;
					bundle.path         = bundlePath;
					bundle.category     = bundle.category     ?: @"Orphaned";
					bundle.name         = bundle.name         ?: info[@"name"];
					bundle.contactName  = bundle.contactName  ?: info[@"contactName"];
					bundle.contactEmail = bundle.contactEmail ?: to_ns(decode::rot13(to_s(info[@"contactEmailRot13"])));
					bundle.summary      = bundle.summary      ?: info[@"description"];

					NSDateFormatter* dateFormatter = [[NSDateFormatter alloc] init];
					dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss ZZZZZ";
					if(NSString* str = to_ns(path::get_attr(to_s(bundlePath), kBundleAttributeUpdated)))
						bundle.lastUpdated = [dateFormatter dateFromString:str];

					res[bundle.identifier] = bundle;
				}
			}
		}

		for(Bundle* bundle in [bundlesByPath allValues])
			bundle.installed = NO;

		return [[res allValues] sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCompare:)] ]];
	}
}

- (NSArray<Bundle*>*)bundles
{
	if(!_bundles)
		_bundles = [self bundlesByLoadingIndex];
	return _bundles;
}

- (NSArray<Bundle*>*)bundlesByLoadingIndex
{
	NSMutableDictionary* previousBundles = [NSMutableDictionary dictionary];
	for(Bundle* bundle : _bundles)
		previousBundles[bundle.identifier] = bundle;
	return BundlesFromIndex(_localIndexPath, _installDirectory, previousBundles);
}

- (void)saveLocalIndex
{
	if(!_bundles)
		return;

	NSMutableArray* bundles = [NSMutableArray array];
	for(Bundle* bundle : [_bundles filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isInstalled == YES AND path != NULL"]])
	{
		NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithDictionary:@{
			@"uuid": [bundle.identifier UUIDString],
			@"path": [bundle.path stringByReplacingOccurrencesOfString:[_installDirectory stringByAppendingString:@"/"] withString:@""],
		}];

		if(bundle.lastUpdated)
			dict[@"updated"]  = bundle.lastUpdated;
		if(bundle.isDependency)
			dict[@"isDependency"] = @YES;
		if(bundle.category)
			dict[@"category"] = bundle.category;

		[bundles addObject:dict];
	}

	NSDictionary* plist = @{ @"bundles": bundles };
	[plist writeToFile:_localIndexPath atomically:YES];
}
@end
