// Copyright 2015-present 650 Industries. All rights reserved.

#import <AVFoundation/AVFoundation.h>
#import <ABI34_0_0UMCore/ABI34_0_0UMUtilities.h>
#import <ABI34_0_0EXAV/ABI34_0_0EXAV.h>
#import <ABI34_0_0EXAV/ABI34_0_0EXVideoView.h>
#import <ABI34_0_0EXAV/ABI34_0_0EXAVPlayerData.h>
#import <ABI34_0_0EXAV/ABI34_0_0EXVideoPlayerViewController.h>

static NSString *const ABI34_0_0EXVideoReadyForDisplayKeyPath = @"readyForDisplay";
static NSString *const ABI34_0_0EXVideoSourceURIKeyPath = @"uri";
static NSString *const ABI34_0_0EXVideoSourceHeadersKeyPath = @"headers";
static NSString *const ABI34_0_0EXVideoBoundsKeyPath = @"videoBounds";
static NSString *const ABI34_0_0EXAVFullScreenViewControllerClassName = @"AVFullScreenViewController";

@interface ABI34_0_0EXVideoView ()

@property (nonatomic, weak) ABI34_0_0EXAV *exAV;

@property (nonatomic, assign) BOOL playerHasLoaded;
@property (nonatomic, strong) ABI34_0_0EXAVPlayerData *data;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) ABI34_0_0EXVideoPlayerViewController *playerViewController;

@property (nonatomic, assign) BOOL fullscreenPlayerIsDismissing;
@property (nonatomic, weak) UIViewController *nativeFullscreenPlayerViewController;
@property (nonatomic, strong) ABI34_0_0EXVideoPlayerViewController *fullscreenPlayerViewController;
@property (nonatomic, strong) ABI34_0_0UMPromiseResolveBlock requestedFullscreenChangeResolver;
@property (nonatomic, strong) ABI34_0_0UMPromiseRejectBlock requestedFullscreenChangeRejecter;
@property (nonatomic, assign) BOOL requestedFullscreenChange;

@property (nonatomic, strong) UIViewController *presentingViewController;
@property (nonatomic, assign) BOOL fullscreenPlayerPresented;

@property (nonatomic, strong) NSDictionary *lastSetSource;
@property (nonatomic, strong) NSMutableDictionary *statusToSet;

@property (nonatomic, weak) ABI34_0_0UMModuleRegistry *moduleRegistry;

@end

@implementation ABI34_0_0EXVideoView

#pragma mark - ABI34_0_0EXVideoView interface methods

- (instancetype)initWithModuleRegistry:(ABI34_0_0UMModuleRegistry *)moduleRegistry
{
  if ((self = [super init])) {
    _moduleRegistry = moduleRegistry;
    _exAV = [_moduleRegistry getModuleImplementingProtocol:@protocol(ABI34_0_0EXAVInterface)];
    [_exAV registerVideoForAudioLifecycle:self];
    
    _data = nil;
    _playerLayer = nil;
    _playerHasLoaded = NO;
    _playerViewController = nil;
    _presentingViewController = nil;
    _fullscreenPlayerPresented = NO;
    _fullscreenPlayerViewController = nil;
    _requestedFullscreenChangeResolver = nil;
    _requestedFullscreenChangeRejecter = nil;
    _nativeFullscreenPlayerViewController = nil;
    _fullscreenPlayerIsDismissing = NO;
    _requestedFullscreenChange = NO;
    _statusToSet = [NSMutableDictionary new];
    _useNativeControls = NO;
    _nativeResizeMode = AVLayerVideoGravityResizeAspectFill;
  }
  
  return self;
}

#pragma mark - callback helper methods

- (void)_callFullscreenCallbackForUpdate:(ABI34_0_0EXVideoFullscreenUpdate)update
{
  if (_onFullscreenUpdate) {
    _onFullscreenUpdate(@{@"fullscreenUpdate": @(update),
                          @"status": [_data getStatus]});
  }
}

- (void)_callErrorCallback:(NSString *)error
{
  if (_onError) {
    _onError(@{@"error": error});
  }
}

#pragma mark - Player and source

- (void)_tryUpdateDataStatus:(ABI34_0_0UMPromiseResolveBlock)resolve
                    rejecter:(ABI34_0_0UMPromiseRejectBlock)reject
{
  if (_data) {
    if ([_statusToSet count] > 0) {
      NSMutableDictionary *newStatus = [NSMutableDictionary dictionaryWithDictionary:_statusToSet];
      [_statusToSet removeAllObjects];
      [_data setStatus:newStatus resolver:resolve rejecter:reject];
    } else if (resolve) {
      resolve([_data getStatus]);
    }
  } else if (resolve) {
    resolve([ABI34_0_0EXAVPlayerData getUnloadedStatus]);
  }
}

- (void)_updateForNewPlayer
{
  [self setPlayerHasLoaded:YES];
  [self _updateNativeResizeMode];
  [self setUseNativeControls:_useNativeControls];
  if (_onLoad) {
    _onLoad([self getStatus]);
  }
  if (_requestedFullscreenChangeResolver || _requestedFullscreenChangeRejecter) {
    [self setFullscreen:_requestedFullscreenChange resolver:_requestedFullscreenChangeResolver rejecter:_requestedFullscreenChangeRejecter];
    _requestedFullscreenChangeResolver = nil;
    _requestedFullscreenChangeRejecter = nil;
    _requestedFullscreenChange = NO;
  }
}

- (void)_removePlayer
{
  if (_requestedFullscreenChangeRejecter) {
    NSString *errorMessage = @"Player is being removed, cancelling fullscreen change request.";
    _requestedFullscreenChangeRejecter(@"E_VIDEO_FULLSCREEN", errorMessage, ABI34_0_0UMErrorWithMessage(errorMessage));
    _requestedFullscreenChangeResolver = nil;
    _requestedFullscreenChangeRejecter = nil;
    _requestedFullscreenChange = NO;
  }

  if (_data) {
    [_data pauseImmediately];
    [_data setStatusUpdateCallback:nil];
    [_exAV demoteAudioSessionIfPossible];
    [self _removeFullscreenPlayerViewController];
    [self _removePlayerLayer];
    [self _removePlayerViewController];
    _data = nil;
  }
}

#pragma mark - _playerViewController / _playerLayer management

- (ABI34_0_0EXVideoPlayerViewController *)_createNewPlayerViewController
{
  if (_data == nil) {
    return nil;
  }
  ABI34_0_0EXVideoPlayerViewController *controller = [[ABI34_0_0EXVideoPlayerViewController alloc] init];
  [controller setShowsPlaybackControls:_useNativeControls];
  [controller setRctDelegate:self];
  [controller.view setFrame:self.bounds];
  [controller setPlayer:_data.player];
  [controller addObserver:self forKeyPath:ABI34_0_0EXVideoReadyForDisplayKeyPath options:NSKeyValueObservingOptionNew context:nil];
  return controller;
}

- (void)_usePlayerLayer
{
  if (_data) {
    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_data.player];
    [_playerLayer setFrame:self.bounds];
    [_playerLayer setNeedsDisplayOnBoundsChange:YES];
    [_playerLayer addObserver:self forKeyPath:ABI34_0_0EXVideoReadyForDisplayKeyPath options:NSKeyValueObservingOptionNew context:nil];
    
    // Resize mode must be set before layer is added
    // to prevent video from being animated when `resizeMode` is `cover`
    [self _updateNativeResizeMode];
    
    [self.layer addSublayer:_playerLayer];
    [self.layer setNeedsDisplayOnBoundsChange:YES];
  }
}

- (void)_removePlayerLayer
{
  if (_playerLayer) {
    [_playerLayer removeFromSuperlayer];
    [_playerLayer removeObserver:self forKeyPath:ABI34_0_0EXVideoReadyForDisplayKeyPath];
    _playerLayer = nil;
  }
}

- (void)_removeFullscreenPlayerViewController
{
  if (_fullscreenPlayerViewController) {
    [_fullscreenPlayerViewController removeObserver:self forKeyPath:ABI34_0_0EXVideoReadyForDisplayKeyPath];
    _fullscreenPlayerViewController = nil;
  }
}

- (void)_removePlayerViewController
{
  if (_playerViewController) {
    __weak ABI34_0_0EXVideoView *weakSelf = self;
    void (^block)(void) = ^ {
      __strong ABI34_0_0EXVideoView *strongSelf = weakSelf;
      if (strongSelf && strongSelf.playerViewController) {
        [strongSelf.playerViewController.view removeFromSuperview];
        [strongSelf.playerViewController removeObserver:strongSelf forKeyPath:ABI34_0_0EXVideoReadyForDisplayKeyPath];
        [strongSelf.playerViewController removeObserver:strongSelf forKeyPath:ABI34_0_0EXVideoBoundsKeyPath];
        strongSelf.playerViewController = nil;
      }
    };

    [ABI34_0_0UMUtilities performSynchronouslyOnMainThread:block];
  }
}


#pragma mark - Observers

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
  if ((object == _playerLayer || object == _playerViewController || object == _fullscreenPlayerViewController) && [keyPath isEqualToString:ABI34_0_0EXVideoReadyForDisplayKeyPath]) {
    if ([change objectForKey:NSKeyValueChangeNewKey] && _onReadyForDisplay) {
      // Calculate natural size of video:
      NSDictionary *naturalSize;
      
      if ([_data.player.currentItem.asset tracksWithMediaType:AVMediaTypeVideo].count > 0) {
        AVAssetTrack *videoTrack = [[_data.player.currentItem.asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
        CGFloat width = videoTrack.naturalSize.width;
        CGFloat height = videoTrack.naturalSize.height;
        CGAffineTransform preferredTransform = [videoTrack preferredTransform];
        CGFloat tx = preferredTransform.tx;
        CGFloat ty = preferredTransform.ty;
        
        naturalSize = @{@"width": @(width),
                        @"height": @(height),
                        @"orientation": ((width == tx && height == ty) || (tx == 0 && ty == 0)) ? @"landscape" : @"portrait"};
      } else {
        naturalSize = nil;
      }
      
      if (naturalSize) {
        _onReadyForDisplay(@{@"naturalSize": naturalSize,
                             @"status": [_data getStatus]});
      }
    }
  } else if (object == _playerViewController && [keyPath isEqualToString:ABI34_0_0EXVideoBoundsKeyPath]) {
    UIViewController *presentedViewController = [[_moduleRegistry getModuleImplementingProtocol:@protocol(ABI34_0_0UMUtilitiesInterface)] currentViewController];
    if (presentedViewController == nil) {
      return;
    }

    // For a short explanation on why we're detecting fullscreen changes in such an extraordinary way
    // see https://stackoverflow.com/questions/36323259/detect-video-playing-full-screen-in-portrait-or-landscape/36388184#36388184

    // We may be presenting a fullscreen player for this video item
    UIViewController *fullscreenViewController;

    if ([[presentedViewController.class description] isEqualToString:ABI34_0_0EXAVFullScreenViewControllerClassName]) {
      // ABI34_0_0RCTPresentedViewController() is fullscreen
       fullscreenViewController = presentedViewController;
    } else if (presentedViewController.presentedViewController != nil && [[presentedViewController.presentedViewController.class description] isEqualToString:ABI34_0_0EXAVFullScreenViewControllerClassName]) {
      // ABI34_0_0RCTPresentedViewController().presentedViewController is fullscreen
      fullscreenViewController = presentedViewController.presentedViewController;
    }

    if (fullscreenViewController.isBeingDismissed && _fullscreenPlayerPresented && _nativeFullscreenPlayerViewController == fullscreenViewController) {
      // Fullscreen player is being dismissed
      _fullscreenPlayerPresented = false;
      _nativeFullscreenPlayerViewController = nil;
      [self _callFullscreenCallbackForUpdate:ABI34_0_0EXVideoFullscreenUpdatePlayerWillDismiss];
      [self _callFullscreenCallbackForUpdate:ABI34_0_0EXVideoFullscreenUpdatePlayerDidDismiss];
    } else if (fullscreenViewController.isBeingPresented && !_fullscreenPlayerPresented && _nativeFullscreenPlayerViewController == nil) {
      // Fullscreen player is being presented
      _fullscreenPlayerPresented = true;
      _nativeFullscreenPlayerViewController = fullscreenViewController;
      [self _callFullscreenCallbackForUpdate:ABI34_0_0EXVideoFullscreenUpdatePlayerWillPresent];
      [self _callFullscreenCallbackForUpdate:ABI34_0_0EXVideoFullscreenUpdatePlayerDidPresent];
    } else {
      return;
    }
  } else {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

#pragma mark - Imperative API

- (void)setSource:(NSDictionary *)source
       withStatus:(NSDictionary *)initialStatus
         resolver:(ABI34_0_0UMPromiseResolveBlock)resolve
         rejecter:(ABI34_0_0UMPromiseRejectBlock)reject
{
  if (_data) {
    [_statusToSet addEntriesFromDictionary:[_data getStatus]];
    [self _removePlayer];
  }
  
  if (initialStatus) {
    [_statusToSet addEntriesFromDictionary:initialStatus];
  }
  
  if (source == nil) {
    if (resolve) {
      resolve([ABI34_0_0EXAVPlayerData getUnloadedStatus]);
    }
    return;
  }
  
  NSMutableDictionary *statusToInitiallySet = [NSMutableDictionary dictionaryWithDictionary:_statusToSet];
  [_statusToSet removeAllObjects];
  
  __weak ABI34_0_0EXVideoView *weakSelf = self;
  
  void (^statusUpdateCallback)(NSDictionary *) = ^(NSDictionary *status) {
    __strong ABI34_0_0EXVideoView *strongSelf = weakSelf;
    if (strongSelf && strongSelf.onStatusUpdate) {
      strongSelf.onStatusUpdate(status);
    }
  };
  
  void (^errorCallback)(NSString *) = ^(NSString *error) {
    __strong ABI34_0_0EXVideoView *strongSelf = weakSelf;
    if (strongSelf) {
      [strongSelf _removePlayer];
      [strongSelf _callErrorCallback:error];
    }
  };
  
  _data = [[ABI34_0_0EXAVPlayerData alloc] initWithEXAV:_exAV
                                    withSource:source
                                    withStatus:statusToInitiallySet
                           withLoadFinishBlock:^(BOOL success, NSDictionary *successStatus, NSString *error) {
                             __strong ABI34_0_0EXVideoView *strongSelf = weakSelf;
                             if (strongSelf && success) {
                               [strongSelf _updateForNewPlayer];
                               if (resolve) {
                                 resolve(successStatus);
                               }
                             } else if (strongSelf) {
                               [strongSelf _removePlayer];
                               if (reject) {
                                 reject(@"E_VIDEO_NOTCREATED", error, ABI34_0_0UMErrorWithMessage(error));
                               }
                               [strongSelf _callErrorCallback:error];
                             }
                           }];
  [_data setStatusUpdateCallback:statusUpdateCallback];
  [_data setErrorCallback:errorCallback];
  
  // Call onLoadStart on next run loop, otherwise it might not be set yet (if it is set at the same time as uri, via props)
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) 0), dispatch_get_main_queue(), ^{
    __strong ABI34_0_0EXVideoView *strongSelf = weakSelf;
    if (strongSelf && strongSelf.onLoadStart) {
      strongSelf.onLoadStart(nil);
    }
  });
}

- (void)setStatus:(NSDictionary *)status
         resolver:(ABI34_0_0UMPromiseResolveBlock)resolve
         rejecter:(ABI34_0_0UMPromiseRejectBlock)reject
{
  if (status != nil) {
    [_statusToSet addEntriesFromDictionary:status];
  }
  [self _tryUpdateDataStatus:resolve rejecter:reject];
}

- (void)replayWithStatus:(NSDictionary *)status
                resolver:(ABI34_0_0UMPromiseResolveBlock)resolve
                rejecter:(ABI34_0_0UMPromiseRejectBlock)reject
{
  if (status != nil) {
    [_statusToSet addEntriesFromDictionary:status];
  }
  
  NSMutableDictionary *newStatus = [NSMutableDictionary dictionaryWithDictionary:_statusToSet];
  [_statusToSet removeAllObjects];
  
  [_data replayWithStatus:newStatus resolver:resolve rejecter:reject];
}

- (void)setFullscreen:(BOOL)value
             resolver:(ABI34_0_0UMPromiseResolveBlock)resolve
             rejecter:(ABI34_0_0UMPromiseRejectBlock)reject
{
  if (!_data) {
    // Tried to set fullscreen for an unloaded component.
    if (reject) {
      NSString *errorMessage = @"Fullscreen encountered an error: video is not loaded.";
      reject(@"E_VIDEO_FULLSCREEN", errorMessage, ABI34_0_0UMErrorWithMessage(errorMessage));
    }
    return;
  } else if (!_playerHasLoaded) {
    // `setUri` has been called, but the video has not yet loaded.
    if (_requestedFullscreenChangeRejecter) {
      NSString *errorMessage = @"Received newer request, cancelling fullscreen mode change request.";
      _requestedFullscreenChangeRejecter(@"E_VIDEO_FULLSCREEN", errorMessage, ABI34_0_0UMErrorWithMessage(errorMessage));
    }
    
    _requestedFullscreenChange = value;
    _requestedFullscreenChangeRejecter = reject;
    _requestedFullscreenChangeResolver = resolve;
    return;
  } else {
    __weak ABI34_0_0EXVideoView *weakSelf = self;
    if (value && !_fullscreenPlayerPresented && !_fullscreenPlayerViewController) {
      _fullscreenPlayerViewController = [self _createNewPlayerViewController];

      // Resize mode must be set before layer is added
      // to prevent video from being animated when `resizeMode` is `cover`
      [self _updateNativeResizeMode];

      // Set presentation style to fullscreen
      [_fullscreenPlayerViewController setModalPresentationStyle:UIModalPresentationFullScreen];

      // Find the nearest view controller
      UIViewController *controller = [UIApplication sharedApplication].keyWindow.rootViewController;
      UIViewController *presentedController = controller.presentedViewController;
      while (presentedController && ![presentedController isBeingDismissed]) {
        controller = presentedController;
        presentedController = controller.presentedViewController;
      }

      _presentingViewController = controller;
      [self _callFullscreenCallbackForUpdate:ABI34_0_0EXVideoFullscreenUpdatePlayerWillPresent];

      dispatch_async(dispatch_get_main_queue(), ^{
        __strong ABI34_0_0EXVideoView *strongSelf = weakSelf;
        if (strongSelf) {
          strongSelf.fullscreenPlayerViewController.showsPlaybackControls = YES;
          [strongSelf.presentingViewController presentViewController:strongSelf.fullscreenPlayerViewController animated:YES completion:^{
            __strong ABI34_0_0EXVideoView *strongSelfInner = weakSelf;
            if (strongSelfInner) {
              strongSelfInner.fullscreenPlayerPresented = YES;
              [strongSelfInner _callFullscreenCallbackForUpdate:ABI34_0_0EXVideoFullscreenUpdatePlayerDidPresent];
              if (resolve) {
                resolve([strongSelfInner getStatus]);
              }
            }
          }];
        }
      });
    } else if (!value && _fullscreenPlayerPresented && !_fullscreenPlayerIsDismissing) {
      [self videoPlayerViewControllerWillDismiss:_fullscreenPlayerViewController];

      dispatch_async(dispatch_get_main_queue(), ^{
        __strong ABI34_0_0EXVideoView *strongSelf = weakSelf;
        if (strongSelf) {
          [strongSelf.presentingViewController dismissViewControllerAnimated:YES completion:^{
            __strong ABI34_0_0EXVideoView *strongSelfInner = weakSelf;
            if (strongSelfInner) {
              [strongSelfInner videoPlayerViewControllerDidDismiss:strongSelfInner.fullscreenPlayerViewController];
              if (resolve) {
                resolve([strongSelfInner getStatus]);
              }
            }
          }];
        }
      });
    } else if (value && !_fullscreenPlayerPresented && _fullscreenPlayerViewController && reject) {
      // Fullscreen player should be presented, is being presented, but hasn't been presented yet.
      NSString *errorMessage = @"Fullscreen player is already being presented. Await the first change request.";
      reject(@"E_VIDEO_FULLSCREEN", errorMessage, ABI34_0_0UMErrorWithMessage(errorMessage));
    } else if (!value && _fullscreenPlayerIsDismissing && _fullscreenPlayerViewController && reject) {
      // Fullscreen player should be dismissing, is already dismissing, but hasn't dismissed yet.
      NSString *errorMessage = @"Fullscreen player is already being dismissed. Await the first change request.";
      reject(@"E_VIDEO_FULLSCREEN", errorMessage, ABI34_0_0UMErrorWithMessage(errorMessage));
    } else if (!value && !_fullscreenPlayerPresented && _fullscreenPlayerViewController && reject) {
      // Fullscreen player is being presented and we receive request to dismiss it.
      NSString *errorMessage = @"Fullscreen player is being presented. Await the `present` request and then dismiss the player.";
      reject(@"E_VIDEO_FULLSCREEN", errorMessage, ABI34_0_0UMErrorWithMessage(errorMessage));
    } else if (value && _fullscreenPlayerIsDismissing && _fullscreenPlayerViewController && reject) {
      // Fullscreen player is being dismissed and we receive request to present it.
      NSString *errorMessage = @"Fullscreen player is being dismissed. Await the `dismiss` request and then present the player again.";
      reject(@"E_VIDEO_FULLSCREEN", errorMessage, ABI34_0_0UMErrorWithMessage(errorMessage));
    } else if (resolve) {
       // Fullscreen is already appropriately set.
      resolve([self getStatus]);
    }
  }
}

#pragma mark - Prop setters

- (void)setSource:(NSDictionary *)source
{
  if (![source isEqualToDictionary:_lastSetSource]) {
    __weak ABI34_0_0EXVideoView *weakSelf = self;
    dispatch_async(_exAV.methodQueue, ^{
      __strong ABI34_0_0EXVideoView *strongSelf = weakSelf;
      if (strongSelf) {
        [strongSelf setSource:source withStatus:nil resolver:nil rejecter:nil];
        strongSelf.lastSetSource = source;
      }
    });
  }
}

- (NSDictionary *)source
{
  return @{
           ABI34_0_0EXVideoSourceURIKeyPath: (_data != nil && _data.url != nil) ? _data.url.absoluteString : @"",
           ABI34_0_0EXVideoSourceHeadersKeyPath: _data.headers
           };
}

- (void)setUseNativeControls:(BOOL)useNativeControls
{
  _useNativeControls = useNativeControls;
  if (_data == nil) {
    return;
  }
  
  __weak ABI34_0_0EXVideoView *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong ABI34_0_0EXVideoView *strongSelf = weakSelf;
    if (strongSelf && strongSelf.useNativeControls) {
      if (strongSelf.playerLayer) {
        [strongSelf _removePlayerLayer];
      }
      if (!strongSelf.playerViewController && strongSelf.data) {
        strongSelf.playerViewController = [strongSelf _createNewPlayerViewController];
        // We're listening for changes to `videoBounds`, because it seems
        // to be the easiest way to detect fullscreen changes triggered by the native video button.
        // See https://stackoverflow.com/questions/36323259/detect-video-playing-full-screen-in-portrait-or-landscape/36388184#36388184
        // and https://github.com/expo/expo/issues/1566
        [strongSelf.playerViewController addObserver:self forKeyPath:ABI34_0_0EXVideoBoundsKeyPath options:NSKeyValueObservingOptionNew context:nil];
        // Resize mode must be set before layer is added
        // to prevent video from being animated when `resizeMode` is `cover`
        [strongSelf _updateNativeResizeMode];
        [strongSelf addSubview:strongSelf.playerViewController.view];
      }
    } else if (strongSelf) {
      if (strongSelf.playerViewController) {
        [strongSelf _removePlayerViewController];
      }
      if (!strongSelf.playerLayer) {
        [strongSelf _usePlayerLayer];
      }
    }
  });
}

- (void)setNativeResizeMode:(NSString*)mode
{
  _nativeResizeMode = mode;
  [self _updateNativeResizeMode];
}

- (void)_updateNativeResizeMode
{
  if (_useNativeControls) {
    if (_playerViewController) {
      [_playerViewController setVideoGravity:_nativeResizeMode];
    }
    if (_fullscreenPlayerViewController) {
      [_fullscreenPlayerViewController setVideoGravity:_nativeResizeMode];
    }
  } else if (_playerLayer) {
    [_playerLayer setVideoGravity:_nativeResizeMode];
  }
}

- (void)setStatus:(NSDictionary *)status
{
  __weak ABI34_0_0EXVideoView *weakSelf = self;
  dispatch_async(_exAV.methodQueue, ^{
    __strong ABI34_0_0EXVideoView *strongSelf = weakSelf;
    if (strongSelf) {
      [strongSelf setStatus:status resolver:nil rejecter:nil];
    }
  });
}

- (NSDictionary *)getStatus
{
  if (_data) {
    return [_data getStatus];
  } else {
    return [ABI34_0_0EXAVPlayerData getUnloadedStatus];
  }
}

#pragma mark - ReactABI34_0_0 View Management

//- (void)insertReactABI34_0_0Subview:(UIView *)view atIndex:(NSInteger)atIndex
//{
//  // We are early in the game and somebody wants to set a subview.
//  // That can only be in the context of playerViewController.
//  if (!_useNativeControls && !_playerLayer && !_playerViewController) {
//    [self setUseNativeControls:YES];
//  }
//
//  if (_useNativeControls && _playerViewController) {
//    [super insertReactABI34_0_0Subview:view atIndex:atIndex];
//    [view setFrame:self.bounds];
//    [_playerViewController.contentOverlayView insertSubview:view atIndex:atIndex];
//  } else {
//    ABI34_0_0RCTLogError(@"video cannot have any subviews");
//  }
//}

//- (void)removeReactABI34_0_0Subview:(UIView *)subview
//{
//  if (_useNativeControls) {
//    [super removeReactABI34_0_0Subview:subview];
//    [subview removeFromSuperview];
//  } else {
//    ABI34_0_0RCTLogError(@"video cannot have any subviews");
//  }
//}

- (void)layoutSubviews
{
  [super layoutSubviews];
  if (_useNativeControls && _playerViewController) {
    [_playerViewController.view setFrame:self.bounds];
    
    // also adjust all subviews of contentOverlayView
    for (UIView* subview in _playerViewController.contentOverlayView.subviews) {
      [subview setFrame:self.bounds];
    }
  } else if (!_useNativeControls && _playerLayer) {
    [CATransaction begin];
    [CATransaction setAnimationDuration:0];
    [_playerLayer setFrame:self.bounds];
    [CATransaction commit];
  }
}

- (void)removeFromSuperview
{
  [self _removePlayer];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [super removeFromSuperview];
}

#pragma mark - ABI34_0_0EXVideoPlayerViewControllerDelegate

- (void)videoPlayerViewControllerWillDismiss:(AVPlayerViewController *)playerViewController
{
  if (_fullscreenPlayerViewController == playerViewController && _fullscreenPlayerPresented) {
    _fullscreenPlayerIsDismissing = YES;
    [self _callFullscreenCallbackForUpdate:ABI34_0_0EXVideoFullscreenUpdatePlayerWillDismiss];
  }
}

- (void)videoPlayerViewControllerDidDismiss:(AVPlayerViewController *)playerViewController
{
  if (_fullscreenPlayerViewController == playerViewController && _fullscreenPlayerPresented) {
    _fullscreenPlayerIsDismissing = NO;
    _fullscreenPlayerPresented = NO;
    _presentingViewController = nil;
    [self _removeFullscreenPlayerViewController];
    [self setUseNativeControls:_useNativeControls];
    [self _callFullscreenCallbackForUpdate:ABI34_0_0EXVideoFullscreenUpdatePlayerDidDismiss];
  }
}

#pragma mark - ABI34_0_0EXAVObject

- (void)pauseImmediately
{
  if (_data) {
    [_data pauseImmediately];
  }
}

- (ABI34_0_0EXAVAudioSessionMode)getAudioSessionModeRequired
{
  return _data == nil ? ABI34_0_0EXAVAudioSessionModeInactive : [_data getAudioSessionModeRequired];
}

- (void)appDidForeground
{
  if (_data) {
    [_data appDidForeground];
  }
}

- (void)appDidBackground
{
  if (_data) {
    [_data appDidBackground];
  }
}

- (void)handleAudioSessionInterruption:(NSNotification*)notification
{
  if (_data) {
    [_data handleAudioSessionInterruption:notification];
  }
}

- (void)handleMediaServicesReset:(void (^)(void))finishCallback
{
  if (_data) {
    if (_onLoadStart) {
      _onLoadStart(nil);
    }
    [self _removePlayerLayer];
    [self _removePlayerViewController];
    
    __weak __typeof__(self) weakSelf = self;
    [_data handleMediaServicesReset:^{
      __strong ABI34_0_0EXVideoView *strongSelf = weakSelf;
      if (strongSelf) {
        [strongSelf _updateForNewPlayer];
      }
      if (finishCallback != nil) {
        finishCallback();
      }
    }];
  }
}

#pragma mark - NSObject Lifecycle

- (void)dealloc
{
  [_exAV unregisterVideoForAudioLifecycle:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_data pauseImmediately];
  [_exAV demoteAudioSessionIfPossible];
}

@end
