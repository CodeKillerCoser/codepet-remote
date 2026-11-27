import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:codepet_remote/ui/theme/app_theme.dart';
import 'package:codepet_remote/application/terminal/terminal_session_controller.dart';
import 'package:codepet_remote/features/common/snap_bottom_sheet.dart';
import 'package:codepet_remote/features/terminal/conversation_terminal_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'terminal_test_gateway.dart';

void main() {
  setUpAll(() async {
    final font = Platform.environment['CODEPET_TERMINAL_PREVIEW_FONT'];
    if (font != null) {
      final bytes = ByteData.sublistView(await File(font).readAsBytes());
      for (final family in ['terminal-preview', 'monospace']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  for (final size in [
    const Size(320, 800),
    const Size(800, 360),
    const Size(1000, 900),
  ]) {
    testWidgets('standard sheet snaps and preserves terminal at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = TestTerminalGateway()
        ..emit(
          '\x1b[32m~/codepet\x1b[0m \$ git status\r\nOn branch main\r\n\x1b[32m电脑终端输出已同步\x1b[0m\r\n',
        );
      final controller = TerminalSessionController(gateway: () => gateway);
      final previewKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: previewKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _previewTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showConversationTerminal(
                    context: context,
                    controller: controller,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      expect(find.byType(TerminalView), findsOneWidget);
      expect(find.text('小半屏'), findsNothing);
      expect(find.text('大半屏'), findsNothing);
      expect(find.byType(SegmentedButton<SnapSheetSize>), findsNothing);
      expect(
        find.byKey(const Key('toggle-snap-sheet-fullscreen')),
        findsOneWidget,
      );
      final model = controller.terminal;
      final sheet = find.byKey(const Key('snap-bottom-sheet'));
      final smallHeight = tester.getSize(sheet).height;
      await _capture(tester, previewKey, '${size.width.toInt()}-small');
      // Fullscreen from small restores small, without a visible size selector.
      await tester.tap(find.byKey(const Key('toggle-snap-sheet-fullscreen')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.tap(find.byKey(const Key('toggle-snap-sheet-fullscreen')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(tester.getSize(sheet).height, closeTo(smallHeight, 1));
      await tester.drag(
        find.byKey(const Key('snap-sheet-drag-handle')),
        Offset(0, -size.height * .35),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(tester.getSize(sheet).height, greaterThan(smallHeight));
      await _capture(tester, previewKey, '${size.width.toInt()}-large');
      final largeHeight = tester.getSize(sheet).height;
      await tester.tap(find.byKey(const Key('toggle-snap-sheet-fullscreen')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(tester.getSize(sheet).height, closeTo(size.height, 1));
      await _capture(tester, previewKey, '${size.width.toInt()}-full');
      await tester.tap(find.byKey(const Key('toggle-snap-sheet-fullscreen')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(tester.getSize(sheet).height, closeTo(largeHeight, 1));
      await tester.tap(find.byKey(const Key('toggle-snap-sheet-fullscreen')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(controller.terminal, same(model));
      expect(gateway.opens, 1);
      expect(gateway.sizes, isNotEmpty);
      // Drag the official attached handle, independently of terminal scroll.
      await tester.drag(
        find.byKey(const Key('snap-sheet-drag-handle')),
        Offset(0, size.height * .8),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(tester.getSize(sheet).height, lessThan(size.height));
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding(bottom: size.height * .4);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.getBottomRight(find.byType(TerminalView)).dy,
        lessThanOrEqualTo(size.height * .6 + 1),
      );
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pump();
      await tester.tap(find.byKey(const Key('close-snap-sheet')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('open'), findsOneWidget);
      expect(gateway.closes, 0);
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(controller.terminal, same(model));
      expect(gateway.opens, 1);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.pump();
    });
  }

  testWidgets(
    'keyboard and large text keep controls visible without moving terminal focus',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = TestTerminalGateway();
      final controller = TerminalSessionController(gateway: () => gateway);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              viewInsets: EdgeInsets.only(bottom: 300),
              textScaler: TextScaler.linear(1.3),
            ),
            child: SnapBottomSheet(
              title: '电脑终端',
              builder: (_) => ConversationTerminalPane(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final terminal = tester.widget<TerminalView>(find.byType(TerminalView));
      terminal.focusNode!.requestFocus();
      await tester.pump();
      await tester.tap(find.byKey(const Key('toggle-snap-sheet-fullscreen')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(terminal.focusNode!.hasFocus, isTrue);
      expect(find.byKey(const Key('close-snap-sheet')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.pump();
    },
  );
}

ThemeData _previewTheme() =>
    Platform.environment['CODEPET_TERMINAL_PREVIEW_FONT'] == null
    ? AppTheme.light
    : AppTheme.light.copyWith(
        textTheme: AppTheme.light.textTheme.apply(
          fontFamily: 'terminal-preview',
        ),
        textButtonTheme: TextButtonThemeData(
          style: AppTheme.light.textButtonTheme.style?.copyWith(
            textStyle: WidgetStatePropertyAll(
              AppTheme.light.textTheme.labelLarge!.copyWith(
                fontFamily: 'terminal-preview',
              ),
            ),
          ),
        ),
      );

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['CODEPET_TERMINAL_PREVIEW_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
