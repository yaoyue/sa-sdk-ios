//
//  SANetwork.m
//  SensorsAnalyticsSDK
//
//  Created by 张敏超 on 2019/3/8.
//  Copyright © 2015-2020 Sensors Data Co., Ltd. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#if ! __has_feature(objc_arc)
#error This file must be compiled with ARC. Either turn on ARC for the project or use -fobjc-arc flag on this file.
#endif

#import "SANetwork.h"
#import "SAURLUtils.h"
#import "SensorsAnalyticsSDK+Private.h"
#import "SensorsAnalyticsSDK.h"
#import "NSString+HashCode.h"
#import "SAGzipUtility.h"
#import "SALog.h"
#import "SAJSONUtil.h"
#import "SAHTTPSession.h"
#import "SAReachability.h"
#import <CoreTelephony/CTTelephonyNetworkInfo.h>

@interface SANetwork ()

@property (nonatomic, copy) NSString *cookie;

@end

@implementation SANetwork

#pragma mark - cookie
- (void)setCookie:(NSString *)cookie isEncoded:(BOOL)encoded {
    if (encoded) {
        _cookie = [cookie stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]];
    } else {
        _cookie = cookie;
    }
}

- (NSString *)cookieWithDecoded:(BOOL)isDecoded {
    return isDecoded ? _cookie.stringByRemovingPercentEncoding : _cookie;
}

#pragma mark - build

- (NSURL *)buildDebugModeCallbackURLWithParams:(NSDictionary<NSString *, NSString *> *)params {
    NSURLComponents *urlComponents = nil;
    NSString *sfPushCallbackUrl = params[@"sf_push_distinct_id"];
    NSString *infoId = params[@"info_id"];
    NSString *project = params[@"project"];
    if (sfPushCallbackUrl.length > 0 && infoId.length > 0 && project.length > 0) {
        NSURL *url = [NSURL URLWithString:sfPushCallbackUrl];
        urlComponents = [[NSURLComponents alloc] initWithURL:url resolvingAgainstBaseURL:NO];
        urlComponents.queryItems = @[[[NSURLQueryItem alloc] initWithName:@"project" value:project], [[NSURLQueryItem alloc] initWithName:@"info_id" value:infoId]];
        return urlComponents.URL;
    }
    urlComponents = [NSURLComponents componentsWithURL:self.serverURL resolvingAgainstBaseURL:NO];
    NSString *queryString = [SAURLUtils urlQueryStringWithParams:params];
    if (urlComponents.query.length) {
        urlComponents.query = [NSString stringWithFormat:@"%@&%@", urlComponents.query, queryString];
    } else {
        urlComponents.query = queryString;
    }
    return urlComponents.URL;
}

- (NSURLRequest *)buildDebugModeCallbackRequestWithURL:(NSURL *)url distinctId:(NSString *)distinctId {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30;
    [request setHTTPMethod:@"POST"];
    [request setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
    
    NSDictionary *callData = @{@"distinct_id": distinctId};
    NSData *jsonData = [SAJSONUtil JSONSerializeObject:callData];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    [request setHTTPBody:[jsonString dataUsingEncoding:NSUTF8StringEncoding]];
    
    return request;
}

#pragma mark - request

- (NSURLSessionTask *)debugModeCallbackWithDistinctId:(NSString *)distinctId params:(NSDictionary<NSString *, NSString *> *)params {
    if (![self isValidServerURL]) {
        SALogError(@"serverURL error，Please check the serverURL");
        return nil;
    }
    NSURL *url = [self buildDebugModeCallbackURLWithParams:params];
    if (!url) {
        SALogError(@"callback url in debug mode was nil");
        return nil;
    }

    NSURLRequest *request = [self buildDebugModeCallbackRequestWithURL:url distinctId:distinctId];

    NSURLSessionDataTask *task = [SAHTTPSession.sharedInstance dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSHTTPURLResponse * _Nullable response, NSError * _Nullable error) {
        NSInteger statusCode = response.statusCode;
        if (statusCode == 200) {
            SALogDebug(@"config debugMode CallBack success");
        } else {
            SALogError(@"config debugMode CallBack Faild statusCode：%ld，url：%@", (long)statusCode, url);
        }
    }];
    [task resume];
    return task;
}

@end

#pragma mark -
@implementation SANetwork (ServerURL)

- (NSURL *)serverURL {
    NSURL *serverURL = [NSURL URLWithString:SensorsAnalyticsSDK.sdkInstance.configOptions.serverURL];
    if (self.debugMode == SensorsAnalyticsDebugOff || serverURL == nil) {
        return serverURL;
    }
    NSURL *url = serverURL;
    // 将 Server URI Path 替换成 Debug 模式的 '/debug'
    if (serverURL.lastPathComponent.length > 0) {
        url = [serverURL URLByDeletingLastPathComponent];
    }
    url = [url URLByAppendingPathComponent:@"debug"];
    if (url.host && [url.host rangeOfString:@"_"].location != NSNotFound) { //包含下划线日志提示
        NSString *referenceURL = @"https://en.wikipedia.org/wiki/Hostname";
        SALogWarn(@"Server url:%@ contains '_'  is not recommend,see details:%@", serverURL, referenceURL);
    }
    return url;
}

- (NSURLComponents *)baseURLComponents {
    if (self.serverURL.absoluteString.length <= 0) {
        return nil;
    }
    NSURLComponents *components;
    NSURL *url = self.serverURL.lastPathComponent.length > 0 ? [self.serverURL URLByDeletingLastPathComponent] : self.serverURL;
    if (url) {
        components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    }
    if (!components.host) {
        SALogError(@"URLString is malformed, nil is returned.");
        return nil;
    }
    return components;
}

- (NSString *)host {
    return [SAURLUtils hostWithURL:self.serverURL] ?: @"";
}

- (NSString *)project {
    return [SAURLUtils queryItemsWithURL:self.serverURL][@"project"] ?: @"default";
}

- (NSString *)token {
    return [SAURLUtils queryItemsWithURL:self.serverURL][@"token"] ?: @"";
}

- (BOOL)isSameProjectWithURLString:(NSString *)URLString {
    if (![self isValidServerURL] || URLString.length == 0) {
        return NO;
    }
    BOOL isEqualHost = [self.host isEqualToString:[SAURLUtils hostWithURLString:URLString]];
    NSString *project = [SAURLUtils queryItemsWithURLString:URLString][@"project"] ?: @"default";
    BOOL isEqualProject = [self.project isEqualToString:project];
    return isEqualHost && isEqualProject;
}

- (BOOL)isValidServerURL {
    return self.serverURL.absoluteString.length > 0;
}

@end

#pragma mark -
@implementation SANetwork (Type)

+ (SensorsAnalyticsNetworkType)networkTypeOptions {
    NSString *networkTypeString = [SANetwork networkTypeString];

    if ([@"NULL" isEqualToString:networkTypeString]) {
        return SensorsAnalyticsNetworkTypeNONE;
    } else if ([@"WIFI" isEqualToString:networkTypeString]) {
        return SensorsAnalyticsNetworkTypeWIFI;
    } else if ([@"2G" isEqualToString:networkTypeString]) {
        return SensorsAnalyticsNetworkType2G;
    } else if ([@"3G" isEqualToString:networkTypeString]) {
        return SensorsAnalyticsNetworkType3G;
    } else if ([@"4G" isEqualToString:networkTypeString]) {
        return SensorsAnalyticsNetworkType4G;
#ifdef __IPHONE_14_1
    } else if ([@"5G" isEqualToString:networkTypeString]) {
        return SensorsAnalyticsNetworkType5G;
#endif
    } else if ([@"UNKNOWN" isEqualToString:networkTypeString]) {
        return SensorsAnalyticsNetworkType4G;
    }
    return SensorsAnalyticsNetworkTypeNONE;
}

+ (NSString *)networkTypeString {
    @try {
        if ([SAReachability sharedInstance].isReachableViaWiFi) {
            return @"WIFI";
        }

        if ([SAReachability sharedInstance].isReachableViaWWAN) {
            static CTTelephonyNetworkInfo *networkInfo = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                networkInfo = [[CTTelephonyNetworkInfo alloc] init];
            });

            NSString *currentRadioAccessTechnology = nil;
#ifdef __IPHONE_12_0
            if (@available(iOS 12.1, *)) {
                currentRadioAccessTechnology = networkInfo.serviceCurrentRadioAccessTechnology.allValues.lastObject;
            }
#endif
            // 测试发现存在少数 12.0 和 12.0.1 的机型 serviceCurrentRadioAccessTechnology 返回空
            if (!currentRadioAccessTechnology) {
                currentRadioAccessTechnology = networkInfo.currentRadioAccessTechnology;
            }

            return [SANetwork networkStatusWithRadioAccessTechnology:currentRadioAccessTechnology];
        }
    } @catch (NSException *exception) {
        SALogError(@"%@: %@", self, exception);
    }

    return @"NULL";
}

+ (NSString *)networkStatusWithRadioAccessTechnology:(NSString *)value {
    if ([value isEqualToString:CTRadioAccessTechnologyGPRS] ||
        [value isEqualToString:CTRadioAccessTechnologyEdge]
        ) {
        return @"2G";
    } else if ([value isEqualToString:CTRadioAccessTechnologyWCDMA] ||
               [value isEqualToString:CTRadioAccessTechnologyHSDPA] ||
               [value isEqualToString:CTRadioAccessTechnologyHSUPA] ||
               [value isEqualToString:CTRadioAccessTechnologyCDMA1x] ||
               [value isEqualToString:CTRadioAccessTechnologyCDMAEVDORev0] ||
               [value isEqualToString:CTRadioAccessTechnologyCDMAEVDORevA] ||
               [value isEqualToString:CTRadioAccessTechnologyCDMAEVDORevB] ||
               [value isEqualToString:CTRadioAccessTechnologyeHRPD]
               ) {
        return @"3G";
    } else if ([value isEqualToString:CTRadioAccessTechnologyLTE]) {
        return @"4G";
    }
#ifdef __IPHONE_14_1
    else if (@available(iOS 14.1, *)) {
        if ([value isEqualToString:CTRadioAccessTechnologyNRNSA] ||
            [value isEqualToString:CTRadioAccessTechnologyNR]
            ) {
            return @"5G";
        }
    }
#endif
    return @"UNKNOWN";
}

@end
