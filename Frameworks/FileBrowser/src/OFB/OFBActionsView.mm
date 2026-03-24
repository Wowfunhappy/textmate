#import "OFBActionsView.h"
#import <OakAppKit/OakAppKit.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakAppKit/NSImage Additions.h>

static NSButton* OakCreateImageButton (NSImage* image)
{
	NSButton* res = [NSButton new];
	[res setButtonType:NSButtonTypeMomentaryChange];
	[res setBordered:NO];
	[res setImage:image];
	[res setImagePosition:NSImageOnly];
	return res;
}

@implementation OFBActionsView
- (id)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		self.style = OakBackgroundFillViewStyleStatusBar;

		self.createButton       = OakCreateImageButton([NSImage imageNamed:NSImageNameAddTemplate]);
		self.actionsPopUpButton = OakCreateActionPopUpButton();
		self.reloadButton       = OakCreateImageButton([NSImage imageNamed:NSImageNameRefreshTemplate]);
		self.searchButton       = OakCreateImageButton([NSImage imageNamed:@"SearchTemplate" inSameBundleAsClass:[self class]]);
		self.scmButton          = OakCreateImageButton([NSImage imageNamed:@"SCMTemplate" inSameBundleAsClass:[self class]]);

		self.createButton.toolTip       = @"Create new file";
		self.reloadButton.toolTip       = @"Reload file browser";
		self.searchButton.toolTip       = @"Search current folder";
		self.scmButton.toolTip          = @"Show source control management status";

		self.reloadButton.image.accessibilityDescription    = self.reloadButton.toolTip;
		self.createButton.image.accessibilityDescription    = self.createButton.toolTip;
		self.searchButton.image.accessibilityDescription    = self.searchButton.toolTip;
		self.scmButton.image.accessibilityDescription       = self.scmButton.toolTip;

		NSView* wrappedActionsPopUpButton = [NSView new];
		OakAddAutoLayoutViewsToSuperview(@[ self.actionsPopUpButton ], wrappedActionsPopUpButton);
		[wrappedActionsPopUpButton addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:[popup]|" options:0 metrics:nil views:@{ @"popup": self.actionsPopUpButton }]];
		[wrappedActionsPopUpButton addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[popup]|" options:0 metrics:nil views:@{ @"popup": self.actionsPopUpButton }]];

		NSView* divider = OakCreateDividerImageView();

		NSDictionary* views = @{
			@"create":    self.createButton,
			@"divider":   divider,
			@"actions":   wrappedActionsPopUpButton,
			@"reload":    self.reloadButton,
			@"search":    self.searchButton,
			@"scm":       self.scmButton,
		};

		OakAddAutoLayoutViewsToSuperview([views allValues], self);
		OakSetupKeyViewLoop(@[ self, _createButton, _actionsPopUpButton, _reloadButton, _searchButton, _scmButton ], NO);

		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-8-[create]-[divider]-[actions(==31)]-(>=8)-[reload]-4-[search]-4-[scm]-(12)-|" options:NSLayoutFormatAlignAllCenterY metrics:nil views:views]];
		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[divider(==reload)]|"                                                                               options:0 metrics:nil views:views]];
	}
	return self;
}

- (NSSize)intrinsicContentSize
{
	return NSMakeSize(-1, 24); // -1 is NSViewNoIntrinsicMetric
}
@end
