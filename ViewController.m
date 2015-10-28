//
//  ViewController.m
//  VIPhotoViewDemo
//
//  Created by Vito on 1/7/15.
//  Copyright (c) 2015 vito. All rights reserved.
//

#import "ViewController.h"
#import "ImageViewController.h"


@interface ViewController ()
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
}

- (void) viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    //NSLog(@"%@", NSStringFromCGRect([[[self.view subviews] lastObject] frame]));
}

- (IBAction) testMethod:(UIButton *)sender {
    ImageViewController *imgCtrl = [[ImageViewController alloc] init];
    imgCtrl.keyWindow = [[UIApplication sharedApplication] keyWindow];
    imgCtrl.image = [UIImage imageNamed:@"test.jpg"];

    imgCtrl.returnBlock = ^ {
        [self dismissViewControllerAnimated:NO completion:nil];
    };

    [self presentViewController:imgCtrl animated:NO completion:^{
    }];
}

- (void) didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end
