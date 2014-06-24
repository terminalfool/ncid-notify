//
//  NSMenu+NCIDExtensions.m
//  ncid
//
//  Created by Nicholas Riley on 8/18/10.
//  Copyright 2010 Nicholas Riley. All rights reserved.
//

#import "NSMenu+NCIDExtensions.h"


@implementation NSMenu (NCIDExtensions)

static unsigned order = UINT_MAX / 2;

- (void)NCID_autohideItemAtIndex:(int)index;
{
    // hide a contextual menu item for the current run loop iteration
    NSMenuItem *item = [[self itemAtIndex:index] retain];
    [self removeItemAtIndex:index];
    
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:@selector(insertItem:atIndex:)]];
    [invocation setSelector:@selector(NCID_insertItem:atIndex:)];
    [invocation setArgument:&item atIndex:2];
    [invocation setArgument:&index atIndex:3];
    [invocation retainArguments];
    [item release];
    
    [[NSRunLoop currentRunLoop] performSelector:@selector(invokeWithTarget:)
					 target:invocation
				       argument:self
					  order:--order
					  modes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
}

- (void)NCID_insertItem:(NSMenuItem *)item atIndex:(int)index;
{
    order = UINT_MAX / 2;
    [self insertItem:item atIndex:index];
}

@end
