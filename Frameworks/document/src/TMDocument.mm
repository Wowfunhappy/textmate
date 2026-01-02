#import "TMDocument.h"
#import "TMDocumentRegistry.h"
#import "TMWindowController.h"
#import "OakDocumentController.h"
#import <oak/debug.h>

OAK_DEBUG_VAR(TMDocument);

@interface TMDocument ()
@property (nonatomic, readwrite) OakDocument* oakDocument;
@property (nonatomic, readwrite) TMWindowController* tmWindowController;
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
	D(DBF_TMDocument, bug("%s\n", self.oakDocument.displayName.UTF8String););
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
		if(!errorOrNil)
		{
			// Sync OakDocument's saved state after successful save
			// Use weak reference to avoid crash if document was closed during async save
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
	D(DBF_TMDocument, bug("%s url=%s\n", self.oakDocument.displayName.UTF8String, url.path.UTF8String););

	NSData* data = [NSData dataWithContentsOfURL:url options:0 error:outError];
	if(!data)
		return NO;

	NSString* content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	if(!content)
	{
		if(outError)
			*outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownStringEncodingError userInfo:nil];
		return NO;
	}

	self.oakDocument.content = content;
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
