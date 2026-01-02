#import "OakDocument.h"

@class TMWindowController;

@interface TMDocument : NSDocument
@property (nonatomic, readonly) OakDocument* oakDocument;
@property (nonatomic, readonly) TMWindowController* tmWindowController;

+ (instancetype)documentForOakDocument:(OakDocument*)oakDocument;
- (instancetype)initWithOakDocument:(OakDocument*)oakDocument;
@end
