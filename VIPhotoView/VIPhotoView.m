//
//  VIPhotoView.m
//  VIPhotoViewDemo
//
//  Created by Vito on 1/7/15.
//  Copyright (c) 2015 vito. All rights reserved.
//

#import "VIPhotoView.h"

@implementation ImageController {
    __weak VIPhotoView *_photoView;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void) setImage:(UIImage *)image {
    _image = image;

    VIPhotoView *photoView = [[VIPhotoView alloc] initWithFrame:self.view.bounds andImage:image];
    photoView.autoresizingMask = (1 << 6) -1;
    photoView.parentController = self;

    self.view = photoView;
    _photoView = photoView;
    if (_returnBlock) {
        _photoView.returnBlock = _returnBlock;
    }
}

- (void) setReturnBlock:(dispatch_block_t)returnBlock {
    _returnBlock = returnBlock;
    if (_photoView) {
        _photoView.returnBlock = returnBlock;
    }
}

@end


@interface UIImage (VIUtil)
- (CGSize)sizeThatFits:(CGSize)size;
@end

@implementation UIImage (VIUtil)
- (CGSize) sizeThatFits:(CGSize)size {
    CGSize imageSize = CGSizeMake(self.size.width / self.scale, self.size.height / self.scale);
    CGFloat widthRatio = imageSize.width / size.width;
    CGFloat heightRatio = imageSize.height / size.height;
    if (widthRatio > heightRatio) {
        imageSize = CGSizeMake(imageSize.width / widthRatio, imageSize.height / widthRatio);
    } else {
        imageSize = CGSizeMake(imageSize.width / heightRatio, imageSize.height / heightRatio);
    }
    return imageSize;
}
@end

@interface UIImageView (VIUtil)
- (CGSize)contentSize;
@end

@implementation UIImageView (VIUtil)
- (CGSize) contentSize {
    return [self.image sizeThatFits:self.bounds.size];
}
@end


static const CGFloat __overlayAlpha = 0.6f;						// opacity of the black overlay displayed below the focused image
static const CGFloat __animationDuration = 0.18f;				// the base duration for present/dismiss animations (except physics-related ones)
static const CGFloat __maximumDismissDelay = 0.5f;				// maximum time of delay (in seconds) between when image view is push out and dismissal animations begin
static const CGFloat __resistance = 0.0f;						// linear resistance applied to the image’s dynamic item behavior
static const CGFloat __density = 1.0f;							// relative mass density applied to the image's dynamic item behavior
static const CGFloat __velocityFactor = 1.0f;					// affects how quickly the view is pushed out of the view
static const CGFloat __angularVelocityFactor = 1.0f;			// adjusts the amount of spin applied to the view during a push force, increases towards the view bounds
static const CGFloat __minimumVelocityRequiredForPush = 50.0f;	// defines how much velocity is required for the push behavior to be applied

/* parallax options */
static const CGFloat __backgroundScale = 0.9f;					// defines how much the background view should be scaled
static const CGFloat __blurRadius = 2.0f;						// defines how much the background view is blurred
static const CGFloat __blurSaturationDeltaMask = 0.8f;
static const CGFloat __blurTintColorAlpha = 0.2f;				// defines how much to tint the background view


@interface VIPhotoView () <UIScrollViewDelegate, UIGestureRecognizerDelegate, UIDynamicAnimatorDelegate>

@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UIImageView *imageView;

@property (nonatomic) BOOL rotating;
@property (nonatomic) CGSize minSize;

@end

@implementation VIPhotoView {
    UIPanGestureRecognizer *_panRecognizer;
    BOOL _doubleTap;
    UIDynamicAnimator *_animator;
    UISnapBehavior *_snapBehavior;
    UIPushBehavior *_pushBehavior;
    UIAttachmentBehavior *_panAttachmentBehavior;
    UIDynamicItemBehavior *_itemBehavior;

    CGFloat _lastZoomScale;
}

+ (void) delayExcute:(double)delayInSeconds queue:(dispatch_queue_t)queue block:(dispatch_block_t)block {
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
    dispatch_after(popTime, queue, block);
}

- (instancetype) initWithFrame:(CGRect)frame andImage:(UIImage *)image {
    self = [super initWithFrame:frame];
    if (self) {
        self.delegate = self;
        self.bouncesZoom = YES;

        // Add container view
        UIView *containerView = [[UIView alloc] initWithFrame:self.bounds];
        containerView.backgroundColor = [UIColor clearColor];
        [self addSubview:containerView];
        _containerView = containerView;
        
        // Add image view
        UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
        imageView.frame = containerView.bounds;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        [containerView addSubview:imageView];
        _imageView = imageView;
        
        // Fit container view's size to image size
        CGSize imageSize = imageView.contentSize;
        self.containerView.frame = CGRectMake(0, 0, imageSize.width, imageSize.height);
        imageView.bounds = CGRectMake(0, 0, imageSize.width, imageSize.height);
        imageView.center = CGPointMake(imageSize.width / 2, imageSize.height / 2);
        
        self.contentSize = imageSize;
        self.minSize = imageSize;
        
        [self setMaxMinZoomScale];
        
        // Center containerView by set insets
        [self centerContent];

        // only add pan gesture and physics stuff if we can (e.g., iOS 7+)
        if (NSClassFromString(@"UIDynamicAnimator")) {
            // pan gesture to handle the physics
            _panRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanGesture:)];
            _panRecognizer.delegate = self;

            [self.containerView addGestureRecognizer:_panRecognizer];

            /* UIDynamics stuff */
            _animator = [[UIDynamicAnimator alloc] initWithReferenceView:self.containerView];
            _animator.delegate = self;

            // snap behavior to keep image view in the center as needed
            _snapBehavior = [[UISnapBehavior alloc] initWithItem:self.imageView snapToPoint:self.containerView.center];
            _snapBehavior.damping = 1.0f;

            _pushBehavior = [[UIPushBehavior alloc] initWithItems:@[self.imageView] mode:UIPushBehaviorModeInstantaneous];
            _pushBehavior.angle = 0.0f;
            _pushBehavior.magnitude = 0.0f;

            _itemBehavior = [[UIDynamicItemBehavior alloc] initWithItems:@[self.imageView]];
            _itemBehavior.elasticity = 0.0f;
            _itemBehavior.friction = 0.2f;
            _itemBehavior.allowsRotation = YES;
            _itemBehavior.density = __density;
            _itemBehavior.resistance = __resistance;
        }

        // Setup other events
        [self setupGestureRecognizer];
        [self setupRotationNotification];
    }
    
    return self;
}

- (void) layoutSubviews {
    [super layoutSubviews];
    
    if (self.rotating) {
        self.rotating = NO;

        // update container view frame
        CGSize containerSize = self.containerView.frame.size;
        BOOL containerSmallerThanSelf = (containerSize.width < CGRectGetWidth(self.bounds)) && (containerSize.height < CGRectGetHeight(self.bounds));

        CGSize imageSize = [self.imageView.image sizeThatFits:self.bounds.size];
        CGFloat minZoomScale = imageSize.width / self.minSize.width;
        self.minimumZoomScale = minZoomScale;
        if (containerSmallerThanSelf || self.zoomScale == self.minimumZoomScale) {
            // 宽度或高度 都小于 self 的宽度和高度
            self.zoomScale = minZoomScale;
        }

        // Center container view
        [self centerContent];
    }
}

- (void) dealloc {
    if (_animator) {
        [_animator removeAllBehaviors];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Setup

- (void) setupRotationNotification {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(orientationChanged:)
                                                 name:UIApplicationDidChangeStatusBarOrientationNotification
                                               object:nil];
}

- (void) setupGestureRecognizer {
    UILongPressGestureRecognizer *recognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    recognizer.minimumPressDuration = 0.5; // 设置最小长按时间；默认为0.5秒 .
    [_containerView addGestureRecognizer:recognizer];

    UITapGestureRecognizer *tapGestureRecognizer1 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapHandler1:)];
    tapGestureRecognizer1.numberOfTouchesRequired = 1;
    tapGestureRecognizer1.numberOfTapsRequired = 1;
    [_containerView addGestureRecognizer:tapGestureRecognizer1];

    UITapGestureRecognizer *tapGestureRecognizer2 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapHandler2:)];
    tapGestureRecognizer2.numberOfTouchesRequired = 1;
    tapGestureRecognizer2.numberOfTapsRequired = 2;
    [_containerView addGestureRecognizer:tapGestureRecognizer2];

    [tapGestureRecognizer1 requireGestureRecognizerToFail:tapGestureRecognizer2];
}

#pragma mark - UIScrollViewDelegate

- (UIView *) viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return self.containerView;
}

- (void) scrollViewDidZoom:(UIScrollView *)scrollView {
    [self centerContent];
}

#pragma mark - GestureRecognizer

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    NSAssert(_parentController, @"parentController must not nil");

    UIActivityViewController *avc =
    [[UIActivityViewController alloc] initWithActivityItems:@[self.imageView.image]
                                      applicationActivities:nil];
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
#if __IPHONE_OS_VERSION_MAX_ALLOWED > __IPHONE_7_1
        avc.popoverPresentationController.sourceView = self;
#endif
    }

    [_parentController presentViewController:avc animated:YES completion:nil];
}

- (void) tapHandler1:(UITapGestureRecognizer *)recognizer {
    NSLog(@"tapHandler    1");
    if (_doubleTap) {
        _doubleTap = NO;
        return;
    }
    if (self.zoomScale == self.minimumZoomScale) {
        if (_returnBlock) {
            _returnBlock();
        }
    }
}

- (void) tapHandler2:(UITapGestureRecognizer *)recognizer {
    NSLog(@"tapHandler    2");
    _doubleTap = YES;

    if (self.zoomScale > self.minimumZoomScale) {
        [self setZoomScale:self.minimumZoomScale animated:YES];

        [[self class] delayExcute:0.2 queue:dispatch_get_main_queue() block:^{
            _doubleTap = NO;
        }];

    } else if (self.zoomScale < self.maximumZoomScale) {
        CGPoint location = [recognizer locationInView:recognizer.view];
        CGRect zoomToRect = CGRectMake(0, 0, 50, 50);
        zoomToRect.origin = CGPointMake(location.x - CGRectGetWidth(zoomToRect)/2, location.y - CGRectGetHeight(zoomToRect)/2);
        [self zoomToRect:zoomToRect animated:YES];
    }
}

#pragma mark - UIGestureRecognizerDelegate Methods

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    CGFloat transformScale = self.imageView.transform.a;
    BOOL shouldRecognize = transformScale > self.minimumZoomScale;

    // make sure tap and double tap gestures aren't recognized simultaneously
    shouldRecognize = shouldRecognize && !([gestureRecognizer isKindOfClass:[UITapGestureRecognizer class]] && [otherGestureRecognizer isKindOfClass:[UITapGestureRecognizer class]]);

    return shouldRecognize;
}

#pragma mark - Gesture Methods

#if 0
- (void) handlePanGesture:(UIPanGestureRecognizer *)gestureRecognizer {
    NSLog(@"handlePanGesture");
}
#else
- (void) handlePanGesture:(UIPanGestureRecognizer *)gestureRecognizer {
    UIView *view = gestureRecognizer.view;
    CGPoint location = [gestureRecognizer locationInView:self.containerView];
    CGPoint boxLocation = [gestureRecognizer locationInView:self.imageView];

    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        [_animator removeBehavior:_snapBehavior];
        [_animator removeBehavior:_pushBehavior];

        UIOffset centerOffset = UIOffsetMake(boxLocation.x - CGRectGetMidX(self.imageView.bounds), boxLocation.y - CGRectGetMidY(self.imageView.bounds));
        _panAttachmentBehavior = [[UIAttachmentBehavior alloc] initWithItem:self.imageView offsetFromCenter:centerOffset attachedToAnchor:location];
        //_panAttachmentBehavior.frequency = 0.0f;
        [_animator addBehavior:_panAttachmentBehavior];
        [_animator addBehavior:_itemBehavior];
        [self scaleImageForDynamics];
    }
    else if (gestureRecognizer.state == UIGestureRecognizerStateChanged) {
        _panAttachmentBehavior.anchorPoint = location;
    }
    else if (gestureRecognizer.state == UIGestureRecognizerStateEnded) {
        [_animator removeBehavior:_panAttachmentBehavior];

        // need to scale velocity values to tame down physics on the iPad
        CGFloat deviceVelocityScale = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) ? 0.2f : 1.0f;
        CGFloat deviceAngularScale = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) ? 0.7f : 1.0f;
        // factor to increase delay before `dismissAfterPush` is called on iPad to account for more area to cover to disappear
        CGFloat deviceDismissDelay = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) ? 1.8f : 1.0f;
        CGPoint velocity = [gestureRecognizer velocityInView:self.containerView];
        CGFloat velocityAdjust = 10.0f * deviceVelocityScale;

        if (fabs(velocity.x / velocityAdjust) > __minimumVelocityRequiredForPush || fabs(velocity.y / velocityAdjust) > __minimumVelocityRequiredForPush) {
            UIOffset offsetFromCenter = UIOffsetMake(boxLocation.x - CGRectGetMidX(self.imageView.bounds), boxLocation.y - CGRectGetMidY(self.imageView.bounds));
            CGFloat radius = sqrtf(powf(offsetFromCenter.horizontal, 2.0f) + powf(offsetFromCenter.vertical, 2.0f));
            CGFloat pushVelocity = sqrtf(powf(velocity.x, 2.0f) + powf(velocity.y, 2.0f));

            // calculate angles needed for angular velocity formula
            CGFloat velocityAngle = atan2f(velocity.y, velocity.x);
            CGFloat locationAngle = atan2f(offsetFromCenter.vertical, offsetFromCenter.horizontal);
            if (locationAngle > 0) {
                locationAngle -= M_PI * 2;
            }

            // angle (θ) is the angle between the push vector (V) and vector component parallel to radius, so it should always be positive
            CGFloat angle = fabs(fabs(velocityAngle) - fabs(locationAngle));
            // angular velocity formula: w = (abs(V) * sin(θ)) / abs(r)
            CGFloat angularVelocity = fabs((fabs(pushVelocity) * sinf(angle)) / fabs(radius));

            // rotation direction is dependent upon which corner was pushed relative to the center of the view
            // when velocity.y is positive, pushes to the right of center rotate clockwise, left is counterclockwise
            CGFloat direction = (location.x < view.center.x) ? -1.0f : 1.0f;
            // when y component of velocity is negative, reverse direction
            if (velocity.y < 0) { direction *= -1; }

            // amount of angular velocity should be relative to how close to the edge of the view the force originated
            // angular velocity is reduced the closer to the center the force is applied
            // for angular velocity: positive = clockwise, negative = counterclockwise
            CGFloat xRatioFromCenter = fabs(offsetFromCenter.horizontal) / (CGRectGetWidth(self.imageView.frame) / 2.0f);
            CGFloat yRatioFromCetner = fabs(offsetFromCenter.vertical) / (CGRectGetHeight(self.imageView.frame) / 2.0f);

            // apply device scale to angular velocity
            angularVelocity *= deviceAngularScale;
            // adjust angular velocity based on distance from center, force applied farther towards the edges gets more spin
            angularVelocity *= ((xRatioFromCenter + yRatioFromCetner) / 2.0f);

            [_itemBehavior addAngularVelocity:angularVelocity * __angularVelocityFactor * direction forItem:self.imageView];
            [_animator addBehavior:_pushBehavior];
            _pushBehavior.pushDirection = CGVectorMake((velocity.x / velocityAdjust) * __velocityFactor, (velocity.y / velocityAdjust) * __velocityFactor);
            _pushBehavior.active = YES;
            
            // delay for dismissing is based on push velocity also
            CGFloat delay = __maximumDismissDelay - (pushVelocity / 10000.0f);
            [self performSelector:@selector(dismissAfterPush) withObject:nil afterDelay:(delay * deviceDismissDelay) * __velocityFactor];
        }
        else {
            [self returnToCenter];
        }
    }
}

- (void) returnToCenter {
    if (_animator) {
        [_animator removeAllBehaviors];
    }
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.imageView.transform = CGAffineTransformIdentity;
        self.imageView.frame = CGRectMake(0, 0, self.minSize.width, self.minSize.height);
    } completion:nil];
}

- (void) hideSnapshotView {
//    [UIView animateWithDuration:__animationDuration delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
//        self.blurredSnapshotView.alpha = 0.0f;
//        self.blurredSnapshotView.transform = CGAffineTransformIdentity;
//        self.snapshotView.transform = CGAffineTransformIdentity;
//    } completion:^(BOOL finished) {
//        [_snapshotView removeFromSuperview];
//        [self.blurredSnapshotView removeFromSuperview];
//        self.snapshotView = nil;
//        self.blurredSnapshotView = nil;
//    }];
}

- (void) scaleImageForDynamics {
    _lastZoomScale = self.zoomScale;

    CGRect imageFrame = self.imageView.frame;
    imageFrame.size.width *= _lastZoomScale;
    imageFrame.size.height *= _lastZoomScale;
    self.imageView.frame = imageFrame;
}

- (void) dismissAfterPush {
    [self hideSnapshotView];
    [UIView animateWithDuration:__animationDuration delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.alpha = 0.0f;
    } completion:^(BOOL finished) {
        if (_returnBlock) {
            _returnBlock();
        }
    }];
}

#endif

#pragma mark - Notification

- (void) orientationChanged:(NSNotification *)notification {
    self.rotating = YES;
}

#pragma mark - Helper

- (void) setMaxMinZoomScale {
    CGSize imageSize = self.imageView.image.size;
    CGSize imagePresentationSize = self.imageView.contentSize;
    CGFloat maxScale = MAX(imageSize.height / imagePresentationSize.height, imageSize.width / imagePresentationSize.width);
    self.maximumZoomScale = MAX(1, maxScale); // Should not less than 1
    self.minimumZoomScale = 1.0;
}

- (void) centerContent {
    CGRect frame = self.containerView.frame;

    CGFloat top = 0, left = 0;
    if (self.contentSize.width < self.bounds.size.width) {
        left = (self.bounds.size.width - self.contentSize.width) * 0.5f;
    }
    if (self.contentSize.height < self.bounds.size.height) {
        top = (self.bounds.size.height - self.contentSize.height) * 0.5f;
    }

    top -= frame.origin.y;
    left -= frame.origin.x;

    self.contentInset = UIEdgeInsetsMake(top, left, top, left);
}

@end
