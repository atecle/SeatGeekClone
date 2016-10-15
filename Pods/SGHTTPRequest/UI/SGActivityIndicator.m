//
//  SGActivityIndicator.m
//  SeatGeek
//
//  Created by James Van-As on 31/07/13.
//  Copyright (c) 2013 SeatGeek. All rights reserved.
//

#import "SGActivityIndicator.h"

@implementation SGActivityIndicator {
    int _activityCount;
    BOOL _indicatorVisible;
}

- (void)incrementActivityCount {
    _activityCount++;
    [self turnOnIndicator];
}

- (void)decrementActivityCount {
    if (_activityCount == 0) {
        return;
    }
    _activityCount--;
    if (_activityCount == 0) {
        [self turnOffIndicatorAfterDelay];
    }
}

- (void)turnOnIndicator {
    if (_indicatorVisible) {
        return;
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(turnOffIndicator)
          object:nil];
#ifndef SG_APP_EXTENSIONS
    [UIApplication.sharedApplication setNetworkActivityIndicatorVisible:YES];
#endif
    _indicatorVisible = YES;
}

- (void)turnOffIndicator {
    if (!_indicatorVisible) {
        return;
    }
#ifndef SG_APP_EXTENSIONS
    [UIApplication.sharedApplication setNetworkActivityIndicatorVisible:NO];
#endif
    _indicatorVisible = NO;
}

- (void)turnOffIndicatorAfterDelay {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(turnOffIndicator)
          object:nil];
    [self performSelector:@selector(turnOffIndicator) withObject:nil afterDelay:0.2];
}

@end
