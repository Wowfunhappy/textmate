#import "TMWindowController.h"
#import <oak/debug.h>

OAK_DEBUG_VAR(TMWindowController);

@implementation TMWindowController

- (instancetype)initWithWindow:(NSWindow*)window
{
	if(self = [super initWithWindow:window])
	{
		D(DBF_TMWindowController, bug("window=%p\n", window););
		// We set shouldCloseDocument to NO because the DocumentWindowController
		// manages the window lifecycle, not us
		self.shouldCloseDocument = NO;
	}
	return self;
}

- (void)dealloc
{
	D(DBF_TMWindowController, bug("\n"););
}

// Override to prevent NSWindowController from managing the window
- (void)setDocument:(NSDocument*)document
{
	[super setDocument:document];
	D(DBF_TMWindowController, bug("document=%s\n", document ? [document displayName].UTF8String : "(nil)"););
}

// Don't close the window when the document closes - DocumentWindowController handles that
- (void)close
{
	D(DBF_TMWindowController, bug("\n"););
	// Don't call [super close] as that would close the window
	// Just remove ourselves from the document
	[self.document removeWindowController:self];
}

@end
