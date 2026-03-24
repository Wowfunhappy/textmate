#import "TMDocument.h"
#import "TMDocumentRegistry.h"
#import "TMWindowController.h"
#import "OakDocumentController.h"
#import <oak/debug.h>

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
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(oakDocumentWillClose:) name:OakDocumentWillCloseNotification object:oakDocument];

		[oakDocument addObserver:self forKeyPath:@"path" options:NSKeyValueObservingOptionNew context:nullptr];

		// NSDocument handles file change detection via NSFilePresenter (since
		// autosavesInPlace is YES). Disable OakDocument's independent kqueue
		// watcher to avoid two systems competing over the same file changes.
		oakDocument.observeFileSystem = NO;
		[oakDocument addObserver:self forKeyPath:@"observeFileSystem" options:0 context:nullptr];

		// Register with NSDocumentController for autosaving to work
		[[NSDocumentController sharedDocumentController] addDocument:self];
	}
	return self;
}

- (void)dealloc
{
	D(DBF_TMDocument, bug("unwrap %s\n", _oakDocument.displayName.UTF8String););
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[_oakDocument removeObserver:self forKeyPath:@"observeFileSystem"];
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
	else if([keyPath isEqualToString:@"observeFileSystem"])
	{
		if(self.oakDocument.observeFileSystem)
		{
			D(DBF_TMDocument, bug("%s suppressing OakDocument file watcher\n", self.oakDocument.displayName.UTF8String););
			self.oakDocument.observeFileSystem = NO;
		}
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
	[self updateChangeCount:NSChangeCleared];
}

- (void)oakDocumentWillClose:(NSNotification*)notification
{
	D(DBF_TMDocument, bug("%s\n", self.oakDocument.displayName.UTF8String););
	// Remove from NSDocumentController
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

	// Let NSDocument handle the save through its normal pipeline (which manages Versions)
	// NSDocument will call our dataOfType:error: to get the content
	OakDocument* __weak weakOakDoc = self.oakDocument;
	[super saveToURL:url ofType:typeName forSaveOperation:saveOperation completionHandler:^(NSError* errorOrNil){
		if(!errorOrNil && saveOperation != NSAutosaveElsewhereOperation)
		{
			// Sync OakDocument's saved state after successful save
			// Don't mark saved for draft autosaves — those preserve unsaved content
			// but shouldn't clear the document's dirty state
			OakDocument* oakDoc = weakOakDoc;
			if(oakDoc && oakDoc.isLoaded)
				[oakDoc markDocumentSaved];
		}
		completionHandler(errorOrNil);
	}];
}

// MARK: - Revert (for Versions)

- (BOOL)revertToContentsOfURL:(NSURL*)url ofType:(NSString*)typeName error:(NSError**)outError
{
	NSLog(@"TMDocument revertToContentsOfURL: %@ (type: %@)", url, typeName);

	NSData* data = [NSData dataWithContentsOfURL:url options:0 error:outError];
	if(!data)
	{
		NSLog(@"TMDocument revertToContentsOfURL: failed to read data from %@", url);
		return NO;
	}

	NSString* content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	if(!content)
	{
		NSLog(@"TMDocument revertToContentsOfURL: failed to decode as UTF-8");
		if(outError)
			*outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownStringEncodingError userInfo:nil];
		return NO;
	}

	NSLog(@"TMDocument revertToContentsOfURL: loaded %lu bytes, setting content", (unsigned long)data.length);

	OakDocument* oakDoc = self.oakDocument;

	_reloading = YES;
	[[NSNotificationCenter defaultCenter] postNotificationName:OakDocumentWillReloadNotification object:oakDoc];
	[oakDoc beginUndoGrouping];
	oakDoc.content = content;
	[oakDoc endUndoGrouping];
	[oakDoc markDocumentSaved];
	[[NSNotificationCenter defaultCenter] postNotificationName:OakDocumentDidReloadNotification object:oakDoc];
	_reloading = NO;

	[self updateChangeCount:NSChangeCleared];
	NSLog(@"TMDocument revertToContentsOfURL: done");
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
