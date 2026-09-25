import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';

/// What the open reader does when the system or a headset asks.
class SpeechControls {
  const SpeechControls({
    required this.play,
    required this.pause,
    required this.stop,
    required this.next,
    required this.previous,
  });

  final Future<void> Function() play;
  final Future<void> Function() pause;
  final Future<void> Function() stop;
  final Future<void> Function() next;
  final Future<void> Function() previous;
}

/// Android media session for speech. Previous and next move one sentence.
class SpeechMediaHandler extends BaseAudioHandler {
  SpeechControls? _controls;

  void attach(SpeechControls controls) => _controls = controls;

  void detach(SpeechControls controls) {
    if (!identical(_controls, controls)) return;
    _controls = null;
    idle();
  }

  void describe({required String title, String? chapter}) {
    mediaItem.add(MediaItem(id: 'reader', title: title, album: chapter));
  }

  void show({required bool playing}) {
    _silence(playing);
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.play,
          MediaAction.pause,
          MediaAction.playPause,
          MediaAction.stop,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: playing,
      ),
    );
  }

  void idle() {
    _silence(false);
    playbackState.add(PlaybackState(processingState: AudioProcessingState.idle, playing: false));
  }

  @override
  Future<void> play() async => _controls?.play();

  @override
  Future<void> pause() async => _controls?.pause();

  @override
  Future<void> stop() async => _controls?.stop();

  @override
  Future<void> skipToNext() async => _controls?.next();

  @override
  Future<void> skipToPrevious() async => _controls?.previous();
}

/// A silent track from this app while speech plays. Android sends headset buttons to the session
/// of the app playing audio, and the system voice plays from the TTS engine's process instead.
void _silence(bool on) {
  const MethodChannel('epub_reader/audio').invokeMethod<void>('silence', on).catchError((_) {});
}

SpeechMediaHandler? speechMedia;

/// Needs the Android service and activity from audio_service. Tests and other platforms skip it.
Future<void> initSpeechMedia({required String channelName}) async {
  try {
    speechMedia = await AudioService.init(
      builder: SpeechMediaHandler.new,
      config: AudioServiceConfig(
        androidNotificationChannelId: 'riverine.studio.epub.speech',
        androidNotificationChannelName: channelName,
      ),
    );
  } catch (_) {
    speechMedia = null;
  }
}
