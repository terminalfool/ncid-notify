//
//  NCIDCaller.m
//  ncid
//
//  Created by Nicholas Riley on 7/28/08.
//  Copyright 2008 Nicholas Riley. All rights reserved.
//

#import "NCIDCaller.h"
#import <AddressBook/AddressBook.h>
#include "ncid_network.h"
#include <time.h>

@interface ABPhoneFormatter : NSObject
- (id)stringForObjectValue:(id)arg1;
@end

@interface ABPhoneFormatter (PHXSingletonAdditions)
+ (id)sharedPhoneFormatter;
@end

@implementation NCIDCaller

- (NSString *)name;
{
    return name;
}

- (NSString *)areaCode;
{
    return (nanpaFormat ? [number substringWithRange:NSMakeRange(0, 3)] : nil);
}

- (NSString *)npa;
{
    return (nanpaFormat ? [number substringWithRange:NSMakeRange(4, 3)] : nil);
}

- (NSString *)nxx;
{
    return (nanpaFormat ? [number substringFromIndex:8] : nil);
}

- (NSURL *)addressBookURL;
{
    if (person == nil)
	return nil;
    
    return [NSURL URLWithString:[NSString stringWithFormat:@"addressbook://%@", [person uniqueId]]];
}

- (NSURL *)reverseLookupURL;
{
    if (!nanpaFormat)
	return nil;

    NSMutableString *template =
	[[[NSUserDefaults standardUserDefaults] stringForKey:@"ReverseLookupURL"] mutableCopy];
    if (!template)
	return nil;
    
    [template replaceOccurrencesOfString:@"$AREA" withString:[self areaCode] options:0
				   range:NSMakeRange(0, [template length])];
    [template replaceOccurrencesOfString:@"$NPA" withString:[self npa] options:0
				   range:NSMakeRange(0, [template length])];
    [template replaceOccurrencesOfString:@"$NXX" withString:[self nxx] options:0
				   range:NSMakeRange(0, [template length])];
    
    NSURL *url = [NSURL URLWithString:template];
    [template release];
    
    return url;
}
    
- (NSString *)number;
{
    ABPhoneFormatter *formatter = nil;
    if ([ABPhoneFormatter respondsToSelector:@selector(sharedPhoneFormatter)]) {
	formatter = [ABPhoneFormatter sharedPhoneFormatter];
    }
    if (formatter != nil && [formatter respondsToSelector:@selector(stringForObjectValue:)]) {
	NSString *formattedNumber = [formatter stringForObjectValue:number];
	if (formattedNumber != nil) {
	    return formattedNumber;
	}
    } else if (nanpaFormat) {
	return [NSString stringWithFormat:@"+1 (%@) %@-%@", [self areaCode], [self npa], [self nxx]];
    }
    return number;
}

- (NSDate *)date;
{
    return date;
}

- (ABPerson *)person;
{
    return person;
}

static NSString *nameForPerson(ABPerson *person) {
    unsigned flags = [[person valueForProperty:kABPersonFlags] unsignedIntValue];
    enum { lastCommaFirst, lastFirst, firstLast } ordering = lastCommaFirst;

    if ((flags & kABShowAsMask) == kABShowAsCompany) {
	NSString *companyName = [person valueForProperty:kABOrganizationProperty];
	if ([companyName length] > 0)
	    return companyName;
    }
    
    if ((flags & kABNameOrderingMask) == kABLastNameFirst)
	ordering = lastFirst;
    else if ((flags & kABNameOrderingMask) == kABLastNameFirst)
	ordering = firstLast;
    
    NSString *first = [person valueForProperty:kABFirstNameProperty];
    NSString *middle = [person valueForProperty:kABMiddleNameProperty];
    NSString *last = [person valueForProperty:kABLastNameProperty];

    if (middle != nil)
	first = [NSString stringWithFormat:@"%@ %@", first, middle];
    
    if (first == nil)
	return last;
    if (last == nil)
	return first;
    
    switch (ordering) {
	case lastCommaFirst:
	    return [NSString stringWithFormat:@"%@, %@", last, first];
	case lastFirst:
	    return [NSString stringWithFormat:@"%@ %@", last, first];
	case firstLast:
	    return [NSString stringWithFormat:@"%@ %@", first, last];
    }
    
    return nil;
}

// note: return value is not autoreleased
static NSString *asMatchableNumber(NSString *number) {
    static NSCharacterSet *notDecimalDigitCharacterSet = nil;
    static NSCharacterSet *zeroCharacterSet = nil;
    
    NSScanner *scanner = [[NSScanner alloc] initWithString:number];
    NSMutableString *matchableNumber = [[NSMutableString alloc] initWithCapacity:[number length]];
    NSString *digits;
    
    if (notDecimalDigitCharacterSet == nil) {
	notDecimalDigitCharacterSet = [[[NSCharacterSet decimalDigitCharacterSet] invertedSet] retain];
	zeroCharacterSet = [[NSCharacterSet characterSetWithCharactersInString:@"0"] retain];
    }
    [scanner setCharactersToBeSkipped:notDecimalDigitCharacterSet];
    
    // skip leading 0s (considered part of area/city code in some countries, but really a prefix)
    [scanner scanCharactersFromSet:zeroCharacterSet intoString:NULL];
    
    while (![scanner isAtEnd]) {
        if (![scanner scanUpToCharactersFromSet:notDecimalDigitCharacterSet intoString:&digits])
	    continue;
	[matchableNumber appendString:digits];
    }
    [scanner release];
    
    if ([matchableNumber length] < 3) {
	[matchableNumber release];
	return nil;
    }
    
    return matchableNumber;
}

- (id)initWithData:(NSData *)infoData;
{
    if ( (self = [super init]) == nil)
	return nil;

    struct callerid_info info;
    
    NSParameterAssert([infoData length] == sizeof(info));
    [infoData getBytes:&info];
    
    name = [NSString stringWithUTF8String:info.name];
    NSMutableString *prettyName = [name mutableCopy];
    [prettyName replaceOccurrencesOfString:@"," withString:@", " options:0
				     range:NSMakeRange(0, [name length])];
    name = prettyName;
    
    number = [[NSString stringWithUTF8String:info.nmbr] retain];
    nanpaFormat = info.is_nanp_number;

    NSString *matchableNumber = asMatchableNumber(number);
    if (matchableNumber != nil) {
	static ABAddressBook *addressBook = nil;
	if (addressBook == nil)
	    addressBook = [[ABAddressBook sharedAddressBook] retain];
	NSArray *people = [addressBook people];
	NSEnumerator *personEnumerator = [people objectEnumerator];
	
	while ( (person = [personEnumerator nextObject]) != nil) {
	    ABMultiValue *numbers = [person valueForProperty:kABPhoneProperty];
	    int i;
	    
	    for (i = 0 ; i < [numbers count] ; i++) {
		NSString *numberToMatch = asMatchableNumber([numbers valueAtIndex:i]);
		
		if (numberToMatch == nil)
		    continue;
		
		if ( ([numberToMatch length] >= 6 || [matchableNumber length] < 6) &&
		     ([numberToMatch rangeOfString: matchableNumber].length > 0 ||
		      [matchableNumber rangeOfString: numberToMatch].length > 0)) {
		    [numberToMatch release];
		    if ( (name = nameForPerson(person)) == nil) {
			name = prettyName;
			continue;
		    }
		    [prettyName release];
		    NSString *label;
		    if ( (label = [numbers labelAtIndex:i]) != nil)
			name = [[NSString alloc] initWithFormat:@"%@ (%@)", name,
				ABLocalizedPropertyOrLabel(label)];
		    else
			name = [name retain];
		    [person retain];
		    goto matched;
		}
		[numberToMatch release];
	    }
	}
    matched:
	[matchableNumber release];
    }
    
    date = [[NSCalendarDate dateWithString:[NSString stringWithFormat:@"%s %s", info.date, info.time]
			    calendarFormat:@"%m-%d-%Y %I:%M %p"] retain];
    
    return self;
}

- (void)dealloc;
{
    [name release];
    [number release];
    [date release];
    [person release];
    [super dealloc];
}

- (NSString *)description;
{
    return [NSString stringWithFormat:@"%@ %@ %@", name, number, date];
}

@end
