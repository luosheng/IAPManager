//
//  IAPManager.m
//  Classes
//
//  Created by Marcel Ruegenberg on 22.11.12.
//  Copyright (c) 2012 Dustlab. All rights reserved.
//

#import "IAPManager.h"

NSString *const IAPManagerIncreaseWaitingCountNotification = @"tc.tangcha.iap.inrease";
NSString *const IAPManagerDecreaseWaitingCountNotification = @"tc.tangcha.iap.derease";

@interface IAPManager () <SKProductsRequestDelegate, SKPaymentTransactionObserver>

@property (strong) NSMutableDictionary *products;

@property (strong) NSMutableArray *productRequests;
@property (strong) NSMutableArray *payments;

@property (strong) NSMutableArray *purchasesChangedCallbacks;

@property (copy) RestorePurchasesCompletionBlock restoreCompletionBlock;

@end

@implementation IAPManager

+ (IAPManager *)sharedIAPManager {
    static IAPManager *sharedInstance;
    if (sharedInstance == nil) sharedInstance = [IAPManager new];
    return sharedInstance;
}

- (id)init {
    if ((self = [super init])) {
        [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
        self.products = [NSMutableDictionary dictionary];
        self.productRequests = [NSMutableArray array];
        self.payments = [NSMutableArray array];
        self.purchasesChangedCallbacks = [NSMutableArray array];
    }
    return self;
}

#pragma mark - Product Information

- (void)getProductsForIds:(NSArray *)productIds completion:(ProductsCompletionBlock)completionBlock {
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *remainingIds = [NSMutableSet set];
    for (NSString *productId in productIds) {
        if ([self.products objectForKey:productId]) [result addObject:[self.products objectForKey:productId]];
        else [remainingIds addObject:productId];
    }

    if ([remainingIds count] == 0) {
        completionBlock(result);
        return;
    }

    SKProductsRequest *req = [[SKProductsRequest alloc] initWithProductIdentifiers:remainingIds];
    req.delegate = self;
    [self.productRequests addObject:@[req, completionBlock]];
    [req start];
}

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
    NSUInteger c = [self.productRequests count];
    for (int i = 0; i < c; ++i) {
        NSArray *tuple = [self.productRequests objectAtIndex:i];
        if ([tuple objectAtIndex:0] == request) {
            ProductsCompletionBlock completion = [tuple objectAtIndex:1];
            completion(response.products);
            [self.productRequests removeObjectAtIndex:i];
            return;
        }
    }
}

#pragma mark - Purchase

- (void)restorePurchases {
    [self restorePurchasesWithCompletion:nil];
}

- (void)restorePurchasesWithCompletion:(RestorePurchasesCompletionBlock)completionBlock {
    [[NSNotificationCenter defaultCenter] postNotificationName:IAPManagerIncreaseWaitingCountNotification object:nil];
    self.restoreCompletionBlock = completionBlock;
    return [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
}

- (void)purchaseProduct:(SKProduct *)product completion:(PurchaseCompletionBlock)completionBlock error:(ErrorBlock)err {
#ifdef SIMULATE_PURCHASES
    [self.purchasedItems addObject:product.productIdentifier];
    self.purchasedItemsChanged = YES;
    for (NSArray *t in self.purchasesChangedCallbacks) {
        PurchasedProductsChanged callback = t[0];
        callback();
    }
    completionBlock(NULL);
#else
    if (![SKPaymentQueue canMakePayments]) err([NSError errorWithDomain:@"IAPManager" code:0 userInfo:[NSDictionary dictionaryWithObject:@"Can't make payments" forKey:NSLocalizedDescriptionKey]]);
    else {
        SKPayment *payment = [SKPayment paymentWithProduct:product];
        [self.payments addObject:@[payment.productIdentifier, completionBlock, err]];
        [[SKPaymentQueue defaultQueue] addPayment:payment];
    }
#endif
}

- (void)purchaseProductForId:(NSString *)productId completion:(PurchaseCompletionBlock)completionBlock error:(ErrorBlock)err {
#ifdef SIMULATE_PURCHASES
    [self.purchasedItems addObject:productId];
    self.purchasedItemsChanged = YES;
    for (NSArray *t in self.purchasesChangedCallbacks) {
        PurchasedProductsChanged callback = t[0];
        callback();
    }
    completionBlock(NULL);
#else
    [self getProductsForIds:@[productId] completion:^(NSArray *products) {
        if ([products count] == 0) err([NSError errorWithDomain:@"IAPManager" code:0 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Didn't find products with ID %@", productId] forKey:NSLocalizedDescriptionKey]]);
        else [self purchaseProduct:[products objectAtIndex:0] completion:completionBlock error:err];
    }];
#endif
}

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions {
    for (SKPaymentTransaction *transaction in transactions) {
        NSUInteger c = [self.payments count];
        PurchaseCompletionBlock completion = nil;
        ErrorBlock err = nil;
        for (int i = 0; i < c; ++i) {
            NSArray *t = [self.payments objectAtIndex:i];
            if ([t[0] isEqual:transaction.payment.productIdentifier]) {
                completion = t[1];
                err = t[2];
                break;
            }
        }


        if (transaction.transactionState == SKPaymentTransactionStatePurchasing) {
            [[NSNotificationCenter defaultCenter] postNotificationName:IAPManagerIncreaseWaitingCountNotification object:nil];
        } else {
            [queue finishTransaction:transaction];
            
            if (transaction.transactionState == SKPaymentTransactionStatePurchased) {
                for (NSArray *t in self.purchasesChangedCallbacks) {
                    PurchasedProductsChanged callback = t[0];
                    callback();
                }
                if (completion) completion(transaction);
                [[NSNotificationCenter defaultCenter] postNotificationName:IAPManagerDecreaseWaitingCountNotification object:nil];
            } else if (transaction.transactionState == SKPaymentTransactionStateFailed) {
                if (err) err(transaction.error);
                [[NSNotificationCenter defaultCenter] postNotificationName:IAPManagerDecreaseWaitingCountNotification object:nil];
            }
        }
    }
}

- (BOOL)canPurchase {
    return [SKPaymentQueue canMakePayments];
}

#pragma mark - Observation

- (void)addPurchasesChangedCallback:(PurchasedProductsChanged)callback withContext:(id)context {
    [self.purchasesChangedCallbacks addObject:@[callback, context]];
}

- (void)removePurchasesChangedCallbackWithContext:(id)context {
    NSUInteger c = [self.purchasesChangedCallbacks count];
    for (int i = c - 1; i >= 0; --c) {
        NSArray *t = self.purchasesChangedCallbacks[i];
        if (t[1] == context) {
            [self.purchasesChangedCallbacks removeObjectAtIndex:i];
        }
    }
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue {
    if (self.restoreCompletionBlock) {
        self.restoreCompletionBlock(queue.transactions);
    }
    self.restoreCompletionBlock = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:IAPManagerDecreaseWaitingCountNotification object:nil];
}

- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error {
    [[NSNotificationCenter defaultCenter] postNotificationName:IAPManagerDecreaseWaitingCountNotification object:nil];
}

- (void)paymentQueue:(SKPaymentQueue *)queue removedTransactions:(NSArray *)transactions {
    for (SKPaymentTransaction *transaction in transactions) {
        NSUInteger c = [self.payments count];
        for (int i = 0; i < c; ++i) {
            NSArray *t = [self.payments objectAtIndex:i];
            if ([t[0] isEqual:transaction.payment.productIdentifier]) {
                [self.payments removeObjectAtIndex:i];
                break;
            }
        }
    }
}

@end
