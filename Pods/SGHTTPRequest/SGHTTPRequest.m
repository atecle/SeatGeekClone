//
//  SGHTTPRequest.m
//  SeatGeek
//
//  Created by James Van-As on 31/07/13.
//  Copyright (c) 2013 SeatGeek. All rights reserved.
//

#import "SGHTTPRequest.h"
#import "AFNetworking.h"
#import "SGActivityIndicator.h"
#import "SGHTTPRequestDebug.h"
#import "NSString+SGHTTPRequest.h"

#define ETAG_CACHE_PATH     @"SGHTTPRequestETagCache"
#define SGETag              @"eTag"
#define SGResponseDataPath  @"dataPath"
#define SGExpiryDate        @"expires"
#define SGDontPurge         @"dontPurge"

NSMutableDictionary *gReachabilityManagers;
SGActivityIndicator *gNetworkIndicator;
NSMutableDictionary *gRetryQueues;
SGHTTPLogging gLogging = SGHTTPLogNothing;

@interface SGHTTPRequest ()
@property (nonatomic, weak) AFHTTPRequestOperation *operation;
@property (nonatomic, strong) NSData *responseData;
@property (nonatomic, strong) NSString *responseString;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, assign) BOOL cancelled;

@property (nonatomic, strong) NSData *multiPartData;
@property (nonatomic, strong) NSString *multiPartName;
@property (nonatomic, strong) NSString *multiPartFilename;
@property (nonatomic, strong) NSString *multiPartMimeType;
@end

void doOnMain(void(^block)()) {
    if (NSThread.isMainThread) { // we're on the main thread. yay
        block();
    } else { // we're off the main thread. Bump off.
        dispatch_async(dispatch_get_main_queue(), ^{
            block();
        });
    }
}

@implementation SGHTTPRequest

#pragma mark - Public

+ (SGHTTPRequest *)requestWithURL:(NSURL *)url {
    return [[self alloc] initWithURL:url method:SGHTTPRequestMethodGet];
}

+ (instancetype)postRequestWithURL:(NSURL *)url {
    return [[self alloc] initWithURL:url method:SGHTTPRequestMethodPost];
}

+ (instancetype)jsonPostRequestWithURL:(NSURL *)url {
    SGHTTPRequest *request = [[self alloc] initWithURL:url method:SGHTTPRequestMethodPost];
    request.requestFormat = SGHTTPDataTypeJSON;
    return request;
}

+ (instancetype)deleteRequestWithURL:(NSURL *)url {
    return [[self alloc] initWithURL:url method:SGHTTPRequestMethodDelete];
}

+ (instancetype)putRequestWithURL:(NSURL *)url {
    return [[self alloc] initWithURL:url method:SGHTTPRequestMethodPut];
}

+ (instancetype)patchRequestWithURL:(NSURL *)url {
    return [[self alloc] initWithURL:url method:SGHTTPRequestMethodPatch];
}

+ (instancetype)multiPartPostRequestWithURL:(NSURL *)url
                                       data:(NSData *)data
                                       name:(NSString *)name
                                   filename:(NSString *)filename
                                   mimeType:(NSString *)mimeType {
    SGHTTPRequest *request = [[self alloc] initWithURL:url method:SGHTTPRequestMethodMultipartPost];
    request.multiPartData = data;
    request.multiPartName = name;
    request.multiPartFilename = filename;
    request.multiPartMimeType = mimeType;
    return request;
}

+ (instancetype)xmlPostRequestWithURL:(NSURL *)url {
    SGHTTPRequest *request =  [[self alloc] initWithURL:url method:SGHTTPRequestMethodPut];
    request.requestFormat = SGHTTPDataTypeXML;
    return request;
}

+ (instancetype)xmlRequestWithURL:(NSURL *)url {
    SGHTTPRequest *request =  [[self alloc] initWithURL:url method:SGHTTPRequestMethodGet];
    request.responseFormat = SGHTTPDataTypeXML;
    return request;
}

- (void)start {
    if (!self.url) {
        return;
    }

    NSString *baseURL = [SGHTTPRequest baseURLFrom:self.url];

    if (self.logRequests) {
        NSLog(@"%@", self.url);
    }

    AFHTTPRequestOperationManager *manager = [self.class managerForBaseURL:baseURL
          requestType:self.requestFormat responseType:self.responseFormat];

    if (!manager) {
        [self failedWithError:nil operation:nil retryURL:baseURL];
        return;
    }

    for (NSString *field in self.requestHeaders) {
        [manager.requestSerializer setValue:self.requestHeaders[field] forHTTPHeaderField:field];
    }

    [self removeCacheFilesIfExpired];

    if (self.eTag.length && ![self.eTag isEqualToString:@"Missing"]) {
        [manager.requestSerializer setValue:self.eTag forHTTPHeaderField:@"If-None-Match"];

        // The iOS URL loading system by default does local caching. If it receives a 304 back,
        // it brings in the most previously cached body for that URL, updates our status code to 200,
        // but seems to keep the other headers from the 304. Unfortunately this means that we get our
        // current eTag back in the headers with the most recent 200 response body, if that previous
        // response lacked an eTag and was not related. So we need to turn off the iOS URL loading system
        // local caching when we are doing our own eTag caching. That way our eTag caching code in -success:
        // can get our 304 responses back undoctored. Local caching will be taken care of by our code.
        manager.requestSerializer.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    } else {
        [manager.requestSerializer setValue:nil forHTTPHeaderField:@"If-None-Match"];
        manager.requestSerializer.cachePolicy = NSURLRequestUseProtocolCachePolicy;
    }

    id success = ^(AFHTTPRequestOperation *operation, id responseObject) {
        [self success:operation];
    };
    id failure = ^(AFHTTPRequestOperation *operation, NSError *error) {
        if (operation.response.statusCode == 304) { // not modified
            [self success:operation];
        } else {
            [self failedWithError:error operation:operation retryURL:baseURL];
        }
    };

    switch (self.method) {
        case SGHTTPRequestMethodGet:
            _operation = [manager GET:self.url.absoluteString parameters:self.parameters
                  success:success failure:failure];
            break;
        case SGHTTPRequestMethodPost:
            _operation = [manager POST:self.url.absoluteString parameters:self.parameters
                  success:success failure:failure];
            break;
        case SGHTTPRequestMethodMultipartPost:
            {
            __weak SGHTTPRequest *me = self;
            _operation = [manager POST:self.url.absoluteString parameters:self.parameters
             constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
                 [formData appendPartWithFileData:me.multiPartData
                                             name:me.multiPartName
                                         fileName:me.multiPartFilename
                                         mimeType:me.multiPartMimeType];
                  }
                  success:success failure:failure];
             }
            break;
        case SGHTTPRequestMethodDelete:
            _operation = [manager DELETE:self.url.absoluteString parameters:self.parameters
                  success:success failure:failure];
            break;
        case SGHTTPRequestMethodPut:
            _operation = [manager PUT:self.url.absoluteString parameters:self.parameters
                  success:success failure:failure];
            break;
        case SGHTTPRequestMethodPatch:
            _operation = [manager PATCH:self.url.absoluteString parameters:self.parameters
                  success:success failure:failure];
            break;
    }

    __weak typeof(self) me = self;
    if (self.onUploadProgress) {
        [_operation setUploadProgressBlock:^(NSUInteger bytesWritten, long long totalBytesWritten, long long totalBytesExpectedToWrite) {
            me.onUploadProgress(totalBytesWritten, totalBytesExpectedToWrite);
        }];
    }
    if (self.onDownloadProgress) {
        [_operation setDownloadProgressBlock:^(NSUInteger bytesRead, long long totalBytesRead, long long totalBytesExpectedToRead) {
            me.onDownloadProgress(totalBytesRead, totalBytesExpectedToRead);
        }];
    }

    if (self.showActivityIndicator) {
        [SGHTTPRequest.networkIndicator incrementActivityCount];
    }
}

- (void)cancel {
    _cancelled = YES;

    doOnMain(^{
        if (self.onNetworkReachable) {
           [SGHTTPRequest removeRetryCompletion:self.onNetworkReachable forHost:self.url.host];
            self.onNetworkReachable = nil;
        }
        [_operation cancel]; // will call the failure block
    });
}

#pragma mark - Private

- (id)initWithURL:(NSURL *)url method:(SGHTTPRequestMethod)method {
    self = [super init];

    self.showActivityIndicator = YES;
    self.allowCacheToDisk = SGHTTPRequest.allowCacheToDisk;
    self.timeToExpire = SGHTTPRequest.defaultCacheMaxAge;
    self.allowNSNull = SGHTTPRequest.allowNSNull;
    self.method = method;
    self.url = url;

    // by default, use the JSON response serialiser only for SeatGeek API requests
    if ([url.host isEqualToString:@"api.seatgeek.com"]) {
        self.responseFormat = SGHTTPDataTypeJSON;
    } else {
        self.responseFormat = SGHTTPDataTypeHTTP;
    }
    self.logging = SGHTTPRequest.logging;

    return self;
}

+ (AFHTTPRequestOperationManager *)managerForBaseURL:(NSString *)baseURL
                                         requestType:(SGHTTPDataType)requestType
                                        responseType:(SGHTTPDataType)responseType {
    static dispatch_once_t token = 0;
    dispatch_once(&token, ^{
        gReachabilityManagers = NSMutableDictionary.new;
    });

    NSURL *url = [NSURL URLWithString:baseURL];
    AFHTTPRequestOperationManager *manager = [[AFHTTPRequestOperationManager alloc] initWithBaseURL:url];
    if (!manager) {
        return nil;
    }

    //responses default to JSON
    if (responseType == SGHTTPDataTypeHTTP) {
        manager.responseSerializer = AFHTTPResponseSerializer.serializer;
    } else if (responseType == SGHTTPDataTypeXML) {
        manager.responseSerializer = AFXMLParserResponseSerializer.serializer;
    }

    if (requestType == SGHTTPDataTypeXML) {
        AFHTTPRequestSerializer *requestSerializer = manager.requestSerializer;
        [requestSerializer setValue:@"application/xml" forHTTPHeaderField:@"Content-Type"];
    } else if (requestType == SGHTTPDataTypeJSON) {
        manager.requestSerializer = AFJSONRequestSerializer.serializer;
    }

    @synchronized(self) {
        if (url.host.length && !gReachabilityManagers[url.host]) {
            AFNetworkReachabilityManager *reacher = [AFNetworkReachabilityManager managerForDomain:url
                  .host];
            if (reacher) {
                gReachabilityManagers[url.host] = reacher;

                reacher.reachabilityStatusChangeBlock = ^(AFNetworkReachabilityStatus status) {
                    switch (status) {
                        case AFNetworkReachabilityStatusReachableViaWWAN:
                        case AFNetworkReachabilityStatusReachableViaWiFi:
                            [self.class runRetryQueueFor:url.host];
                            break;
                        case AFNetworkReachabilityStatusNotReachable:
                        default:
                            break;
                    }
                };
                [reacher startMonitoring];
            }
        }
    }

    return manager;
}

#pragma mark - Success / Fail Handlers

- (void)success:(AFHTTPRequestOperation *)operation {
    if (self.showActivityIndicator) {
        [SGHTTPRequest.networkIndicator decrementActivityCount];
    }

    self.responseData = operation.responseData;
    self.responseString = operation.responseString;
    self.statusCode = operation.response.statusCode;
    if (!self.cancelled) {
        if (self.logResponses) {
            [self logResponse:operation error:nil];
        }
        NSDictionary *reponseHeader = operation.response.allHeaderFields;
        NSString *eTag = reponseHeader[@"Etag"];
        NSString *cacheControlPolicy = reponseHeader[@"Cache-Control"];
        if ([cacheControlPolicy containsSubstring:@"no-cache"] ||
            [cacheControlPolicy containsSubstring:@"no-store"] ||
            [cacheControlPolicy containsSubstring:@"private"]) {
            self.allowCacheToDisk = NO;
        }
        NSDate *expiryDate = self.timeToExpire ? [NSDate dateWithTimeIntervalSinceNow:self.timeToExpire] : nil;
        if ([cacheControlPolicy containsSubstring:@"max-age"]) {
            NSError *error;
            NSRegularExpression *regex = [NSRegularExpression
                                          regularExpressionWithPattern:@"(max-age=)(\\d+)"
                                          options:NSRegularExpressionCaseInsensitive
                                          error:&error];
            NSTextCheckingResult *match = [regex firstMatchInString:cacheControlPolicy
                                                            options:0
                                                              range:NSMakeRange(0, cacheControlPolicy.length)];
            if (match) {
                NSString *maxAge = [cacheControlPolicy substringWithRange:match.range];
                NSArray *maxAgeComponents = [maxAge componentsSeparatedByString:@"="];
                if (maxAgeComponents.count == 2) {
                    NSString *maxAgeValueString = maxAgeComponents[1];
                    NSTimeInterval expiryInterval = maxAgeValueString.doubleValue;
                    expiryDate = [NSDate dateWithTimeIntervalSinceNow:expiryInterval];
                }
            }
        }
        if (eTag.length) {
            if (self.statusCode == 304) {
                if (!self.responseData.length && self.allowCacheToDisk) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        // If we got a 304 and no respose from iOS level caching, check the disk.
                        NSData *cachedData = [self cachedDataForETag:eTag newExpiryDate:expiryDate];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (cachedData) {
                                self.responseData = cachedData;
                                self.eTag = eTag;
                                if (self.onSuccess) {
                                    self.onSuccess(self);
                                }
                            } else {
                                self.eTag = nil;
                                [self removeCacheFiles];
                                [self start];   //cached data is missing. try again without eTag
                            }
                        });
                    });
                    return;
                }
            } else if (self.allowCacheToDisk) {
                // response has changed.  Let's cache the new version.
                [self cacheDataForETag:eTag expiryDate:expiryDate];
            }
        } else if (self.eTag.length && self.statusCode == 200) {
            // Sometimes servers can ommit an ETag, even if the contents have changed.
            // (We've experienced this with gzipped payloads stripping ETag information.)
            // In this case, *if* we received a 200 response and received no ETag, we should
            // overwrite the cached copy with the fresh data.
            self.eTag = @"Missing";
            [self cacheDataForETag:self.eTag expiryDate:expiryDate];
        }
        if (!self.allowCacheToDisk) {
            [self removeCacheFiles];
        }
        self.eTag = eTag;
        if (self.onSuccess) {
            self.onSuccess(self);
        }
    }
}

- (void)failedWithError:(NSError *)error operation:(AFHTTPRequestOperation *)operation
      retryURL:(NSString *)retryURL {
    if (self.showActivityIndicator) {
        [SGHTTPRequest.networkIndicator decrementActivityCount];
    }

    if (self.cancelled) {
        return;
    }

    self.error = error;
    self.responseData = operation.responseData;
    self.responseString = operation.responseString;
    self.statusCode = operation.response.statusCode;

    if (self.logErrors) {
        [self logResponse:operation error:error];
    }

    if (self.onFailure) {
        self.onFailure(self);
    }
    self.error = nil;

    if (self.onNetworkReachable && retryURL) {
        NSURL *url = [NSURL URLWithString:retryURL];
        if (url.host) {
            [[SGHTTPRequest retryQueueFor:url.host] addObject:self.onNetworkReachable];
        }
    }
}

#pragma mark - Getters

- (id)responseJSON {
    return [SGJSONSerialization JSONObjectWithData:self.responseData allowNSNull:self.allowNSNull logURL:self.url.absoluteString];
}

+ (NSMutableArray *)retryQueueFor:(NSString *)baseURL {
    if (!baseURL) {
        return nil;
    }

    static dispatch_once_t token = 0;
    dispatch_once(&token, ^{
        gRetryQueues = NSMutableDictionary.new;
    });

    NSMutableArray *queue = gRetryQueues[baseURL];
    if (!queue) {
        queue = NSMutableArray.new;
        gRetryQueues[baseURL] = queue;
    }

    return queue;
}

+ (void)runRetryQueueFor:(NSString *)host {
    NSMutableArray *retryQueue = [self retryQueueFor:host];

    NSArray *localCopy = retryQueue.copy;
    [retryQueue removeAllObjects];

    for (SGHTTPRetryBlock retryBlock in localCopy) {
        retryBlock();
    }
}

+ (void)removeRetryCompletion:(SGHTTPRetryBlock)onNetworkReachable forHost:(NSString *)host {
    doOnMain(^{
        if ([[SGHTTPRequest retryQueueFor:host] containsObject:onNetworkReachable]) {
            [[SGHTTPRequest retryQueueFor:host] removeObject:onNetworkReachable];
    }});
}

+ (NSString *)baseURLFrom:(NSURL *)url {
    return [NSString stringWithFormat:@"%@://%@/", url.scheme, url.host];
}

+ (SGActivityIndicator *)networkIndicator {
    if (gNetworkIndicator) {
        return gNetworkIndicator;
    }
    gNetworkIndicator = [[SGActivityIndicator alloc] init];
    return gNetworkIndicator;
}

#pragma mark - ETag Caching

- (NSString *)eTag {
    if (_allowCacheToDisk && !_eTag) {
        NSString *indexPath = self.pathForCachedIndex;
        NSDictionary *index = [NSDictionary dictionaryWithContentsOfFile:indexPath];
        if (index) {
            // sanity check that the data file exists.
            NSString *fullDataPath = [SGHTTPRequest fullDataPathFromIndex:index];
            if ([NSFileManager.defaultManager fileExistsAtPath:fullDataPath]) {
                _eTag = index[SGETag];
            } else {
    #ifdef DEBUG
                NSLog(@"SGHTTPRequest could not find cached data for Etag: %@", index[SGETag]);
    #endif
            }
        }
    }
    return _eTag;
}

- (NSData *)cachedResponseData {
    if (!self.allowCacheToDisk) {
        return nil;
    }
    return [self cachedDataForETag:self.eTag];
}

- (id)cachedResponseJSON {
    if (!self.allowCacheToDisk) {
        return nil;
    }
    NSData *cachedData = self.cachedResponseData;
    if (!cachedData) {
        return nil;
    }
    return [SGJSONSerialization JSONObjectWithData:cachedData allowNSNull:self.allowNSNull logURL:self.url.absoluteString];
}

- (NSData *)cachedDataForETag:(NSString *)eTag {
    return [self cachedDataForETag:eTag newExpiryDate:nil updateExpiry:NO];
}

- (NSData *)cachedDataForETag:(NSString *)eTag newExpiryDate:(NSDate *)newExpiryDate {
    return [self cachedDataForETag:eTag newExpiryDate:newExpiryDate updateExpiry:YES];
}

- (NSData *)cachedDataForETag:(NSString *)eTag newExpiryDate:(NSDate *)newExpiryDate updateExpiry:(BOOL)updateExpiry {
    if (!self.url) {
        return nil;
    }
    NSString *indexPath = self.pathForCachedIndex;
    NSDictionary *index = [NSDictionary dictionaryWithContentsOfFile:indexPath];
    if (![index[SGETag] isEqualToString:eTag] || !index[SGResponseDataPath]) {
        return nil;
    }

    if (updateExpiry) {
        if ((index[SGExpiryDate] && !newExpiryDate) ||
            (newExpiryDate && !index[SGExpiryDate]) ||
            (newExpiryDate && index[SGExpiryDate] && ![newExpiryDate isEqualToDate:index[SGExpiryDate]])) {
            NSMutableDictionary *newIndex = index.mutableCopy;
            if (newExpiryDate) {
                newIndex[SGExpiryDate] = newExpiryDate;
            } else {
                [newIndex removeObjectForKey:SGExpiryDate];
            }
            [newIndex writeToFile:indexPath atomically:YES];
        }
    }

    NSString *fullDataPath = [SGHTTPRequest fullDataPathFromIndex:index];
    if (![NSFileManager.defaultManager fileExistsAtPath:fullDataPath]) {
      return nil;
    }

    // touch the date modified timestamp
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:NSDate.date}
                       ofItemAtPath:fullDataPath
                         error:nil];
        return [NSData dataWithContentsOfFile:fullDataPath];
}

- (void)cacheDataForETag:(NSString *)eTag expiryDate:(NSDate *)expiryDate {
    SGHTTPAssert([NSThread isMainThread], @"This must be run from the main thread");
    if (!self.url || !eTag.length) {
        return;
    }

    NSData *data = self.responseData;
    if (!data.length) {
        return;
    }

    if (SGHTTPRequest.maxDiskCacheSize) {
        if (data.length  > SGHTTPRequest.maxDiskCacheSizeBytes) {
            return;
        }
        [SGHTTPRequest purgeOldestCacheFilesLeaving:MAX(SGHTTPRequest.maxDiskCacheSizeBytes / 4, data.length * 2)];
    }

    NSString *indexPath = self.pathForCachedIndex;
    NSString *fullDataPath = nil;

    NSDictionary *index = [NSDictionary dictionaryWithContentsOfFile:indexPath];
    if (index[SGResponseDataPath]) {
        fullDataPath = [SGHTTPRequest fullDataPathFromIndex:index];
    }
    // delete the index file before the data file.  Noone should reference the data file without the index file.
    if ([NSFileManager.defaultManager fileExistsAtPath:indexPath]) {
        [NSFileManager.defaultManager removeItemAtPath:indexPath error:nil];
    }
    if (fullDataPath && [NSFileManager.defaultManager fileExistsAtPath:fullDataPath]) {
        [NSFileManager.defaultManager removeItemAtPath:fullDataPath error:nil];
    }

    NSString *dataFileName = self.fileNameForCacheIndex;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // We write the index file last, because noone will try to access the data file unless the
        // index file exists.  The index file gets written last atomically.
        NSCharacterSet *illegalFileNameChars = [NSCharacterSet characterSetWithCharactersInString:@":/"];
        NSString *fileSafeETag = [[eTag componentsSeparatedByCharactersInSet:illegalFileNameChars] componentsJoinedByString:@"-"];
        if (!fileSafeETag.length) {
            return ;
        }
        // data file name format is [indexFileName].[ETagHash] so we can fast map back to the index file
        NSString *shortDataPath = [NSString stringWithFormat:@"Data/%@.%@",
                                       dataFileName,
                                       fileSafeETag];
        NSString *fullDataPath = [NSString stringWithFormat:@"%@/%@", SGHTTPRequest.cacheFolder, shortDataPath];
        if (![data writeToFile:fullDataPath atomically:YES]) {
            return;
        }

        NSMutableDictionary *newIndex = @{SGETag : eTag,
                                          SGResponseDataPath : shortDataPath}.mutableCopy;
        if (expiryDate) {
            newIndex[SGExpiryDate] = expiryDate;
        }
        [newIndex writeToFile:indexPath atomically:YES];
    });
}

+ (NSString *)fullDataPathFromIndex:(NSDictionary *)index {
    if (!index) {
        return nil;
    }
    NSString *fullDataPath = [NSString stringWithFormat:@"%@/%@", SGHTTPRequest.cacheFolder, index[SGResponseDataPath]];
    return fullDataPath;
}

+ (void)removeCacheFilesForIndexPath:(NSString *)indexPath index:(NSDictionary *)index {
    // delete the index file before the data to maintain data link integrity
    if ([NSFileManager.defaultManager fileExistsAtPath:indexPath]) {
        [NSFileManager.defaultManager removeItemAtPath:indexPath error:nil];
    }
    if (index[SGResponseDataPath]) {
        NSString *fullDataPath = [self fullDataPathFromIndex:index];
        if ([NSFileManager.defaultManager fileExistsAtPath:fullDataPath]) {
            [NSFileManager.defaultManager removeItemAtPath:fullDataPath error:nil];
        }
    }
}

+ (void)removeCacheFilesForIndexPath:(NSString *)indexPath {
    NSDictionary *index = [NSDictionary dictionaryWithContentsOfFile:indexPath];
    [self removeCacheFilesForIndexPath:indexPath index:index];
}

+ (BOOL)removeCacheFilesIfExpiredForIndexPath:(NSString *)indexPath {
    NSDictionary *index = [NSDictionary dictionaryWithContentsOfFile:indexPath];

    BOOL dataFileMissing = NO;
    if (index[SGResponseDataPath]) {
        NSString *fullDataPath = [self fullDataPathFromIndex:index];
        if (![NSFileManager.defaultManager fileExistsAtPath:fullDataPath]) {
            dataFileMissing = YES;
        }
    }

    if (dataFileMissing ||
        (index[SGExpiryDate] && [(NSDate *)index[SGExpiryDate] compare:NSDate.date] == NSOrderedAscending)) {
        [self removeCacheFilesForIndexPath:indexPath index:index];
        return YES;
    }
    return NO;
}

- (void)removeCacheFiles {
    [SGHTTPRequest removeCacheFilesForIndexPath:self.pathForCachedIndex];
}

- (void)removeCacheFilesIfExpired {
    if ([SGHTTPRequest removeCacheFilesIfExpiredForIndexPath:self.pathForCachedIndex]) {
        self.eTag = nil;
    }
}

+ (NSURL *)cacheIndexPathFromDataFile:(NSURL *)dataFileURL searchIndexFiles:(NSMutableArray **)searchIndexFiles {
    NSString *fileNameForCacheIndex = dataFileURL.path.lastPathComponent;

    NSArray *components = [fileNameForCacheIndex componentsSeparatedByString:@"."];
    // data file name format is [indexFileName].[ETagHash]
    fileNameForCacheIndex = components.firstObject;
    NSString *indexPath = [NSString stringWithFormat:@"%@/%@", SGHTTPRequest.cacheFolder, fileNameForCacheIndex];
    if ([NSFileManager.defaultManager fileExistsAtPath:indexPath]) {
        return [NSURL URLWithString:indexPath];
    }

    // below is a brute force approach for legacy purposes
    // where the data filename might not map back to the index filename.
    // Grabbing the contents of the directory is only done once and only if necessary
    // because it's slow.

    if (!*searchIndexFiles) {
        // sort the index files by date modified too for fast search.  Should be almost identical to the data order
        NSString *indexFolder = self.cacheFolder;
        NSArray *indexFilesArray = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL URLWithString:indexFolder]
                                                                 includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                                    options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                      error:nil];
        indexFilesArray = [indexFilesArray sortedArrayUsingComparator:^(NSURL *file1, NSURL *file2) {
            NSDate *file1Date;
            [file1 getResourceValue:&file1Date forKey:NSURLContentModificationDateKey error:nil];
            NSDate *file2Date;
            [file2 getResourceValue:&file2Date forKey:NSURLContentModificationDateKey error:nil];
            return [file1Date compare:file2Date];
        }];
        *searchIndexFiles = indexFilesArray.mutableCopy;
    }
    for (NSURL *indexFileURL in *searchIndexFiles) {
        NSDictionary *index = [NSDictionary dictionaryWithContentsOfURL:indexFileURL];
        if (index[SGResponseDataPath]) {
            NSString *fullDataPath = [self fullDataPathFromIndex:index];
            NSURL *fullDataURL = [NSURL fileURLWithPath:fullDataPath];
            if ([fullDataURL isEqual:dataFileURL.URLByResolvingSymlinksInPath]) {
                return indexFileURL;
            }
        }
    }
#ifdef DEBUG
    NSLog(@"Couldn't find index file for cached SGHTTPRequest data file.");
#endif
    return nil;
}

- (NSString *)fileNameForCacheIndex {
    NSMutableString *filename = self.url.absoluteString.mutableCopy;
    if (self.requestHeaders.count) {
        for (id key in self.requestHeaders) {
            if ([key isKindOfClass:NSString.class] && [key isEqualToString:@"If-None-Match"]) {
                continue;
            }
            [filename appendFormat:@":%@:%@", key, self.requestHeaders[key]];
        }
    }
    if (self.preventPurging) {
        return [SGDontPurge stringByAppendingString:filename.sgHTTPRequestHash];
    } else {
        return filename.sgHTTPRequestHash;
    }
}

- (NSString *)pathForCachedIndex {
    return [NSString stringWithFormat:@"%@/%@", SGHTTPRequest.cacheFolder, self.fileNameForCacheIndex];
}

+ (void)purgeOldestCacheFilesLeaving:(NSInteger)bytesFree {
    SGHTTPAssert([NSThread isMainThread], @"This must be run from the main thread");

    NSString *dataFolder = [self.cacheFolder stringByAppendingString:@"/Data"];
    NSURL *dataFolderURL = [NSURL URLWithString:dataFolder];
    NSArray *dataFilesArray = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:dataFolderURL
                                                              includingPropertiesForKeys:@[NSURLContentModificationDateKey,
                                                                                           NSURLFileSizeKey]
                                                                                 options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                   error:nil];
    NSInteger existingCacheSize = 0;
    for (NSURL *fileURL in dataFilesArray) {
        if ([fileURL.absoluteString.lastPathComponent containsSubstring:SGDontPurge]) {
            continue;
        }
        NSNumber *fileSize;
        [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        existingCacheSize += fileSize.longLongValue;
    }

    if (existingCacheSize + bytesFree < SGHTTPRequest.maxDiskCacheSizeBytes) {
        return;     // we already have enough space thanks.
    }

    dataFilesArray = [dataFilesArray sortedArrayUsingComparator:^(NSURL *file1, NSURL *file2) {
                        NSDate *file1Date;
                        [file1 getResourceValue:&file1Date forKey:NSURLContentModificationDateKey error:nil];
                        NSDate *file2Date;
                        [file2 getResourceValue:&file2Date forKey:NSURLContentModificationDateKey error:nil];
                        return [file1Date compare:file2Date];
                        }];

    NSInteger bytesToDelete = bytesFree - (SGHTTPRequest.maxDiskCacheSizeBytes - existingCacheSize);
    if (bytesToDelete <= 0) {
        return;
    }
    NSInteger bytesDeleted = 0;
    NSMutableArray *filesToDelete = NSMutableArray.new;

    for (NSURL *fileURL in dataFilesArray) {
        if (bytesToDelete <= 0) {
            break;
        }
        if ([fileURL.absoluteString.lastPathComponent containsSubstring:SGDontPurge]) {
            continue;
        }

        NSError *error;

        NSNumber *fileSize;
        [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:&error];
        if (error) {
#ifdef DEBUG
            NSLog(@"Error trying to get fileSize from eTag cache file: %@", error);
#endif
        }
        [filesToDelete addObject:fileURL];
        bytesToDelete -= fileSize.longLongValue;
        bytesDeleted += fileSize.longLongValue;
    }

    if (!filesToDelete.count) {
        return;
    }

#ifdef DEBUG
    if (bytesDeleted) {
        NSLog(@"Flushing %.1fMB from SGHTTPRequest ETag cache", (CGFloat)bytesDeleted / 1024.0 / 1024.0);
    }
#endif


    NSMutableArray *searchIndexFiles = nil;
    for (NSURL *dataFileURL in filesToDelete) {
        // index path filename should match the data filename.  If not we do the brute force approach.
        NSURL *indexPathToDelete = [self cacheIndexPathFromDataFile:dataFileURL searchIndexFiles:&searchIndexFiles];
        if (indexPathToDelete && [NSFileManager.defaultManager fileExistsAtPath:indexPathToDelete.path]) {
            [searchIndexFiles removeObject:indexPathToDelete];
            if ([NSFileManager.defaultManager fileExistsAtPath:indexPathToDelete.path]) {
                [NSFileManager.defaultManager removeItemAtPath:indexPathToDelete.path error:nil];
            }
        } else {
#ifdef DEBUG
            NSLog(@"Could not find index file for old data file in SGHTTPRequest cache.  Removing orphaned data file.");
#endif
        }
        if ([NSFileManager.defaultManager fileExistsAtPath:dataFileURL.path]) {
            [NSFileManager.defaultManager removeItemAtPath:dataFileURL.path error:nil];
        }
    }
}

+ (void)clearCache {
    SGHTTPAssert([NSThread isMainThread], @"This must be run from the main thread");

    NSString *indexFolder = self.cacheFolder;
    NSMutableArray *indexFileNamesArray = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:indexFolder error:nil].mutableCopy;
    NSMutableArray *indexFilesArray = NSMutableArray.new;
    for (NSString *indexFileName in indexFileNamesArray) {
        [indexFilesArray addObject:[indexFolder stringByAppendingPathComponent:indexFileName]];
    }

    for (NSString *filePath in indexFilesArray) {
        if ([NSFileManager.defaultManager fileExistsAtPath:filePath]) {
            [NSFileManager.defaultManager removeItemAtPath:filePath error:nil];
        }
    }

    NSString *dataFolder = [self.cacheFolder stringByAppendingString:@"/Data"];
    NSArray *dataFilesNamesArray = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dataFolder error:nil];
    NSMutableArray *dataFilesArray = NSMutableArray.new;
    for (NSString *dataFileName in dataFilesNamesArray) {
        [dataFilesArray addObject:[dataFolder stringByAppendingPathComponent:dataFileName]];
    }

    for (NSString *filePath in dataFilesArray) {
        if ([NSFileManager.defaultManager fileExistsAtPath:filePath]) {
            [NSFileManager.defaultManager removeItemAtPath:filePath error:nil];
        }
    }
}

+ (void)clearExpiredFiles {
    NSString *cacheFolder = self.cacheFolder;
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:cacheFolder error:nil];

    for (NSString *file in files) {
        if ([file isEqualToString:@"."] || [file isEqualToString:@".."]) {
            continue;
        }
        NSString *indexFile = [cacheFolder stringByAppendingPathComponent:file];
        [self removeCacheFilesIfExpiredForIndexPath:indexFile];
    }
}

+ (NSString *)cacheFolder {
    static NSString *gCacheFolder;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gCacheFolder = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask,
                                                         YES)[0];
        gCacheFolder = [gCacheFolder stringByAppendingFormat:@"/%@", ETAG_CACHE_PATH];
        BOOL isDir;
        NSString *dataPath = [gCacheFolder stringByAppendingString:@"/Data"];
        if (![NSFileManager.defaultManager fileExistsAtPath:dataPath isDirectory:&isDir]) {
            [NSFileManager.defaultManager createDirectoryAtPath:dataPath withIntermediateDirectories:YES
                                                     attributes:nil error:nil];
        }
    });
    return gCacheFolder;
}

static BOOL gAllowCacheToDisk = NO;

+ (void)setAllowCacheToDisk:(BOOL)allowCacheToDisk {
    gAllowCacheToDisk = allowCacheToDisk;
}

+ (BOOL)allowCacheToDisk {
    return gAllowCacheToDisk;
}

static NSUInteger gMaxDiskCacheSize = 20;

+ (void)setMaxDiskCacheSize:(NSUInteger)megaBytes {
    gMaxDiskCacheSize = megaBytes;
}

+ (NSInteger)maxDiskCacheSize {
    return gMaxDiskCacheSize;
}

+ (NSInteger)maxDiskCacheSizeBytes {
    return self.maxDiskCacheSize * 1024 * 1024;
}

static NSUInteger gDefaultCacheMaxAge = 2592000;

- (NSTimeInterval)timeToExpire {
    return _timeToExpire ?: SGHTTPRequest.defaultCacheMaxAge;
}

+ (void)setDefaultCacheMaxAge:(NSTimeInterval)timeToExpire {
    gDefaultCacheMaxAge = timeToExpire;
}

+ (NSTimeInterval)defaultCacheMaxAge {
    return gDefaultCacheMaxAge;
}

+ (void)initialize {
    [self clearExpiredFiles];
}

#pragma mark - NSNull Handling

static BOOL gAllowNSNulls = YES;

+ (void)setAllowNSNull:(BOOL)allow {
    gAllowNSNulls = allow;
}

+ (BOOL)allowNSNull {
    return gAllowNSNulls;
}

#pragma mark - Logging

+ (void)setLogging:(SGHTTPLogging)logging {
#ifdef DEBUG
    // Logging in debug builds only.
    gLogging = logging;
#endif
}

+ (SGHTTPLogging)logging {
    return gLogging;
}

- (NSString *)boxUpString:(NSString *)string fatLine:(BOOL)fatLine {
    NSMutableString *boxString = NSMutableString.new;
    NSInteger charsInLine = string.length + 4;

    if (fatLine) {
        [boxString appendString:@"\n╔"];
        [boxString appendString:[@"" stringByPaddingToLength:charsInLine - 2 withString:@"═" startingAtIndex:0]];
        [boxString appendString:@"╗\n"];
        [boxString appendString:[NSString stringWithFormat:@"║ %@ ║\n", string]];
        [boxString appendString:@"╚"];
        [boxString appendString:[@"" stringByPaddingToLength:charsInLine - 2 withString:@"═" startingAtIndex:0]];
        [boxString appendString:@"╝\n"];
    } else {
        [boxString appendString:@"\n┌"];
        [boxString appendString:[@"" stringByPaddingToLength:charsInLine - 2 withString:@"─" startingAtIndex:0]];
        [boxString appendString:@"┐\n"];
        [boxString appendString:[NSString stringWithFormat:@"│ %@ │\n", string]];
        [boxString appendString:@"└"];
        [boxString appendString:[@"" stringByPaddingToLength:charsInLine - 2 withString:@"─" startingAtIndex:0]];
        [boxString appendString:@"┘\n"];
    }
    return boxString;
}

- (void)logResponse:(AFHTTPRequestOperation *)operation error:(NSError *)error {
    NSString *responseString = self.responseString;
    NSObject *requestParameters = self.parameters;
    NSString *requestMethod = operation.request.HTTPMethod ?: @"";

    if (self.responseData &&
        [operation.responseSerializer isKindOfClass:AFJSONResponseSerializer.class] &&
        [NSJSONSerialization isValidJSONObject:operation.responseObject]) {
        NSError *error;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:operation.responseObject
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:&error];
        if (jsonData) {
            responseString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        }
    }
    if (self.parameters &&
        self.requestFormat == SGHTTPDataTypeJSON &&
        [NSJSONSerialization isValidJSONObject:self.parameters]) {
        NSError *error;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:self.parameters
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:&error];
        if (jsonData) {
            requestParameters = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        }
    }

    NSMutableString *output = NSMutableString.new;

    if (error) {
        [output appendString:[self boxUpString:[NSString stringWithFormat:@"HTTP %@ Request failed!", requestMethod]
                                       fatLine:YES]];
    } else {
        [output appendString:[self boxUpString:[NSString stringWithFormat:@"HTTP %@ Request succeeded", requestMethod]
                                       fatLine:YES]];
    }
    [output appendString:[self boxUpString:@"URL:" fatLine:NO]];
    [output appendString:[NSString stringWithFormat:@"%@", self.url]];
    [output appendString:[self boxUpString:@"Request Headers:" fatLine:NO]];
    [output appendString:[NSString stringWithFormat:@"%@", self.requestHeaders]];

    // this prints out POST Data: / PUT data: etc
    [output appendString:[self boxUpString:[NSString stringWithFormat:@"%@ Data:", requestMethod]
                                    fatLine:NO]];
    [output appendString:[NSString stringWithFormat:@"%@", requestParameters]];
    [output appendString:[self boxUpString:@"Status Code:" fatLine:NO]];
    [output appendString:[NSString stringWithFormat:@"%@", @(self.statusCode)]];
    [output appendString:[self boxUpString:@"Response:" fatLine:NO]];
    [output appendString:[NSString stringWithFormat:@"%@", responseString]];

    if (error) {
        [output appendString:[self boxUpString:@"NSError:" fatLine:NO]];
        [output appendString:[NSString stringWithFormat:@"%@", error]];
    }
    [output appendString:@"\n═══════════════════════\n\n"];
    NSLog(@"%@", [NSString stringWithString:output]);
}

- (BOOL)logErrors {
    return (self.logging & SGHTTPLogErrors) || (self.logging & SGHTTPLogResponses);
}

- (BOOL)logRequests {
    return self.logging & SGHTTPLogRequests;
}

- (BOOL)logResponses {
    return self.logging & SGHTTPLogResponses;
}

@end
