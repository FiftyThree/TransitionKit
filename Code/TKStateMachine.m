//
//  TKStateMachine.m
//  TransitionKit
//
//  Created by Blake Watters on 3/17/13.
//  Copyright (c) 2013 Blake Watters. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "TKStateMachine.h"
#import "TKState.h"
#import "TKEvent.h"
#import "Core/NSTimer+Helpers.h"

@interface TKEvent ()
@property (nonatomic, copy) BOOL (^shouldFireEventBlock)(TKEvent *event, TKStateMachine *stateMachine);
@property (nonatomic, copy) void (^willFireEventBlock)(TKEvent *event, TKStateMachine *stateMachine);
@property (nonatomic, copy) void (^didFireEventBlock)(TKEvent *event, TKStateMachine *stateMachine);
@end

@interface TKState ()
@property (nonatomic, copy) void (^willEnterStateBlock)(TKState *state, TKStateMachine *stateMachine);
@property (nonatomic, copy) void (^didEnterStateBlock)(TKState *state, TKStateMachine *stateMachine);
@property (nonatomic, copy) void (^willExitStateBlock)(TKState *state, TKStateMachine *stateMachine);
@property (nonatomic, copy) void (^didExitStateBlock)(TKState *state, TKStateMachine *stateMachine);
@property (nonatomic, copy) void (^timeoutExpiredBlock)(TKState *state, TKStateMachine *stateMachine);
@end

NSString *const TKErrorDomain = @"org.blakewatters.TransitionKit.errors";
NSString *const TKStateMachineDidChangeStateNotification = @"TKStateMachineDidChangeStateNotification";
NSString *const TKStateMachineStateTimeoutDidExpireNotification = @"TKStateMachineStateTimeoutDidExpireNotification";
NSString *const TKStateMachineStateTimeoutDidExpireUserInfoKey = @"expired";
NSString *const TKStateMachineDidChangeStateOldStateUserInfoKey = @"old";
NSString *const TKStateMachineDidChangeStateNewStateUserInfoKey = @"new";
NSString *const TKStateMachineDidChangeStateEventUserInfoKey = @"event";

NSString *const TKStateMachineIsImmutableException = @"TKStateMachineIsImmutableException";

#define TKRaiseIfActive() \
    if ([self isActive]) [NSException raise:TKStateMachineIsImmutableException format:@"Unable to modify state machine: The state machine has already been activated."];

static NSString *TKQuoteString(NSString *string)
{
    return string ? [NSString stringWithFormat:@"'%@'", string] : nil;
}

@interface TKStateMachine ()
@property (nonatomic, strong) NSMutableSet *mutableStates;
@property (nonatomic, strong) NSMutableSet *mutableEvents;
@property (nonatomic, assign, getter = isActive) BOOL active;
@property (nonatomic, strong, readwrite) TKState *currentState;
@property (nonatomic, strong) NSTimer *stateTimeoutTimer;
@end

@implementation TKStateMachine

+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key
{
    NSSet *keyPaths = [super keyPathsForValuesAffectingValueForKey:key];
    
    if ([key isEqualToString:@"states"]) {
        NSSet *affectingKey = [NSSet setWithObject:@"mutableStates"];
        keyPaths = [keyPaths setByAddingObjectsFromSet:affectingKey];
        return keyPaths;
    } else if ([key isEqualToString:@"events"]) {
        NSSet *affectingKey = [NSSet setWithObject:@"mutableEvents"];
        keyPaths = [keyPaths setByAddingObjectsFromSet:affectingKey];
        return keyPaths;
    }
    
    return keyPaths;
}

- (id)init
{
    self = [super init];
    if (self) {
        self.mutableStates = [NSMutableSet set];
        self.mutableEvents = [NSMutableSet set];
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@:%p %ld States, %ld Events. currentState=%@, initialState='%@', isActive=%@>",
            NSStringFromClass([self class]), self, (unsigned long) [self.mutableStates count], (unsigned long) [self.mutableEvents count],
            TKQuoteString(self.currentState.name), self.initialState.name, self.isActive ? @"YES" : @"NO"];
}

- (void)setInitialState:(TKState *)initialState
{
    TKRaiseIfActive();
    _initialState = initialState;
}

- (void)setCurrentState:(TKState *)currentState
{
    _currentState = currentState;

    [self resetStateTimeoutTimer];
}

- (void)resetStateTimeoutTimer
{
    [self.stateTimeoutTimer invalidate];
    self.stateTimeoutTimer = nil;
    
    if (self.currentState.timeoutDuration > 0)
    {
        self.stateTimeoutTimer = [NSTimer weakScheduledTimerWithTimeInterval:self.currentState.timeoutDuration
                                                                      target:self
                                                                    selector:@selector(stateTimeoutTimerFired:)
                                                                    userInfo:nil
                                                                     repeats:NO];
    }
}

- (void)stateTimeoutTimerFired:(NSTimer *)timer
{
    NSDictionary *userInfo = @{ TKStateMachineStateTimeoutDidExpireUserInfoKey: self.currentState };
    [[NSNotificationCenter defaultCenter] postNotificationName:TKStateMachineStateTimeoutDidExpireNotification object:self userInfo:userInfo];
    
    if (self.currentState.timeoutExpiredBlock)
    {
        self.currentState.timeoutExpiredBlock(self.currentState, self);
    }
}

- (NSSet *)states
{
    return [NSSet setWithSet:self.mutableStates];
}

- (void)addState:(TKState *)state
{
    TKRaiseIfActive();
    if (! [state isKindOfClass:[TKState class]]) [NSException raise:NSInvalidArgumentException format:@"Expected a `TKState` object or `NSString` object specifying the name of a state, instead got a `%@` (%@)", [state class], state];
    if (self.initialState == nil) self.initialState = state;
    [self.mutableStates addObject:state];
}

- (void)addStates:(NSArray *)arrayOfStates
{
    TKRaiseIfActive();
    for (TKState *state in arrayOfStates) {
        [self addState:state];
    }
}

- (TKState *)stateNamed:(NSString *)name
{
    for (TKState *state in self.mutableStates) {
        if ([state.name isEqualToString:name]) return state;
    }
    return nil;
}

- (BOOL)isInState:(id)stateOrStateName
{
    if (! [stateOrStateName isKindOfClass:[TKState class]] && ![stateOrStateName isKindOfClass:[NSString class]]) [NSException raise:NSInvalidArgumentException format:@"Expected a `TKState` object or `NSString` object specifying the name of a state, instead got a `%@` (%@)", [stateOrStateName class], stateOrStateName];
    TKState *state = [stateOrStateName isKindOfClass:[TKState class]] ? stateOrStateName : [self stateNamed:stateOrStateName];
    if (! state) [NSException raise:NSInvalidArgumentException format:@"Cannot find a State named '%@'", stateOrStateName];
    return [self.currentState isEqual:state];
}

- (NSSet *)events
{
    return [NSSet setWithSet:self.mutableEvents];
}

- (void)addEvent:(TKEvent *)event
{
    TKRaiseIfActive();
    if (! event) [NSException raise:NSInvalidArgumentException format:@"Cannot add a `nil` event to the state machine."];
    if (event.sourceStates) {
        for (TKState *state in event.sourceStates) {
            if (! [self.mutableStates containsObject:state]) {
                [NSException raise:NSInternalInconsistencyException format:@"Cannot add event '%@' to the state machine: the event references a state '%@', which has not been added to the state machine.", event.name, state.name];
            }
        }
    }
    if (! [self.mutableStates containsObject:event.destinationState]) [NSException raise:NSInternalInconsistencyException format:@"Cannot add event '%@' to the state machine: the event references a state '%@', which has not been added to the state machine.", event.name, event.destinationState.name];
    [self.mutableEvents addObject:event];
}

- (void)addEvents:(NSArray *)arrayOfEvents
{
    TKRaiseIfActive();
    for (TKEvent *event in arrayOfEvents) {
        [self addEvent:event];
    }
}

- (TKEvent *)eventNamed:(NSString *)name
{
    for (TKEvent *event in self.mutableEvents) {
        if ([event.name isEqualToString:name]) return event;
    }
    return nil;
}

- (void)activate
{
    if (self.isActive) [NSException raise:NSInternalInconsistencyException format:@"The state machine has already been activated."];
    self.active = YES;
    
    // Dispatch callbacks to establish initial state
    if (self.initialState.willEnterStateBlock) self.initialState.willEnterStateBlock(self.initialState, self);
    self.currentState = self.initialState;
    if (self.initialState.didEnterStateBlock) self.initialState.didEnterStateBlock(self.initialState, self);
}

- (BOOL)canFireEvent:(id)eventOrEventName
{
    if (! [eventOrEventName isKindOfClass:[TKEvent class]] && ![eventOrEventName isKindOfClass:[NSString class]]) [NSException raise:NSInvalidArgumentException format:@"Expected a `TKEvent` object or `NSString` object specifying the name of an event, instead got a `%@` (%@)", [eventOrEventName class], eventOrEventName];
    TKEvent *event = [eventOrEventName isKindOfClass:[TKEvent class]] ? eventOrEventName : [self eventNamed:eventOrEventName];
    if (! event) [NSException raise:NSInvalidArgumentException format:@"Cannot find an Event named '%@'", eventOrEventName];
    return [event.sourceStates containsObject:self.currentState];
}

- (BOOL)fireEvent:(id)eventOrEventName error:(NSError **)error
{
    if (! self.isActive) [self activate];
    if (! [eventOrEventName isKindOfClass:[TKEvent class]] && ![eventOrEventName isKindOfClass:[NSString class]]) [NSException raise:NSInvalidArgumentException format:@"Expected a `TKEvent` object or `NSString` object specifying the name of an event, instead got a `%@` (%@)", [eventOrEventName class], eventOrEventName];
    TKEvent *event = [eventOrEventName isKindOfClass:[TKEvent class]] ? eventOrEventName : [self eventNamed:eventOrEventName];
    if (! event) [NSException raise:NSInvalidArgumentException format:@"Cannot find an Event named '%@'", eventOrEventName];
    
    // Check that this transition is permitted
    if (event.sourceStates != nil && ![event.sourceStates containsObject:self.currentState]) {
        NSString *failureReason = [NSString stringWithFormat:@"An attempt was made to fire the '%@' event while in the '%@' state, but the event can only be fired from the following states: %@", event.name, self.currentState.name, [[event.sourceStates valueForKey:@"name"] componentsJoinedByString:@", "]];
        NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"The event cannot be fired from the current state.", NSLocalizedFailureReasonErrorKey: failureReason };
        if (error) *error = [NSError errorWithDomain:TKErrorDomain code:TKInvalidTransitionError userInfo:userInfo];
        return NO;
    }
    
    if (event.shouldFireEventBlock) {
        if (! event.shouldFireEventBlock(event, self)) {
            NSString *failureReason = [NSString stringWithFormat:@"An attempt to fire the '%@' event was declined because `shouldFireEventBlock` returned `NO`.", event.name];
            NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"The event declined to be fired.", NSLocalizedFailureReasonErrorKey: failureReason };
            if (error) *error = [NSError errorWithDomain:TKErrorDomain code:TKTransitionDeclinedError userInfo:userInfo];
            return NO;
        }
    }
    
    if (event.willFireEventBlock) event.willFireEventBlock(event, self);
    
    TKState *oldState = self.currentState;
    TKState *newState = event.destinationState;
    
    if (oldState.willExitStateBlock) oldState.willExitStateBlock(oldState, self);
    if (newState.willEnterStateBlock) newState.willEnterStateBlock(newState, self);
    self.currentState = newState;
    
    NSDictionary *userInfo = @{ TKStateMachineDidChangeStateOldStateUserInfoKey: oldState, TKStateMachineDidChangeStateNewStateUserInfoKey: newState, TKStateMachineDidChangeStateEventUserInfoKey: event };
    [[NSNotificationCenter defaultCenter] postNotificationName:TKStateMachineDidChangeStateNotification object:self userInfo:userInfo];
    
    if (oldState.didExitStateBlock) oldState.didExitStateBlock(oldState, self);
    if (newState.didEnterStateBlock) newState.didEnterStateBlock(newState, self);
    
    if (event.didFireEventBlock) event.didFireEventBlock(event, self);
    
    return YES;
}

#pragma mark - NSCoding

- (id)initWithCoder:(NSCoder *)aDecoder
{
    self = [self init];
    if (!self) {
        return nil;
    }
    
    self.initialState = [aDecoder decodeObjectForKey:@"initialState"];
    self.currentState =[aDecoder decodeObjectForKey:@"currentState"];
    self.mutableStates = [[aDecoder decodeObjectForKey:@"states"] mutableCopy];
    self.mutableEvents = [[aDecoder decodeObjectForKey:@"events"] mutableCopy];
    self.active = [aDecoder decodeBoolForKey:@"isActive"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder
{
    [aCoder encodeObject:self.initialState forKey:@"initialState"];
    [aCoder encodeObject:self.currentState forKey:@"currentState"];
    [aCoder encodeObject:self.states forKey:@"states"];
    [aCoder encodeObject:self.events forKey:@"events"];
    [aCoder encodeBool:self.isActive forKey:@"isActive"];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone
{
    TKStateMachine *copiedStateMachine = [[[self class] allocWithZone:zone] init];
    copiedStateMachine.active = NO;
    copiedStateMachine.currentState = nil;
    copiedStateMachine.initialState = self.initialState;
    
    for (TKState *state in self.states) {
        [copiedStateMachine addState:[state copy]];
    }
    
    for (TKEvent *event in self.events) {
        NSMutableArray *sourceStates = [NSMutableArray arrayWithCapacity:[event.sourceStates count]];
        for (TKState *sourceState in event.sourceStates) {
            [sourceStates addObject:[copiedStateMachine stateNamed:sourceState.name]];
        }
        TKState *destinationState = [copiedStateMachine stateNamed:event.destinationState.name];
        TKEvent *copiedEvent = [TKEvent eventWithName:event.name transitioningFromStates:sourceStates toState:destinationState];
        [copiedStateMachine addEvent:copiedEvent];
    }
    return copiedStateMachine;
}

@end
