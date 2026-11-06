import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

/// Captured synchronously at the producer, before any writer queue or channel.
final class LogContext {
  static final int? Function() _threadId = _nativeThreadIdReader();
  static final _frame = RegExp(r'\((.+\.dart):(\d+)(?::\d+)?\)$');

  static Map<String, Object?> capture(StackTrace stack) {
    String? file;
    int? line;
    for (final frame in stack.toString().split('\n')) {
      final match = _frame.firstMatch(frame.trim());
      if (match == null) continue;
      final uri = match.group(1)!;
      if (uri.startsWith('dart:') ||
          uri.contains('/diagnostics/app_log.dart') ||
          uri.contains('/diagnostics/log_context.dart') ||
          uri.contains('/gateway/webrtc/rtc_diagnostics.dart') ||
          uri.contains('package:logging/')) {
        continue;
      }
      file = uri;
      line = int.tryParse(match.group(2)!);
      break;
    }
    return {
      'pid': pid,
      'threadId': _threadId(),
      'isolate': Isolate.current.debugName ?? 'unnamed',
      'sourceFile': file,
      'sourceLine': line,
    };
  }

  // Keep native platform details inside this adapter, not business call sites.
  // FFI must run on the calling thread; a MethodChannel would report its handler.
  static int? Function() _nativeThreadIdReader() {
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        return DynamicLibrary.process()
            .lookupFunction<Int32 Function(), int Function()>('gettid');
      }
      if (Platform.isMacOS || Platform.isIOS) {
        final library = DynamicLibrary.process();
        final self = library
            .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
              'pthread_self',
            );
        final thread = library
            .lookupFunction<
              Uint32 Function(Pointer<Void>),
              int Function(Pointer<Void>)
            >('pthread_mach_thread_np');
        return () => thread(self());
      }
      if (Platform.isWindows) {
        return DynamicLibrary.open('kernel32.dll')
            .lookupFunction<Uint32 Function(), int Function()>(
              'GetCurrentThreadId',
            );
      }
    } catch (_) {
      // Missing platform symbols are metadata loss, never a logging failure.
    }
    return () => null;
  }
}
