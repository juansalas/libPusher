//
//  PTNativePusher.m
//  libPusher
//
//  Created by James Fisher on 25/07/2016.
//
//

#import "PTNativePusher.h"

NSString *const PLATFORM_TYPE = @"apns";
NSString *const CLIENT_API_V1_ENDPOINT = @"https://nativepushclient-cluster1.pusher.com/client_api/v1";

const int MAX_FAILED_REQUEST_ATTEMPTS = 6;

// FIXME free() of below vars? ref counting?
@implementation PTNativePusher {
  NSURLSession *urlSession;
  int failedNativeServiceRequests;
  NSString *pusherAppKey;
  NSString *clientId;
  NSMutableArray *outbox;
}

- (id)initWithPusherAppKey:(NSString *)_pusherAppKey {
  if (self = [super init]) {
    urlSession = [NSURLSession sharedSession];
    failedNativeServiceRequests = 0;
    pusherAppKey = _pusherAppKey;
    clientId = NULL;  // NULL until we register
    outbox = [NSMutableArray array];
  }
  return self;
}

// Lovingly borrowed from http://stackoverflow.com/a/16411517/229792
- (NSString *) deviceTokenToString:(NSData *)deviceToken {
  const char *data = [deviceToken bytes];
  NSMutableString *token = [NSMutableString string];
  
  for (NSUInteger i = 0; i < [deviceToken length]; i++) {
    [token appendFormat:@"%02.2hhX", data[i]];
  }
  
  return [token copy];
}

- (void) registerWithDeviceToken: (NSData*) deviceToken {
  NSMutableURLRequest *request =
  [NSMutableURLRequest requestWithURL:[NSURL URLWithString: [NSString stringWithFormat:@"%@%@", CLIENT_API_V1_ENDPOINT, @"/clients"]]];
  [request setHTTPMethod:@"POST"];
  
  NSString *deviceTokenString = [self deviceTokenToString:deviceToken];
  
  NSDictionary *params = @{
    @"app_key": pusherAppKey,
    @"platform_type": PLATFORM_TYPE,
    @"token": deviceTokenString
    // TODO client name/version
  };
  
  assert([NSJSONSerialization isValidJSONObject:params]);
  
  NSError *jsonSerializationError;
  NSData *serializedJson = [NSJSONSerialization dataWithJSONObject:params options:@[] error: &jsonSerializationError];
  if (serializedJson == nil) {
    NSLog(@"Error serializing JSON when attempting to register: %@", [jsonSerializationError description]);
    return;
  }

  [request setHTTPBody: serializedJson];
  
  // FIXME what encoding does the above ^ serialization use? UTF-8?
  [request addValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  
  NSURLSessionDataTask *task = [urlSession dataTaskWithRequest:request
                                              completionHandler: ^(NSData * data, NSURLResponse * response, NSError * error) {
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*) response;
    if ([httpResponse statusCode] >= 200 && [httpResponse statusCode] < 300) {
      NSError *jsonDecodingError;
      id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:@[] error:&jsonDecodingError];
      // FIXME check jsonDecodingError
      NSDictionary *jsonDict = (NSDictionary*) jsonObj;
      NSObject *clientIdObj = [jsonDict objectForKey:@"id"];
      NSString *clientIdString = (NSString*) clientIdObj;
      clientId = clientIdString;
      [self tryFlushOutbox];
    } else {
      NSLog(@"Expected 2xx response to registration request; got %ld", (long)[httpResponse statusCode]);
    }
  }];
  [task resume];
}

- (void) subscribe:(NSString *)interestName {
  // TODO using a dictionary here is kinda horrible
  [outbox addObject:@{ @"interestName": interestName, @"change": @"subscribe" }];
  [self tryFlushOutbox];
}

- (void) unsubscribe:(NSString *)interestName {
  [outbox addObject:@{ @"interestName": interestName, @"change": @"unsubscribe" }];
  [self tryFlushOutbox];
}

- (void) tryFlushOutbox {
  if (clientId != NULL && 0 < [outbox count]) {
    NSDictionary *subscriptionChange = (NSDictionary*) [outbox objectAtIndex:0];
    NSString *interestName = (NSString*) [subscriptionChange objectForKey:@"interestName"];
    NSString *change = (NSString*) [subscriptionChange objectForKey:@"change"];
    [self
     modifySubscriptionForPusherAppKey:pusherAppKey
     clientId:clientId
     interestName:interestName
     subscriptionChange:change
     callback: ^(BOOL success) {
       if (success) {
         [outbox removeObjectAtIndex:0];
       }
       [self tryFlushOutbox];
     }];
  }
}

- (void) modifySubscriptionForPusherAppKey:(NSString*) _pusherAppKey clientId: (NSString*) _clientId interestName: (NSString*) interestName subscriptionChange: (NSString*) subscriptionChange callback: (void(^)(BOOL)) callback {
  NSString *url = [NSString stringWithFormat:@"%@/clients/%@/interests/%@", CLIENT_API_V1_ENDPOINT, _clientId, interestName];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL: [NSURL URLWithString:url]];
  
  if ([subscriptionChange isEqualToString:@"subscribe"]) {
    [request setHTTPMethod:@"POST"];
  } else if ([subscriptionChange isEqualToString:@"subscribe"]) {
    [request setHTTPMethod:@"DELETE"];
  }
  
  NSDictionary *params = @{
    @"app_key": _pusherAppKey
    // TODO client name/version
    };
  
  NSError *jsonSerializationError;
  [request setHTTPBody:[NSJSONSerialization dataWithJSONObject:params options:@[] error:&jsonSerializationError]];
  if (jsonSerializationError != nil) {
    NSLog(@"Error serializing JSON for subscription modification request: %@", [jsonSerializationError description]);
    return;
  }
  
  [request addValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; // TODO charset
  
  NSURLSessionDataTask *task = [urlSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*) response;
    if ([httpResponse statusCode] >= 200 && [httpResponse statusCode] < 300) {
      // Reset number of failed requests to 0 upon success
      failedNativeServiceRequests = 0;
      
      callback(true);
    } else {
      NSLog(@"Expected 2xx response to subscription modification request; received %ld", (long)[httpResponse statusCode]);
      
      if (error != nil) {
        NSLog(@"Received error when making subscription modification HTTP request: %@", [error description]);
      }
      
      failedNativeServiceRequests += 1;
      
      if (failedNativeServiceRequests < MAX_FAILED_REQUEST_ATTEMPTS) {
        callback(false);
      } else {
        NSLog(@"Too many failed native service requests (tried %d times)", failedNativeServiceRequests);
      }
    }
  }];
  [task resume];
}

@end