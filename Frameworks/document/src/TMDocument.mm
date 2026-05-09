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
@end

@implementation TMDocument

+ (BOOL)autosavesInPlace
{
	return YES;
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

		// Register with NSDocumentController for autosaving to work
		[[NSDocumentController sharedDocumentController] addDocument:self];
	}
	return self;
}

- (void)dealloc
{
	D(DBF_TMDocument, bug("unwrap %s\n", _oakDocument.displayName.UTF8String););
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[_oakDocument removeObserver:self forKeyPath:@"path"];
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
}

// MARK: - OakDocument Notification Handlers

- (void)oakDocumentContentDidChange:(NSNotification*)notification
{
	D(DBF_TMDocument, bug("%s reloading=%d\n", self.oakDocument.displayName.UTF8String, _reloading););
	if(!_reloading)
		[self updateChangeCount:NSChangeDone];
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
}

- (void)oakDocumentWillClose:(NSNotification*)notification
{
	D(DBF_TMDocument, bug("%s\n", self.oakDocument.displayName.UTF8String););
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

- (void)relinquishPresentedItemToWriter:(void (^)(void (^reacquirer)(void)))writer
{
	// NSDocument's default implementation dispatches to the main thread via
	// _performFileAccessOnMainThread:, which deadlocks when the main thread
	// is already inside a coordinated save (the autosave path). Call the
	// writer block directly on the current thread to break the cycle.
	writer(^{
		dispatch_async(dispatch_get_main_queue(), ^{
			if(self.fileURL)
			{
				[self.fileURL removeCachedResourceValueForKey:NSURLContentModificationDateKey];
				NSDate* modDate = nil;
				[self.fileURL getResourceValue:&modDate forKey:NSURLContentModificationDateKey error:nil];
				if(modDate)
					self.fileModificationDate = modDate;
			}
		});
	});
}

- (BOOL)hasUnautosavedChanges
{
	return self.oakDocument.isDocumentEdited || [super hasUnautosavedChanges];
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


	OakDocument* __weak weakOakDoc = oakDoc;
	[super saveToURL:url ofType:typeName forSaveOperation:saveOperation completionHandler:^(NSError* errorOrNil){
		OakDocument* strongOakDoc = weakOakDoc;
		if(!errorOrNil && saveOperation != NSAutosaveElsewhereOperation)
		{
			if(strongOakDoc && strongOakDoc.isLoaded)
				[strongOakDoc markDocumentSaved];
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
