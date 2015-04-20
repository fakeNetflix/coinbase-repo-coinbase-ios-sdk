#import "Coinbase.h"
#import <CommonCrypto/CommonHMAC.h>
#import "CoinbaseAccount.h"
#import "CoinbasePagingHelper.h"
#import "CoinbaseAddress.h"

typedef NS_ENUM(NSUInteger, CoinbaseAuthenticationType) {
    CoinbaseAuthenticationTypeAPIKey,
    CoinbaseAuthenticationTypeOAuth,
    CoinbaseAuthenticationTypeNone
};

@interface Coinbase ()

@property CoinbaseAuthenticationType authenticationType;
@property (strong) NSString *apiKey;
@property (strong) NSString *apiSecret;
@property (strong) NSString *accessToken;

@end

@implementation Coinbase

+ (Coinbase *)coinbaseWithOAuthAccessToken:(NSString *)accessToken {
    return [[self alloc] initWithOAuthAccessToken:accessToken];
}

+ (Coinbase *)coinbaseWithApiKey:(NSString *)key secret:(NSString *)secret {
    return [[self alloc] initWithApiKey:key secret:secret];
}

// equivalent to [Coinbase new]
+ (Coinbase *)unauthenticatedCoinbase {
    return [[self alloc] init];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.authenticationType = CoinbaseAuthenticationTypeNone;
    }
    return self;
}

- (instancetype)initWithOAuthAccessToken:(NSString *)accessToken {
    self = [self init];
    if (self) {
        self.authenticationType = CoinbaseAuthenticationTypeOAuth;
        self.accessToken = accessToken;
    }
    return self;
}

- (instancetype)initWithApiKey:(NSString *)key secret:(NSString *)secret {
    self = [self init];
    if (self) {
        self.authenticationType = CoinbaseAuthenticationTypeAPIKey;
        self.apiKey = key;
        self.apiSecret = secret;
    }
    return self;
}

- (void)requestSuccess:(NSHTTPURLResponse *)operation
              response:(NSData *)data
            completion:(CoinbaseCompletionBlock)completion {
    NSError *error = nil;
    id response = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (response == nil) {
        response = @{};
    }

    // Check for errors
    NSMutableDictionary *errorUserInfo = [@{ @"statusCode": [NSNumber numberWithInteger: [operation statusCode]], @"response": response } mutableCopy];
    if ([response isKindOfClass:[NSDictionary class]] && ([response objectForKey:@"error"] || [response objectForKey:@"errors"])) {
        if ([response objectForKey:@"error"]) {
            errorUserInfo[@"errors"] = @[ [response objectForKey:@"error"] ];
        } else {
            errorUserInfo[@"errors"] = [response objectForKey:@"errors"];
        }
        error = [NSError errorWithDomain:CoinbaseErrorDomain code:CoinbaseServerErrorWithMessage userInfo:errorUserInfo];
    } else if ([operation statusCode] >= 300) {
        error = [NSError errorWithDomain:CoinbaseErrorDomain code:CoinbaseServerErrorWithMessage userInfo:errorUserInfo];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        completion(response, error);
    });
}

// http://stackoverflow.com/a/16458798/764272
- (NSString *)generateSignature:(NSString *)body {
    const char *cKey  = [self.apiSecret cStringUsingEncoding:NSASCIIStringEncoding];
    const char *cData = [body cStringUsingEncoding:NSASCIIStringEncoding];

    unsigned char cHMAC[CC_SHA256_DIGEST_LENGTH];

    CCHmac(kCCHmacAlgSHA256, cKey, strlen(cKey), cData, strlen(cData), cHMAC);

    NSData *HMACData = [[NSData alloc] initWithBytes:cHMAC length:sizeof(cHMAC)];

    const unsigned char *buffer = (const unsigned char *)[HMACData bytes];
    NSString *HMAC = [NSMutableString stringWithCapacity:HMACData.length * 2];

    for (int i = 0; i < HMACData.length; ++i)
        HMAC = [HMAC stringByAppendingFormat:@"%02lx", (unsigned long)buffer[i]];

    return HMAC;
}

- (void)doRequestType:(CoinbaseRequestType)type
                 path:(NSString *)path
           parameters:(NSDictionary *)parameters
           completion:(CoinbaseCompletionBlock)completion {
    [self doRequestType:type path:path parameters:parameters headers:nil completion:completion];
}

- (void)doRequestType:(CoinbaseRequestType)type
                 path:(NSString *)path
           parameters:(NSDictionary *)parameters
              headers:(NSDictionary *)headers
           completion:(CoinbaseCompletionBlock)completion {

    NSData *body = nil;
    if (type == CoinbaseRequestTypeGet || type == CoinbaseRequestTypeDelete) {
        // Parameters need to be appended to URL
        NSMutableArray *parts = [NSMutableArray array];
        NSString *encodedKey, *encodedValue;
        for (NSString *key in parameters) {
            encodedKey = [Coinbase URLEncodedStringFromString:key];
            encodedValue = [Coinbase URLEncodedStringFromString:[parameters objectForKey:key]];
            [parts addObject:[NSString stringWithFormat:@"%@=%@", encodedKey, encodedValue]];
        }
        if (parts.count > 0) {
            path = [path stringByAppendingString:@"?"];
            path = [path stringByAppendingString:[parts componentsJoinedByString:@"&"]];
        }
    } else if (parameters) {
        // POST body is encoded as JSON
        NSError *error = nil;
        body = [NSJSONSerialization dataWithJSONObject:parameters options:0 error:&error];
        if (error) {
            completion(nil, error);
            return;
        }
    }

    NSURL *baseURL = [NSURL URLWithString:@"https://coinbase.com/api/v1/"];
    NSURL *URL = [NSURL URLWithString:path relativeToURL:baseURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10];
    if (body) {
        [request setHTTPBody:body];
    }
    switch (type) {
        case CoinbaseRequestTypeGet:
            [request setHTTPMethod:@"GET"];
            break;
        case CoinbaseRequestTypePost:
            [request setHTTPMethod:@"POST"];
            [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            break;
        case CoinbaseRequestTypeDelete:
            [request setHTTPMethod:@"DELETE"];
            break;
        case CoinbaseRequestTypePut:
            [request setHTTPMethod:@"PUT"];
            [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            break;
    }

    if (self.authenticationType == CoinbaseAuthenticationTypeAPIKey) {
        // HMAC auth
        NSInteger nonce = [[NSDate date] timeIntervalSince1970] * 100000;
        NSString *toBeSigned = [NSString stringWithFormat:@"%ld%@%@", (long)nonce, [URL absoluteString], body ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : @""];
        NSString *signature = [self generateSignature: toBeSigned];
        [request setValue:self.apiKey forHTTPHeaderField:@"ACCESS_KEY"];
        [request setValue:signature forHTTPHeaderField:@"ACCESS_SIGNATURE"];
        [request setValue:[NSString stringWithFormat:@"%ld", (long)nonce] forHTTPHeaderField:@"ACCESS_NONCE"];
    } else if (self.authenticationType == CoinbaseAuthenticationTypeOAuth) {
        // OAuth
        [request setValue:[NSString stringWithFormat:@"Bearer %@", self.accessToken] forHTTPHeaderField:@"Authorization"];
    }

    if (headers != nil) {
        for (NSString *header in [headers keyEnumerator]) {
            [request setValue:headers[header] forKey:header];
        }
    }

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLSessionDataTask *task;
    task = [session dataTaskWithRequest:request
                      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                          if (error) {
                              dispatch_async(dispatch_get_main_queue(), ^{
                                  completion(nil, error);
                              });
                              return;
                          }
                          [self requestSuccess:(NSHTTPURLResponse*)response response:data completion: completion];
                      }];
    [task resume];
}

#pragma mark - Accounts

-(void) getAccountsList:(void(^)(NSArray*, NSError*))callback
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"accounts" parameters:nil headers:nil completion:^(id response, NSError *error) {

        if (error)
        {
            callback(nil, error);
            return;
        }

        if ([response isKindOfClass:[NSDictionary class]])
        {
            NSArray *responseAccounts = [response objectForKey:@"accounts"];

            NSMutableArray *accounts = [[NSMutableArray alloc] initWithCapacity:responseAccounts.count];

            for (NSDictionary *dictionary in responseAccounts)
            {
                CoinbaseAccount *account = [[CoinbaseAccount alloc] initWithDictionary:dictionary];
                [accounts addObject:account];
            }

            callback(accounts, error);
        }
    }];
}

-(void) getAccountsListWithPage:(NSUInteger)page
                          limit:(NSUInteger)limit
                    allAccounts:(BOOL)allAccounts
                     completion:(void(^)(NSArray*, CoinbasePagingHelper*, NSError*))callback
{
    NSDictionary *parameters = @{
                                 @"page" : [@(page) stringValue],
                                 @"limit" : [@(limit)  stringValue],
                                 @"all_accounts" : allAccounts ? @"true" : @"false",
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"accounts" parameters:parameters headers:nil completion:^(id response, NSError *error) {

        if (error)
        {
            callback(nil, nil, error);
            return;
        }

        if ([response isKindOfClass:[NSDictionary class]])
        {
            NSArray *responseAccounts = [response objectForKey:@"accounts"];

            NSMutableArray *accounts = [[NSMutableArray alloc] initWithCapacity:responseAccounts.count];

            for (NSDictionary *dictionary in responseAccounts)
            {
                CoinbaseAccount *account = [[CoinbaseAccount alloc] initWithDictionary:dictionary];
                [accounts addObject:account];
            }

            CoinbasePagingHelper *pagingHelper = [[CoinbasePagingHelper alloc] initWithDictionary:response];

            callback(accounts, pagingHelper, error);
        }
    }];
}

-(void) getAccount:(NSString *)accountID completion:(void(^)(CoinbaseAccount*, NSError*))callback
{
    NSString *path = [NSString stringWithFormat:@"accounts/%@", accountID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:^(id response, NSError *error) {

        if (error)
        {
            callback(nil, error);
            return;
        }

        if ([response isKindOfClass:[NSDictionary class]])
        {
            CoinbaseAccount *account = [[CoinbaseAccount alloc] initWithDictionary:[response objectForKey:@"account"]];
            callback(account , error);
        }
    }];
}

-(void) getPrimaryAccount:(void(^)(CoinbaseAccount*, NSError*))callback
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"accounts/primary" parameters:nil headers:nil completion:^(id response, NSError *error) {

        if (error)
        {
            callback(nil, error);
            return;
        }

        if ([response isKindOfClass:[NSDictionary class]])
        {
            CoinbaseAccount *account = [[CoinbaseAccount alloc] initWithDictionary:[response objectForKey:@"account"]];
            callback(account , error);
        }
    }];
}

-(void) createAccountWithName:(NSString *)name
                   completion:(void(^)(CoinbaseAccount*, NSError*))callback
{
    NSDictionary *parameters = @{@"account" :
                                     @{@"name" : name}};

    [self doRequestType:CoinbaseRequestTypePost path:@"accounts" parameters:parameters headers:nil completion:^(id response, NSError *error) {

        if (error)
        {
            callback(nil, error);
            return;
        }

        if ([response isKindOfClass:[NSDictionary class]])
        {
            CoinbaseAccount *account = [[CoinbaseAccount alloc] initWithDictionary:[response objectForKey:@"account"]];
            callback(account , error);
        }
    }];
}

-(void) getBalanceForAccount:(NSString *)accountID completion:(void(^)(CoinbaseBalance*, NSError*))callback;
{
    NSString *path = [NSString stringWithFormat:@"accounts/%@/balance", accountID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:^(id response, NSError *error) {

        if (error)
        {
            callback(nil, error);
            return;
        }

        if ([response isKindOfClass:[NSDictionary class]])
        {
            CoinbaseBalance *balance = [[CoinbaseBalance alloc] initWithDictionary:[response objectForKey:@"account"]];
            callback(balance , error);
        }
    }];
}

-(void) getBitcoinAddressForAccount:(NSString *)accountID completion:(void(^)(CoinbaseAddress*, NSError*))callback
{
    NSString *path = [NSString stringWithFormat:@"accounts/%@/address", accountID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:^(id response, NSError *error) {

        if (error)
        {
            callback(nil, error);
            return;
        }

        if ([response isKindOfClass:[NSDictionary class]])
        {
            CoinbaseAddress *address = [[CoinbaseAddress alloc] initWithDictionary:[response objectForKey:@"account"]];
            callback(address , error);
        }
    }];
}

-(void) createBitcoinAddressForAccount:(NSString *)accountID completion:(void(^)(CoinbaseAddress*, NSError*))callback
{
    [self createBitcoinAddressForAccount:accountID label:nil callBackURL:nil completion:^(id response, NSError *error) {

        if (error)
        {
            callback(nil, error);
            return;
        }

        if ([response isKindOfClass:[NSDictionary class]])
        {
            CoinbaseAddress *address = [[CoinbaseAddress alloc] initWithDictionary:[response objectForKey:@"account"]];
            callback(address , error);
        }
    }];
}

-(void) createBitcoinAddressForAccount:(NSString *)accountID
                                 label:(NSString *)label
                           callBackURL:(NSString *)callBackURL
                            completion:(void(^)(CoinbaseAddress*, NSError*))callback
{
    NSDictionary *parameters = @{@"address" :
                                     @{@"label" : label,
                                       @"callback_url" : callBackURL
                                       }};

    NSString *path = [NSString stringWithFormat:@"accounts/%@/address", accountID];

    [self doRequestType:CoinbaseRequestTypePost path:path parameters:parameters headers:nil completion:^(id response, NSError *error) {

        if (error)
        {
            callback(nil, error);
            return;
        }

        if ([response isKindOfClass:[NSDictionary class]])
        {
            CoinbaseAddress *address = [[CoinbaseAddress alloc] initWithDictionary:[response objectForKey:@"account"]];
            callback(address , error);
        }
    }];
}

-(void) modifyAccount:(NSString *)accountID
                 name:(NSString *)name
           completion:(void(^)(CoinbaseAccount*, NSError*))callback
{
    NSDictionary *parameters = @{@"account" :
                                     @{@"name" : name}};

    NSString *path = [NSString stringWithFormat:@"accounts/%@", accountID];

    [self doRequestType:CoinbaseRequestTypePut path:path parameters:parameters headers:nil completion:^(id response, NSError *error) {

        if (error)
        {
            callback(nil, error);
            return;
        }

        if ([response isKindOfClass:[NSDictionary class]])
        {
            CoinbaseAccount *account = [[CoinbaseAccount alloc] initWithDictionary:[response objectForKey:@"account"]];
            callback(account , error);
        }
    }];
}

-(void) setAccountAsPrimary:(NSString *)accountID completion:(void(^)(BOOL, NSError*))callback
{
    NSString *path = [NSString stringWithFormat:@"accounts/%@/primary", accountID];

    [self doRequestType:CoinbaseRequestTypePost path:path parameters:nil headers:nil completion:^(id response, NSError *error) {

        if (error)
        {
            callback(nil, error);
            return;
        }

        if ([response isKindOfClass:[NSDictionary class]])
        {
            BOOL success = [[response objectForKey:@"success"] boolValue];

            callback(success , error);
        }
    }];
}

-(void) deleteAccount:(NSString *)accountID completion:(void(^)(BOOL, NSError*))callback
{
    NSString *path = [NSString stringWithFormat:@"accounts/%@", accountID];

    [self doRequestType:CoinbaseRequestTypeDelete path:path parameters:nil headers:nil completion:^(id response, NSError *error) {

        if (error)
        {
            callback(nil, error);
            return;
        }

        if ([response isKindOfClass:[NSDictionary class]])
        {
            BOOL success = [[response objectForKey:@"success"] boolValue];

            callback(success , error);
        }
    }];
}

#pragma mark - Account Changes

-(void) getAccountChanges:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"account_changes" parameters:nil headers:nil completion:completion];
}

-(void) getAccountChangesWithPage:(NSUInteger)page
                            limit:(NSUInteger)limit
                        accountId:(NSString *)accountId
                       completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"page" : [@(page) stringValue],
                                 @"limit" : [@(limit)  stringValue],
                                 @"account_id" : accountId
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"account_changes" parameters:parameters headers:nil completion:completion];
}

#pragma mark - Addresses

-(void) getAccountAddresses:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"addresses" parameters:nil headers:nil completion:completion];
}

-(void) getAccountAddressesWithPage:(NSUInteger)page
                              limit:(NSUInteger)limit
                          accountId:(NSString *)accountId
                              query:(NSString *)query
                         completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"page" : [@(page) stringValue],
                                 @"limit" : [@(limit)  stringValue],
                                 @"account_id" : accountId,
                                 @"query" : query,
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"addresses" parameters:parameters headers:nil completion:completion];
}

-(void) getAddressWithAddressOrID:(NSString *) addressOrID completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"addresses/%@", addressOrID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:completion];
}

-(void) getAddressWithAddressOrID:(NSString *)addressOrID
                        accountId:(NSString *)accountId
                       completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"addresses/%@", addressOrID];

    NSDictionary *parameters = @{
                                 @"account_id" : accountId,
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:parameters headers:nil completion:completion];
}

#pragma mark - Authorization

-(void) getAuthorizationInformation:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"authorization" parameters:nil headers:nil completion:completion];
}

#pragma mark - Button

-(void) createButtonWithName:(NSString *)name
                      price:(NSString *)price
           priceCurrencyISO:(NSString *)priceCurrencyISO
                 completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"button" :
                                     @{@"name" : name,
                                       @"price_string": price,
                                       @"price_currency_iso" : priceCurrencyISO
                                       }
                                 };
    
    [self doRequestType:CoinbaseRequestTypeGet path:@"buttons" parameters:parameters headers:nil completion:completion];
}

-(void) createButtonWithName:(NSString *)name
                      price:(NSString *)price
           priceCurrencyISO:(NSString *)priceCurrencyISO
                  accountID:(NSString *)accountID
                       type:(NSString *)type
               subscription:(BOOL)subscription
                     repeat:(NSString *)repeat
                      style:(NSString *)style
                       text:(NSString *)text
                description:(NSString *)description
                     custom:(NSString *)custom
               customSecure:(BOOL)customSecure
                callbackURL:(NSString *)callbackURL
                 successURL:(NSString *)successURL
                  cancelURL:(NSString *)cancelURL
                    infoURL:(NSString *)infoURL
               autoRedirect:(BOOL)autoRedirect
        autoRedirectSuccess:(BOOL)autoRedirectSuccess
         autoRedirectCancel:(BOOL)autoRedirectCancel
              variablePrice:(BOOL)variablePrice
             includeAddress:(BOOL)includeAddress
               includeEmail:(BOOL)includeEmail
                choosePrice:(BOOL)choosePrice
                     price1:(NSString *)price1
                     price2:(NSString *)price2
                     price3:(NSString *)price3
                     price4:(NSString *)price4
                     price5:(NSString *)price5
                 completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"button" :
                                     @{@"name" : name,
                                       @"price_string": price,
                                       @"price_currency_iso" : priceCurrencyISO,
                                       @"account_id" : accountID,
                                       @"type" : type,
                                       @"subscription" : subscription ? @"true" : @"false",
                                       @"repeat" : repeat,
                                       @"style" : style,
                                       @"text" : text,
                                       @"description" : description,
                                       @"custom" : custom,
                                       @"custom_secure" : customSecure ? @"true" : @"false",
                                       @"callback_url" : callbackURL,
                                       @"success_url" : successURL,
                                       @"cancel_url" : cancelURL,
                                       @"info_url" : infoURL,
                                       @"auto_redirect" : autoRedirect ? @"true" : @"false",
                                       @"auto_redirect_success" : autoRedirectSuccess ? @"true" : @"false",
                                       @"auto_redirect_cancel" : autoRedirectCancel ? @"true" : @"false",
                                       @"variable_price" : variablePrice ? @"true" : @"false",
                                       @"include_address" : includeAddress ? @"true" : @"false",
                                       @"include_email" : includeEmail ? @"true" : @"false",
                                       @"choose_price" : choosePrice ? @"true" : @"false",
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"buttons" parameters:parameters headers:nil completion:completion];
}

-(void)getButtonWithID:(NSString *)customValueOrID completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"buttons/%@", customValueOrID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:completion];
}

-(void) createOrderForButtonWithID:(NSString *)customValueOrID completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"buttons/%@/create_order", customValueOrID];

    [self doRequestType:CoinbaseRequestTypePost path:path parameters:nil headers:nil completion:completion];
}

-(void)getOrdersForButtonWithID:(NSString *)customValueOrID completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"buttons/%@/orders", customValueOrID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:completion];
}

#pragma mark - Buys

-(void) buy:(double)quantity completion:(CoinbaseCompletionBlock)completion
{
    NSNumber *quantityNumber = [NSNumber numberWithDouble:quantity];

    NSDictionary *parameters = @{
                                 @"qty" : [quantityNumber stringValue]
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"buys" parameters:parameters headers:nil completion:completion];
}

-(void)                 buy:(double)quantity
                  accountID:(NSString *)accountID
                   currency:(NSString *)currency
       agreeBTCAmountVaries:(BOOL)agreeBTCAmountVaries
                     commit:(BOOL)commit
            paymentMethodID:(NSString *)paymentMethodID
                 completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"qty" : [[NSNumber numberWithDouble:quantity] stringValue],
                                 @"account_id" : accountID,
                                 @"currency" : currency,
                                 @"agree_btc_amount_varies" : agreeBTCAmountVaries ? @"true" : @"false",
                                 @"commit" : commit ? @"true" : @"false",
                                 @"paymentMethodID" : paymentMethodID
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"buys" parameters:parameters headers:nil completion:completion];
}

#pragma mark - Contacts


-(void) getContacts:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"contacts" parameters:nil headers:nil completion:completion];
}

-(void) getContactsWithPage:(NSUInteger)page
                      limit:(NSUInteger)limit
                      query:(NSString *)query
                 completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"page" : [@(page) stringValue],
                                 @"limit" : [@(limit)  stringValue],
                                 @"query" : query,
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"contacts" parameters:parameters headers:nil completion:completion];

}

#pragma mark - Currencies

-(void) getSupportedCurrencies:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"currencies" parameters:nil headers:nil completion:completion];
}

-(void) getExchangeRates:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"exchange_rates" parameters:nil headers:nil completion:completion];
}

#pragma mark - Deposits

-(void) makeDepositToAccount:(NSString *)accountID
                      amount:(double)amount
             paymentMethodId:(NSString *)paymentMethodId
                      commit:(BOOL)commit
                  completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"account_id" : accountID,
                                 @"amount" : [[NSNumber numberWithDouble:amount] stringValue],
                                 @"payment_method_id" : paymentMethodId,
                                 @"commit" : commit ? @"true" : @"false",
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"deposits" parameters:parameters headers:nil completion:completion];
}

#pragma mark - Multisig

-(void) createMultiSigAccountWithName:(NSString *)name
                                 type:(NSString *)type
                   requiredSignatures:(NSUInteger)requiredSignatures
                             xPubKeys:(NSArray *)xPubKeys
                           completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"account" :
                                     @{@"name" : name,
                                       @"type": type,
                                       @"m" : [[NSNumber numberWithUnsignedInteger:requiredSignatures] stringValue],
                                       @"xpubkeys": xPubKeys}
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"accounts" parameters:parameters headers:nil completion:completion];
}

-(void) getSignatureHashesWithTransactionID:(NSString *)transactionID completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"transactions/%@/sighashes", transactionID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:completion];
}

-(void) getSignatureHashesWithTransactionID:(NSString *)transactionID accountID:(NSString *)accountID completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"transactions/%@/sighashes", transactionID];

    NSDictionary *parameters = @{
                                 @"account_id" : accountID,
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:parameters headers:nil completion:completion];
}

-(void) signaturesForMultiSigTransaction:(NSString *)transactionID
                              signatures:(NSArray *)signatures
                              completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"signatures": signatures
                                 };

    NSString *path = [NSString stringWithFormat:@"transactions/%@/signatures", transactionID];

    [self doRequestType:CoinbaseRequestTypePut path:path parameters:parameters headers:nil completion:completion];
}

#pragma mark - OAuth Applications


-(void) getOAuthApplications:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"oauth/applications" parameters:nil headers:nil completion:completion];

}

-(void) getOAuthApplicationsWithPage:(NSUInteger)page
                               limit:(NSUInteger)limit
                          completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"page" : [@(page) stringValue],
                                 @"limit" : [@(limit)  stringValue],
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"oauth/applications" parameters:parameters headers:nil completion:completion];
}

-(void) getOAuthApplicationWithID:(NSString *)applicationID
                       completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"oauth/applications/%@", applicationID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:completion];
}

-(void) createOAuthApplicationWithName:(NSString *)name
                           reDirectURL:(NSString *)reDirectURL
                            completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"application" :
                                     @{@"name" : name,
                                       @"redirect_uri": reDirectURL
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"oauth/applications" parameters:parameters headers:nil completion:completion];
}

#pragma mark - Orders

-(void) getOrders:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"orders" parameters:nil headers:nil completion:completion];
}

-(void) getOrdersWithPage:(NSUInteger)page
                    limit:(NSUInteger)limit
                accountID:(NSString *)accountID
               completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"page" : [@(page) stringValue],
                                 @"limit" : [@(limit)  stringValue],
                                 @"account_id" : accountID
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"orders" parameters:parameters headers:nil completion:completion];
}

-(void) createOrderWithName:(NSString *)name
                      price:(NSString *)price
           priceCurrencyISO:(NSString *)priceCurrencyISO
                 completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"button" :
                                     @{@"name" : name,
                                       @"price_string": price,
                                       @"price_currency_iso" : priceCurrencyISO
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"orders" parameters:parameters headers:nil completion:completion];
}

-(void) createOrderWithName:(NSString *)name
                      price:(NSString *)price
           priceCurrencyISO:(NSString *)priceCurrencyISO
                  accountID:(NSString *)accountID
                       type:(NSString *)type
               subscription:(BOOL)subscription
                     repeat:(NSString *)repeat
                      style:(NSString *)style
                       text:(NSString *)text
                description:(NSString *)description
                     custom:(NSString *)custom
               customSecure:(BOOL)customSecure
                callbackURL:(NSString *)callbackURL
                 successURL:(NSString *)successURL
                  cancelURL:(NSString *)cancelURL
                    infoURL:(NSString *)infoURL
               autoRedirect:(BOOL)autoRedirect
        autoRedirectSuccess:(BOOL)autoRedirectSuccess
         autoRedirectCancel:(BOOL)autoRedirectCancel
              variablePrice:(BOOL)variablePrice
             includeAddress:(BOOL)includeAddress
               includeEmail:(BOOL)includeEmail
                choosePrice:(BOOL)choosePrice
                     price1:(NSString *)price1
                     price2:(NSString *)price2
                     price3:(NSString *)price3
                     price4:(NSString *)price4
                     price5:(NSString *)price5
                 completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"button" :
                                     @{@"name" : name,
                                       @"price_string": price,
                                       @"price_currency_iso" : priceCurrencyISO,
                                       @"account_id" : accountID,
                                       @"type" : type,
                                       @"subscription" : subscription ? @"true" : @"false",
                                       @"repeat" : repeat,
                                       @"style" : style,
                                       @"text" : text,
                                       @"description" : description,
                                       @"custom" : custom,
                                       @"custom_secure" : customSecure ? @"true" : @"false",
                                       @"callback_url" : callbackURL,
                                       @"success_url" : successURL,
                                       @"cancel_url" : cancelURL,
                                       @"info_url" : infoURL,
                                       @"auto_redirect" : autoRedirect ? @"true" : @"false",
                                       @"auto_redirect_success" : autoRedirectSuccess ? @"true" : @"false",
                                       @"auto_redirect_cancel" : autoRedirectCancel ? @"true" : @"false",
                                       @"variable_price" : variablePrice ? @"true" : @"false",
                                       @"include_address" : includeAddress ? @"true" : @"false",
                                       @"include_email" : includeEmail ? @"true" : @"false",
                                       @"choose_price" : choosePrice ? @"true" : @"false",
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"orders" parameters:parameters headers:nil completion:completion];
}

-(void) getOrderWithID:(NSString *)customFieldOrID
            completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"orders/%@", customFieldOrID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:completion];
}

-(void) getOrderWithID:(NSString *)customFieldOrID
             accountID:(NSString *)accountID
            completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"account_id" : accountID
                                 };

    NSString *path = [NSString stringWithFormat:@"orders/%@", customFieldOrID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:parameters headers:nil completion:completion];
}

#pragma mark - Payment Methods

-(void) getPaymentMethods:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"payment_methods" parameters:nil headers:nil completion:completion];
}

-(void) paymentMethodWithID:(NSString *)paymentMethodID completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"payment_methods/%@", paymentMethodID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:completion];
}

-(void) refundOrderWithID:(NSString *)customFieldOrID
            refundISOCode:(NSString *)refundISOCode
               completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"refund_iso_code" : refundISOCode
                                 };

    NSString *path = [NSString stringWithFormat:@"orders/%@/refund", customFieldOrID];

    [self doRequestType:CoinbaseRequestTypePost path:path parameters:parameters headers:nil completion:completion];
}

-(void) refundOrderWithID:(NSString *)customFieldOrID
            refundISOCode:(NSString *)refundISOCode
             mispaymentID:(NSString *)mispaymentID
    externalRefundAddress:(NSString *)externalRefundAddress
               instantBuy:(BOOL)instantBuy
               completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"refund_iso_code" : refundISOCode,
                                 @"mispayment_id" : mispaymentID,
                                 @"external_refund_address" :externalRefundAddress,
                                 @"instant_buy" : instantBuy ? @"true" : @"false"
                                 };

    NSString *path = [NSString stringWithFormat:@"orders/%@/refund", customFieldOrID];

    [self doRequestType:CoinbaseRequestTypePost path:path parameters:parameters headers:nil completion:completion];
}

#pragma mark - Prices

-(void) getBuyPrice:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"prices/buy" parameters:nil headers:nil completion:completion];
}

-(void) getBuyPriceWithQuantity:(double)qty
                       currency:(NSString *)currency
                     completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"qty" : [[NSNumber numberWithDouble:qty] stringValue],
                                 @"currency" : currency
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"prices/buy" parameters:parameters headers:nil completion:completion];
}

-(void) getSellPrice:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"prices/sell" parameters:nil headers:nil completion:completion];
}

-(void) getSellPriceWithQuantity:(double)qty
                        currency:(NSString *)currency
                      completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"qty" : [[NSNumber numberWithDouble:qty] stringValue],
                                 @"currency" : currency
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"prices/sell" parameters:parameters headers:nil completion:completion];
}

-(void) getSpotRate:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"prices/spot_rate" parameters:nil headers:nil completion:completion];
}

-(void) getSpotRateWithCurrency:(NSString *)currency
                     completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"currency" : currency
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"prices/spot_rate" parameters:parameters headers:nil completion:completion];
}

-(void) getHistoricalSpotRate:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"prices/historical" parameters:nil headers:nil completion:completion];
}

-(void) getHistoricalSpotRateWithPage:(NSUInteger)page
                           completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"page" : [NSNumber numberWithUnsignedInteger:page]
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"prices/historical" parameters:parameters headers:nil completion:completion];
}

#pragma mark - Recurring Payments

-(void) getRecurringPayments:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"recurring_payments" parameters:nil headers:nil completion:completion];
}

-(void) getRecurringPaymentsWithPage:(NSUInteger)page
                               limit:(NSUInteger)limit
                          completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"page" : [@(page) stringValue],
                                 @"limit" : [@(limit)  stringValue]
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"recurring_payments" parameters:parameters headers:nil completion:completion];
}

-(void) recurringPaymentWithID:(NSString *)recurringPaymentID
                    completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"recurring_payments/%@", recurringPaymentID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:completion];
}

-(void) createReportWithType:(NSString *)type
                       email:(NSString *)email
                  completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"report" :
                                     @{@"type" : type,
                                       @"email": email,
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"reports" parameters:parameters headers:nil completion:completion];
}

-(void) createReportWithType:(NSString *)type
                       email:(NSString *)email
                   accountID:(NSString *)accountID
                 callbackURL:(NSString *)callbackURL
                   timeRange:(NSString *)timeRange
              timeRangeStart:(NSString *)timeRangeStart
                timeRangeEnd:(NSString *)timeRangeEnd
                   startType:(NSString *)startType
                 nextRunDate:(NSString *)nextRunDate
                 nextRunTime:(NSString *)nextRunTime
                      repeat:(NSString *)repeat
                       times:(NSUInteger)times
                  completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"report" :
                                     @{@"type" : type,
                                       @"email": email,
                                       @"callback_url": callbackURL,
                                       @"time_range": timeRange,
                                       @"time_range_start": timeRangeStart,
                                       @"time_range_end": timeRangeEnd,
                                       @"start_type": startType,
                                       @"next_run_date": nextRunDate,
                                       @"next_run_time": nextRunTime,
                                       @"repeat": repeat,
                                       @"times": [NSNumber numberWithUnsignedInteger:times]
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"reports" parameters:parameters headers:nil completion:completion];
}

#pragma mark - Refunds

-(void) refundWithID:(NSString *)refundID
          completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"refunds/%@", refundID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:completion];
}

#pragma mark - Reports

-(void) getReports:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"reports" parameters:nil headers:nil completion:completion];
}

-(void) getReportsWithPage:(NSUInteger)page
                     limit:(NSUInteger)limit
                completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"page" : [@(page) stringValue],
                                 @"limit" : [@(limit)  stringValue],
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"reports" parameters:parameters headers:nil completion:completion];
}

-(void) reportWithID:(NSString *)reportID completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"reports/%@", reportID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:completion];
}

#pragma mark - Sells

-(void) sellQuantity:(double)quantity
          completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"qty" : [[NSNumber numberWithDouble:quantity] stringValue]
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"sells" parameters:parameters headers:nil completion:completion];
}

-(void) sellQuantity:(double)quantity
           accountID:(NSString *)accountID
            currency:(NSString *)currency
              commit:(BOOL)commit
agreeBTCAmountVaries:(BOOL)agreeBTCAmountVaries
     paymentMethodID:(NSString *)paymentMethodID
          completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"qty" : [[NSNumber numberWithDouble:quantity] stringValue],
                                 @"account_id" : accountID,
                                 @"currency" : currency,
                                 @"commit" : commit ? @"true" : @"false",
                                 @"agree_btc_amount_varies" : agreeBTCAmountVaries ? @"true" : @"false",
                                 @"payment_method_id" : paymentMethodID
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"sells" parameters:parameters headers:nil completion:completion];
}

#pragma mark - Subscribers

-(void) getSubscribers:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"subscribers" parameters:nil headers:nil completion:completion];
}

-(void) getSubscribersWithAccountID:(NSString *)accountID
                         completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"account_id" : accountID
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"subscribers" parameters:parameters headers:nil completion:completion];
}

-(void) subscriptionWithID:(NSString *)subscriptionID completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"subscribers/%@", subscriptionID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:completion];
}

-(void) subscriptionWithID:(NSString *)subscriptionID
                 accountID:(NSString *)accountID
                completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"account_id" : accountID
                                 };
    NSString *path = [NSString stringWithFormat:@"subscribers/%@", subscriptionID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:parameters headers:nil completion:completion];
}

#pragma mark - Tokens

-(void) createToken:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypePost path:@"tokens" parameters:nil headers:nil completion:completion];
}

-(void) redeemTokenWithID:(NSString *)tokenID completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"token_id" : tokenID
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"tokens/redeem" parameters:parameters headers:nil completion:completion];
}

#pragma mark - Transactions

-(void) getTransactions:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"transactions" parameters:nil headers:nil completion:completion];
}

-(void) getTransactionsWithPage:(NSUInteger)page
                          limit:(NSUInteger)limit
                      accountID:(NSString *)accountID
                     completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"page" : [@(page) stringValue],
                                 @"limit" : [@(limit)  stringValue],
                                 @"account_id" : accountID
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"transactions" parameters:parameters headers:nil completion:completion];
}

-(void) transactionWithID:(NSString *)transactionID
               completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"transactions/%@", transactionID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:completion];
}

-(void) transactionWithID:(NSString *)transactionID
                accountID:(NSString *)accountID
               completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"account_id" : accountID
                                 };

    NSString *path = [NSString stringWithFormat:@"transactions/%@", transactionID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:parameters headers:nil completion:completion];
}

-(void) sendAmount:(double)amount
                to:(NSString *)to
        completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"transaction" :
                                     @{@"to" : to,
                                       @"amount": [[NSNumber numberWithDouble:amount] stringValue]
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"transactions/send_money" parameters:parameters headers:nil completion:completion];
}

-(void) sendAmount:(double)amount
                to:(NSString *)to
             notes:(NSString *)notes
           userFee:(double)userFee
        referrerID:(NSString *)referrerID
              idem:(NSString *)idem
        instantBuy:(BOOL)instantBuy
           orderID:(NSString *)orderID
         accountID:(NSString *)accountID
        completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"transaction" :
                                     @{@"to" : to,
                                       @"amount": [[NSNumber numberWithDouble:amount] stringValue],
                                       @"notes" :notes,
                                       @"user_fee" : userFee ? @"true" : @"false",
                                       @"referrer_id" : referrerID,
                                       @"idem" : idem,
                                       @"instant_buy" : instantBuy ? @"true" : @"false",
                                       @"order_id" : orderID,
                                       @"account_id" : accountID
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"transactions/send_money" parameters:parameters headers:nil completion:completion];
}

-(void) sendAmount:(double)amount
 amountCurrencyISO:(NSString *)amountCurrencyISO
                to:(NSString *)to
             notes:(NSString *)notes
           userFee:(double)userFee
        referrerID:(NSString *)referrerID
              idem:(NSString *)idem
        instantBuy:(BOOL)instantBuy
           orderID:(NSString *)orderID
         accountID:(NSString *)accountID
        completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"transaction" :
                                     @{@"to" : to,
                                       @"amount": [[NSNumber numberWithDouble:amount] stringValue],
                                       @"amount_currency_iso" : amountCurrencyISO,
                                       @"notes" :notes,
                                       @"user_fee" : userFee ? @"true" : @"false",
                                       @"referrer_id" : referrerID,
                                       @"idem" : idem,
                                       @"instant_buy" : instantBuy ? @"true" : @"false",
                                       @"order_id" : orderID,
                                       @"account_id" : accountID
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"transactions/send_money" parameters:parameters headers:nil completion:completion];
}

-(void) transferAmount:(double)amount
                    to:(NSString *)to
            completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"transaction" :
                                     @{@"to" : to,
                                       @"amount": [[NSNumber numberWithDouble:amount] stringValue]
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"transactions/transfer_money" parameters:parameters headers:nil completion:completion];
}

-(void) transferAmount:(double)amount
                    to:(NSString *)to
             accountID:(NSString *)accountID
            completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"transaction" :
                                     @{@"to" : to,
                                       @"amount": [[NSNumber numberWithDouble:amount] stringValue],
                                       @"account_id" : accountID
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"transactions/transfer_money" parameters:parameters headers:nil completion:completion];
}

-(void) requestAmount:(double)amount
                 from:(NSString *)from
           completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"transaction" :
                                     @{@"from" : from,
                                       @"amount": [[NSNumber numberWithDouble:amount] stringValue]
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"transactions/request_money" parameters:parameters headers:nil completion:completion];
}

-(void) requestAmount:(double)amount
                 from:(NSString *)from
                notes:(NSString *)notes
            accountID:(NSString *)accountID
           completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"transaction" :
                                     @{@"from" : from,
                                       @"amount": [[NSNumber numberWithDouble:amount] stringValue],
                                       @"notes" :notes,
                                       @"account_id" : accountID
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"transactions/request_money" parameters:parameters headers:nil completion:completion];

}

-(void) requestAmount:(double)amount
    amountCurrencyISO:(NSString *)amountCurrencyISO
                 from:(NSString *)from
                notes:(NSString *)notes
            accountID:(NSString *)accountID
           completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"transaction" :
                                     @{@"from" : from,
                                       @"amount": [[NSNumber numberWithDouble:amount] stringValue],
                                       @"amount_currency_iso" : amountCurrencyISO,
                                       @"notes" :notes,
                                       @"account_id" : accountID
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"transactions/request_money" parameters:parameters headers:nil completion:completion];
}

-(void) resendRequestWithID:(NSString *)transactionID
                 completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"transactions/%@/resend_request", transactionID];

    [self doRequestType:CoinbaseRequestTypePut path:path parameters:nil headers:nil completion:completion];
}

-(void) resendRequestWithID:(NSString *)transactionID
                  accountID:(NSString *)accountID
                 completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"account_id" : accountID
                                 };

    NSString *path = [NSString stringWithFormat:@"transactions/%@/resend_request", transactionID];

    [self doRequestType:CoinbaseRequestTypePut path:path parameters:parameters headers:nil completion:completion];
}

-(void) completeRequestWithID:(NSString *)transactionID
                   completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"transactions/%@/complete_request", transactionID];

    [self doRequestType:CoinbaseRequestTypePut path:path parameters:nil headers:nil completion:completion];
}

-(void) completeRequestWithID:(NSString *)transactionID
                    accountID:(NSString *)accountID
                   completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"account_id" : accountID
                                 };

    NSString *path = [NSString stringWithFormat:@"transactions/%@/complete_request", transactionID];

    [self doRequestType:CoinbaseRequestTypePut path:path parameters:parameters headers:nil completion:completion];
}

-(void) cancelRequestWithID:(NSString *)transactionID
                 completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"transactions/%@/cancel_request", transactionID];

    [self doRequestType:CoinbaseRequestTypePut path:path parameters:nil headers:nil completion:completion];
}

-(void) cancelRequestWithID:(NSString *)transactionID
                  accountID:(NSString *)accountID
                 completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"account_id" : accountID
                                 };

    NSString *path = [NSString stringWithFormat:@"transactions/%@/cancel_request", transactionID];

    [self doRequestType:CoinbaseRequestTypePut path:path parameters:parameters headers:nil completion:completion];
}


#pragma mark - Transfers

-(void) getTransfers:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"transfers" parameters:nil headers:nil completion:completion];
}

-(void) getTransfersWithPage:(NSUInteger)page
                       limit:(NSUInteger)limit
                   accountID:(NSString *)accountID
                  completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"page" : [@(page) stringValue],
                                 @"limit" : [@(limit)  stringValue],
                                 @"account_id" : accountID
                                 };

    [self doRequestType:CoinbaseRequestTypeGet path:@"transfers" parameters:parameters headers:nil completion:completion];
}

-(void) transferWithID:(NSString *)transferID
            completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"transfers/%@", transferID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:nil headers:nil completion:completion];
}

-(void) transferWithID:(NSString *)transferID
             accountID:(NSString *)accountID
            completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"account_id" : accountID
                                 };

    NSString *path = [NSString stringWithFormat:@"transfers/%@", transferID];

    [self doRequestType:CoinbaseRequestTypeGet path:path parameters:parameters headers:nil completion:completion];
}

-(void) commitTransferWithID:(NSString *)transferID
                  completion:(CoinbaseCompletionBlock)completion
{
    NSString *path = [NSString stringWithFormat:@"transfers/%@/commit", transferID];

    [self doRequestType:CoinbaseRequestTypePost path:path parameters:nil headers:nil completion:completion];
}

-(void) commitTransferWithID:(NSString *)transferID
                   accountID:(NSString *)accountID
                  completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"account_id" : accountID
                                 };

    NSString *path = [NSString stringWithFormat:@"transfers/%@/commit", transferID];

    [self doRequestType:CoinbaseRequestTypePost path:path parameters:parameters headers:nil completion:completion];
}

#pragma mark - Users

-(void) getCurrentUser:(CoinbaseCompletionBlock)completion
{
    [self doRequestType:CoinbaseRequestTypeGet path:@"users/self" parameters:nil headers:nil completion:completion];
}

-(void) modifyCurrentUserName:(NSString *)name
                   completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"user" :
                                     @{@"name" : name,
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePut path:@"users/self" parameters:parameters headers:nil completion:completion];
}

-(void) modifyCurrentUserNativeCurrency:(NSString *)nativeCurrency
                             completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"user" :
                                     @{@"native_currency" : nativeCurrency,
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePut path:@"users/self" parameters:parameters headers:nil completion:completion];

}

-(void) modifyCurrentUserTimeZone:(NSString *)timeZone
                       completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"user" :
                                     @{@"time_zone" : timeZone,
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePut path:@"users/self" parameters:parameters headers:nil completion:completion];

}

-(void) modifyCurrentUserName:(NSString *)name
               nativeCurrency:(NSString *)nativeCurrency
                     timeZone:(NSString *)timeZone
                   completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{@"user" :
                                     @{@"name" : name,
                                       @"native_currency" : nativeCurrency,
                                       @"time_zone" : timeZone
                                       }
                                 };

    [self doRequestType:CoinbaseRequestTypePut path:@"users/self" parameters:parameters headers:nil completion:completion];
}

#pragma mark - Withdrawals

-(void) withdrawAmount:(double)amount
             accountID:(NSString *)accountID
       paymentMethodID:(NSString *)paymentMethodID
            completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"amount" : [[NSNumber numberWithDouble:amount] stringValue],
                                 @"payment_method_id" : paymentMethodID,
                                 @"account_id" : accountID
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"withdrawals" parameters:parameters headers:nil completion:completion];
}

-(void) withdrawAmount:(double)amount
             accountID:(NSString *)accountID
       paymentMethodID:(NSString *)paymentMethodID
                commit:(BOOL)commit
            completion:(CoinbaseCompletionBlock)completion
{
    NSDictionary *parameters = @{
                                 @"amount" : [[NSNumber numberWithDouble:amount] stringValue],
                                 @"payment_method_id" : paymentMethodID,
                                 @"account_id" : accountID,
                                 @"commit" : commit ? @"true" : @"false"
                                 };

    [self doRequestType:CoinbaseRequestTypePost path:@"withdrawals" parameters:parameters headers:nil completion:completion];
}

#pragma mark -

+ (NSString *)URLEncodedStringFromString:(NSString *)string
{
    static CFStringRef charset = CFSTR("!@#$%&*()+'\";:=,/?[] ");
    CFStringRef str = (__bridge CFStringRef)string;
    CFStringEncoding encoding = kCFStringEncodingUTF8;
    return (NSString *)CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(NULL, str, NULL, charset, encoding));
}

@end
