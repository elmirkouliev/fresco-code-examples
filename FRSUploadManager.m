//
//  FRSUploadManager.m
//  Fresco
//
//  Created by Elmir Kouev on 2/23/17.
//  Copyright © 2016 Fresco. All rights reserved.
//

#import "FRSUploadManager.h"
#import <AWSCore/AWSCore.h>
#import <AWSS3/AWSS3.h>
#import "FRSUpload+CoreDataProperties.h"
#import "EndpointManager.h"
#import "NSManagedObject+MagicalRecord.h"
#import "FRSLocator.h"
#import "NSDate+ISO.h"
#import "NSError+Fresco.h"
#import "PHAsset+Fresco.h"
#import "CLLocation+Fresco.h"
#import "NSURL+Fresco.h"
#import "FRSGalleryUploadedToast.h"

#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v) ([[[UIDevice currentDevice] systemVersion] compare:(v) options:NSNumericSearch] != NSOrderedAscending)
#define AWS_REGION AWSRegionUSEast1


static NSString *const postID = @"post_id";
static NSString *const totalUploadProgress = @"uploadProgress";
static NSString *const totalUploadFileSize = @"totalUploadFileSize";

@interface FRSUploadManager ()

@property (nonatomic, strong) AWSS3TransferManager *transferManager;

@end

@implementation FRSUploadManager

+ (id)sharedInstance {
    static FRSUploadManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      sharedInstance = [[self alloc] init];
      [[NSNotificationCenter defaultCenter] addObserver:sharedInstance selector:@selector(notifyExit:) name:UIApplicationWillResignActiveNotification object:nil];

    });

    return sharedInstance;
}

#pragma mark - Object lifecycle

- (instancetype)init {
    self = [super init];

    if (self) {
        FRSAppDelegate *delegate = (FRSAppDelegate *)[[UIApplication sharedApplication] delegate];
        self.context = delegate.coreDataController.managedObjectContext;
        
        [self subscribeToEvents];
        [self resetState];
        [self startAWS];
    }

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isUploading {
    return numberOfAssets > 0;
}

/**
 This method will reset the state of the upload manager to a blank slate. 
 Should typically be called once an upload is finished or before starting a new one.
 
 Note: Managed objects are cleared on a forcel cancel of the upload, not here
 */
- (void)resetState {
    self.transcodingProgressDictionary = [[NSMutableDictionary alloc] init];
    self.uploadProgressDictionary = [[NSMutableDictionary alloc] init];
    totalFileSize = 0;
    totalVideoFilesSize = 0;
    totalImageFilesSize = 0;
    uploadedFileSize = 0;
    lastProgress = 0;
    toComplete = 0;
    numberOfAssets = 0;
    completed = 0;
    uploadSpeed = 0;
    numberOfVideos = 0;
}

/**
 Configures AWS for us
 */
- (void)startAWS {
    AWSStaticCredentialsProvider *credentialsProvider = [[AWSStaticCredentialsProvider alloc]
                                                         initWithAccessKey:[EndpointManager sharedInstance].currentEndpoint.amazonS3AccessKey
                                                         secretKey:[EndpointManager sharedInstance].currentEndpoint.amazonS3SecretKey];
    
    AWSServiceConfiguration *configuration = [[AWSServiceConfiguration alloc] initWithRegion:AWS_REGION credentialsProvider:credentialsProvider];
    
    [AWSServiceManager defaultServiceManager].defaultServiceConfiguration = configuration;
    
    self.transferManager = [AWSS3TransferManager defaultS3TransferManager];
}


#pragma mark - Files

- (void)checkCachedUploads {
    NSPredicate *signedInPredicate = [NSPredicate predicateWithFormat:@"%K == %@", @"completed", @(FALSE)];
    NSFetchRequest *signedInRequest = [NSFetchRequest fetchRequestWithEntityName:@"FRSUpload"];
    NSMutableDictionary *uploadsDictionary = [[NSMutableDictionary alloc] init];
    signedInRequest.predicate = signedInPredicate;

    //No need to sort response, because theoretically there is 1
    NSError *fetchError;
    NSArray *uploads = [self.context executeFetchRequest:signedInRequest error:&fetchError];
    
    if(uploads == nil && fetchError != nil) return;

    if (uploads.count > 0) {
        for (FRSUpload *upload in uploads) {
            NSTimeInterval sinceStart = [upload.creationDate timeIntervalSinceNow];
            sinceStart *= -1;

            //If older than a day, in seconds, remove from persistence
            if (sinceStart >= (24 * 60 * 60)) {
                [self.context performBlock:^{
                    [self.context deleteObject:upload];
                    [self.context save:nil];
                }];
            } else {
                NSString *key = upload.uploadID;
                [uploadsDictionary setObject:upload forKey:key];
            }
        }
        
        //Assign to class and retry
        self.managedObjects = uploadsDictionary;
        [self retryUpload];
    } else {
        //Otherwise clear cached uploads
        [self clearCachedUploads];
    }
}


/**
 Destroys all cached uploads in the local file system
 */
- (void)clearCachedUploads {
    BOOL isDir;
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:localDirectory]; // temp directory where we store video
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:directory isDirectory:&isDir]) {
        if (![fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) {
            NSLog(@"Error: Create folder failed %@", directory);
            return;
        }
    }
    
    //Purge old un-needed files
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:localDirectory];
        NSError *error = nil;
        for (NSString *file in [fileManager contentsOfDirectoryAtPath:directory error:&error]) {
            NSString *filePath =[NSString stringWithFormat:@"%@/%@", directory, file];
            BOOL success = [fileManager removeItemAtPath:filePath error:&error];
            
            if (!success || error) {
                NSLog(@"Upload cache purge %@ with error: %@", (success) ? @"succeeded" : @"failed", error);
            }
        }
    });
}

#pragma mark - Events

- (void)appWillResignActive {
    if (completed == toComplete) {
        return;
    }

    if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"10.0") == FALSE) {
        UILocalNotification *localNotification = [[UILocalNotification alloc] init];
        localNotification.fireDate = [NSDate dateWithTimeIntervalSinceNow:3];
        localNotification.alertBody = @"Wait, we're almost done! Come back to Fresco to finish uploading your gallery.";
        localNotification.timeZone = [NSTimeZone defaultTimeZone];
        [[UIApplication sharedApplication] scheduleLocalNotification:localNotification];

        return;
    }

    UNMutableNotificationContent *objNotificationContent = [[UNMutableNotificationContent alloc] init];
    objNotificationContent.title = [NSString localizedUserNotificationStringForKey:@"Come back and finish your upload!" arguments:nil];
    objNotificationContent.body = [NSString localizedUserNotificationStringForKey:@"Wait, we're almost done! Come back to Fresco to finish uploading your gallery."
                                                                        arguments:nil];
    objNotificationContent.sound = [UNNotificationSound defaultSound];
    objNotificationContent.userInfo = @{ @"type" : @"trigger-upload-notification" };

    NSDateComponents *components = [[NSCalendar currentCalendar] components:NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:[NSDate date]];
    components.second += 3;
    UNCalendarNotificationTrigger *trigger = [UNCalendarNotificationTrigger
        triggerWithDateMatchingComponents:components
                                  repeats:FALSE];

    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"com.fresconews.Fresco"
                                                                          content:objNotificationContent
                                                                          trigger:trigger];
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center addNotificationRequest:request
             withCompletionHandler:^(NSError *_Nullable error) {
               if (!error) {
                   NSLog(@"Local Notification succeeded!");
               } else {
                   NSLog(@"Local Notification failed.");
               }
             }];
}



- (void)notifyExit:(NSNotification *)notification {
    if (completed == toComplete || toComplete == 0) {
        return;
    }
    
    [FRSTracker track:uploadClose
           parameters:@{ @"percent_complete" : @(lastProgress) }];
}

- (void)subscribeToEvents {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillResignActive) name:UIApplicationWillResignActiveNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:FRSRetryUpload
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *notification) {
                                                      [self retryUpload];
                                                  }];

    [[NSNotificationCenter defaultCenter] addObserverForName:FRSDismissUpload
                                                      object:nil
                                                       queue:nil
     
                                                  usingBlock:^(NSNotification *notification) {
                                                      [self cancelUploadWithForce:YES];
                                                  }];
}

/**
 Updates trancoding progress in state dictionary, then signals an update progress call to
 broadcast to navigation bar
 
 @param progress Floating point of current progress for a post
 @param postID The ID of the post progress is being reported on
 */
- (void)updateTranscodingProgress:(float)progress withPostID:(NSString *)postID {
    [self.transcodingProgressDictionary setValue:[NSNumber numberWithFloat:progress] forKey:postID];
    [self updateProgress];
}


/**
 Updates the upload progress in for the post passed in the 
 state's upload progress dictionary

 @param bytes Number of bytes just uploaded
 @param postID The post on which to update the upload progress on
 */
- (void)updateUploadProgress:(int64_t)bytes forPost:(NSString *)postID{
    NSMutableDictionary *uploadProgress = [self.uploadProgressDictionary objectForKey:postID];
    
    if([uploadProgress objectForKey:totalUploadProgress] != nil) {
        float currentProgress = [((NSNumber *)[uploadProgress objectForKey:totalUploadProgress]) floatValue];
        [uploadProgress setObject:@(bytes + currentProgress) forKey:totalUploadProgress];
    } else {
        [uploadProgress setObject:@(bytes) forKey:totalUploadProgress];
    }
    
    [self updateProgress];
}


/**
 Updates progress by adding together upload and trancoding progress in current state. The progresses are add together
 to represent one signal percentage
 */
- (void)updateProgress {
    // Default progress to 10% to draw the users attention to the bar when uploading.
    float progress = 0.1;
    __block float uploadingProgress = 0.1;
    
    if(toComplete > 0) {
        [self.uploadProgressDictionary enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *uploadProgress, BOOL *stop) {
            uploadingProgress += [((NSNumber *)uploadProgress[totalUploadProgress]) floatValue] / [((NSNumber *)uploadProgress[totalUploadFileSize]) floatValue];
        }];
        //We user `numberOfAssets` instead because `toComplete` is set as trancoding occurs
        uploadingProgress = uploadingProgress / numberOfAssets;
    }
    
    //Add together by total percentages, which is 2, to consider trancoding time
    if(numberOfVideos > 0) {
        __block float transcodeProgress = 0;
        
        [self.transcodingProgressDictionary enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *value, BOOL *stop) {
            transcodeProgress += value.floatValue;
        }];
        transcodeProgress = transcodeProgress / numberOfVideos;
        
        progress = (uploadingProgress + transcodeProgress) / 2;
    } else {
        progress = uploadingProgress;
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:FRSUploadNotification
                                                        object:nil
                                                      userInfo:@{ @"type" : @"progress",
                                                                  @"percentage" : @(progress) }];
}

#pragma mark - Assets

- (void)digestForAsset:(PHAsset *)asset callback:(FRSAPIDefaultCompletionBlock)callback {
    NSMutableDictionary *digest = [[NSMutableDictionary alloc] init];
    
    // Add captured_at regardless if photo/video or location exists
    digest[@"captured_at"] = [(NSDate *)asset.creationDate ISODateWithTimeZone];
    
    // Reuseable block to configure photo or video digest
    void (^createDigest)(void) = ^ {
        if (asset.mediaType == PHAssetMediaTypeImage) {
            digest[@"contentType"] = @"image/jpeg";
        } else {
            digest[@"contentType"] = @"video/mp4";
        }
        [asset fetchFileSize:^(NSInteger size, NSError *error) {
            digest[@"fileSize"] = @(size);
            digest[@"chunkSize"] = @(size);
            callback(digest, error);
        }];
    };
    
    // Avoid adding location related keys to digest if the asset does not have a location
    if (asset.location) {
        [asset.location fetchAddress:^(id responseObject, NSError *error) {
            digest[@"address"] = responseObject;
            digest[@"lat"] = @(asset.location.coordinate.latitude);
            digest[@"lng"] = @(asset.location.coordinate.longitude);
            createDigest();
        }];
    } else {
        createDigest();
    }
}

/**
 Creates an an asset for uploading by writing to the local file system and returning information
 on the location and size of the asset. The upload itself will also be saved to Core Data here if it's not already
 so that it can be pulled from cache or the upload fails mid-way
 
 TODO: Make this save the local path to be re-used later instead on the FRSUpload
 of trancoding every time if the user fails and retries the upload
 
 @param asset The PHAsset to genereate for upload
 @param key The AWS file key we're uploading to
 @param postID The ID of the post which correpsonds to this asset
 @param completion completion handler returning metadata on the asset
 */
- (void)createAssetForUpload:(PHAsset *)asset withKey:(NSString *)key withPostID:(NSString *)postID completion:(FRSUploadPostAssetCompletionBlock)completion {
    NSString *revisedKey = [@"raw/" stringByAppendingString:key];
    
    if (asset.mediaType == PHAssetMediaTypeImage) {
        PHImageRequestOptions *options = [[PHImageRequestOptions alloc] init];
        options.resizeMode = PHImageRequestOptionsResizeModeNone;
        options.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
        options.version = PHImageRequestOptionsVersionOriginal;
        
        [[PHImageManager defaultManager] requestImageDataForAsset:asset
                                                          options:options
                                                    resultHandler:^(NSData *_Nullable imageData, NSString *_Nullable dataUTI, UIImageOrientation orientation, NSDictionary *_Nullable info) {

                                                        NSString *tempPath = [[NSURL uniqueFileString] stringByAppendingString:@".jpeg"];
                                                        NSError *imageError;
                                                        
                                                        //Write data to temp path (background thread, async)
                                                        if([imageData writeToFile:tempPath options:NSDataWritingAtomic error:&imageError]) {
                                                            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:tempPath error:&imageError];
                                                            
                                                            //Handle possible read error
                                                            if(attributes != nil && !imageError) {
                                                                NSDictionary *uploadMeta = [self uploadDictionaryForPost:tempPath key:revisedKey post:postID];
                                                                completion(uploadMeta, NO, [attributes fileSize], nil);
                                                            } else {
                                                                completion(nil, NO, 0, imageError);
                                                            }
                                                        } else {
                                                            completion(nil, NO, 0, imageError);
                                                        }
                                                    }];
        
    } else if (asset.mediaType == PHAssetMediaTypeVideo) {
        [[PHImageManager defaultManager] requestAVAssetForVideo:asset
                                                        options:nil
                                                  resultHandler:^(AVAsset *avasset, AVAudioMix *audioMix, NSDictionary *info) {

                                                      //Create temp location to move data (PHAsset can not be weakly linked to)
                                                      NSString *tempPath = [NSURL uniqueFileString];
                                                      NSArray *videoTracks = [avasset tracksWithMediaType:AVMediaTypeVideo];
                                                      AVAssetTrack *videoTrack;
                                                      
                                                      if ([videoTracks count] == 0) {
                                                          completion(nil,
                                                                     YES,
                                                                     0,
                                                                     [NSError
                                                                      errorWithMessage:@"One of your videos couldn't be processed, please cancel your upload and try a different set of videos!"]);
                                                      }
                                                      
                                                      videoTrack = [videoTracks objectAtIndex:0];
                                                      [self updateEncoderWithAVAsset:avasset phasset:asset videoTrack:videoTrack postID:postID];
                                                      self.exportSession.outputURL = [NSURL fileURLWithPath:tempPath];
                                                      
                   
                                                      //Begin encoding the video, delegate responder will update the progress
                                                      [self.exportSession exportAsynchronouslyWithCompletionHandler:^{
                                                          if(self.exportSession.status == AVAssetExportSessionStatusCancelled) {
                                                              completion(nil, YES, 0, [NSError errorWithMessage:@"The export was canceled!"]);
                                                          } else if(self.exportSession.error != nil) {
                                                              completion(nil, YES, 0, self.exportSession.error);
                                                          } else if(self.exportSession.status == AVAssetExportSessionStatusCompleted) {
                                                              NSError *videoError;
                                                              NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:tempPath error:&videoError];
                                                              
                                                              //Handle possible read error
                                                              if(attributes != nil && !videoError) {
                                                                  NSDictionary *uploadMeta = [self uploadDictionaryForPost:tempPath key:revisedKey post:postID];
                                                                  completion(uploadMeta, YES, [attributes fileSize], nil);
                                                              } else {
                                                                  completion(nil, YES, 0, videoError);
                                                              }
                                                          } else {
                                                              completion(nil, YES, 0, [NSError errorWithMessage:@"Unknown error, possibly canceled."]);
                                                          }
                                                      }];
                                                  }];
    }
}


/**
 Updates the classe's SDAVAssetExportSession for use. We have a single export session
 as trancodes happen one at a time, and because uploads also occur concurrently we may need
 to cancel the transcode in progress if the upload fails, in which we would need to be 
 able to access the transcoder at any time.

 @param asset AVAsset to initialize with
 @param phasset PHAsset to initialize with
 @param videoTrack AVAssetTrack corresponding to the asset
 @param postID Post ID associated with the export session
 @return New initialized SDAVAssetExportSession
 */
- (void)updateEncoderWithAVAsset:(AVAsset *)asset phasset:(PHAsset *)phasset videoTrack:(AVAssetTrack *)videoTrack postID:(NSString *)postID {
    self.exportSession = [SDAVAssetExportSession.alloc initWithAsset:asset];
    self.exportSession.outputFileType = AVFileTypeMPEG4;
    self.exportSession.postID = postID;
    self.exportSession.delegate = self;
    float targetBitRate = [videoTrack estimatedDataRate] * .80; //Reduce bitrate by 80%
    float targetFrameRate = [videoTrack nominalFrameRate];
    
    self.exportSession.videoSettings = @{
                              AVVideoCodecKey : AVVideoCodecH264,
                              AVVideoWidthKey : [NSNumber numberWithInteger:phasset.pixelWidth],
                              AVVideoHeightKey : [NSNumber numberWithInteger:phasset.pixelHeight],
                              AVVideoCompressionPropertiesKey: @
                                  {
                                  AVVideoAverageBitRateKey: [NSNumber numberWithFloat:targetBitRate],
                                  AVVideoMaxKeyFrameIntervalKey: [NSNumber numberWithFloat:targetFrameRate]
                                  }
                              };
    self.exportSession.audioSettings = @{
                              AVFormatIDKey : @(kAudioFormatMPEG4AAC),
                              AVNumberOfChannelsKey : @2,
                              AVSampleRateKey : @44100,
                              AVEncoderBitRateKey : @64000,
                              };
    
}


#pragma mark - Upload Events

- (void)startNewUploadWithPosts:(NSArray *)posts galleryID:(NSString *)galleryID {
    __weak typeof(self) weakSelf = self;
    __block NSInteger currentIndex = 0;

    //Clear state before we begin
    [self resetState];
    
    //Loop through and create cached uploads
    //We do this before in order to not have to wait for transcoding to finish to have cached upload objects
    for (NSInteger i = 0; i < [posts count]; i++) {
        NSDictionary *post = posts[i];

        //Check if the upload is already in memory as this can be populated before hand if the upload
        if([self.managedObjects objectForKey:post[postID]] == nil) {
            [self createUploadWithAsset:post[@"asset"] key:post[@"key"] post:post[postID] galleryID:galleryID];
        }
        
        //Count the number of videos for the transcoding progress
        numberOfVideos = numberOfVideos + (((PHAsset *)post[@"asset"]).mediaType == PHAssetMediaTypeVideo ? 1 : 0);
    }
    
    //Set of number assets in state
    numberOfAssets = (int)[posts count];
    
    __block __weak FRSUploadPostAssetCompletionBlock weakHandleAssetCreation = nil;

    //This is done recursively because we can't have too many videos transcoding at a time, otherwise iOS will scream at us and the transcode will fail
    FRSUploadPostAssetCompletionBlock handleAssetCreation = ^void(NSDictionary *postUploadMeta, BOOL isVideo, NSInteger fileSize, NSError *error) {
        toComplete++;
        
        //No error, and we still have assets
        if(!error) {
            //We have this check in case the state is reset
            //and assets shouldn't continue to be transcoded and uploaded
            if(numberOfAssets == 0) return;
            
            totalFileSize += fileSize;
            if(isVideo) {
                totalVideoFilesSize += fileSize;
            } else {
                totalImageFilesSize += fileSize;
            }
            
            //Update index for next iteration
            currentIndex++;
            
            //Create dictionary to track progress for the post
            NSMutableDictionary *uploadProgress = [NSMutableDictionary dictionaryWithDictionary:@{ totalUploadFileSize : @(fileSize) }];
            [self.uploadProgressDictionary setObject:uploadProgress forKey:postUploadMeta[postID]];
            
            //Commence upload on the returned post
            [self addUploadForPost:postUploadMeta[postID]
                           andPath:postUploadMeta[@"path"]
                            andKey:postUploadMeta[@"key"]
                        completion:^(id responseObject, NSError *error) {
                            if(error) {
                                [weakSelf uploadDidErrorWithError:error];
                            } else if (completed == numberOfAssets) {
                                [weakSelf uploadComplete:galleryID];
                            }
                        }];
            
            //Current index has exceeded posts array
            if(currentIndex >= [posts count]) return;
            
            //Needed for recursive defintion
            FRSUploadPostAssetCompletionBlock strongHandleAssetCreation = weakHandleAssetCreation;
            
            //Recursive call to block to process next post
            [self createAssetForUpload:posts[currentIndex][@"asset"]
                               withKey:posts[currentIndex][@"key"]
                            withPostID:posts[currentIndex][postID]
                            completion:strongHandleAssetCreation];
        } else {
            [self uploadDidErrorWithError:error];
        }
    };
    
    weakHandleAssetCreation = handleAssetCreation;
    
    //Start post processing process
    [self createAssetForUpload:posts[currentIndex][@"asset"]
                       withKey:posts[currentIndex][@"key"]
                    withPostID:posts[currentIndex][postID]
                    completion:handleAssetCreation];
}

/**
 This method should be called when an upload successfully uploads.

 @param galleryID NSString that will be used to segue to the newly created gallery when tapping [view] on the gallery complete UIView
 */
- (void)uploadComplete:(NSString *)galleryID {
    __weak typeof(self) weakSelf = self;
    numberOfAssets = 0;
    [[NSNotificationCenter defaultCenter]
     postNotificationName:FRSUploadNotification
     object:nil
     userInfo:@{ @"type" : @"completion" }];
    [weakSelf trackDebugWithMessage:@"Upload Completed"];
    //Create and present upload compelte toast
    FRSGalleryUploadedToast *toast = [[FRSGalleryUploadedToast alloc] init];
    toast.galleryID = galleryID;
    [toast show];
}

/**
 Retries an upload with the current uploads in state. Before attempting to retry, the required
 assets will be fetched, then a new upload will be started
 */
- (void)retryUpload {
    NSMutableArray *posts = [NSMutableArray new];
    NSString *galleryID = nil;

    //Generate posts from managed objects in coredata
    for (NSString *uploadPost in [self.managedObjects allKeys]) {
        FRSUpload *upload = [self.managedObjects objectForKey:uploadPost];

        if (upload.key && upload.uploadID && upload.resourceURL && [upload.completed boolValue] == FALSE) {
            PHFetchResult *assetArray = [PHAsset fetchAssetsWithLocalIdentifiers:@[ upload.resourceURL ] options:nil];
            
            //Asset no longer available, skip this item
            if([assetArray count] == 0) continue;
            
            [posts addObject:@{
                               postID: upload.uploadID,
                               @"key": upload.key,
                               @"asset": [assetArray firstObject]
                               }];
            
            galleryID = upload.galleryID;
        }
    }
    
    if (posts.count > 0 && galleryID != nil) {
        //Start new uploads once we've retrieved posts and assets
        [self startNewUploadWithPosts:posts galleryID:galleryID];
    } else {
        [self cancelUploadWithForce:YES];
    }
}


- (void)checkInternet {
    //Check if we have internet
    if([[AFNetworkReachabilityManager sharedManager] isReachable] == FALSE){
        return [self uploadDidErrorWithError:[NSError errorWithMessage:@"Unable to secure an internet connection! Please try again once you've connected to WiFi or have a celluar connection."]];
    }
}

/**
 Cancels upload in progress

 @param withForce BOOL value passed if the cancel should clear all of the core data uploads as well to do a full erase
 */
- (void)cancelUploadWithForce:(BOOL)withForce {
    [self resetState];
    [self clearCachedUploads];
    [self.transferManager cancelAll];
    [self.exportSession cancelExport];
    
    if(withForce == YES) {
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"FRSUpload"];
        NSBatchDeleteRequest *delete = [[NSBatchDeleteRequest alloc] initWithFetchRequest:request];
        NSError *deleteError;
        //Delete all FRSUploads
        [self.context executeRequest:delete error:&deleteError];
    }
}

/**
 Utiltiy to create the dictionary representing the asset being uploaded.

 @param path Path in local filesystem for the asset
 @param key AWS Key for the post
 @param post ID of the post
 @return NSDictionary representing the post's asset
 */
- (NSDictionary *)uploadDictionaryForPost:(NSString *)path key:(NSString *)key post:(NSString *)post {
    return @{
             @"path": path,
             @"key": key,
             postID: post
             };
}

/**
 Starts the AWS upload for the passed post. 
 If completed, will set the managed object to complete and return on completion block.

 @param postID ID of the post being uploaded
 @param path File Path string in local system
 @param key AWS Key for the media file
 @param completion Completion block returning success or error upload
 */
- (void)addUploadForPost:(NSString *)postID andPath:(NSString *)path andKey:(NSString *)key completion:(FRSAPIDefaultCompletionBlock)completion {
    //Speed tracking
    __block double lastUploadSpeed;
    __block NSDate *lastDate = [NSDate date];
    __weak typeof(self) weakSelf = self;
    
    //Configure AWS upload object
    AWSS3TransferManagerUploadRequest *upload = [AWSS3TransferManagerUploadRequest new];
    upload.contentType = [path containsString:@".jpeg"] ? @"image/jpeg" :  @"video/mp4";
    upload.body = [NSURL fileURLWithPath:path];
    upload.key = key;
    upload.metadata = @{ @"post_id" : postID };
    upload.bucket = [EndpointManager sharedInstance].currentEndpoint.amazonS3Bucket;
    
    //Progress handler
    upload.uploadProgress = ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
        //Send progress to be notified
        [self updateUploadProgress:bytesSent forPost:postID];

        //Get time interval since lastDate (set at the bottom of this method)
        NSTimeInterval secondsSinceLastUpdate = [[NSDate date] timeIntervalSinceDate:lastDate];
        //Calculate speed at current runtime
        float currentUploadSpeed = (bytesSent / 1024.0) / secondsSinceLastUpdate; //kBps
        
        if (lastUploadSpeed > 0) {
            uploadSpeed = (currentUploadSpeed + lastUploadSpeed) / 2;
            lastUploadSpeed = uploadSpeed;
        } else {
            uploadSpeed = currentUploadSpeed;
        }
        
        lastDate = [NSDate date];
    };
    
    //This actually starts the upload and takes a completion block when the upload is done
    [[self.transferManager upload:upload] continueWithExecutor:[AWSExecutor mainThreadExecutor] withBlock:^id _Nullable(AWSTask * _Nonnull task) {
        if (task.error) {
            completion(nil, task.error);
        } else if (task.result) {
            [weakSelf trackDebugWithMessage:[NSString stringWithFormat:@"%@ completed", postID]];
            completed++;
            FRSUpload *upload = [weakSelf.managedObjects objectForKey:postID];
            
            //Handle object in cache if it exists
            if (upload) {
                [weakSelf.context performBlock:^{
                    upload.completed = @(TRUE);
                    [weakSelf.context save:nil];
                    completion(nil, nil);
                    //Remove after completing
                    [weakSelf.managedObjects removeObjectForKey:postID];
                }];
            } else {
                completion(nil, nil);
            }
            
        }
        
        return nil;
    }];
}


/**
 Creates FRSUpload CoreData object and saves to context, and also saves to 
 manager's state to keep track of all managed objects currently being uploaded.

 @param asset PHAsset assocaited with upload
 @param key AWS File key assocaited with upload
 @param post Post ID associated with upload
 @param galleryID NSString that will be used to segue to the newly created gallery when tapping [view] on the gallery complete UIView
 */
- (void)createUploadWithAsset:(PHAsset *)asset key:(NSString *)key post:(NSString *)post galleryID:(NSString *)galleryID {
    if (!self.managedObjects) {
        self.managedObjects = [[NSMutableDictionary alloc] init];
    }
    
    FRSUpload *upload = [FRSUpload MR_createEntityInContext:self.context];
    upload.resourceURL = asset.localIdentifier;
    upload.key = key;
    upload.uploadID = post;
    upload.completed = @(FALSE);
    upload.creationDate = [NSDate date];
    upload.galleryID = galleryID;
    
    [self.context performBlock:^{
        [self.context save:Nil];
    }];
    
    //After saving to context, save to class's state as well for later use
    [self.managedObjects setObject:upload forKey:post];
}

/**
 Broadcasts failure upload notification to the app and also formally cancels the upload process.
 When this is called, the cancel is called without a force so that it can be retried at a later time. Last, this
 method also checks if there's no upload currently in progress to avoid re-broadcasting the failure.

 @param error NSError representing the error, should pass a localizedDescription to be presented to the user
 */
- (void)uploadDidErrorWithError:(NSError *)error {
    //No upload in progress, added this check due to this being called in a callback cycle
    if(toComplete == 0) return;
    
    //Do this before cancelling so we can use the active state variables
    NSMutableDictionary *uploadErrorSummary = [@{ @"error_message" : error.localizedDescription } mutableCopy];
    
    if (uploadSpeed > 0) {
        [uploadErrorSummary setObject:@(uploadSpeed) forKey:@"upload_speed_kBps"];
    }
    
    //Convert from bytes to megabytes
    [uploadErrorSummary setObject:@{ @"video" : [NSString stringWithFormat:@"%lluMB", totalVideoFilesSize / 1024 / 1024],
                                     @"photo" : [NSString stringWithFormat:@"%lluMB", totalImageFilesSize / 1024 / 1024] }
                           forKey:@"files"];
    
    //Cancel the upload
    [self cancelUploadWithForce:NO];
    
    if(!error || !error.localizedDescription){
        error = [NSError errorWithMessage:@"Please contact support@fresconews.com for assistance, or use our in-app chat to get in contact with us."];
    }
    
    [FRSTracker track:uploadError parameters:uploadErrorSummary];
    [[NSNotificationCenter defaultCenter] postNotificationName:FRSUploadNotification object:Nil userInfo:@{ @"type" : @"failure", @"error": error }];
}

#pragma mark - Tracking

/**
 Tracks a debug message, and the upload speed if it's currently set in state
 
 @param message Message to pass along to the mobile event
 */
- (void)trackDebugWithMessage:(NSString *)message {
    NSMutableDictionary *uploadErrorSummary = [@{ @"debug_message" : message } mutableCopy];
    
    if (uploadSpeed > 0) {
        [uploadErrorSummary setObject:@(uploadSpeed) forKey:@"upload_speed_kBps"];
    }
    
    [FRSTracker track:uploadDebug parameters:uploadErrorSummary];
}

@end
