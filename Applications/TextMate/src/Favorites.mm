#import "Favorites.h"
#import <OakFilterList/OakAbbreviations.h>
#import <OakAppKit/OakAppKit.h>
#import <OakAppKit/OakFileIconImage.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <OakAppKit/OakSound.h>
#import <OakFoundation/NSString Additions.h>
#import <text/ranker.h>
#import <text/case.h>
#import <text/ctype.h>
#import <io/path.h>
#import <ns/ns.h>
#import <kvdb/kvdb.h>

@interface FavoriteChooser ()
{
	NSMutableArray* _originalItems;
}
@end

@implementation FavoriteChooser
+ (instancetype)sharedInstance
{
	static FavoriteChooser* sharedInstance = [self new];
	return sharedInstance;
}

- (KVDB*)sharedProjectStateDB
{
	NSString* appSupport = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"TextMate"];
	return [KVDB sharedDBUsingFile:@"RecentProjects.db" inDirectory:appSupport];
}

- (id)init
{
	if((self = [super init]))
	{
		self.window.title = @"Open Recent Project";
		self.tableView.allowsTypeSelect = NO;
		self.tableView.allowsMultipleSelection = YES;
		self.tableView.refusesFirstResponder = NO;
		self.tableView.rowHeight = 38;

		self.window.nextResponder = nil;
		NSResponder* nextResponder = self.tableView.nextResponder;
		self.tableView.nextResponder = self;
		self.nextResponder = nextResponder;

		OakBackgroundFillView* topDivider    = OakCreateHorizontalLine([NSColor darkGrayColor], [NSColor colorWithCalibratedWhite:0.551 alpha:1]);
		OakBackgroundFillView* bottomDivider = OakCreateHorizontalLine([NSColor grayColor], [NSColor lightGrayColor]);

		NSDictionary* views = @{
			@"searchField":        self.searchField,
			@"topDivider":         topDivider,
			@"scrollView":         self.scrollView,
			@"bottomDivider":      bottomDivider,
			@"statusTextField":    self.statusTextField,
			@"itemCountTextField": self.itemCountTextField,
		};

		NSView* contentView = self.window.contentView;
		OakAddAutoLayoutViewsToSuperview([views allValues], contentView);
		OakSetupKeyViewLoop(@[ self.tableView, self.searchField ]);

		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(8)-[searchField(>=50)]-(8)-|"                      options:0 metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[scrollView(==topDivider,==bottomDivider)]|"         options:0 metrics:nil views:views]];
		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-[statusTextField]-[itemCountTextField]-|"           options:NSLayoutFormatAlignAllCenterY metrics:nil views:views]];

		[contentView addConstraint:[NSLayoutConstraint constraintWithItem:topDivider    attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:contentView attribute:NSLayoutAttributeLeft multiplier:1.0 constant:0.0]];
		[contentView addConstraint:[NSLayoutConstraint constraintWithItem:bottomDivider attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:contentView attribute:NSLayoutAttributeLeft multiplier:1.0 constant:0.0]];

		[contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(2)-[searchField]-(8)-[topDivider][scrollView(>=50)][bottomDivider]-(4)-[statusTextField]-(5)-|" options:0 metrics:nil views:views]];
	}
	return self;
}


- (NSView*)tableView:(NSTableView*)aTableView viewForTableColumn:(NSTableColumn*)aTableColumn row:(NSInteger)row
{
	NSTableCellView* res = [aTableView makeViewWithIdentifier:aTableColumn.identifier owner:self];
	if(!res)
	{
		NSButton* removeButton = [NSButton new];
		[[removeButton cell] setControlSize:NSControlSizeSmall];
		removeButton.refusesFirstResponder = YES;
		removeButton.bezelStyle = NSRoundRectBezelStyle;
		removeButton.buttonType = NSMomentaryPushInButton;
		removeButton.image      = [NSImage imageNamed:NSImageNameRemoveTemplate];
		removeButton.target     = self;
		removeButton.action     = @selector(takeItemToRemoveFrom:);

		res = [[OakFileTableCellView alloc] initWithCloseButton:removeButton];
		res.identifier = aTableColumn.identifier;

		[removeButton bind:NSHiddenBinding toObject:res withKeyPath:@"objectValue.isRemoveDisabled" options:nil];
	}

	res.objectValue = self.items[row];
	return res;
}

- (void)loadItems:(id)sender
{
	NSMutableArray* items = [NSMutableArray new];
	for(id pair in [[[self sharedProjectStateDB] allObjects] sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"value.lastRecentlyUsed" ascending:NO], [NSSortDescriptor sortDescriptorWithKey:@"key.lastPathComponent" ascending:YES selector:@selector(localizedCompare:)] ]])
	{
		if(access([pair[@"key"] fileSystemRepresentation], F_OK) == 0)
			[items addObject:@{ @"path": pair[@"key"] }];
	}

	_originalItems = [NSMutableArray new];
	for(NSDictionary* item in items)
	{
		NSString* path = item[@"path"];
		NSMutableDictionary* tmp = [item mutableCopy];
		[tmp addEntriesFromDictionary:@{
			@"icon":   [OakFileIconImage fileIconImageWithPath:path size:NSMakeSize(32, 32)],
			@"name":   item[@"name"]   ?: [NSString stringWithCxxString:path::display_name(to_s(path))],
			@"folder": item[@"folder"] ?: [[path stringByDeletingLastPathComponent] stringByAbbreviatingWithTildeInPath],
			@"info":   [path stringByAbbreviatingWithTildeInPath]
		}];
		[_originalItems addObject:tmp];
	}
}

- (void)showWindow:(id)sender
{
	if(![self.window isVisible])
	{
		self.filterString = @"";
		[self loadItems:self];
		[self updateItems:self];
		if([self.tableView numberOfRows])
			[self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	}
	[super showWindow:sender];
}

- (void)updateItems:(id)sender
{
	NSArray* bindings = [[OakAbbreviations abbreviationsForName:@"OakFavoriteChooserBindings"] stringsForAbbreviation:self.filterString];
	std::string const filter = to_s([self.filterString decomposedStringWithCanonicalMapping]);

	std::multimap<double, NSDictionary*> ranked;
	for(NSDictionary* item in _originalItems)
	{
		NSString* name = item[@"name"];

		double rank = ranked.size();
		std::vector<std::pair<size_t, size_t>> ranges;
		if(filter != NULL_STR && filter != "")
		{
			rank = oak::rank(filter, to_s(name), &ranges);
			if(rank <= 0)
				continue;

			NSUInteger bindingIndex = [bindings indexOfObject:item[@"path"]];
			if(bindingIndex != NSNotFound)
					rank = -1.0 * (bindings.count - bindingIndex);
			else	rank = -rank;
		}

		NSMutableDictionary* entry = [item mutableCopy];
		entry[@"name"]   = CreateAttributedStringWithMarkedUpRanges(to_s(name), ranges, NSLineBreakByTruncatingTail);
		entry[@"folder"] = CreateAttributedStringWithMarkedUpRanges(to_s(item[@"folder"]), { }, NSLineBreakByTruncatingHead);
		ranked.emplace(rank, entry);
	}

	NSMutableArray* res = [NSMutableArray new];
	for(auto const& pair : ranked)
		[res addObject:pair.second];
	self.items = res;
}

- (void)updateStatusText:(id)sender
{
	if(self.tableView.selectedRow != -1)
	{
		NSDictionary* item = self.items[self.tableView.selectedRow];
		self.statusTextField.stringValue = [item objectForKey:@"info"];
	}
	else
	{
		self.statusTextField.stringValue = @"";
	}
}

- (void)accept:(id)sender
{
	if(self.filterString)
	{
		for(NSDictionary* item in self.selectedItems)
			[[OakAbbreviations abbreviationsForName:@"OakFavoriteChooserBindings"] learnAbbreviation:self.filterString forString:[item objectForKey:@"path"]];
	}

	for(NSDictionary* item in self.selectedItems)
	{
		if(NSMutableDictionary* tmp = [[[self sharedProjectStateDB] valueForKey:item[@"path"]] mutableCopy])
		{
			tmp[@"lastRecentlyUsed"] = [NSDate date];
			[[self sharedProjectStateDB] setValue:tmp forKey:item[@"path"]];
		}
	}

	[super accept:sender];
}

- (NSUInteger)removeItemsAtIndexes:(NSIndexSet*)anIndexSet
{
	NSMutableArray* items = [self.items mutableCopy];
	for(NSDictionary* item in [items objectsAtIndexes:anIndexSet])
	{
		if(NSString* path = item[@"path"])
			[[self sharedProjectStateDB] removeObjectForKey:path];
	}

	[self loadItems:self];
	return [super removeItemsAtIndexes:anIndexSet];
}

- (void)takeItemToRemoveFrom:(NSButton*)sender
{
	NSInteger row = [self.tableView rowForView:sender];
	if(row != -1)
		[self removeItemsAtIndexes:[NSIndexSet indexSetWithIndex:row]];
}


- (void)deleteForward:(id)sender
{
	NSUInteger itemsRemoved = [self removeItemsAtIndexes:[self.tableView selectedRowIndexes]];
	if(itemsRemoved == 0)
		NSBeep();
}

- (void)deleteBackward:(id)sender
{
	NSUInteger index = [[self.tableView selectedRowIndexes] firstIndex];
	NSUInteger itemsRemoved = [self removeItemsAtIndexes:[self.tableView selectedRowIndexes]];
	if(itemsRemoved == 0)
		NSBeep();
	else if(index && index != NSNotFound && self.tableView.numberOfRows)
		[self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:index-1] byExtendingSelection:NO];
}

- (void)insertText:(id)aString
{
	self.filterString = aString;
	[self.window makeFirstResponder:self.searchField];
	NSText* fieldEditor = (NSText*)[self.window firstResponder];
	if([fieldEditor isKindOfClass:[NSText class]])
		[fieldEditor setSelectedRange:NSMakeRange([[fieldEditor string] length], 0)];
}

- (void)doCommandBySelector:(SEL)aSelector
{
	if([self respondsToSelector:aSelector])
	{
		[super doCommandBySelector:aSelector];
	}
	else
	{
		NSUInteger res = OakPerformTableViewActionFromSelector(self.tableView, aSelector);
		if(res == OakMoveAcceptReturn)
			[self accept:self];
		else if(res == OakMoveCancelReturn)
			[self cancel:self];
	}
}

- (void)keyDown:(NSEvent*)anEvent  { [self interpretKeyEvents:@[ anEvent ]]; }
- (void)insertTab:(id)sender       { [self.window selectNextKeyView:self]; }
- (void)insertBacktab:(id)sender   { [self.window selectPreviousKeyView:self]; }
@end
