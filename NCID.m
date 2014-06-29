//
//  NCID.m
//  NCID
//
//  Created by Alexei Kosut on Mon Jan 27 2003.
//  Copyright (c) 2003 __MyCompanyName__. All rights reserved.`
//  Copyright (c) 2014 David Watson. All rights reserved.
//

#import "NCID.h"
#import "NCIDCaller.h"
#import "NSMenu+NCIDExtensions.h"
//#import <Growl/Growl.h>
#include "ncid_network.h"
#include <Carbon/Carbon.h>
#include <SystemConfiguration/SystemConfiguration.h>

@interface NCID (NCIDPrivateMethods)
- (int)_runModalForWindow:(NSWindow *)window;
- (void)_editSettings;
- (void)_startThread;
- (void)_stopThread;
- (BOOL)_isCommandKeyDown;
@end

static const int HISTORY_SIZE = 100;

static BOOL isReachable = NO;
static SCNetworkReachabilityRef networkReachability;

@implementation NCID

- (float)cellHeight {
    return [_callHistoryTableView rowHeight] + [_callHistoryTableView intercellSpacing].height;
}

- (void)awakeFromNib {
    _popupWindow = [[NSWindow alloc] initWithContentRect:[_contentView frame] styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:YES screen:[NSScreen mainScreen]];

    [_popupWindow setContentView:_contentView];

    [_popupWindow setLevel:NSStatusWindowLevel];
    [_popupWindow setBackgroundColor:[NSColor colorWithCalibratedWhite:0.0 alpha:0.5]];
    [_popupWindow setOpaque:NO];

    [_popupWindow setIgnoresMouseEvents:YES];
    [_popupWindow setReleasedWhenClosed:NO];
    
    NSSortDescriptor *dateDescending = [[NSSortDescriptor alloc] initWithKey:@"date" ascending:NO];
    [_callHistoryTableView setSortDescriptors:[NSArray arrayWithObject:dateDescending]];
    [_callHistoryTableView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    [dateDescending release];
    
    [_callHistoryWindow setResizeIncrements: NSMakeSize(1, [self cellHeight])];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    _callHistory = [[NSMutableArray alloc] init];

    if ([defaults stringForKey:@"NCIDServer"] == nil || [self _isCommandKeyDown]) {
	[self _editSettings];
    }
    
    set_leading_one_state(0); // strip leading 1

    [self _startThread];
    
    if ([defaults boolForKey:@"NCIDShowHistoryAtLaunch"]) {
	[_callHistoryWindow makeKeyAndOrderFront:self];
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)flag {
    if ([self _isCommandKeyDown]) {
	[self _stopThread];
	[self _editSettings];
	[self _startThread];
    } else {
	[_callHistoryWindow makeKeyAndOrderFront:self];
    }
        
    return NO;
}

static void ncid_connect_callback(void *object, const int connect) {
    // connecting?
}

static void ncid_callback(void *object, const struct callerid_info *info) {
    [(NCID *)object performSelectorOnMainThread:@selector(showCaller:)
	withObject:[[[NCIDCaller alloc] initWithData:[NSData dataWithBytes:info length:sizeof(struct callerid_info)]] autorelease]
        waitUntilDone:NO];
}

static void ncid_history_callback(void *object, const struct callerid_info *info) {
    if (info == NULL) {
	[(NCID *)object setValue:[[[NSMutableArray alloc] init] autorelease] forKey:@"_callHistory"];
	return;
    }
    [(NCID *)object performSelectorOnMainThread:@selector(addCallerToHistory:)
	 withObject:[[[NCIDCaller alloc] initWithData:[NSData dataWithBytes:info length:sizeof(struct callerid_info)]] autorelease]
	 waitUntilDone:NO];
}

static void ncid_call_info_callback(void *object, const struct calleridinfo_info *info) {
    // call received
}

static void ncid_message_callback(void *object, const char *message) {
    [(NCID *)object performSelectorOnMainThread:@selector(showMessage:)
	     withObject:[NSString stringWithUTF8String:message]
	     waitUntilDone:NO];
}

static void ncid_info_callback(void *object, int messagenum, const char *message) {
    // info message 200 provides the NCIDD server name
    // info message 300 indicates that a call log has finished transmitting
    // if (messagenum == 200) {
    // 	NSLog(@"server name: %s", message);
    // }
}

static void networkReachabilityCallback(SCNetworkReachabilityRef target,
					SCNetworkConnectionFlags flags,
					void *object) {
    // Observed flags:
    // - nearly gone: kSCNetworkFlagsReachable alone (ignored)
    // - gone: kSCNetworkFlagsTransientConnection | kSCNetworkFlagsReachable | kSCNetworkFlagsConnectionRequired
    // - connected: kSCNetworkFlagsIsDirect | kSCNetworkFlagsReachable

    if (networkReachability == NULL)
	return;
    
    if ((flags & kSCNetworkFlagsReachable) && !(flags & kSCNetworkFlagsConnectionRequired)) {
	if (isReachable) // typically receive a reachable message ~20ms before the unreachable one
	    return;

	isReachable = YES;
	ncid_network_kill();
	[NSThread detachNewThreadSelector:@selector(runThread:) toTarget:object withObject:nil];
    } else {
	isReachable = NO;
	ncid_network_kill();
    }
}

- (void)runThread:(id)arg {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSString *server = [[NSUserDefaults standardUserDefaults] stringForKey:@"NCIDServer"];
    
    ncid_network_loop([server UTF8String], ncid_connect_callback, ncid_callback, ncid_history_callback, ncid_call_info_callback, ncid_message_callback, ncid_info_callback, self);

    [pool release];
}

- (void)_startThread {
    NSString *server = [[NSUserDefaults standardUserDefaults] stringForKey:@"NCIDServer"];

    if (server == nil) {
        ncid_message_callback(self, [NSLocalizedString(@"No caller ID server was specified.", nil) UTF8String]);
        return;
    }
    
    const char *serverName = [[[server componentsSeparatedByString:@":"] objectAtIndex:0] UTF8String];
    SCNetworkReachabilityContext context = {0, (void *)self, NULL, NULL, NULL};
    networkReachability = SCNetworkReachabilityCreateWithName(NULL, serverName);
    if (networkReachability == NULL)
	goto fail;
    // If reachability information is available now, we don't get a callback later
    SCNetworkConnectionFlags flags;
    if (SCNetworkReachabilityGetFlags(networkReachability, &flags))
	networkReachabilityCallback(networkReachability, flags, self);
    if (!SCNetworkReachabilitySetCallback(networkReachability, networkReachabilityCallback, &context))
	goto fail;
    if (!SCNetworkReachabilityScheduleWithRunLoop(networkReachability, [[NSRunLoop currentRunLoop] getCFRunLoop], kCFRunLoopCommonModes))
	goto fail;
    return;
    
fail:
    if (networkReachability != NULL)
	CFRelease(networkReachability);
    networkReachability = NULL;
    
    [NSThread detachNewThreadSelector:@selector(runThread:) toTarget:self withObject:nil];
}

- (void)_stopThread {
    SCNetworkReachabilityUnscheduleFromRunLoop(networkReachability, [[NSRunLoop currentRunLoop] getCFRunLoop], kCFRunLoopCommonModes);
    networkReachability = NULL;

    isReachable = NO;
    ncid_network_kill();
}

- (void)addCallerToHistory:(NCIDCaller *)caller {
    if ([_callHistory count] >= HISTORY_SIZE) {
	NSRange range = NSMakeRange(0, [_callHistory count] - HISTORY_SIZE + 1);
	[_callHistory removeObjectsInRange:range];
	[self didChange:NSKeyValueChangeRemoval valuesAtIndexes:[NSIndexSet indexSetWithIndexesInRange:range]
		 forKey:@"_callHistory"];
    }
    [_callHistoryController addObject:caller];
    [_callHistoryController rearrangeObjects];
}

- (void)showCaller:(NCIDCaller *)caller {
    [self addCallerToHistory:caller];
    
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.title = [caller name];
    notification.subtitle = [caller number];
    [notification set_identityImage:[NSImage imageNamed:@"[[caller person] imageData]"]];
    [NSUserNotificationCenter.defaultUserNotificationCenter deliverNotification:notification];

/*
 if ([[NSUserDefaults standardUserDefaults] boolForKey:@"UseGrowl"] && [GrowlApplicationBridge isGrowlRunning]) {
	[GrowlApplicationBridge setGrowlDelegate:@""];
	[GrowlApplicationBridge notifyWithTitle:[caller name]
				    description:[caller number]
			       notificationName:@"Incoming Call"
				       iconData:[[caller person] imageData]
				       priority:0
				       isSticky:NO
				   clickContext:nil];
	return;
    }
    
    [_popupName setStringValue:[caller name]];
    [_popupNumber setStringValue:[caller number]];
    [_popupDateTime setObjectValue:[caller date]];
    [_popupImage setImage:[NSImage imageNamed:@"NSApplicationIcon"]];
    imageLoadingTag = [[caller person] beginLoadingImageDataForClient:self];
    [_popupWindow makeKeyAndOrderFront:self];
    
*/
    [_currentTimer invalidate];
    [_currentTimer release];
    NSTimeInterval timeInterval = [[NSUserDefaults standardUserDefaults] floatForKey:@"MessageDisplayTime"];
    if (timeInterval <= 0)
	timeInterval = 20;
    _currentTimer = [[NSTimer scheduledTimerWithTimeInterval:timeInterval target:self selector:@selector(hideCaller:)
						    userInfo:nil repeats:NO] retain];
}

- (void)showMessage:(NSString *)message {
    [self _runModalForWindow:NSGetInformationalAlertPanel(message, @"", NSLocalizedString(@"OK", nil),
                                                          nil, nil)];
}

- (void)consumeImageData:(NSData *)data forTag:(int)tag;
{
    if (data == nil)
	return;
    
    [_popupImage setImage:[[[NSImage alloc] initWithData:data] autorelease]];
}

- (void)hideCaller:(id)sender {
    [_popupWindow orderOut:nil];
    [ABPerson cancelLoadingImageDataForTag:imageLoadingTag];

    [_currentTimer invalidate];
    [_currentTimer release];
    _currentTimer = nil;
}

- (void)dealloc {
    [_popupWindow release];
    [_currentTimer invalidate];
    [_currentTimer release];
    [super dealloc];
}

- (IBAction)settingsOK:(id)sender {
    // see http://www.red-sweater.com/blog/229/stay-responsive
    if (![_settingsWindow makeFirstResponder:_settingsWindow])
	[_settingsWindow endEditingFor:nil];
    
    [NSApp stopModalWithCode:NSOKButton];
}

- (IBAction)settingsCancel:(id)sender {
    [NSApp stopModalWithCode:NSCancelButton];
}

- (NCIDCaller *)_clickedCaller;
{
    int clickedRow = [_callHistoryTableView clickedRow];
    if (clickedRow == -1)
	return nil;
    
    return [[_callHistoryController arrangedObjects] objectAtIndex:clickedRow];
}

- (IBAction)reverseLookupCaller:(id)sender;
{
    [[NSWorkspace sharedWorkspace] openURL:[[self _clickedCaller] reverseLookupURL]];
}

- (IBAction)openCallerInAddressBook:(id)sender;
{
    [[NSWorkspace sharedWorkspace] openURL:[[self _clickedCaller] addressBookURL]];
}

- (void)menuNeedsUpdate:(NSMenu *)menu;
{
    NCIDCaller *clickedCaller = [self _clickedCaller];
    if ([clickedCaller reverseLookupURL] == nil)
	[menu NCID_autohideItemAtIndex:
	  [menu indexOfItemWithTarget:self andAction:@selector(reverseLookupCaller:)]];
    if ([clickedCaller person] == nil)
	[menu NCID_autohideItemAtIndex:
	 [menu indexOfItemWithTarget:self andAction:@selector(openCallerInAddressBook:)]];

    int lastIndex = [menu numberOfItems] - 1;
    if ([[menu itemAtIndex:lastIndex] isSeparatorItem])
	[menu NCID_autohideItemAtIndex:lastIndex];
}

- (IBAction)showCallerInfo:(id)sender;
{
    NSArray *selectedCallers = [_callHistoryController selectedObjects];
    if ([selectedCallers count] != 1)
	return;
    
    NCIDCaller *caller = [selectedCallers objectAtIndex:0];
    ABPerson *person = [caller person];
    NSURL *url = (person == nil) ? [caller reverseLookupURL] : [caller addressBookURL];
    
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (BOOL)tableView:(NSTableView *)tv writeRowsWithIndexes:(NSIndexSet *)indexes toPasteboard:(NSPasteboard *)pboard;
{
    unsigned count = [indexes count];
    if (count == 0)
	return NO;

    NSArray *callers = [_callHistoryController arrangedObjects];
    NSMutableArray *numbers = [[NSMutableArray alloc] initWithCapacity:count];
    for (unsigned index = [indexes firstIndex] ; index != NSNotFound ;
	 index = [indexes indexGreaterThanIndex:index]) {
	NCIDCaller *caller = [callers objectAtIndex:index];
	[numbers addObject:[caller number]];
    }
    [pboard declareTypes:[NSArray arrayWithObjects:NSStringPboardType, nil] owner:nil];
    [pboard setString:[numbers componentsJoinedByString:@"\n"] forType:NSStringPboardType];
    [numbers release];
    return YES;
}

- (void)copy:(id)sender;
{
    NSIndexSet *rowIndexes = [_callHistoryTableView selectedRowIndexes];
    int clickedRow = [_callHistoryTableView clickedRow];

    if (clickedRow != -1 && ![rowIndexes containsIndex:clickedRow])
        rowIndexes = [NSIndexSet indexSetWithIndex:clickedRow];

    [self tableView:_callHistoryTableView writeRowsWithIndexes:rowIndexes toPasteboard:[NSPasteboard generalPasteboard]];
}

- (void)_editSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *currentHost = [defaults stringForKey:@"NCIDServer"];

    [NSBundle loadNibNamed:@"Settings" owner:self];

    [_settingsHost setStringValue:currentHost ? currentHost : @"localhost"];
 //   [_settingsUseGrowl setEnabled:[GrowlApplicationBridge isGrowlRunning]];

    if ([self _runModalForWindow:_settingsWindow] != NSOKButton)
	return;
    
    [defaults setObject:[_settingsHost stringValue] forKey:@"NCIDServer"];
    [defaults synchronize];
/*
 if ([defaults boolForKey:@"UseGrowl"]) {
	[GrowlApplicationBridge registerWithDictionary:
	 [NSDictionary dictionaryWithContentsOfFile:
	  [[NSBundle mainBundle] pathForResource:@"Growl Registration Ticket"
					  ofType:@"growlRegDict"]]];
    }
*/
}

- (int)_runModalForWindow:(NSWindow *)window {
    NSModalSession session = [NSApp beginModalSessionForWindow:window];
    int code;

    /* bring our windows to the foreground and keep them there. */
    [NSApp activateIgnoringOtherApps:YES];

    for (;;) {
        [window setLevel:NSStatusWindowLevel];
        if ((code = [NSApp runModalSession:session]) != NSRunContinuesResponse)
            break;
    }
    [NSApp endModalSession:session];
    [window close];

    return code;
}

- (BOOL)_isCommandKeyDown {
    return ([[NSApp currentEvent] modifierFlags] & NSCommandKeyMask) ||
	   (GetCurrentKeyModifiers() & cmdKey);
}

- (NSRect)windowWillUseStandardFrame:(NSWindow *)window defaultFrame:(NSRect)defaultFrame;
{
    NSRect frame = [window frame];
    NSScrollView *scrollView = [_callHistoryTableView enclosingScrollView];
    float displayedHeight = [[scrollView contentView] bounds].size.height;
    float heightChange = [[scrollView documentView] bounds].size.height - displayedHeight;
    float heightExcess;
    
    if (heightChange >= 0 && heightChange <= 1) {
        // either the window is already optimal size, or it's too big
        float rowHeight = [self cellHeight];
        heightChange = (rowHeight * [_callHistoryTableView numberOfRows]) - displayedHeight;
    }
    
    frame.size.height += heightChange;
    
    if ( (heightExcess = [window minSize].height - frame.size.height) > 1 ||
	(heightExcess = [window maxSize].height - frame.size.height) < 1) {
        heightChange += heightExcess;
        frame.size.height += heightExcess;
    }
    
    frame.origin.y -= heightChange;
    
    return frame;
}

@end
