#import "OakDocument.h"

@class TMWindowController;

@interface TMDocument : NSDocument
@property (nonatomic, readonly) OakDocument* oakDocument;
@property (nonatomic, readonly) TMWindowController* tmWindowController;

+ (instancetype)documentForOakDocument:(OakDocument*)oakDocument;
- (instancetype)initWithOakDocument:(OakDocument*)oakDocument;

// "File ▸ Revert To" commands. -revertDocumentToSaved: (declared by NSDocument)
// is overridden to restore the last explicit ⌘S rather than the live autosaved
// file; this one restores the state the document was opened from.
- (void)revertDocumentToLastOpened:(id)sender;
@end
