//
//  ImageViewController.m
//

#import "ImageViewController.h"

@interface UIView (URBMediaFocusViewController)
- (UIImage *) urb_snapshotImageWithScale:(CGFloat)scale;
- (void) urb_snapshowImageWithScale:(CGFloat)scale completion:(void (^)(UIImage *snapshotImage))completionBlock;
@end

@implementation UIView (URBMediaFocusViewController)

- (UIImage *) urb_snapshotImageWithScale:(CGFloat)scale {
    __strong CALayer *underlyingLayer = self.layer;
    CGRect bounds = self.bounds;

    CGSize size = bounds.size;
    if (self.contentMode == UIViewContentModeScaleToFill ||
        self.contentMode == UIViewContentModeScaleAspectFill ||
        self.contentMode == UIViewContentModeScaleAspectFit ||
        self.contentMode == UIViewContentModeRedraw)
    {
        // prevents edge artefacts
        size.width = floorf(size.width * scale) / scale;
        size.height = floorf(size.height * scale) / scale;
    }
    else if ([[UIDevice currentDevice].systemVersion floatValue] < 7.0f && [UIScreen mainScreen].scale == 1.0f) {
        // prevents pixelation on old devices
        scale = 1.0f;
    }
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, -bounds.origin.x, -bounds.origin.y);

    [underlyingLayer renderInContext:context];
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return snapshot;
}

- (void) urb_snapshowImageWithScale:(CGFloat)scale completion:(void (^)(UIImage *snapshotImage))completionBlock {
    if ([self respondsToSelector:@selector(drawViewHierarchyInRect:afterScreenUpdates:)]) {
        [CATransaction setCompletionBlock:^{
            UIGraphicsBeginImageContextWithOptions(self.bounds.size, NO, scale);
            [self drawViewHierarchyInRect:self.bounds afterScreenUpdates:NO];
            UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();

            if (completionBlock) {
                completionBlock(image);
            }
        }];
    }
    else {
        UIGraphicsBeginImageContextWithOptions(self.bounds.size, NO, scale);
        [self.layer renderInContext:UIGraphicsGetCurrentContext()];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        if (completionBlock) {
            completionBlock(image);
        }
    }
}

@end


#import <Accelerate/Accelerate.h>
#import <QuartzCore/QuartzCore.h>
#import <AssetsLibrary/AssetsLibrary.h>

@interface UIImage (URBImageEffects)
- (UIImage *) urb_applyBlurWithRadius:(CGFloat)blurRadius tintColor:(UIColor *)tintColor saturationDeltaFactor:(CGFloat)saturationDeltaFactor maskImage:(UIImage *)maskImage;
@end

@implementation UIImage (URBImageEffects)

- (UIImage *) urb_applyBlurWithRadius:(CGFloat)blurRadius tintColor:(UIColor *)tintColor saturationDeltaFactor:(CGFloat)saturationDeltaFactor maskImage:(UIImage *)maskImage {
    // Check pre-conditions.
    if (self.size.width < 1 || self.size.height < 1) {
        NSLog (@"*** error: invalid size: (%.2f x %.2f). Both dimensions must be >= 1: %@", self.size.width, self.size.height, self);
        return nil;
    }
    if (!self.CGImage) {
        NSLog (@"*** error: image must be backed by a CGImage: %@", self);
        return nil;
    }
    if (maskImage && !maskImage.CGImage) {
        NSLog (@"*** error: maskImage must be backed by a CGImage: %@", maskImage);
        return nil;
    }

    CGRect imageRect = { CGPointZero, self.size };
    UIImage *effectImage = self;

    BOOL hasBlur = blurRadius > __FLT_EPSILON__;
    BOOL hasSaturationChange = fabs(saturationDeltaFactor - 1.) > __FLT_EPSILON__;
    if (hasBlur || hasSaturationChange) {
        UIGraphicsBeginImageContextWithOptions(self.size, NO, [[UIScreen mainScreen] scale]);
        CGContextRef effectInContext = UIGraphicsGetCurrentContext();
        CGContextScaleCTM(effectInContext, 1.0, -1.0);
        CGContextTranslateCTM(effectInContext, 0, -self.size.height);
        CGContextDrawImage(effectInContext, imageRect, self.CGImage);

        vImage_Buffer effectInBuffer;
        effectInBuffer.data     = CGBitmapContextGetData(effectInContext);
        effectInBuffer.width    = CGBitmapContextGetWidth(effectInContext);
        effectInBuffer.height   = CGBitmapContextGetHeight(effectInContext);
        effectInBuffer.rowBytes = CGBitmapContextGetBytesPerRow(effectInContext);

        UIGraphicsBeginImageContextWithOptions(self.size, NO, [[UIScreen mainScreen] scale]);
        CGContextRef effectOutContext = UIGraphicsGetCurrentContext();
        vImage_Buffer effectOutBuffer;
        effectOutBuffer.data     = CGBitmapContextGetData(effectOutContext);
        effectOutBuffer.width    = CGBitmapContextGetWidth(effectOutContext);
        effectOutBuffer.height   = CGBitmapContextGetHeight(effectOutContext);
        effectOutBuffer.rowBytes = CGBitmapContextGetBytesPerRow(effectOutContext);

        if (hasBlur) {
            // A description of how to compute the box kernel width from the Gaussian
            // radius (aka standard deviation) appears in the SVG spec:
            // http://www.w3.org/TR/SVG/filters.html#feGaussianBlurElement
            //
            // For larger values of 's' (s >= 2.0), an approximation can be used: Three
            // successive box-blurs build a piece-wise quadratic convolution kernel, which
            // approximates the Gaussian kernel to within roughly 3%.
            //
            // let d = floor(s * 3*sqrt(2*pi)/4 + 0.5)
            //
            // ... if d is odd, use three box-blurs of size 'd', centered on the output pixel.
            //
            CGFloat inputRadius = blurRadius * [[UIScreen mainScreen] scale];
            float radius = floor(inputRadius * 3. * sqrt(2 * M_PI) / 4 + 0.5);
            if ((int)radius % 2 != 1) {
                radius += 1; // force radius to be odd so that the three box-blur methodology works.
            }
            vImageBoxConvolve_ARGB8888(&effectInBuffer, &effectOutBuffer, NULL, 0, 0, radius, radius, 0, kvImageEdgeExtend);
            vImageBoxConvolve_ARGB8888(&effectOutBuffer, &effectInBuffer, NULL, 0, 0, radius, radius, 0, kvImageEdgeExtend);
            vImageBoxConvolve_ARGB8888(&effectInBuffer, &effectOutBuffer, NULL, 0, 0, radius, radius, 0, kvImageEdgeExtend);
        }
        BOOL effectImageBuffersAreSwapped = NO;
        if (hasSaturationChange) {
            CGFloat s = saturationDeltaFactor;
            CGFloat floatingPointSaturationMatrix[] = {
                0.0722 + 0.9278 * s,  0.0722 - 0.0722 * s,  0.0722 - 0.0722 * s,  0,
                0.7152 - 0.7152 * s,  0.7152 + 0.2848 * s,  0.7152 - 0.7152 * s,  0,
                0.2126 - 0.2126 * s,  0.2126 - 0.2126 * s,  0.2126 + 0.7873 * s,  0,
                0,                    0,                    0,  1,
            };
            const int32_t divisor = 256;
            NSUInteger matrixSize = sizeof(floatingPointSaturationMatrix)/sizeof(floatingPointSaturationMatrix[0]);
            int16_t saturationMatrix[matrixSize];
            for (NSUInteger i = 0; i < matrixSize; ++i) {
                saturationMatrix[i] = (int16_t)roundf(floatingPointSaturationMatrix[i] * divisor);
            }
            if (hasBlur) {
                vImageMatrixMultiply_ARGB8888(&effectOutBuffer, &effectInBuffer, saturationMatrix, divisor, NULL, NULL, kvImageNoFlags);
                effectImageBuffersAreSwapped = YES;
            }
            else {
                vImageMatrixMultiply_ARGB8888(&effectInBuffer, &effectOutBuffer, saturationMatrix, divisor, NULL, NULL, kvImageNoFlags);
            }
        }
        if (!effectImageBuffersAreSwapped)
            effectImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        if (effectImageBuffersAreSwapped)
            effectImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }

    // Set up output context.
    UIGraphicsBeginImageContextWithOptions(self.size, NO, [[UIScreen mainScreen] scale]);
    CGContextRef outputContext = UIGraphicsGetCurrentContext();
    CGContextScaleCTM(outputContext, 1.0, -1.0);
    CGContextTranslateCTM(outputContext, 0, -self.size.height);

    // Draw base image.
    CGContextDrawImage(outputContext, imageRect, self.CGImage);

    // Draw effect image.
    if (hasBlur) {
        CGContextSaveGState(outputContext);
        if (maskImage) {
            CGContextClipToMask(outputContext, imageRect, maskImage.CGImage);
        }
        CGContextDrawImage(outputContext, imageRect, effectImage.CGImage);
        CGContextRestoreGState(outputContext);
    }

    // Add in color tint.
    if (tintColor) {
        CGContextSaveGState(outputContext);
        CGContextSetFillColorWithColor(outputContext, tintColor.CGColor);
        CGContextFillRect(outputContext, imageRect);
        CGContextRestoreGState(outputContext);
    }

    // Output image is ready.
    UIImage *outputImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return outputImage;
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


@interface RichPhotoView () <UIScrollViewDelegate, UIGestureRecognizerDelegate, UIDynamicAnimatorDelegate>

@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UIImageView *imageView;

@property (nonatomic) BOOL rotating;
@property (nonatomic) CGSize minSize;

@end

@implementation RichPhotoView {
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
        imageView.backgroundColor = [UIColor clearColor];
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
            // 宽度或高度 都小于 self 的宽度和高度 .
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
        CGPoint pt = [recognizer locationInView:self];
        avc.popoverPresentationController.sourceView = self;
        avc.popoverPresentationController.sourceRect = CGRectMake(pt.x, pt.y, 1, 1);
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

- (void) scaleImageForDynamics {
    _lastZoomScale = self.zoomScale;

    CGRect imageFrame = self.imageView.frame;
    imageFrame.size.width *= _lastZoomScale;
    imageFrame.size.height *= _lastZoomScale;
    self.imageView.frame = imageFrame;
}

- (void) dismissAfterPush {
    if (_returnBlock) {
        _returnBlock();
    }
}

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


@implementation ImageViewController {
    RichPhotoView *_photoView;

    __weak UIView *_keyWindow;

    UIImageView *_blurredSnapshotView;
    UIView *_snapshotView;
}

- (void) dealloc {
    // NSLog(@"ImageViewController::dealloc");
}

- (void) setKeyWindow:(UIView *)keyWindow {
    _keyWindow = keyWindow;
    [self createViewsForBackground];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    if ([UIView instancesRespondToSelector:@selector(setTintAdjustmentMode:)]) {
        _keyWindow.tintAdjustmentMode = UIViewTintAdjustmentModeDimmed;
        [_keyWindow tintColorDidChange];
    }

    if (_snapshotView) {
        [_keyWindow addSubview:_blurredSnapshotView];
        [_keyWindow insertSubview:_snapshotView belowSubview:_blurredSnapshotView];
    }

    _photoView.alpha = 0.0f;
    [_keyWindow addSubview:_photoView];

    [UIView animateWithDuration:__animationDuration delay:0.1 options:UIViewAnimationOptionCurveEaseOut animations:^{
        if (_snapshotView) {
            _blurredSnapshotView.alpha = 1.0f;
            _blurredSnapshotView.transform = CGAffineTransformScale(CGAffineTransformIdentity, __backgroundScale, __backgroundScale);
            _snapshotView.transform = CGAffineTransformScale(CGAffineTransformIdentity, __backgroundScale, __backgroundScale);
        }
    } completion:^(BOOL finished) {
        _photoView.alpha = 1.0f;
    }];
}

- (BOOL) prefersStatusBarHidden {
    return YES;
}

- (void) setImage:(UIImage *)image {
    _image = image;

    CGRect rc = self.view.bounds;
    RichPhotoView *photoView = [[RichPhotoView alloc] initWithFrame:rc andImage:image];
    photoView.autoresizingMask = (1 << 6) -1;
    photoView.parentController = self;

    _photoView = photoView;

    [self setReturnBlock:_returnBlock];
}

- (void) setReturnBlock:(dispatch_block_t)returnBlock {
    _returnBlock = returnBlock;
    if (_photoView) {
        typeof(self) __weak weakSelf = self;
        _photoView.returnBlock = ^{
            typeof(weakSelf) __strong strongSelf = weakSelf;

            [strongSelf hideSnapshotView];
            [UIView animateWithDuration:__animationDuration delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                strongSelf->_photoView.alpha = 0.0f;
            } completion:^(BOOL finished) {
                [strongSelf->_photoView removeFromSuperview];
                strongSelf->_photoView = nil;
                if (returnBlock) {
                    returnBlock();
                }
            }];
        };
    }
}

- (void) createViewsForBackground {
    // container view for window
    CGRect containerFrame = CGRectMake(0, 0, CGRectGetWidth(_keyWindow.frame), CGRectGetHeight(_keyWindow.frame));

    // inset container view so we can blur the edges, but we also need to scale up so when __backgroundScale is applied, everything lines up
    containerFrame.size.width *= 1.0f / __backgroundScale;
    containerFrame.size.height *= 1.0f / __backgroundScale;

    UIView *tmpSnapshotView = [[UIView alloc] initWithFrame:CGRectIntegral(containerFrame)];
    tmpSnapshotView.backgroundColor = [UIColor blackColor];

    // add snapshot of window to the container
    UIImage *windowSnapshot = [_keyWindow urb_snapshotImageWithScale:[UIScreen mainScreen].scale];
    UIImageView *windowSnapshotView = [[UIImageView alloc] initWithImage:windowSnapshot];
    windowSnapshotView.center = tmpSnapshotView.center;
    [tmpSnapshotView addSubview:windowSnapshotView];
    tmpSnapshotView.center = _keyWindow.center;

    UIImageView *snapshotView;
    // only add blurred view if radius is above 0
    if (__blurRadius) {
        UIImage *snapshot = [tmpSnapshotView urb_snapshotImageWithScale:[UIScreen mainScreen].scale];
        snapshot = [snapshot urb_applyBlurWithRadius:__blurRadius
                                           tintColor:[UIColor colorWithWhite:0.0f alpha:__blurTintColorAlpha]
                               saturationDeltaFactor:__blurSaturationDeltaMask
                                           maskImage:nil];
        snapshotView = [[UIImageView alloc] initWithImage:snapshot];
        snapshotView.center = tmpSnapshotView.center;
        snapshotView.alpha = 0.0f;
        snapshotView.userInteractionEnabled = NO;
    }

    _snapshotView = tmpSnapshotView;
    _blurredSnapshotView = snapshotView;
}

- (void) hideSnapshotView {
    [UIView animateWithDuration:__animationDuration delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        _blurredSnapshotView.alpha = 0.0f;
        _blurredSnapshotView.transform = CGAffineTransformIdentity;
        _snapshotView.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        [_snapshotView removeFromSuperview];
        [_blurredSnapshotView removeFromSuperview];
        _snapshotView = nil;
        _blurredSnapshotView = nil;
    }];
}

@end
