#import "mfrx_audio.h"
#import <AVFAudio/AVFAudio.h>

NSString *mfrx_audio_connect(AVAudioEngine *engine, AVAudioPlayerNode *player, AVAudioFormat *format) {
    @try {
        [engine connect:player to:engine.mainMixerNode format:format];
        return nil;
    } @catch (NSException *exception) {
        return exception.reason ?: exception.name;
    }
}

NSString *mfrx_audio_start(AVAudioEngine *engine, AVAudioPlayerNode *player) {
    @try {
        NSError *error = nil;
        if (![engine startAndReturnError:&error]) {
            return error.localizedDescription ?: @"avvio del motore audio rifiutato";
        }
        [player play];
        return nil;
    } @catch (NSException *exception) {
        return exception.reason ?: exception.name;
    }
}
