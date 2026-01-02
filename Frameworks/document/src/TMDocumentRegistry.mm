#import "TMDocumentRegistry.h"
#import "TMDocument.h"
#import <oak/debug.h>

OAK_DEBUG_VAR(TMDocumentRegistry);

@interface TMDocumentRegistry ()
{
	NSMapTable<OakDocument*, TMDocument*>* _documents;
}
@end

@implementation TMDocumentRegistry

+ (instancetype)sharedRegistry
{
	static TMDocumentRegistry* sharedInstance;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		sharedInstance = [[TMDocumentRegistry alloc] init];
	});
	return sharedInstance;
}

- (instancetype)init
{
	if(self = [super init])
	{
		// Use weak references to keys (OakDocument) and strong references to values (TMDocument)
		// This way when an OakDocument is deallocated, the entry is automatically removed
		_documents = [NSMapTable mapTableWithKeyOptions:NSMapTableWeakMemory|NSMapTableObjectPointerPersonality
		                                   valueOptions:NSMapTableStrongMemory|NSMapTableObjectPointerPersonality];
	}
	return self;
}

- (TMDocument*)documentForOakDocument:(OakDocument*)oakDocument
{
	if(!oakDocument)
		return nil;

	@synchronized(self)
	{
		TMDocument* tmDocument = [_documents objectForKey:oakDocument];
		if(!tmDocument)
		{
			D(DBF_TMDocumentRegistry, bug("creating TMDocument for %s\n", oakDocument.displayName.UTF8String););
			tmDocument = [[TMDocument alloc] initWithOakDocument:oakDocument];
			[_documents setObject:tmDocument forKey:oakDocument];
		}
		return tmDocument;
	}
}

- (void)unregisterOakDocument:(OakDocument*)oakDocument
{
	if(!oakDocument)
		return;

	@synchronized(self)
	{
		D(DBF_TMDocumentRegistry, bug("unregistering TMDocument for %s\n", oakDocument.displayName.UTF8String););
		[_documents removeObjectForKey:oakDocument];
	}
}

@end
