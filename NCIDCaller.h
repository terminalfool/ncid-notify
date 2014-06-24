//
//  NCIDCaller.h
//  ncid
//
//  Created by Nicholas Riley on 7/28/08.
//  Copyright 2008 Nicholas Riley. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class ABPerson;

@interface NCIDCaller : NSObject {
    NSString *name;
    NSString *number;
    NSCalendarDate *date;
    BOOL nanpaFormat;
    ABPerson *person;
}

- (NSString *)name;
- (NSString *)number;
- (NSDate *)date;
- (ABPerson *)person;

- (NSURL *)addressBookURL;
- (NSURL *)reverseLookupURL;

- (id)initWithData:(NSData *)infoData;

@end
