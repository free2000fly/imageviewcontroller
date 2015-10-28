//
//  VIPhotoView.h
//  VIPhotoViewDemo
//
//  Created by Vito on 1/7/15.
//  Copyright (c) 2015 vito. All rights reserved.
//
// https://github.com/u10int/URBMediaFocusViewController
//

#import <UIKit/UIKit.h>

@interface VIPhotoView : UIScrollView
@property(nonatomic, weak) UIViewController *parentController;
@property(nonatomic, strong) dispatch_block_t returnBlock;
- (instancetype)initWithFrame:(CGRect)frame andImage:(UIImage *)image;
@end

@interface ImageController : UIViewController
@property(nonatomic, strong) UIImage *image;
@property(nonatomic, strong) dispatch_block_t returnBlock;
@end
