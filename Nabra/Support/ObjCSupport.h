#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>

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

/// From the local transcribe.cpp patch: the decoder attention heads that follow the audio, as
/// (layer, head) pairs. While set, decodes on the calling thread report each token through
/// `transcribe_get_token` with its probability and the time it was heard at. Pass NULL, 0 to stop.
void transcribe_cohere_set_alignment_heads(const int32_t * _Nullable layer_head_pairs, int n_pairs);

/// From the local transcribe.cpp patch: while set, decodes on the calling thread are fed exactly
/// these token ids instead of choosing their own, and report how probable the model finds each one
/// for the audio. Pass NULL, 0 to return to normal decoding.
void transcribe_cohere_set_forced_tokens(const int32_t * _Nullable ids, int n);

/// From the local transcribe.cpp patch: log-probability the most recent decode on the calling thread
/// gave to ending where it ended (NaN when unknown).
float transcribe_cohere_last_end_logprob(void);

/// Matches `ggml_abort_callback`; `data` must be a `NabraFlag *`.
bool NabraAbortCallback(void * _Nullable data);

NS_ASSUME_NONNULL_END
