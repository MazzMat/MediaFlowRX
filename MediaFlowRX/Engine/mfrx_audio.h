#import <Foundation/Foundation.h>

@class AVAudioEngine;
@class AVAudioPlayerNode;
@class AVAudioFormat;

NS_ASSUME_NONNULL_BEGIN

// nil when the connection succeeds, otherwise the reason. The macOS 14 APIs throw
// NSException instead of returning an error, which would kill the main thread from Swift.
NSString *_Nullable mfrx_audio_connect(AVAudioEngine *engine, AVAudioPlayerNode *player, AVAudioFormat *format);
NSString *_Nullable mfrx_audio_start(AVAudioEngine *engine, AVAudioPlayerNode *player);

NS_ASSUME_NONNULL_END
