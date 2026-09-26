//
//  SpliceKitSentry.m
//  mikagosz: Sentry usunięty. Atrapa zachowuje symbole z SpliceKitSentry.h,
//  żeby reszta kodu się linkowała, ale nic nie zbiera i nic nie wysyła.
//  SpliceKit.m widzi RuntimeEnabled == NO i włącza lokalny zapis awarii.
//

#import "SpliceKitSentry.h"

BOOL SpliceKit_sentryRuntimeEnabled(void) {
    return NO;
}

NSDictionary *SpliceKit_sentryRuntimeStatus(void) {
    return @{@"enabled": @NO, @"removed": @YES};
}

void SpliceKit_sentryStartRuntime(void) {}
void SpliceKit_sentrySetLaunchPhase(NSString *phase) {}
void SpliceKit_sentrySetLastRPCMethod(NSString *method) {}
void SpliceKit_sentryAddBreadcrumb(NSString *category, NSString *message, NSDictionary *data) {}
void SpliceKit_sentryLog(NSString *message, NSString *category, NSDictionary *attributes) {}
void SpliceKit_sentryCaptureMessage(NSString *message, NSString *context, NSDictionary *data) {}
void SpliceKit_sentryCaptureException(NSException *exception, NSString *context, NSDictionary *data) {}
void SpliceKit_sentryCaptureNSError(NSError *error, NSString *context, NSDictionary *data) {}
