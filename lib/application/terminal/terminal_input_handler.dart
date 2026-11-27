import 'package:xterm/core.dart';

/// xterm 4's keytab adapter uses appKeypadMode for AppCuKeys. DEC cursor
/// application mode is independent: handle plain cursor keys using the actual
/// DECCKM state, for both the software toolbar and hardware keyboard.
class TerminalCursorInputHandler implements TerminalInputHandler {
  const TerminalCursorInputHandler();
  @override
  String? call(TerminalKeyboardEvent event) {
    if (event.shift || event.alt || event.ctrl) return null;
    final suffix = switch (event.key) {
      TerminalKey.arrowUp => 'A',
      TerminalKey.arrowDown => 'B',
      TerminalKey.arrowRight => 'C',
      TerminalKey.arrowLeft => 'D',
      TerminalKey.home => 'H',
      TerminalKey.end => 'F',
      _ => null,
    };
    if (suffix == null) return null;
    return event.state.cursorKeysMode ? '\x1bO$suffix' : '\x1b[$suffix';
  }
}
