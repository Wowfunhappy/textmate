#import "TMDocument.h"
#import "TMDocumentRegistry.h"
#import "TMWindowController.h"
#import "OakDocumentController.h"
#import "OakDocument Private.h"
#import <oak/debug.h>
#import <oak/algorithm.h>
#import <file/encoding.h>
#import <file/bytes.h>
#import <text/newlines.h>
#import <ns/ns.h>

OAK_DEBUG_VAR(TMDocument);

@interface TMDocument ()
@property (nonatomic, readwrite) OakDocument* oakDocument;
@property (nonatomic, readwrite) TMWindowController* tmWindowController;
@property (nonatomic) BOOL reloading;
@property (nonatomic) NSTimer* autosaveTimer;
@property (nonatomic) NSDate* lastVersionDate;
@property (nonatomic) BOOL performingIdleAutosave;
@property (nonatomic) BOOL performingRevert;

// Session checkpoints for the “Revert To” submenu. These exist because we drive
// autosave straight to the document's file (see -idleAutosaveFired:), so the
// live file is *not* a meaningful "last saved" state — it's whatever the most
// recent idle autosave wrote. Native autosave-in-place reverts to a checkpoint
// in the Versions store rather than to the live bytes; we reproduce that with
// two in-memory snapshots of the buffer (held only for the session, matching
// the semantics of "Last Saved"/"Last Opened").
@property (nonatomic, copy) NSString* openedContentSnapshot; // disk state we opened/last reloaded from
@property (nonatomic, copy) NSString* savedContentSnapshot;  // content of the last *explicit* (⌘S) save; nil until one happens
@property (nonatomic) NSDate* openedContentDate;            // when openedContentSnapshot was captured (shown greyed in the menu)
@property (nonatomic) NSDate* savedContentDate;             // when savedContentSnapshot was captured
@end

// Private AppKit hook that NSDocument's own Revert-To items use to give a menu
// item a second, white title that the menu swaps in while the item is highlighted.
// Without it the greyed timestamp stays grey on the blue selection. Present on the
// 10.9 target (verified in AppKit); guarded with -respondsToSelector: at the call.
@interface NSMenuItem (TMRevertAlternateTitle)
- (void)_setAlternateAttributedTitle:(NSAttributedString*)title;
@end

@implementation TMDocument

+ (BOOL)autosavesInPlace
{
	// Deliberately NO. Autosave-in-place engages NSDocument's coordinated-save
	// and presented-item machinery, which deadlocks/crashes against OakDocument's
	// own file ownership (its kqueue watcher, undo, and save path). We instead
	// drive autosave ourselves on an idle timer (see -scheduleIdleAutosave) and
	// author revisions explicitly via NSFileVersion. The native Versions browser
	// still works because +preservesVersions remains YES (verified on 10.9).
	return NO;
}

+ (BOOL)preservesVersions
{
	return YES;
}

+ (BOOL)autosavesDrafts
{
	return YES;
}

+ (NSArray<NSString*>*)readableTypes
{
	// TMDocument can read any text file - return the main UTI we handle
	return @[@"public.plain-text", @"public.text", @"public.data"];
}

+ (NSArray<NSString*>*)writableTypes
{
	return @[@"public.plain-text", @"public.text", @"public.data"];
}

+ (BOOL)isNativeType:(NSString*)type
{
	return YES;
}

+ (NSTimeInterval)autosavingDelay
{
	// Autosave after 5 seconds of inactivity (default is longer)
	return 5.0;
}

// Override to handle document opening via NSDocumentController
- (instancetype)initWithContentsOfURL:(NSURL*)url ofType:(NSString*)typeName error:(NSError**)outError
{
	D(DBF_TMDocument, bug("url=%s type=%s\n", url.path.UTF8String, typeName.UTF8String););

	// Create the OakDocument for this file
	OakDocument* oakDoc = [OakDocument documentWithPath:url.path];
	if(!oakDoc)
	{
		if(outError)
			*outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil];
		return nil;
	}

	// Check if we already have a TMDocument wrapper for this OakDocument
	TMDocument* existing = [[TMDocumentRegistry sharedRegistry] documentForOakDocument:oakDoc];
	if(existing && existing != self)
	{
		// Return the existing wrapper
		return existing;
	}

	return [self initWithOakDocument:oakDoc];
}

- (instancetype)initForURL:(NSURL*)urlOrNil withContentsOfURL:(NSURL*)contentsURL ofType:(NSString*)typeName error:(NSError**)outError
{
	D(DBF_TMDocument, bug("url=%s contentsURL=%s type=%s\n", urlOrNil.path.UTF8String, contentsURL.path.UTF8String, typeName.UTF8String););
	return [self initWithContentsOfURL:contentsURL ofType:typeName error:outError];
}

+ (instancetype)documentForOakDocument:(OakDocument*)oakDocument
{
	return [[TMDocumentRegistry sharedRegistry] documentForOakDocument:oakDocument];
}

- (instancetype)initWithOakDocument:(OakDocument*)oakDocument
{
	if(self = [super init])
	{
		D(DBF_TMDocument, bug("wrap %s\n", oakDocument.displayName.UTF8String););
		_oakDocument = oakDocument;

		if(oakDocument.path)
			self.fileURL = [NSURL fileURLWithPath:oakDocument.path];

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(oakDocumentContentDidChange:) name:OakDocumentContentDidChangeNotification object:oakDocument];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(oakDocumentDidSave:) name:OakDocumentDidSaveNotification object:oakDocument];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(oakDocumentDidReload:) name:OakDocumentDidReloadNotification object:oakDocument];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(oakDocumentWillClose:) name:OakDocumentWillCloseNotification object:oakDocument];


		[oakDocument addObserver:self forKeyPath:@"path" options:NSKeyValueObservingOptionNew context:nullptr];
		[oakDocument addObserver:self forKeyPath:@"loaded" options:NSKeyValueObservingOptionNew context:nullptr];

		// If the document is already loaded, KVO on "loaded" won't fire, so grab
		// the opened-state baseline now.
		if(oakDocument.isLoaded)
			[self captureOpenedContentSnapshot];

		// Register with NSDocumentController for autosaving to work
		[[NSDocumentController sharedDocumentController] addDocument:self];
	}
	return self;
}

- (void)dealloc
{
	D(DBF_TMDocument, bug("unwrap %s\n", _oakDocument.displayName.UTF8String););
	[_autosaveTimer invalidate];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[_oakDocument removeObserver:self forKeyPath:@"path"];
	[_oakDocument removeObserver:self forKeyPath:@"loaded"];
}

// MARK: - KVO

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if([keyPath isEqualToString:@"path"])
	{
		NSString* path = self.oakDocument.path;
		self.fileURL = path ? [NSURL fileURLWithPath:path] : nil;
		D(DBF_TMDocument, bug("path changed: %s\n", path.UTF8String););
	}
	else if([keyPath isEqualToString:@"loaded"])
	{
		if(self.oakDocument.isLoaded)
			[self captureOpenedContentSnapshot];
	}
}

// MARK: - Revert Checkpoints

- (void)captureOpenedContentSnapshot
{
	// The buffer equals the on-disk content right after a load/reload, so this is
	// the state we opened from. Capture it only once per load; explicit saves move
	// the separate "Last Saved" checkpoint, not this one.
	if(self.oakDocument.isLoaded)
	{
		self.openedContentSnapshot = self.oakDocument.content;
		self.openedContentDate     = [NSDate date];
	}
}

- (void)setFileURL:(NSURL*)url
{
	[super setFileURL:url];
	// When NSDocument changes the URL itself (Rename… / Move To…), propagate to
	// OakDocument. -[OakDocument setPath:] only repoints the logical path; the
	// file has already been moved on disk by NSDocument. The path→fileURL KVO
	// sets the same value back, where setPath early-returns, so there's no loop.
	NSString* path = url.filePathURL.path;
	if(path && ![self.oakDocument.path isEqualToString:path])
		self.oakDocument.path = path;
}

// MARK: - OakDocument Notification Handlers

- (void)oakDocumentContentDidChange:(NSNotification*)notification
{
	D(DBF_TMDocument, bug("%s reloading=%d\n", self.oakDocument.displayName.UTF8String, _reloading););
	if(!_reloading)
	{
		[self updateChangeCount:NSChangeDone];
		[self scheduleIdleAutosave];
	}
}

// MARK: - Idle Autosave (replaces NSDocument autosave-in-place)

- (void)scheduleIdleAutosave
{
	// Only autosave documents that have a backing file; untitled documents are
	// handled by crash-recovery drafts (NSAutosaveElsewhereOperation).
	if(!self.fileURL || _reloading)
		return;

	[self.autosaveTimer invalidate];
	self.autosaveTimer = [NSTimer scheduledTimerWithTimeInterval:[[self class] autosavingDelay] target:self selector:@selector(idleAutosaveFired:) userInfo:nil repeats:NO];
}

- (void)cancelIdleAutosave
{
	[self.autosaveTimer invalidate];
	self.autosaveTimer = nil;
}

- (void)idleAutosaveFired:(NSTimer*)timer
{
	self.autosaveTimer = nil;
	if(!self.fileURL || _reloading || !self.oakDocument.isDocumentEdited)
		return;

	D(DBF_TMDocument, bug("%s\n", self.oakDocument.displayName.UTF8String););
	_performingIdleAutosave = YES;
	[self saveToURL:self.fileURL ofType:self.fileType forSaveOperation:NSSaveOperation completionHandler:^(NSError* errorOrNil){
		_performingIdleAutosave = NO;
		if(errorOrNil)
			D(DBF_TMDocument, bug("idle autosave failed: %s\n", errorOrNil.localizedDescription.UTF8String););
	}];
}

- (void)preserveVersionOfURL:(NSURL*)url
{
	if(!url)
		return;
	// Author a revision in the same store the native Versions browser reads.
	// Option 0 == copy (NSFileVersionAddingByMoving would move the live file).
	NSError* error = nil;
	if(![NSFileVersion addVersionOfItemAtURL:url withContentsOfURL:url options:0 error:&error])
		D(DBF_TMDocument, bug("addVersion failed: %s\n", error.localizedDescription.UTF8String););
}

- (void)oakDocumentDidSave:(NSNotification*)notification
{
	D(DBF_TMDocument, bug("%s\n", self.oakDocument.displayName.UTF8String););
	// Update file modification date so Versions can snapshot the new state
	if(self.fileURL)
	{
		[self.fileURL removeCachedResourceValueForKey:NSURLContentModificationDateKey];
		NSDate* modDate = nil;
		[self.fileURL getResourceValue:&modDate forKey:NSURLContentModificationDateKey error:nil];
		if(modDate)
			self.fileModificationDate = modDate;
	}
	[self updateChangeCount:NSChangeCleared];

	// This notification is posted only by OakDocument's own save path — the first
	// save of an untitled document, Save As, Save All, save-on-close — all of which
	// bypass -saveToURL:…. Capture the explicit-save checkpoint here too. Idle
	// autosaves write through -saveToURL: and never post this, so they can't move it.
	if(!_performingRevert && self.oakDocument.isLoaded)
	{
		self.savedContentSnapshot = self.oakDocument.content;
		self.savedContentDate     = [NSDate date];
	}
}

- (void)oakDocumentDidReload:(NSNotification*)notification
{
	D(DBF_TMDocument, bug("%s\n", self.oakDocument.displayName.UTF8String););
	// OakDocument's kqueue watcher detected an external change and reloaded
	// the content. Update NSDocument's modification date so it doesn't think
	// there's a conflict when it next tries to save.
	if(self.fileURL)
	{
		[self.fileURL removeCachedResourceValueForKey:NSURLContentModificationDateKey];
		NSDate* modDate = nil;
		[self.fileURL getResourceValue:&modDate forKey:NSURLContentModificationDateKey error:nil];
		if(modDate)
			self.fileModificationDate = modDate;
	}
	if(!self.oakDocument.isDocumentEdited)
		[self updateChangeCount:NSChangeCleared];

	// An *external* reload re-baselines us to the new on-disk content: that's the
	// state we're now editing from, and any prior explicit save is stale. (Our own
	// revert posts this same notification with _reloading == YES — skip those, or
	// reverting would overwrite the checkpoint we just reverted to.)
	if(!_reloading)
	{
		[self captureOpenedContentSnapshot];
		self.savedContentSnapshot = nil;
		self.savedContentDate     = nil;
	}
}

- (void)oakDocumentWillClose:(NSNotification*)notification
{
	D(DBF_TMDocument, bug("%s\n", self.oakDocument.displayName.UTF8String););
	[self cancelIdleAutosave];
	// Prevent self from being deallocated during removeDocument:
	// as NSDocumentController may access our properties (e.g. autosavedContentsFileURL)
	TMDocument* __attribute__((objc_precise_lifetime)) ref = self;
	[[NSNotificationCenter defaultCenter] removeObserver:self name:OakDocumentWillCloseNotification object:nil];
	[[NSDocumentController sharedDocumentController] removeDocument:self];
	[[TMDocumentRegistry sharedRegistry] unregisterOakDocument:self.oakDocument];
}

// MARK: - NSDocument Overrides

- (NSString*)displayName
{
	return self.oakDocument.displayName;
}

- (NSString*)fileType
{
	return self.oakDocument.fileType ?: @"public.plain-text";
}

- (NSString*)fileNameExtensionForType:(NSString*)typeName saveOperation:(NSSaveOperationType)saveOperation
{
	// TextMate uses scope names (e.g., "source.ruby") as file types, not UTIs.
	// Return the actual file extension so NSDocument's Versions system can
	// create temporary files without crashing on nil extensions.
	NSString* ext = self.fileURL.pathExtension;
	return ext.length > 0 ? ext : @"txt";
}

- (BOOL)isDocumentEdited
{
	// Check both OakDocument's state and NSDocument's change count
	// This handles cases like duplicated documents that have NSDocument changes but OakDocument thinks it's saved
	return self.oakDocument.isDocumentEdited || [super isDocumentEdited];
}

- (BOOL)hasUnautosavedChanges
{
	return self.oakDocument.isDocumentEdited || [super hasUnautosavedChanges];
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem
{
	SEL action = menuItem.action;
	if(action == @selector(revertDocumentToSaved:) || action == @selector(revertDocumentToLastOpened:))
	{
		BOOL toSaved = action == @selector(revertDocumentToSaved:);
		BOOL applicable = [self canRevertToContent:(toSaved ? self.savedContentSnapshot : self.openedContentSnapshot)];

		// The native "Revert To" submenu hides these when inapplicable rather than
		// greying them out, and labels each with its version's timestamp.
		menuItem.hidden = !applicable;
		if(applicable)
		{
			// Feed in the menu's own font: an attributed title doesn't inherit it the
			// way a plain title does, and +menuFontOfSize: doesn't reproduce it exactly.
			NSFont*   menuFont = [[menuItem menu] font] ?: [NSFont menuFontOfSize:0];
			NSString* label    = toSaved ? @"Last Saved" : @"Last Opened";
			NSDate*   date     = toSaved ? self.savedContentDate : self.openedContentDate;

			// Colours reverse-engineered from Mavericks' own -[NSDocument
			// _addRevertItemsToMenu:]: the timestamp is greyed with gamma-2.2 white
			// 0.47/α0.75, and a white alternate title is installed that AppKit swaps
			// in while the item is highlighted (otherwise the grey date would stay
			// grey on the blue selection). Both hooks exist on the 10.9 target.
			menuItem.attributedTitle = [self revertMenuTitle:label date:date font:menuFont labelColor:nil dateColor:[NSColor colorWithGenericGamma22White:0.47 alpha:0.75]];
			if([menuItem respondsToSelector:@selector(_setAlternateAttributedTitle:)])
			{
				NSColor* white = [NSColor colorWithGenericGamma22White:1.0 alpha:1.0];
				[menuItem _setAlternateAttributedTitle:[self revertMenuTitle:label date:date font:menuFont labelColor:white dateColor:white]];
			}
		}
		return applicable;
	}
	return [self validateUserInterfaceItem:menuItem];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
	SEL action = [item action];
	if(action == @selector(revertDocumentToSaved:))
		return [self canRevertToContent:self.savedContentSnapshot];
	if(action == @selector(revertDocumentToLastOpened:))
		return [self canRevertToContent:self.openedContentSnapshot];
	return [super validateUserInterfaceItem:item];
}

// Builds "Last Saved — Today, 1:37 PM": the label in labelColor (nil = inherit the
// menu's default, i.e. black normally / white on highlight) and the " — timestamp"
// run in dateColor. colorWithGenericGamma22White: is public since 10.7.
- (NSAttributedString*)revertMenuTitle:(NSString*)label date:(NSDate*)date font:(NSFont*)font labelColor:(NSColor*)labelColor dateColor:(NSColor*)dateColor
{
	NSDictionary* labelAttrs = labelColor ? @{ NSForegroundColorAttributeName: labelColor } : @{};
	NSMutableAttributedString* title = [[NSMutableAttributedString alloc] initWithString:label attributes:labelAttrs];
	if(date)
	{
		NSString* suffix = [NSString stringWithFormat:@" — %@", [[self class] revertDateStringForDate:date]];
		[title appendAttributedString:[[NSAttributedString alloc] initWithString:suffix attributes:@{ NSForegroundColorAttributeName: dateColor }]];
	}
	if(font)
		[title addAttribute:NSFontAttributeName value:font range:NSMakeRange(0, title.length)];
	return title;
}

+ (NSString*)revertDateStringForDate:(NSDate*)date
{
	// Comma-joined "Today, 1:37 PM" to match the native menu. NSDateFormatter's own
	// date+time joining would instead read "Today at 1:37 PM", so format separately.
	static NSDateFormatter* dayFormatter;
	static NSDateFormatter* timeFormatter;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		dayFormatter = [[NSDateFormatter alloc] init];
		dayFormatter.dateStyle = NSDateFormatterMediumStyle;
		dayFormatter.timeStyle = NSDateFormatterNoStyle;
		dayFormatter.doesRelativeDateFormatting = YES;

		timeFormatter = [[NSDateFormatter alloc] init];
		timeFormatter.dateStyle = NSDateFormatterNoStyle;
		timeFormatter.timeStyle = NSDateFormatterShortStyle;
	});
	return [NSString stringWithFormat:@"%@, %@", [dayFormatter stringFromDate:date], [timeFormatter stringFromDate:date]];
}

- (void)canCloseDocumentWithDelegate:(id)delegate shouldCloseSelector:(SEL)shouldCloseSelector contextInfo:(void*)contextInfo
{
	// Bypass NSDocument's close confirmation — DocumentWindowController handles this
	if(delegate && shouldCloseSelector)
	{
		BOOL shouldClose = YES;
		void* document = (__bridge void*)self;
		NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:[delegate methodSignatureForSelector:shouldCloseSelector]];
		invocation.target = delegate;
		invocation.selector = shouldCloseSelector;
		[invocation setArgument:&document atIndex:2];
		[invocation setArgument:&shouldClose atIndex:3];
		[invocation setArgument:&contextInfo atIndex:4];
		[invocation invoke];
	}
}

// MARK: - Data Read/Write

- (NSData*)dataOfType:(NSString*)typeName error:(NSError**)outError
{
	D(DBF_TMDocument, bug("%s type=%s\n", self.oakDocument.displayName.UTF8String, typeName.UTF8String););

	NSMutableData* data = [NSMutableData data];
	[self.oakDocument enumerateByteRangesUsingBlock:^(char const* bytes, NSRange byteRange, BOOL* stop){
		[data appendBytes:bytes length:byteRange.length];
	}];
	return data;
}

- (BOOL)readFromData:(NSData*)data ofType:(NSString*)typeName error:(NSError**)outError
{
	D(DBF_TMDocument, bug("%s type=%s bytes=%lu\n", self.oakDocument.displayName.UTF8String, typeName.UTF8String, (unsigned long)data.length););

	self.oakDocument.content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	return YES;
}

// MARK: - Autosave

- (void)saveToURL:(NSURL*)url ofType:(NSString*)typeName forSaveOperation:(NSSaveOperationType)saveOperation completionHandler:(void (^)(NSError* errorOrNil))completionHandler
{
	D(DBF_TMDocument, bug("%s url=%s type=%s op=%ld\n", self.oakDocument.displayName.UTF8String, url.path.UTF8String, typeName.UTF8String, (long)saveOperation););

	// Sync fileModificationDate with disk before saving so NSDocument
	// doesn't think the file was changed by another application
	if(self.fileURL && saveOperation != NSAutosaveElsewhereOperation)
	{
		[self.fileURL removeCachedResourceValueForKey:NSURLContentModificationDateKey];
		NSDate* modDate = nil;
		[self.fileURL getResourceValue:&modDate forKey:NSURLContentModificationDateKey error:nil];
		if(modDate)
			self.fileModificationDate = modDate;
	}

	// Temporarily disable OakDocument's kqueue watcher so it doesn't
	// interpret our own save as an external change
	OakDocument* oakDoc = self.oakDocument;
	BOOL wasObserving = oakDoc.observeFileSystem;
	oakDoc.observeFileSystem = NO;


	BOOL isIdleAutosave = _performingIdleAutosave;
	OakDocument* __weak weakOakDoc = oakDoc;
	[super saveToURL:url ofType:typeName forSaveOperation:saveOperation completionHandler:^(NSError* errorOrNil){
		OakDocument* strongOakDoc = weakOakDoc;
		if(!errorOrNil && saveOperation != NSAutosaveElsewhereOperation)
		{
			if(strongOakDoc && strongOakDoc.isLoaded)
				[strongOakDoc markDocumentSaved];

			// A real ⌘S — not an idle autosave or the write we issue while
			// reverting — establishes the "Last Saved" checkpoint that
			// -revertDocumentToSaved: restores. Idle autosaves keep writing the
			// file but must not move this checkpoint, or "Last Saved" would track
			// them and become a no-op (the bug this whole mechanism fixes).
			if(!isIdleAutosave && !_performingRevert && strongOakDoc && strongOakDoc.isLoaded)
			{
				self.savedContentSnapshot = strongOakDoc.content;
				self.savedContentDate     = [NSDate date];
			}

			// Author a revision for the native Versions browser. Explicit saves
			// always snapshot; idle autosaves are throttled so a long editing
			// session doesn't flood the version store.
			NSDate* now = [NSDate date];
			BOOL throttled = isIdleAutosave && self.lastVersionDate && [now timeIntervalSinceDate:self.lastVersionDate] < 120;
			if(!throttled)
			{
				[self preserveVersionOfURL:url];
				self.lastVersionDate = now;
			}
		}
		if(strongOakDoc)
		{
			if(!errorOrNil && strongOakDoc.isLoaded)
				[strongOakDoc snapshot];
			if(wasObserving)
				strongOakDoc.observeFileSystem = YES;
		}
		completionHandler(errorOrNil);
	}];
}

- (BOOL)writeToURL:(NSURL*)url ofType:(NSString*)typeName forSaveOperation:(NSSaveOperationType)saveOperation originalContentsURL:(NSURL*)absoluteOriginalContentsURL error:(NSError**)outError
{
	if(saveOperation == NSAutosaveElsewhereOperation)
	{
		// Crash recovery drafts: write raw UTF-8 buffer bytes.
		// readFromData: also assumes UTF-8, so the round-trip is consistent.
		return [super writeToURL:url ofType:typeName forSaveOperation:saveOperation originalContentsURL:absoluteOriginalContentsURL error:outError];
	}

	D(DBF_TMDocument, bug("%s url=%s op=%ld\n", self.oakDocument.displayName.UTF8String, url.path.UTF8String, (long)saveOperation););

	// For saves to the actual file, convert encoding and newlines.
	// The buffer stores UTF-8 with LF; the file may need different encoding/newlines.
	OakDocument* oakDoc = self.oakDocument;

	// Get raw UTF-8 LF buffer content
	NSMutableData* rawData = [NSMutableData data];
	[oakDoc enumerateByteRangesUsingBlock:^(char const* bytes, NSRange byteRange, BOOL* stop){
		[rawData appendBytes:bytes length:byteRange.length];
	}];

	std::string content((char const*)[rawData bytes], [rawData length]);

	// Convert LF to disk line endings (e.g. CRLF)
	std::string newlines = to_s(oakDoc.diskNewlines);
	if(!newlines.empty() && newlines != kLF)
	{
		std::string converted;
		oak::replace_copy(content.begin(), content.end(), kLF.begin(), kLF.end(), newlines.begin(), newlines.end(), back_inserter(converted));
		content.swap(converted);
	}

	// Convert UTF-8 to disk encoding (e.g. ISO-8859-1)
	std::string charset = to_s(oakDoc.diskEncoding);
	if(!charset.empty() && charset != kCharsetNoEncoding && charset != kCharsetUTF8)
	{
		auto utf8Bytes = std::make_shared<io::bytes_t>(content);
		io::bytes_ptr encoded = encoding::convert(utf8Bytes, kCharsetUTF8, charset);
		if(encoded)
			content.assign(encoded->begin(), encoded->end());
		// If conversion fails, write UTF-8 as fallback
	}

	NSData* data = [[NSData alloc] initWithBytesNoCopy:(void*)content.data() length:content.size() freeWhenDone:NO];
	return [data writeToURL:url options:0 error:outError];
}

// MARK: - Revert (for Versions)

- (BOOL)revertToContentsOfURL:(NSURL*)url ofType:(NSString*)typeName error:(NSError**)outError
{
	D(DBF_TMDocument, bug("url=%s type=%s\n", url.path.UTF8String, typeName.UTF8String););

	NSData* data = [NSData dataWithContentsOfURL:url options:0 error:outError];
	if(!data)
		return NO;

	OakDocument* oakDoc = self.oakDocument;

	// Decode the file data using the document's disk encoding.
	// Versions snapshots the actual file on disk, which is in the
	// original encoding. We need to convert back to UTF-8 for the buffer.
	std::string charset = to_s(oakDoc.diskEncoding);
	if(charset.empty() || charset == kCharsetNoEncoding)
		charset = kCharsetUTF8;

	auto bytes = std::make_shared<io::bytes_t>((char const*)[data bytes], [data length], false);
	io::bytes_ptr utf8Bytes = encoding::convert(bytes, charset, kCharsetUTF8);
	if(!utf8Bytes)
	{
		// Encoding conversion failed — try UTF-8 as fallback
		utf8Bytes = bytes;
	}

	// Convert line endings from disk format (e.g. CRLF) to LF for the buffer
	std::string text(utf8Bytes->begin(), utf8Bytes->end());
	std::string newlines = to_s(oakDoc.diskNewlines);
	if(!newlines.empty() && newlines != kLF)
	{
		std::string normalized;
		oak::replace_copy(text.begin(), text.end(), newlines.begin(), newlines.end(), kLF.begin(), kLF.end(), back_inserter(normalized));
		text.swap(normalized);
	}

	NSString* content = [NSString stringWithUTF8String:text.c_str()];
	if(!content)
	{
		if(outError)
			*outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownStringEncodingError userInfo:nil];
		return NO;
	}

	_reloading = YES;
	[[NSNotificationCenter defaultCenter] postNotificationName:OakDocumentWillReloadNotification object:oakDoc];
	[oakDoc beginUndoGrouping];
	oakDoc.content = content;
	[oakDoc endUndoGrouping];
	[oakDoc markDocumentSaved];
	[[NSNotificationCenter defaultCenter] postNotificationName:OakDocumentDidReloadNotification object:oakDoc];
	_reloading = NO;

	[self updateChangeCount:NSChangeCleared];
	return YES;
}

// MARK: - Revert To (Last Saved / Last Opened)

- (BOOL)canRevertToContent:(NSString*)snapshot
{
	// Enabled only when reverting would actually change something. Comparing the
	// whole buffer is fine here — validation runs when the menu opens, not per
	// keystroke.
	if(!snapshot || !self.fileURL || !self.oakDocument.isLoaded)
		return NO;
	NSString* current = self.oakDocument.content;
	return current && ![current isEqualToString:snapshot];
}

- (void)revertDocumentToSaved:(id)sender
{
	// Overrides NSDocument's default, which would re-read the live file — and our
	// live file is the latest *autosave*, so the stock revert is a no-op. Go to the
	// last explicit-save checkpoint instead.
	[self confirmRevertToContent:self.savedContentSnapshot question:[NSString stringWithFormat:@"Do you want to revert the document “%@” to the last saved version?", self.displayName]];
}

- (void)revertDocumentToLastOpened:(id)sender
{
	[self confirmRevertToContent:self.openedContentSnapshot question:[NSString stringWithFormat:@"Do you want to revert the document “%@” to the last opened version?", self.displayName]];
}

- (void)confirmRevertToContent:(NSString*)snapshot question:(NSString*)question
{
	if(![self canRevertToContent:snapshot])
		return;

	// Wording mirrors AppKit's stock revert sheet (which we bypass by overriding
	// -revertDocumentToSaved:). "Saved in your version history" is literally true:
	// -revertOakDocumentToContent: authors a version of the current state first.
	NSAlert* alert = [[NSAlert alloc] init];
	alert.messageText     = question;
	alert.informativeText = @"Recent changes will be saved in your version history.";
	[alert addButtonWithTitle:@"Revert"];
	[alert addButtonWithTitle:@"Cancel"];

	void(^handler)(NSModalResponse) = ^(NSModalResponse response){
		if(response == NSAlertFirstButtonReturn)
			[self revertOakDocumentToContent:snapshot];
	};

	if(NSWindow* window = self.windowForSheet)
		[alert beginSheetModalForWindow:window completionHandler:handler];
	else
		handler([alert runModal]);
}

- (void)revertOakDocumentToContent:(NSString*)snapshot
{
	OakDocument* oakDoc = self.oakDocument;
	if(!snapshot || !oakDoc.isLoaded)
		return;

	// Keep the work we're discarding recoverable in the Versions browser: snapshot
	// the current on-disk state (idle autosave keeps it within ~5s of the buffer)
	// before we overwrite it. Undo is the immediate safety net — the swap below is
	// a single undo group.
	if(self.fileURL)
		[self preserveVersionOfURL:self.fileURL];

	_reloading = YES;
	[[NSNotificationCenter defaultCenter] postNotificationName:OakDocumentWillReloadNotification object:oakDoc];
	[oakDoc beginUndoGrouping];
	oakDoc.content = snapshot;
	[oakDoc endUndoGrouping];
	[[NSNotificationCenter defaultCenter] postNotificationName:OakDocumentDidReloadNotification object:oakDoc];
	_reloading = NO;

	// Write the reverted buffer back so the file matches it. _performingRevert
	// keeps this from being mistaken for a ⌘S and moving the "Last Saved"
	// checkpoint we may have just reverted to.
	if(self.fileURL)
	{
		_performingRevert = YES;
		[self saveToURL:self.fileURL ofType:self.fileType forSaveOperation:NSSaveOperation completionHandler:^(NSError* errorOrNil){
			_performingRevert = NO;
		}];
	}
}

// MARK: - Duplication

- (NSDocument*)duplicateAndReturnError:(NSError**)outError
{
	// Get the current content
	NSData* data = [self dataOfType:self.fileType error:outError];
	if(!data)
		return nil;

	// Create a new OakDocument with the content
	NSString* newName = [NSString stringWithFormat:@"%@ copy", [self.oakDocument displayNameWithExtension:NO]];
	OakDocument* newOakDoc = [OakDocument documentWithData:data fileType:self.oakDocument.fileType customName:newName];
	if(!newOakDoc)
	{
		if(outError)
			*outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil];
		return nil;
	}

	// Copy settings from original
	newOakDoc.diskEncoding = self.oakDocument.diskEncoding;
	newOakDoc.diskNewlines = self.oakDocument.diskNewlines;

	// Create TMDocument wrapper
	TMDocument* duplicate = [[TMDocumentRegistry sharedRegistry] documentForOakDocument:newOakDoc];

	// Mark as having unsaved changes (since it's a new untitled document)
	[duplicate updateChangeCount:NSChangeDone];

	// Show the duplicate in TextMate's UI
	[OakDocumentController.sharedInstance showDocument:newOakDoc];

	return duplicate;
}

// MARK: - Window Controller Management

- (void)makeWindowControllers
{
	// We don't create window controllers here since DocumentWindowController handles windows
	// TMWindowController is attached externally by DocumentWindowController
}

- (void)addWindowController:(NSWindowController*)windowController
{
	[super addWindowController:windowController];
	if([windowController isKindOfClass:[TMWindowController class]])
		_tmWindowController = (TMWindowController*)windowController;
}

- (void)removeWindowController:(NSWindowController*)windowController
{
	[super removeWindowController:windowController];
	if(windowController == _tmWindowController)
		_tmWindowController = nil;
}

@end
