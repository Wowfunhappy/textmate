#import "BundlesPreferences.h"
#import <BundlesManager/BundlesManager.h>
#import <OakFoundation/OakFoundation.h>
#import <OakFoundation/NSDate Additions.h>
#import <OakFoundation/NSString Additions.h>
#import <MGScopeBar/MGScopeBar.h>
#import <ns/ns.h>
#import <regexp/format_string.h>
#import <text/case.h>
#import <text/ctype.h>
#import <text/decode.h>
#import <bundles/bundles.h>

static NSString* const kAlwaysShowBundlesKey = @"alwaysShowBundlesInLanguageMenu";

@interface Bundle (AlwaysShowInLanguageMenu)
@property (nonatomic) BOOL alwaysShowInLanguageMenu;
@end

@implementation Bundle (AlwaysShowInLanguageMenu)
- (BOOL)alwaysShowInLanguageMenu
{
	if(!self.isInstalled)
		return NO;
	if(bundles::item_ptr item = bundles::lookup(to_s(self.identifier.UUIDString)))
	{
		if(item->menu().empty() || item->disabled())
			return NO;
	}
	NSArray* uuids = [[NSUserDefaults standardUserDefaults] arrayForKey:kAlwaysShowBundlesKey] ?: @[];
	return [uuids containsObject:self.identifier.UUIDString];
}

- (void)setAlwaysShowInLanguageMenu:(BOOL)flag
{
	if(!self.isInstalled)
		return;

	if(bundles::item_ptr item = bundles::lookup(to_s(self.identifier.UUIDString)))
	{
		if(item->menu().empty() || item->disabled())
			return;
	}

	NSMutableArray* uuids = [([[NSUserDefaults standardUserDefaults] arrayForKey:kAlwaysShowBundlesKey] ?: @[]) mutableCopy];
	NSString* uuid = self.identifier.UUIDString;
	if(flag && ![uuids containsObject:uuid])
		[uuids addObject:uuid];
	else if(!flag)
		[uuids removeObject:uuid];
	[[NSUserDefaults standardUserDefaults] setObject:uuids forKey:kAlwaysShowBundlesKey];
}
@end

@interface BundlesPreferences ()
{
	NSMutableSet* enabledCategories;
}
@property (nonatomic) BundlesManager* bundlesManager;
@end

@implementation BundlesPreferences
- (NSString*)viewIdentifier        { return @"Bundles"; }
- (NSImage*)toolbarItemImage       { return [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"TextMate Bundle" ofType:@"icns"]]; }
- (NSString*)toolbarItemLabel      { return @"Bundles"; }
- (NSView*)initialKeyView          { return bundlesTableView; }

- (id)init
{
	if(self = [super initWithNibName:@"BundlesPreferences" bundle:[NSBundle bundleForClass:[self class]]])
	{
		[MGScopeBar class]; // Ensure that we reference the class so that the linker doesn’t strip the framework

		_bundlesManager = [BundlesManager sharedInstance];
		enabledCategories = [NSMutableSet set];
	}
	return self;
}

- (void)awakeFromNib
{
	[bundlesTableView tableColumnWithIdentifier:@"alwaysShow"].headerToolTip = @"Always show in Language menu";
	[bundlesTableView setIndicatorImage:[NSImage imageNamed:@"NSAscendingSortIndicator"] inTableColumn:[bundlesTableView tableColumnWithIdentifier:@"name"]];
	arrayController.sortDescriptors = @[
		[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCompare:)],
		[NSSortDescriptor sortDescriptorWithKey:@"textSummary" ascending:YES selector:@selector(localizedCompare:)]
	];
}

// =======================
// = MGScopeBar Delegate =
// =======================

- (int)numberOfGroupsInScopeBar:(MGScopeBar*)theScopeBar
{
	return 1;
}

- (NSArray*)scopeBar:(MGScopeBar*)theScopeBar itemIdentifiersForGroup:(int)groupNumber
{
	if(groupNumber != 0)
		return @[ ];

	NSMutableSet* set = [NSMutableSet set];
	for(Bundle* bundle in _bundlesManager.bundles)
	{
		if(NSString* category = bundle.category)
			[set addObject:category];
	}
	return [[set allObjects] sortedArrayUsingSelector:@selector(localizedCompare:)];
}

- (NSString*)scopeBar:(MGScopeBar*)theScopeBar labelForGroup:(int)groupNumber
{
	return nil;
}

- (MGScopeBarGroupSelectionMode)scopeBar:(MGScopeBar*)theScopeBar selectionModeForGroup:(int)groupNumber
{
	return MGMultipleSelectionMode;
}

- (NSString*)scopeBar:(MGScopeBar*)theScopeBar titleOfItem:(NSString*)identifier inGroup:(int)groupNumber
{
	return identifier;
}

- (void)scopeBar:(MGScopeBar*)theScopeBar selectedStateChanged:(BOOL)selected forItem:(NSString*)identifier inGroup:(int)groupNumber
{
	if(selected)
			[enabledCategories addObject:identifier];
	else	[enabledCategories removeObject:identifier];
	[self filterStringDidChange:self];
}

- (NSView*)accessoryViewForScopeBar:(MGScopeBar*)theScopeBar
{
	return searchField;
}

- (IBAction)filterStringDidChange:(id)sender
{
	NSMutableArray* predicates = [NSMutableArray array];
	if(OakNotEmptyString(searchField.stringValue))
		[predicates addObject:[NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@", searchField.stringValue]];
	if(enabledCategories.count)
		[predicates addObject:[NSPredicate predicateWithFormat:@"category IN %@", enabledCategories]];
	arrayController.filterPredicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];
	[arrayController rearrangeObjects];
}

// ========================
// = NSTableView Delegate =
// ========================

- (void)tableView:(NSTableView*)aTableView didClickTableColumn:(NSTableColumn*)aTableColumn
{
	NSDictionary* map = @{
		@"name":        @"name",
		@"description": @"textSummary"
	};

	NSString* key = map[aTableColumn.identifier];
	if(!key)
		return;

	NSMutableArray* descriptors = [arrayController.sortDescriptors mutableCopy];

	NSInteger i = 0;
	while(i < descriptors.count && ![arrayController.sortDescriptors[i].key isEqualToString:key])
		++i;

	if(i == descriptors.count)
		return;

	NSSortDescriptor* descriptor = descriptors[i];
	descriptor = i == 0 || !descriptor.ascending ? [descriptor reversedSortDescriptor] : descriptor;
	[descriptors removeObjectAtIndex:i];
	[descriptors insertObject:descriptor atIndex:0];

	arrayController.sortDescriptors = descriptors;

	for(NSTableColumn* tableColumn in [bundlesTableView tableColumns])
		[aTableView setIndicatorImage:nil inTableColumn:tableColumn];
	[aTableView setIndicatorImage:[NSImage imageNamed:(descriptor.ascending ? @"NSAscendingSortIndicator" : @"NSDescendingSortIndicator")] inTableColumn:aTableColumn];
}

- (void)tableView:(NSTableView*)aTableView willDisplayCell:(id)aCell forTableColumn:(NSTableColumn*)aTableColumn row:(NSInteger)rowIndex
{
	if([[aTableColumn identifier] isEqualToString:@"alwaysShow"])
	{
		Bundle* bundle = arrayController.arrangedObjects[rowIndex];
		BOOL hasMenu = NO;
		if(bundle.isInstalled)
		{
			if(bundles::item_ptr item = bundles::lookup(to_s(bundle.identifier.UUIDString)))
				hasMenu = !item->menu().empty() && !item->disabled();
		}
		[aCell setEnabled:hasMenu];
	}
}

- (BOOL)tableView:(NSTableView*)aTableView shouldEditTableColumn:(NSTableColumn*)aTableColumn row:(NSInteger)rowIndex
{
	if([[aTableColumn identifier] isEqualToString:@"alwaysShow"])
	{
		Bundle* bundle = arrayController.arrangedObjects[rowIndex];
		return bundle.isInstalled;
	}
	return NO;
}

- (BOOL)tableView:(NSTableView*)aTableView shouldSelectRow:(NSInteger)rowIndex
{
	NSInteger clickedColumn = [aTableView clickedColumn];
	return clickedColumn != [aTableView columnWithIdentifier:@"alwaysShow"];
}

- (NSString*)tableView:(NSTableView*)aTableView toolTipForCell:(NSCell*)aCell rect:(NSRectPointer)rect tableColumn:(NSTableColumn*)aTableColumn row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation
{
	if([[aTableColumn identifier] isEqualToString:@"alwaysShow"])
		return @"Always show in Language menu";
	return nil;
}
@end
