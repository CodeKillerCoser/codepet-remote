import 'dart:convert';
import 'dart:typed_data';

const rtcFrameBytes = 16 * 1024;
const rtcHeaderBytes = 12;
const rtcRequestBytes = 256 * 1024;
const rtcResponseBytes = 4 * 1024 * 1024;

Uint8List rtcFragment(int total, int offset, List<int> payload) {
  final frame = Uint8List(rtcHeaderBytes + payload.length);
  frame.setRange(0, 4, const [67, 80, 71, 49]);
  final header = ByteData.sublistView(frame);
  header.setUint32(4, total);
  header.setUint32(8, offset);
  frame.setRange(rtcHeaderBytes, frame.length, payload);
  return frame;
}

sealed class RtcEnvelope {}

final class RtcJson extends RtcEnvelope {
  RtcJson(this.bytes);
  final Uint8List bytes;
}

final class RtcClose extends RtcEnvelope {
  RtcClose(this.code, this.reason);
  final int code;
  final String reason;
}

/// CPG1 runs on one reliable ordered channel; messages never interleave.
class RtcDecoder {
  RtcDecoder({this.maximum = rtcResponseBytes});
  final int maximum;
  Uint8List? _partial;
  int _offset = 0;
  bool get pending => _partial != null;

  void clear() {
    _partial = null;
    _offset = 0;
  }

  RtcEnvelope? push(Uint8List frame) {
    if (frame.length <= rtcHeaderBytes ||
        frame.length > rtcFrameBytes ||
        frame[0] != 67 ||
        frame[1] != 80 ||
        frame[2] != 71 ||
        frame[3] != 49) {
      throw const FormatException('Invalid CPG1 frame');
    }
    final header = ByteData.sublistView(frame);
    final total = header.getUint32(4);
    final offset = header.getUint32(8);
    final payload = Uint8List.sublistView(frame, rtcHeaderBytes);
    if (total == 0) {
      if (offset != 0 || payload.length < 2 || payload.length > 125) {
        throw const FormatException('Invalid CPG1 close');
      }
      final code = ByteData.sublistView(payload).getUint16(0);
      final reason = utf8.decode(payload.sublist(2));
      clear();
      return RtcClose(code, reason);
    }
    if (total > maximum ||
        offset != _offset ||
        offset + payload.length > total ||
        (_partial != null && _partial!.length != total)) {
      throw const FormatException('Invalid CPG1 message bounds or offset');
    }
    _partial ??= Uint8List(total);
    _partial!.setRange(offset, offset + payload.length, payload);
    _offset += payload.length;
    if (_offset == total) {
      final result = RtcJson(_partial!);
      clear();
      return result;
    }
    return null;
  }
}
