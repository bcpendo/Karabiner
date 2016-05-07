#import "AXApplicationObserverManager.h"
#import "AXApplicationObserver.h"
#import "PreferencesModel.h"

/*
 * Notification and Information
 * ============================
 *
 * We need to observe these notifications on a web browser which has tab and multi window.
 *
 * - NSWorkspaceDidActivateApplicationNotification
 * - kAXTitleChangedNotification
 * - kAXFocusedUIElementChangedNotification
 * - kAXFocusedWindowChangedNotification
 *
 *
 * NSWorkspaceDidActivateApplicationNotification
 * ---------------------------------------------
 *
 *   A essential notification for bundle identifier.
 *   This notification is also needed for title and role when user changed focused application.
 *
 *   (kAXTitleChangedNotification and other AX notifications will not be sent when user changed focused application
 *   because we create an observer for focused application when application is focused.)
 *
 *   Items that need to be updated:
 *     - bundleIdentifier
 *     - title
 *     - role
 *
 *
 * kAXTitleChangedNotification
 * ---------------------------
 *
 *   A essential notification for window name.
 *
 *   We need to observe this notification in this case:
 *     The window name will be changed when we use Google Chrome and click a link.
 *     If the link does not open new tab, kAXFocusedUIElementChangedNotification is not triggered.
 *     So we observe the window name changes by kAXTitleChangedNotification.
 *
 *     Note:
 *     kAXTitleChangedNotification will not be called on Safari 7.0.4 in this case.
 *     It might be a bug of Safari 7.0.4.
 *
 *   Items that need to be updated:
 *     - title
 *
 *
 * kAXFocusedUIElementChangedNotification
 * --------------------------------------
 *
 *   A essential notification for ui element role.
 *
 *   On Safari, kAXTitleChangedNotification will not be called when user changed the current tab.
 *   (It might be a bug of Safari 7.0.4.)
 *   So we need to update title at kAXFocusedUIElementChangedNotification.
 *
 *   Items that need to be updated:
 *     - title
 *     - role
 *
 *   Note:
 *   kAXFocusedUIElementChangedNotification will also be triggered when user changed focused window.
 *   But kAXFocusedUIElementChangedNotification and kAXFocusedWindowChangedNotification is not unordered.
 *   Therefore, we need to update title at both notifications.
 *
 *
 * kAXFocusedWindowChangedNotification
 * -----------------------------------
 *
 *   We need to register kAXTitleChangedNotification to the focused window.
 *   (If register kAXTitleChangedNotification to application element,
 *   kAXTitleChangedNotification will not be triggered on Emacs.app.)
 *
 *   We need to observe this notification in order to refresh kAXTitleChangedNotification observer.
 *
 *   Items that need to be updated:
 *     - title
 *
 *   Note:
 *   See the note of kAXFocusedUIElementChangedNotification.
 *
 */

@interface AXApplicationObserverManager ()

@property AXNotifierPreferencesModel* axNotifierPreferencesModel;
@property NSMutableDictionary* systemApplicationObservers;

// We need to observe frontmostApplication only because
// kAXFocusedWindowChangedNotification will be sent from apps which are not frontmost.
// (You can confirm it by WindowChangedNotificationTester.app.)
@property AXApplicationObserver* observer;

@property NSTimer* timer;
@property NSRunningApplication* runningApplicationForAXApplicationObserver;
@property int retryCounter;

@property NSTimer* systemApplicationObserversRefreshTimer;

@end

@implementation AXApplicationObserverManager

- (void)systemApplicationObserversRefreshTimerFireMethod:(NSTimer*)timer {
  dispatch_async(dispatch_get_main_queue(), ^{
    @synchronized(self) {
      for (NSString* bundleIdentifier in @[ @"com.apple.systemuiserver",
                                            @"com.apple.notificationcenterui" ]) {
        {
          // Remove if terminated.
          AXApplicationObserver* o = self.systemApplicationObservers[bundleIdentifier];
          if (o) {
            NSRunningApplication* runningApplication = o.runningApplication;
            if (!runningApplication || runningApplication.terminated) {
              NSLog(@"Remove %@ from systemApplicationObservers", bundleIdentifier);
              [self.systemApplicationObservers removeObjectForKey:bundleIdentifier];
            }
          }
        }

        if (!self.systemApplicationObservers[bundleIdentifier]) {
          NSArray* runningApplications = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
          if ([runningApplications count] > 0) {
            @try {
              self.systemApplicationObservers[bundleIdentifier] = [[AXApplicationObserver alloc] initWithRunningApplication:runningApplications[0] axNotifierPreferencesModel:self.axNotifierPreferencesModel];
            } @catch (NSException* e) {
#if 0
              NSLog(@"%@", e);
#endif
            }
          }
        }
      }
    }
  });
}

- (void)timerFireMethod:(NSTimer*)timer {
  dispatch_async(dispatch_get_main_queue(), ^{
    @synchronized(self) {
      if (!self.runningApplicationForAXApplicationObserver) {
        self.retryCounter = 0;

      } else {
        if (self.retryCounter > 20) {
          self.runningApplicationForAXApplicationObserver = nil;
          return;
        }
#if 0
        if (self.retryCounter > 0) {
          NSLog(@"AXApplicationObserverManager creates AXApplicationObserver for %@ (retryCounter:%d)",
                self.runningApplicationForAXApplicationObserver,
                self.retryCounter);
        }
#endif

        @try {
          self.observer = [[AXApplicationObserver alloc] initWithRunningApplication:self.runningApplicationForAXApplicationObserver axNotifierPreferencesModel:self.axNotifierPreferencesModel];
          [self.observer observeTitleChangedNotification];
          [self.observer postNotification];

          self.runningApplicationForAXApplicationObserver = nil;
          self.retryCounter = 0;

        } @catch (NSException* e) {
#if 0
          NSLog(@"%@", e);
#endif
          ++(self.retryCounter);
        }
      }
    }
  });
}

- (void)observer_NSWorkspaceDidActivateApplicationNotification:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    @synchronized(self) {
      self.observer = nil;

      self.runningApplicationForAXApplicationObserver = [notification userInfo][NSWorkspaceApplicationKey];
      [self.timer fire];
    }
  });
}

- (instancetype)initWithAXNotifierPreferencesModel:(AXNotifierPreferencesModel*)axNotifierPreferencesModel {
  self = [super init];

  if (self) {
    self.axNotifierPreferencesModel = axNotifierPreferencesModel;

    self.systemApplicationObservers = [NSMutableDictionary new];

    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(observer_NSWorkspaceDidActivateApplicationNotification:)
                                                               name:NSWorkspaceDidActivateApplicationNotification
                                                             object:nil];

    // ----------------------------------------
    self.systemApplicationObserversRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:3
                                                                                   target:self
                                                                                 selector:@selector(systemApplicationObserversRefreshTimerFireMethod:)
                                                                                 userInfo:nil
                                                                                  repeats:YES];
    [self.systemApplicationObserversRefreshTimer fire];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                  target:self
                                                selector:@selector(timerFireMethod:)
                                                userInfo:nil
                                                 repeats:YES];

    self.runningApplicationForAXApplicationObserver = [[NSWorkspace sharedWorkspace] frontmostApplication];
    [self.timer fire];
  }

  return self;
}

- (void)dealloc {
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
}

@end
