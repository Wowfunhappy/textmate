@class OakDocument;
@class TMDocument;

@interface TMDocumentRegistry : NSObject
+ (instancetype)sharedRegistry;
- (TMDocument*)documentForOakDocument:(OakDocument*)oakDocument;
- (void)unregisterOakDocument:(OakDocument*)oakDocument;
@end
