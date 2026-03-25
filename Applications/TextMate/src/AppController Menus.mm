#import "AppController.h"
#import <oak/oak.h>
#import <text/ctype.h>
#import <text/parse.h>
#import <bundles/bundles.h>
#import <command/parser.h>
#import <cf/cf.h>
#import <ns/ns.h>
#import <OakAppKit/NSMenu Additions.h>
#import <OakAppKit/NSMenuItem Additions.h>
#import <OakAppKit/OakToolTip.h>
#import <OakFoundation/NSString Additions.h>
#import <OakTextView/OakTextView.h>
#import <oak/debug.h>
#import <BundleMenu/BundleMenu.h>

OAK_DEBUG_VAR(AppController_Menus);

@implementation AppController (BundlesMenu)
- (BOOL)menuHasKeyEquivalent:(NSMenu*)aMenu forEvent:(NSEvent*)theEvent target:(id*)aTarget action:(SEL*)anAction
{
	D(DBF_AppController_Menus, bug("%s (%s)\n", ns::glyphs_for_event_string(to_s(theEvent)).c_str(), to_s(theEvent).c_str()););
	return NO;
}

- (void)languageMenuNeedsUpdate:(NSMenu*)aMenu
{
	D(DBF_AppController_Menus, bug("\n"););
	[aMenu removeAllItems];

	scope::context_t scope = "";
	if(id textView = [NSApp targetForAction:@selector(scopeContext)])
		scope = [textView scopeContext];

	// Find the grammar bundle for the current document's scope
	std::string const fullScope = to_s(scope.left);
	std::string const rootScope = fullScope.substr(0, fullScope.find(' '));
	std::string currentBundleUUID;

	// "Choose Language" submenu
	NSMenuItem* chooseItem = [aMenu addItemWithTitle:@"Choose Language" action:NULL keyEquivalent:@""];
	NSMenu* chooseMenu = [[NSMenu alloc] initWithTitle:@"Choose Language"];

	std::multimap<std::string, bundles::item_ptr, text::less_t> grammars;
	for(auto const& item : bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, bundles::kItemTypeGrammar))
	{
		if(item->value_for_field(bundles::kFieldGrammarScope) != NULL_STR && !item->hidden_from_user())
			grammars.emplace(item->name(), item);
	}

	for(auto const& pair : grammars)
	{
		NSMenuItem* item = [chooseMenu addItemWithTitle:[NSString stringWithCxxString:pair.first] action:@selector(takeGrammarUUIDFrom:) keyEquivalent:@""];
		[item setRepresentedObject:[NSString stringWithCxxString:pair.second->uuid()]];
		if(pair.second->value_for_field(bundles::kFieldGrammarScope) == rootScope)
			[item setState:NSControlStateValueOn];
	}

	chooseItem.submenu = chooseMenu;

	// Current language's bundle menu items
	if(!rootScope.empty())
	{
		bundles::item_ptr grammarItem;
		for(auto const& item : bundles::query(bundles::kFieldGrammarScope, rootScope, scope::wildcard, bundles::kItemTypeGrammar))
		{
			grammarItem = item;
			break;
		}

		if(grammarItem)
		{
			bundles::item_ptr bundle = bundles::lookup(grammarItem->bundle_uuid());
			if(bundle && !bundle->menu().empty())
			{
				currentBundleUUID = bundle->uuid();

				NSMenu* tmpMenu = [[NSMenu alloc] initWithTitle:[NSString stringWithCxxString:currentBundleUUID]];
				[[BundleMenuDelegate sharedInstance] menuNeedsUpdate:tmpMenu];

				if(tmpMenu.numberOfItems > 0)
				{
					[aMenu addItem:[NSMenuItem separatorItem]];
					for(NSMenuItem* item in [tmpMenu.itemArray copy])
					{
						[tmpMenu removeItem:item];
						[aMenu addItem:item];
					}
				}
			}
		}
	}

	// Append "always show" bundles after a separator
	NSArray* alwaysShowUUIDs = [[NSUserDefaults standardUserDefaults] arrayForKey:@"alwaysShowBundlesInLanguageMenu"] ?: @[];
	NSSet* alwaysShowSet = [NSSet setWithArray:alwaysShowUUIDs];

	std::multimap<std::string, bundles::item_ptr, text::less_t> ordered;
	for(auto const& item : bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, bundles::kItemTypeBundle))
		ordered.emplace(item->name(), item);

	bool addedSeparator = false;
	for(auto const& pair : ordered)
	{
		if(pair.second->menu().empty())
			continue;

		if(![alwaysShowSet containsObject:[NSString stringWithCxxString:pair.second->uuid()]])
			continue;

		if(pair.second->uuid() == currentBundleUUID)
			continue;

		if(!addedSeparator)
		{
			[aMenu addItem:[NSMenuItem separatorItem]];
			addedSeparator = true;
		}

		NSMenuItem* menuItem = [aMenu addItemWithTitle:[NSString stringWithCxxString:pair.first] action:NULL keyEquivalent:@""];
		menuItem.submenu = [[NSMenu alloc] initWithTitle:[NSString stringWithCxxString:pair.second->uuid()]];
		menuItem.submenu.delegate = [BundleMenuDelegate sharedInstance];
	}
}

- (void)themesMenuNeedsUpdate:(NSMenu*)aMenu
{
	D(DBF_AppController_Menus, bug("\n"););
	[aMenu removeAllItems];

	std::map<std::string, std::multimap<std::string, bundles::item_ptr, text::less_t>> ordered;
	for(auto const& item : bundles::query(bundles::kFieldAny, NULL_STR, scope::wildcard, bundles::kItemTypeTheme))
	{
		if(item->hidden_from_user())
			continue;

		auto semanticClass = text::split(item->value_for_field(bundles::kFieldSemanticClass), ".");
		std::string themeClass = semanticClass.size() > 2 && semanticClass.front() == "theme" ? semanticClass[1] : "unspecified";
		ordered[themeClass].emplace(item->name(), item);
	}

	for(auto const& themeClasses : ordered)
	{
		[aMenu addItemWithTitle:[[NSString stringWithCxxString:themeClasses.first] capitalizedString] action:@selector(nop:) keyEquivalent:@""];
		for(auto const& pair : themeClasses.second)
		{
			NSMenuItem* menuItem = [aMenu addItemWithTitle:[NSString stringWithCxxString:pair.first] action:@selector(takeThemeUUIDFrom:) keyEquivalent:@""];
			[menuItem setKeyEquivalentCxxString:key_equivalent(pair.second)];
			[menuItem setRepresentedObject:[NSString stringWithCxxString:pair.second->uuid()]];
			[menuItem setIndentationLevel:1];
		}
	}

	if(ordered.empty())
		[aMenu addItemWithTitle:@"No Themes Loaded" action:@selector(nop:) keyEquivalent:@""];
}

- (void)wrapColumnMenuNeedsUpdate:(NSMenu*)aMenu
{
	D(DBF_AppController_Menus, bug("\n"););
	[aMenu removeAllItems];

	NSMenuItem* menuItem;

	menuItem = [aMenu addItemWithTitle:@"Disable Soft Wrap" action:@selector(toggleSoftWrap:) keyEquivalent:@"w"];
	menuItem.keyEquivalentModifierMask = NSEventModifierFlagCommand|NSEventModifierFlagOption;
	[aMenu addItem:[NSMenuItem separatorItem]];

	SEL action = @selector(takeWrapColumnFrom:);

	menuItem = [aMenu addItemWithTitle:@"To Window Frame" action:action keyEquivalent:@""];
	menuItem.tag = NSWrapColumnWindowWidth;

	NSArray* presets = [[NSUserDefaults standardUserDefaults] arrayForKey:kUserDefaultsWrapColumnPresetsKey];
	for(NSNumber* preset in [presets sortedArrayUsingSelector:@selector(compare:)])
	{
		menuItem = [aMenu addItemWithTitle:[NSString stringWithFormat:@"To %@ Characters", preset] action:action keyEquivalent:@""];
		menuItem.tag = [preset integerValue];
	}

	[aMenu addItem:[NSMenuItem separatorItem]];
	menuItem = [aMenu addItemWithTitle:@"Other…" action:action keyEquivalent:@""];
	menuItem.tag = NSWrapColumnAskUser;
}

- (void)menuNeedsUpdate:(NSMenu*)aMenu
{
	if(aMenu == languageMenu)
		[self languageMenuNeedsUpdate:aMenu];
	else if(aMenu == themesMenu)
		[self themesMenuNeedsUpdate:aMenu];
	else if(aMenu == wrapColumnMenu)
		[self wrapColumnMenuNeedsUpdate:aMenu];
}
@end
