//
//  NCID.h
//  NCID
//
//  Created by Alexei Kosut on Mon Jan 27 2003.
//  Copyright (c) 2003 __MyCompanyName__. All rights reserved.
//  Copyright (c) 2014 David Watson. All rights reserved.
//

#import <AppKit/AppKit.h>
#import <AddressBook/AddressBook.h>

@class NCIDCaller;

@interface NCID : NSObject <ABImageClient> {
    IBOutlet NSView *_contentView;
    IBOutlet NSImageView *_popupImage;
    IBOutlet NSTextField *_popupName;
    IBOutlet NSTextField *_popupNumber;
    IBOutlet NSTextField *_popupDateTime;

    IBOutlet NSWindow *_settingsWindow;
    IBOutlet NSTextField *_settingsHost;
//    IBOutlet NSButton *_settingsUseGrowl;
    
    IBOutlet NSWindow *_callHistoryWindow;
    IBOutlet NSTableView *_callHistoryTableView;
    IBOutlet NSArrayController *_callHistoryController;

    NSWindow *_popupWindow;
    NSTimer *_currentTimer;
    
    NSMutableArray *_callHistory;

    int imageLoadingTag;
}

- (void)showCaller:(NCIDCaller *)infoData;
- (void)hideCaller:(id)sender;

- (void)runThread:(id)arg;

- (IBAction)settingsOK:(id)sender;
- (IBAction)settingsCancel:(id)sender;

- (IBAction)showCallerInfo:(id)sender;
- (IBAction)reverseLookupCaller:(id)sender;
- (IBAction)openCallerInAddressBook:(id)sender;

@end
