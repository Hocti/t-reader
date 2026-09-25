import 'package:flutter/services.dart';

const _channel = MethodChannel('epub_reader/screen');

enum ScreenTurn { auto, portrait, landscape, landscapeFlipped }

/// Null brightness hands it back to the system.
Future<void> setScreenBrightness(double? value) async {
  try {
    await _channel.invokeMethod<void>('brightness', value ?? -1.0);
  } catch (_) {}
}

/// The system brightness from 0 to 1, for the bar's first position. Null when unknown.
Future<double?> systemBrightness() async {
  try {
    final value = await _channel.invokeMethod<double>('systemBrightness');
    return value?.clamp(0.0, 1.0);
  } catch (_) {
    return null;
  }
}

Future<void> keepScreenOn(bool on) async {
  try {
    await _channel.invokeMethod<void>('keepOn', on);
  } catch (_) {}
}

Future<void> applyScreenTurn(ScreenTurn turn) async {
  final orientations = switch (turn) {
    ScreenTurn.auto => const <DeviceOrientation>[],
    ScreenTurn.portrait => const [DeviceOrientation.portraitUp],
    ScreenTurn.landscape => const [DeviceOrientation.landscapeLeft],
    ScreenTurn.landscapeFlipped => const [DeviceOrientation.landscapeRight],
  };
  try {
    await SystemChrome.setPreferredOrientations(orientations);
  } catch (_) {}
}
