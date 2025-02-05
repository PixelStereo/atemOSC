/* -LICENSE-START-
 ** Copyright (c) 2011 Blackmagic Design
 **
 ** Permission is hereby granted, free of charge, to any person or organization
 ** obtaining a copy of the software and accompanying documentation covered by
 ** this license (the "Software") to use, reproduce, display, distribute,
 ** execute, and transmit the Software, and to prepare derivative works of the
 ** Software, and to permit third-parties to whom the Software is furnished to
 ** do so, all subject to the following:
 **
 ** The copyright notices in the Software and this entire statement, including
 ** the above license grant, this restriction and the following disclaimer,
 ** must be included in all copies of the Software, in whole or in part, and
 ** all derivative works of the Software, unless such copies or derivative
 ** works are solely in the form of machine-executable object code generated by
 ** a source language processor.
 **
 ** THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 ** IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 ** FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
 ** SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
 ** FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
 ** ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 ** DEALINGS IN THE SOFTWARE.
 ** -LICENSE-END-
 */

#import "AppDelegate.h"
#include <libkern/OSAtomic.h>
#import "OSCReceiver.h"
#import <Bugsnag/Bugsnag.h>

@implementation AppDelegate

@synthesize endpoints;
@synthesize inPort;
@synthesize manager;
@synthesize switchers;

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	[Bugsnag start];
	
	endpoints = [[NSMutableArray alloc] init];
	mOscReceiver = [[OSCReceiver alloc] initWithDelegate:self];
	
	// Load switchers from preferences
	switchers = [[NSMutableArray alloc] init];
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSArray *uids = [defaults stringArrayForKey:@"switchers"];
	for (NSString *uid : uids)
	{
		NSData *encodedObject = [defaults objectForKey:[NSString stringWithFormat:@"switcher-%@", uid]];
		if (encodedObject != nil)
		{
			Switcher *switcher = [NSKeyedUnarchiver unarchiveObjectWithData:encodedObject];
			[switcher setAppDelegate:self];
			[switchers addObject:switcher];
		}
	}

	if ([switchers count] == 0)
	{
		[self addSwitcher];
	}
	
	// Create switcher discovery instance here just to check if SDK is working
	IBMDSwitcherDiscovery *switcherDiscovery = CreateBMDSwitcherDiscoveryInstance();
	if (!switcherDiscovery)
	{
		NSBeginAlertSheet(@"Could not find ATEM Software, which is required for atemOSC to work. ATEM Switcher Software may not be installed, or you may be running an older version that is not compatible with this version of atemOSC.\n",
						  @"OK", nil, nil, window, self, @selector(sheetDidEndShouldTerminate:returnCode:contextInfo:), nil, nil, @"");
	}
	else
	{
		manager = [[OSCManager alloc] init];
		[manager setDelegate:mOscReceiver];
		
		NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];

		int incomingPort = 3333;
		if ([prefs integerForKey:@"incoming"])
			incomingPort = (int) [prefs integerForKey:@"incoming"];

		[self incomingPortChanged:incomingPort];
	}
	
	[self checkForUpdate];
	
	dispatch_async(dispatch_get_main_queue(), ^{
		Window *window = (Window *) [[NSApplication sharedApplication] mainWindow];
		self->window = window;
		
		[self->window loadSettingsFromPreferences];
		
		[[self->window outlineView] reloadData];
		NSIndexSet* indexes = [[NSIndexSet alloc] initWithIndex:1];
		[[self->window outlineView] selectRowIndexes:indexes byExtendingSelection:NO];
		
		// Hoping that by the time the main queue is available on computer startup, the networking is up and the auto-reconnect works
		for (Switcher *switcher in self->switchers)
		{
			if ([switcher connectAutomatically] && [switcher ipAddress])
				[switcher connectBMD];
		}
	});
}

- (void)applicationWillBecomeActive:(NSNotification *)notification
{
	[[self->window outlineView] refreshList];
	[[self->window connectionView] loadFromSwitcher:[[self->window connectionView] switcher]];
}

- (void)checkForUpdate
{
	NSString *url_string = [NSString stringWithFormat: @"https://api.github.com/repos/SteffeyDev/atemOSC/releases/latest"];
	NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
	[request setHTTPMethod:@"GET"];
	[request setURL:[NSURL URLWithString:url_string]];
	
	// Don't want to use cached response
	[[NSURLCache sharedURLCache] removeAllCachedResponses];
	
	[NSURLConnection sendAsynchronousRequest:request queue:[[NSOperationQueue alloc] init] completionHandler:^(NSURLResponse *response,
							NSData *data,
							NSError *error)
		{
			if (error == nil)
			{
				NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
				NSString *availableVersion = [[json objectForKey:@"name"] stringByReplacingOccurrencesOfString:@"v" withString:@""];
				NSString *installedVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
				NSLog(@"version available: %@", availableVersion);
				NSLog(@"version installed: %@", installedVersion);
				if (![availableVersion isEqualToString:installedVersion])
				{
					dispatch_async(dispatch_get_main_queue(), ^{

						NSAlert *alert = [[NSAlert alloc] init];
						[alert setMessageText:@"New Version Available"];
						[alert setInformativeText:@"There is a new version of AtemOSC available!"];
						[alert addButtonWithTitle:@"Go to Download"];
						[alert addButtonWithTitle:@"Skip"];
						[alert beginSheetModalForWindow:[[NSApplication sharedApplication] mainWindow] completionHandler:^(NSInteger returnCode)
						 {
							 if ( returnCode == NSAlertFirstButtonReturn )
							 {
								 [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/SteffeyDev/atemOSC/releases/latest"]];
							 }
						 }];
					});
				}
			}
		 }];
}

- (void)incomingPortChanged:(int)inPortValue
{
	if (inPort == nil)
		inPort = [manager createNewInputForPort:inPortValue withLabel:@"atemOSC"];
	else if (inPortValue != [inPort port])
		[inPort setPort:inPortValue];
}

- (void)applicationWillTerminate:(NSNotification*)aNotification
{
	for (Switcher *switcher in switchers)
	{
		[switcher cleanUpConnection];
	}
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
	return YES;
}

- (void)sheetDidEndShouldTerminate:(NSWindow *)sheet returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
{
	[NSApp terminate:self];
}

- (IBAction)githubPageButtonPressed:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/SteffeyDev/atemOSC/"]];
}

- (IBAction)bugFeatureButtonPressed:(id)sender;
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/SteffeyDev/atemOSC/issues/new"]];
}

- (IBAction)websiteButtonPressed:(id)sender;
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://www.atemosc.com"]];
}

- (void) addSwitcher
{
	Switcher *newSwitcher = [[Switcher alloc] init];
	[newSwitcher setAppDelegate:self];
	CFUUIDRef UUID = CFUUIDCreate(kCFAllocatorDefault);
	[newSwitcher setUid: (NSString *) CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault,UUID))];
	[newSwitcher saveChanges];
	[switchers addObject:newSwitcher];
	
	NSMutableArray *uids = [[NSMutableArray alloc] init];
	for (Switcher *switcher: switchers)
	{
		[uids addObject:[switcher uid]];
	}
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults setValue:[NSArray arrayWithArray: uids] forKey:@"switchers"];
	[defaults synchronize];
	
	[[window outlineView] reloadData];
	NSIndexSet* indexes = [[NSIndexSet alloc] initWithIndex:[switchers count]];
	[[window outlineView] selectRowIndexes:indexes byExtendingSelection:NO];
}

- (void) removeSwitcher:(Switcher *)switcher
{
	NSString *uid = [[switcher uid] copy];
	
	[switchers removeObject: switcher];
	[[window outlineView] reloadData];
	
	NSMutableArray *uids = [[NSMutableArray alloc] init];
	for (Switcher *switcher: switchers)
	{
		[uids addObject:[switcher uid]];
	}
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults setValue:[NSArray arrayWithArray: uids] forKey:@"switchers"];
	[defaults removeObjectForKey:[NSString stringWithFormat:@"switcher-%@",uid]];
	[defaults synchronize];
}

- (void)logMessage:(NSString *)message;
{
	[[window logView] logMessage:message];
}

@end
