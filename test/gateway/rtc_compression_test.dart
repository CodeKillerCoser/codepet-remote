import 'dart:convert';
import 'dart:typed_data';

import 'package:codepet_remote/gateway/webrtc/framing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'compression is negotiated, reduces large text, and bounds inflated data',
    () {
      final original = Uint8List.fromList(
        utf8.encode('中文🙂 conversation output ' * 20000),
      );
      final encoded = rtcEncodeMessage(original, true);
      expect(encoded.compressed, true);
      expect(encoded.bytes.length, lessThan(original.length ~/ 10));
      expect(rtcEncodeMessage(original, false).compressed, false);
      final frame = rtcFragment(
        encoded.bytes.length,
        0,
        encoded.bytes,
        compressed: true,
      );
      expect(() => RtcDecoder().push(frame), throwsFormatException);
      final small = RtcDecoder(maximum: 4096)..allowCompression = true;
      expect(() => small.push(frame), throwsFormatException);
      final decoder = RtcDecoder()..allowCompression = true;
      expect((decoder.push(frame) as RtcJson).bytes, original);
      final corrupt = Uint8List.fromList(encoded.bytes)..[0] = 0;
      expect(
        () => decoder.push(
          rtcFragment(corrupt.length, 0, corrupt, compressed: true),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'mixed encoding mid-message is rejected and close remains uncompressed',
    () {
      final decoder = RtcDecoder()..allowCompression = true;
      expect(decoder.push(rtcFragment(4, 0, [1, 2], compressed: true)), null);
      expect(
        () => decoder.push(rtcFragment(4, 2, [3, 4])),
        throwsFormatException,
      );
      expect(
        () => decoder.push(rtcFragment(0, 0, [3, 232], compressed: true)),
        throwsFormatException,
      );
      expect(decoder.push(rtcFragment(0, 0, [3, 232])), isA<RtcClose>());
    },
  );
}
