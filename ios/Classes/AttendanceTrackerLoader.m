#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#if __has_include(<attendance_tracker/attendance_tracker-Swift.h>)
#import <attendance_tracker/attendance_tracker-Swift.h>
#else
#import "attendance_tracker-Swift.h"
#endif

// Starts the native attendance engine at every launch, including the
// background relaunches iOS does for region, iBeacon and significant-change
// events. It must not wait for Flutter plugin registration: apps using the
// UIScene lifecycle register plugins only when a scene connects, which does
// not happen on a background relaunch, and the location event would be lost.
@interface AttendanceTrackerLoader : NSObject
@end

@implementation AttendanceTrackerLoader

+ (void)load {
  [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                    object:nil
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification *note) {
                                                  [AttendanceTrackerEngine bootstrapWithLaunchOptions:note.userInfo];
                                                }];
}

@end
