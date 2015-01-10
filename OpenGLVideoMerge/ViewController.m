//
//  ViewController.m
//  OpenGLVideoMerge
//
//  Created by Tuo on 11/9/13.
//  Copyright (c) 2013 Tuo. All rights reserved.
//

#import "ViewController.h"
#import "SVProgressHUD.h"


#import <GPUImageView.h>
#import <GPUImageMovie.h>
#import <GPUImageChromaKeyBlendFilter.h>
#import <GPUImageMovieWriter.h>

#import <AssetsLibrary/ALAsset.h>
#import <AssetsLibrary/ALAssetsLibrary.h>
#import <AssetsLibrary/ALAssetRepresentation.h>

@interface ViewController ()
@property (strong, nonatomic) IBOutlet UIButton *startMergeBtn;
@property (weak, nonatomic) IBOutlet UILabel *gpuResultLabel;
@property (weak, nonatomic) IBOutlet UILabel *customResultLabel;

@property (weak, nonatomic) IBOutlet UILabel *videoMergeTipName;

@property (nonatomic, strong) GPUImageMovie *gpuMovieFX;
@property (nonatomic, strong) GPUImageMovie *gpuMovieA;
@property (nonatomic, strong) GPUImageMovieWriter *movieWriter;
@property (nonatomic, strong) GPUImageChromaKeyBlendFilter *filter;
@property (nonatomic, strong) ALAssetsLibrary *library;

@property(nonatomic) NSDate *startDate;
@property(nonatomic) NSURL *outputURL;

@property(nonatomic) dispatch_group_t recordSyncingDispatchGroup;
@end

@implementation ViewController {
    
    NSURL *fxURL,*rawVideoURL;
}



- (void)viewDidLoad
{
    [super viewDidLoad];




}


- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (IBAction)onMergeAllAudios:(id)sender {
    [self gpuimageProcessWithFXMovieName: @"FXSample" rawMovieName: @"record"];
}


- (IBAction)onMergeOnlyOneAudio:(id)sender {
    [self gpuimageProcessWithFXMovieName: @"FXSample" rawMovieName: @"record_no_audio"];
    //[self gpuimageProcessWithFXMovieName: @"FXSample_no_audio" rawMovieName: @"record"];
}
- (IBAction)onMergeNoAudioAtAll:(id)sender {
    [self gpuimageProcessWithFXMovieName: @"FXSample_no_audio" rawMovieName: @"record_no_audio"];
}

- (void)gpuimageProcessWithFXMovieName:(NSString *)fxName rawMovieName:(NSString *)rawName {
    //tips on how to use ffmpeg to extract audio track from video
    //ffmpeg -i FXSample.mov -vcodec copy -an FXSample_no_audio.mov
    //ffmpeg -i record.mov -vcodec copy -an record_no_audio.mov


    fxURL = [[NSBundle mainBundle] URLForResource:fxName withExtension:@"mov"];
    rawVideoURL = [[NSBundle mainBundle] URLForResource:rawName withExtension:@"mov"];

    self.videoMergeTipName.text = [NSString stringWithFormat:@"FX:%@, RAW: %@", fxName, rawName];


    [SVProgressHUD showWithStatus:@"processing..."];
    self.startDate = [NSDate date];
    self.gpuMovieA = [[GPUImageMovie alloc] initWithURL:rawVideoURL];
    
    self.gpuMovieFX = [[GPUImageMovie alloc] initWithURL:fxURL];
  
    
    self.filter = [[GPUImageChromaKeyBlendFilter alloc] init];
    [self.filter forceProcessingAtSize:CGSizeMake(640/2, 640/2)];
    
    [self.gpuMovieFX addTarget:self.filter];
    [self.gpuMovieA addTarget:self.filter];
    
    
    //setup writer
    NSString *pathToMovie = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/gpu_output.mov"];
    unlink([pathToMovie UTF8String]); // If a file already exists, AVAssetWriter won't let you record new frames, so delete the old movie
    self.outputURL = [NSURL fileURLWithPath:pathToMovie];
    self.movieWriter =  [[GPUImageMovieWriter alloc] initWithMovieURL:self.outputURL size:CGSizeMake(640.0/2, 640.0/2)];
    [self.filter addTarget:self.movieWriter];

    NSArray *movies = @[self.gpuMovieA, self.gpuMovieFX];


    dispatch_group_t movieReadyDispatchGroup = dispatch_group_create();
    for(GPUImageMovie *movie in movies){
        [movie loadAsset:movieReadyDispatchGroup];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(movieReadyDispatchGroup, dispatch_get_main_queue(), ^{
        NSLog(@"all movies are ready to process :)");

        NSMutableArray *audioTracks = [NSMutableArray array];
        for(GPUImageMovie *movie in movies){
            AVAssetTrack *track = [movie.asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
            if(track){
                [audioTracks addObject:track];
            }
        }

        if(audioTracks.count > 0){
            [self.movieWriter setupAudioReaderWithTracks:audioTracks];
            [self.movieWriter setHasAudioTrack:YES]; //use default audio settings, setup asset writer audio
        }


        self.recordSyncingDispatchGroup = dispatch_group_create();

        //this has to be called before, to make sure all audio/video in movie writer is set
        [self.movieWriter startRecording];


        //video handling
        dispatch_group_enter(self.recordSyncingDispatchGroup);
        [self.gpuMovieA startProcessing];
        [self.gpuMovieFX startProcessing];

        [self.movieWriter setCompletionBlock:^{
            [weakSelf.gpuMovieFX endProcessing];
            [weakSelf.gpuMovieA endProcessing];
            [weakSelf.movieWriter finishVideoRecordingWithCompletionHandler:^{
                //[SVProgressHUD showSuccessWithStatus:@"Done"];
                NSLog(@"===video wrote is done");
                dispatch_group_leave(weakSelf.recordSyncingDispatchGroup);
            }];
        }];
         


        //audio handling
        dispatch_group_enter(self.recordSyncingDispatchGroup);
        [self.movieWriter startAudioRecording];
        [self.movieWriter startAudioWritingWithComplectionBlock:^{
            NSLog(@"====audio wring is done");
            dispatch_group_leave(weakSelf.recordSyncingDispatchGroup);
        }];
        


        dispatch_group_notify(self.recordSyncingDispatchGroup, dispatch_get_main_queue(), ^{
            NSLog(@"vidoe and audio writing are both done-----------------");
            [self.movieWriter finishRecordingWithCompletionHandler:^{
                NSLog(@"final clean up is done :)");
                [weakSelf writeToAlbum:weakSelf.outputURL];

                dispatch_async(dispatch_get_main_queue(), ^{
                    [SVProgressHUD showSuccessWithStatus:@"Done"];
                    NSString *time = [NSString stringWithFormat:@"GPU: %f seconds.",  -([weakSelf.startDate timeIntervalSinceNow])];

                    weakSelf.gpuResultLabel.text = time;
                });
            }];
        });

    });




}


- (void)writeToAlbum:(NSURL *)outputFileURL{
    self.library = [[ALAssetsLibrary alloc] init];
    if ([_library videoAtPathIsCompatibleWithSavedPhotosAlbum:outputFileURL])
    {
        [_library writeVideoAtPathToSavedPhotosAlbum:outputFileURL
                                     completionBlock:^(NSURL *assetURL, NSError *error)
         {
             if (error)
             {
                 dispatch_async(dispatch_get_main_queue(), ^{
                     [SVProgressHUD showErrorWithStatus:@"failed"];
                 });
                 NSLog(@"fail to saved: %@", error);
             }else{
                 NSLog(@"saved");
                 dispatch_async(dispatch_get_main_queue(), ^{
                     [SVProgressHUD showSuccessWithStatus:@"saved"];
                 });
             }
         }];
    }
}




@end
