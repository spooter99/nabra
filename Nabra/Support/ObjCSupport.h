#import <Foundation/Foundation.h>
#include <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and converts any Objective-C exception into an NSError.
/// AVAudioEngine raises NSExceptions (not Swift errors) for format mismatches, which Swift cannot catch.
BOOL NabraTryObjC(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error);

/// A lock-free flag that can be shared with C callbacks (used to abort a running decode).
typedef struct NabraFlag NabraFlag;
NabraFlag *NabraFlagCreate(void);
void NabraFlagDestroy(NabraFlag *flag);
void NabraFlagSet(NabraFlag *flag, bool value);
bool NabraFlagGet(NabraFlag *flag);

/// From the local transcribe.cpp patch: mean log-probability of the tokens produced by the most
/// recent decode on the calling thread (0 when unavailable). Closer to 0 means more confident.
float transcribe_cohere_last_avg_logprob(void);

/// From the local transcribe.cpp patch: when true, the next decode on the calling thread reuses the
/// encoder output of the previous one (same audio, different language hint).
void transcribe_cohere_set_reuse_encoder(bool reuse);

/// Matches `ggml_abort_callback`; `data` must be a `NabraFlag *`.
bool NabraAbortCallback(void * _Nullable data);

NS_ASSUME_NONNULL_END
