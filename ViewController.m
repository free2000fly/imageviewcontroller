//
//  ViewController.m
//  VIPhotoViewDemo
//
//  Created by Vito on 1/7/15.
//  Copyright (c) 2015 vito. All rights reserved.
//

#import "ViewController.h"
#import "VIPhotoView.h"


@interface ImageController : UIViewController
@property(nonatomic, strong) UIImage *image;
@property(nonatomic, strong) dispatch_block_t returnBlock;
@end

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



@interface ViewController ()
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

}

- (void) viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    NSLog(@"%@", NSStringFromCGRect([[[self.view subviews] lastObject] frame]));
}

- (IBAction) testMethod:(UIButton *)sender {
    ImageController *imgCtrl = [[ImageController alloc] init];
    imgCtrl.image = [UIImage imageNamed:@"test.jpg"];

    imgCtrl.returnBlock = ^ {
        [self dismissViewControllerAnimated:YES completion:nil];
    };

    [self presentViewController:imgCtrl animated:YES completion:nil];
}

- (void) didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end
