import 'dart:typed_data';
import 'dart:ui' as ui;

/// Grid covers are at most this wide in pixels.
const coverThumbWidth = 360;

/// A PNG no wider than [coverThumbWidth]. The original bytes come back if decoding fails.
Future<Uint8List> makeCoverThumbnail(Uint8List bytes) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    if (width <= coverThumbWidth) {
      descriptor.dispose();
      buffer.dispose();
      return bytes;
    }
    final codec = await descriptor.instantiateCodec(targetWidth: coverThumbWidth);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    if (data == null) return bytes;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    return bytes;
  }
}
