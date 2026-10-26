#import <Foundation/Foundation.h>
#include "include/Http.h"
#include "include/Encoding.h"
#include <algorithm>
#include <memory>
#include <mutex>

// A delegate enforces the body bound while receiving, including chunked responses.
@interface BSTHTTPDelegate : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) NSMutableData *body;
@property(nonatomic) NSUInteger limit;
@property(nonatomic) NSHTTPURLResponse *response;
@property(nonatomic) NSError *failure;
@property(nonatomic) dispatch_semaphore_t completed;
@end
@implementation BSTHTTPDelegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    if (![response isKindOfClass:[NSHTTPURLResponse class]] || (response.expectedContentLength > 0 && static_cast<uint64_t>(response.expectedContentLength) > self.limit)) {
        self.failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorDataLengthExceedsMaximum userInfo:nil]; handler(NSURLSessionResponseCancel); return;
    }
    self.response = (NSHTTPURLResponse*)response; handler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (data.length > self.limit - self.body.length) {
        self.failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorDataLengthExceedsMaximum userInfo:nil]; [task cancel]; return;
    }
    [self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (!self.failure) self.failure = error;
    dispatch_semaphore_signal(self.completed);
}
@end
namespace OSTPlatform::Http {
Result Execute(const wchar_t *method, const char *url, const void *body, uint32_t bodyLength, const wchar_t *headers,
               uint32_t resolve, uint32_t connect, uint32_t send, uint32_t receive, uint32_t maxBody) {
    @autoreleasepool {
        if (!method || !url || (!body && bodyLength)) return {};
        NSURL *target = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
        if (!target || ![@[@"http", @"https"] containsObject:target.scheme.lowercaseString]) return {};
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:target];
        request.HTTPMethod = [NSString stringWithUTF8String:Encoding::WideToUtf8(method).c_str()];
        request.HTTPBody = bodyLength ? [NSData dataWithBytes:body length:bodyLength] : nil;
        if (headers) {
            NSString *lines = [NSString stringWithUTF8String:Encoding::WideToUtf8(headers).c_str()];
            for (NSString *line in [lines componentsSeparatedByString:@"\r\n"]) {
                NSRange colon = [line rangeOfString:@":"];
                if (colon.location == NSNotFound) continue;
                NSString *key = [line substringToIndex:colon.location];
                NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                [request setValue:value forHTTPHeaderField:key];
            }
        }
        const double timeout = std::max(0.001, (static_cast<double>(resolve) + connect + send + receive) / 1000.0);
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = std::max(0.001, receive / 1000.0);
        config.timeoutIntervalForResource = timeout;
        config.HTTPShouldSetCookies = NO;
        BSTHTTPDelegate *delegate = [BSTHTTPDelegate new];
        delegate.body = [NSMutableData data]; delegate.limit = maxBody; delegate.completed = dispatch_semaphore_create(0);
        NSOperationQueue *queue = [NSOperationQueue new]; queue.maxConcurrentOperationCount = 1;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:queue];
        NSURLSessionDataTask *task = [session dataTaskWithRequest:request]; [task resume];
        const auto deadline = dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(timeout * NSEC_PER_SEC));
        if (dispatch_semaphore_wait(delegate.completed, deadline) != 0) { [session invalidateAndCancel]; return {}; }
        Result result;
        if (!delegate.failure && delegate.response) {
            result.ok = true; result.status = static_cast<uint32_t>(delegate.response.statusCode);
            if (delegate.body.length) result.body.assign(static_cast<const char*>(delegate.body.bytes), delegate.body.length);
        }
        [session finishTasksAndInvalidate];
        return result;
    }
}
}
