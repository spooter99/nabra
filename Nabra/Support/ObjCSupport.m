#import "ObjCSupport.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

BOOL NabraTryObjC(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"app.nabra.objc"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason ?: @"Unknown Objective-C exception"}];
        }
        return NO;
    }
}

struct NabraFlag {
    atomic_bool value;
};

NabraFlag *NabraFlagCreate(void) {
    NabraFlag *flag = malloc(sizeof(NabraFlag));
    atomic_init(&flag->value, false);
    return flag;
}

void NabraFlagDestroy(NabraFlag *flag) {
    free(flag);
}

void NabraFlagSet(NabraFlag *flag, bool value) {
    atomic_store(&flag->value, value);
}

bool NabraFlagGet(NabraFlag *flag) {
    return atomic_load(&flag->value);
}

bool NabraAbortCallback(void *data) {
    if (data == NULL) {
        return false;
    }
    return atomic_load(&((NabraFlag *)data)->value);
}
