//
//  NPReachability.m
//  
//  Copyright (c) 2011, Nick Paulson
//  All rights reserved.
//  
//  Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
//  
//  Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
//  Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
//  Neither the name of the Nick Paulson nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import "NPReachability.h"

NSString *NPReachabilityChangedNotification = @"NPReachabilityChangedNotification";

@interface NPReachability ()
- (NSArray *)_handlers;

@property (nonatomic, readwrite) SCNetworkReachabilityFlags currentReachabilityFlags;
@end

static void NPNetworkReachabilityCallBack(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
	NPReachability *reach = (NPReachability *)info;
    
    // NPReachability maintains its own copy of |flags| so that KVO works 
    // correctly. Note that -setCurrentReachabilityFlags also triggers KVO
    // for the |currentlyReachable| property.
    [reach setCurrentReachabilityFlags:flags];
    
	NSArray *allHandlers = [reach _handlers];
	for (void (^currHandler)(SCNetworkReachabilityFlags flags) in allHandlers) {
		currHandler(flags);
	}
}

static const void * NPReachabilityRetain(const void *info) {
	NPReachability *reach = (NPReachability *)info;
	return (void*)[reach retain];
}
static void NPReachabilityRelease(const void *info) {
	NPReachability *reach = (NPReachability *)info;
	[reach release];
}
static CFStringRef NPReachabilityCopyDescription(const void *info) {
	NPReachability *reach = (NPReachability *)info;
	return (CFStringRef)[[reach description] copy];
}

@implementation NPReachability

@synthesize currentReachabilityFlags;
@dynamic currentlyReachable;

- (id)init {
	if ((self = [super init])) {
		_handlerByOpaqueObject = [[NSMutableDictionary alloc] init];
		
		struct sockaddr zeroAddr;
		bzero(&zeroAddr, sizeof(zeroAddr));
		zeroAddr.sa_len = sizeof(zeroAddr);
		zeroAddr.sa_family = AF_INET;
		
		_reachabilityRef = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *) &zeroAddr);
		
		SCNetworkReachabilityContext context;
		context.version = 0;
		context.info = (void *)self;
		context.retain = NPReachabilityRetain;
		context.release = NPReachabilityRelease;
		context.copyDescription = NPReachabilityCopyDescription;
		
		if (SCNetworkReachabilitySetCallback(_reachabilityRef, NPNetworkReachabilityCallBack, &context)) {
			SCNetworkReachabilityScheduleWithRunLoop(_reachabilityRef, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
		}
        SCNetworkReachabilityGetFlags(_reachabilityRef, &currentReachabilityFlags);
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
	}
	return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    
    if (_reachabilityRef != NULL) {
        SCNetworkReachabilityUnscheduleFromRunLoop(_reachabilityRef, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
        CFRelease(_reachabilityRef);
        _reachabilityRef = NULL;
    }
	
	[_handlerByOpaqueObject release];
	_handlerByOpaqueObject = nil;
    
    [super dealloc];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    // We don't receive network reachability flags in the background, usually.
    // (Exceptions are made for apps like voip or music streaming.)
    // Update the reachability flags since we're now coming back to the
    // foreground.
    
    SCNetworkReachabilityFlags flags;
    if (SCNetworkReachabilityGetFlags(_reachabilityRef, &flags)) {
        [self setCurrentReachabilityFlags:flags];
    }
}

- (NSArray *)_handlers {
	return [_handlerByOpaqueObject allValues];
}

- (id)addHandler:(void (^)(SCNetworkReachabilityFlags flags))handler {
	NSString *obj = [[NSProcessInfo processInfo] globallyUniqueString];
	[_handlerByOpaqueObject setObject:[[handler copy] autorelease] forKey:obj];
	return obj;
}

- (void)removeHandler:(id)opaqueObject {
	[_handlerByOpaqueObject removeObjectForKey:opaqueObject];
}

- (BOOL)isCurrentlyReachable {
	return [[self class] isReachableWithFlags:[self currentReachabilityFlags]];
}

+ (BOOL)automaticallyNotifiesObserversOfCurrentlyReachable {
    return NO;
}

- (void)setCurrentReachabilityFlags:(SCNetworkReachabilityFlags)newReachabilityFlags {
    if (newReachabilityFlags == currentReachabilityFlags) {
        return;
    }
    
    BOOL oldCurrentlyReachable = [NPReachability isReachableWithFlags:currentReachabilityFlags];
    BOOL newCurrentlyReachable = [NPReachability isReachableWithFlags:newReachabilityFlags];
    BOOL currentlyReachableChanged = (oldCurrentlyReachable != newCurrentlyReachable);
    
    if (currentlyReachableChanged) [self willChangeValueForKey:@"currentlyReachable"];
    [self willChangeValueForKey:@"currentReachabilityFlags"];
    currentReachabilityFlags = newReachabilityFlags;
    [self didChangeValueForKey:@"currentReachabilityFlags"];
    if (currentlyReachableChanged) [self didChangeValueForKey:@"currentlyReachable"];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:NPReachabilityChangedNotification object:self];
}

+ (BOOL)automaticallyNotifiesObserversOfCurrentReachabilityFlags {
    return NO;
}

+ (BOOL)isReachableWithFlags:(SCNetworkReachabilityFlags)flags {
	
	if ((flags & kSCNetworkReachabilityFlagsReachable) == 0) {
		// if target host is not reachable
		return NO;
	}
	
	if ((flags & kSCNetworkReachabilityFlagsConnectionRequired) == 0) {
		// if target host is reachable and no connection is required
		//  then we'll assume (for now) that your on Wi-Fi
		return YES;
	}
	
	
	if ((((flags & kSCNetworkReachabilityFlagsConnectionOnDemand ) != 0) ||
		 (flags & kSCNetworkReachabilityFlagsConnectionOnTraffic) != 0)) {
		// ... and the connection is on-demand (or on-traffic) if the
		//     calling application is using the CFSocketStream or higher APIs
		
		if ((flags & kSCNetworkReachabilityFlagsInterventionRequired) == 0) {
			// ... and no [user] intervention is needed
			return YES;
		}
	}
	
	return NO;
}

#pragma mark - Singleton Methods

+ (void)load {
    [super load];
    
    // Attempt to initialize the shared instance so that NSNotifications are 
    // sent even if you never initialize the class
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NPReachability sharedInstance];
    [pool drain];
}

+ (NPReachability *)sharedInstance
{
    static NPReachability *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (id)copyWithZone:(NSZone *)zone
{
    return self;
}

@end
