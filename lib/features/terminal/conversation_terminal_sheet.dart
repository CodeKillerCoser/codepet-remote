import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../application/terminal/terminal_session_controller.dart';
import '../../ui/layout/app_layout.dart';
import '../../ui/theme/app_terminal_theme.dart';
import '../common/snap_bottom_sheet.dart';

Future<void> showConversationTerminal({
  required BuildContext context,
  required TerminalSessionController controller,
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await showSnapBottomSheet<void>(
    context: context,
    title: '电脑终端',
    builder: (_) => ConversationTerminalPane(controller: controller),
  );
}

class ConversationTerminalPane extends StatefulWidget {
  const ConversationTerminalPane({super.key, required this.controller});
  final TerminalSessionController controller;
  @override
  State<ConversationTerminalPane> createState() =>
      _ConversationTerminalPaneState();
}

class _ConversationTerminalPaneState extends State<ConversationTerminalPane>
    with WidgetsBindingObserver {
  final _focus = FocusNode();
  bool _attached = false;
  TerminalSessionController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_changed);
    _attach();
  }

  void _attach() {
    if (_attached) return;
    _attached = true;
    controller.attach();
  }

  void _detach() {
    if (!_attached) return;
    _attached = false;
    controller.detach();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _attach();
    } else {
      _detach();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_changed);
    _detach();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxHeight < 140;
      final status = controller.status;
      final busy =
          status == TerminalSessionStatus.opening ||
          status == TerminalSessionStatus.closing;
      final exited = status == TerminalSessionStatus.exited;
      final failed = status == TerminalSessionStatus.failed;
      final text =
          controller.error ??
          switch (status) {
            TerminalSessionStatus.idle => '准备终端',
            TerminalSessionStatus.opening => '正在打开电脑终端…',
            TerminalSessionStatus.running => controller.info?.cwd ?? '已连接',
            TerminalSessionStatus.offline => '等待电脑重新连接',
            TerminalSessionStatus.failed => '终端暂时不可用',
            TerminalSessionStatus.exited => '终端已结束',
            TerminalSessionStatus.closing => '正在结束终端…',
            TerminalSessionStatus.unsupported => '请更新电脑端以使用终端',
          };
      return Column(
        children: [
          SizedBox(
            height: AppLayout.compactControlHeight,
            child: Padding(
              padding: const EdgeInsets.only(left: AppLayout.space12),
              child: Row(
                children: [
                  if (busy) ...[
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Tooltip(
                      message: text,
                      child: Text(
                        text,
                        key: const Key('terminal-status'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                  if ((failed || status == TerminalSessionStatus.unsupported) &&
                      !controller.hasSession)
                    TextButton(
                      onPressed: () => unawaited(controller.retry()),
                      child: const Text('重试'),
                    ),
                  if (exited || failed && controller.hasSession)
                    TextButton(
                      key: const Key('restart-terminal'),
                      onPressed: () => unawaited(controller.restart()),
                      child: const Text('新建终端'),
                    ),
                  if (controller.hasSession && !exited)
                    PopupMenuButton<String>(
                      tooltip: '终端操作',
                      enabled: !busy,
                      onSelected: (_) => unawaited(controller.end()),
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'end', child: Text('结束终端')),
                      ],
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: TerminalView(
              controller.terminal,
              key: ObjectKey(controller.terminal),
              focusNode: _focus,
              readOnly: !controller.canInput,
              textStyle: AppTerminalTheme.textStyle(context),
              keyboardType: TextInputType.multiline,
              padding: const EdgeInsets.all(AppLayout.space8),
            ),
          ),
          if (!compact)
            SizedBox(
              height: AppLayout.controlHeight,
              child: Row(
                children: [
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final entry in const {
                          'Esc': TerminalKey.escape,
                          'Tab': TerminalKey.tab,
                          'Ctrl+C': TerminalKey.keyC,
                          '↑': TerminalKey.arrowUp,
                          '↓': TerminalKey.arrowDown,
                          '←': TerminalKey.arrowLeft,
                          '→': TerminalKey.arrowRight,
                        }.entries)
                          TextButton(
                            onPressed: controller.canInput
                                ? () {
                                    controller.terminal.keyInput(
                                      entry.value,
                                      ctrl: entry.key == 'Ctrl+C',
                                    );
                                    _focus.requestFocus();
                                  }
                                : null,
                            child: Text(entry.key),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('terminal-keyboard'),
                    tooltip: '显示或隐藏键盘',
                    onPressed: controller.canInput
                        ? () {
                            if (_focus.hasFocus) {
                              _focus.unfocus();
                            } else {
                              _focus.requestFocus();
                            }
                          }
                        : null,
                    icon: const Icon(Icons.keyboard_outlined),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}
