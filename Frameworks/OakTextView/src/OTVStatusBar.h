#import <OakAppKit/OakUIConstructionFunctions.h>

@protocol OTVStatusBarDelegate <NSObject>
- (void)showSymbolSelector:(NSPopUpButton*)popUpButton;
@end

@interface OTVStatusBar : OakBackgroundFillView
@property (nonatomic) NSString* selectionString;
@property (nonatomic) NSString* grammarName;
@property (nonatomic) NSString* symbolName;
@property (nonatomic) NSString* fileType; // This will update grammarName
@property (nonatomic, getter = isRecordingMacro) BOOL recordingMacro;
@property (nonatomic) BOOL softTabs;
@property (nonatomic) NSUInteger tabSize;

@property (nonatomic, weak) id <OTVStatusBarDelegate> delegate;
@property (nonatomic, weak) id target;
@end
