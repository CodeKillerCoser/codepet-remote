import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/conversations/recent_conversation_controller.dart';
import '../../application/sessions/device_session.dart';
import '../../core/domain/models.dart';
import '../conversations/widgets/conversation_list_item.dart';

/// Recent's footer is observed after layout as well as on scroll, including
/// viewports where the first page is too short to produce a scroll event.
class RecentConversationFeed extends StatefulWidget {
  const RecentConversationFeed({
    super.key,
    required this.controller,
    required this.scrollController,
    required this.online,
    required this.onTap,
  });

  final RecentConversationController? controller;
  final ScrollController scrollController;
  final bool online;
  final ValueChanged<ConversationSummary> onTap;

  @override
  State<RecentConversationFeed> createState() => _RecentConversationFeedState();
}

class _RecentConversationFeedState extends State<RecentConversationFeed> {
  final _rowKeys = <String, GlobalKey>{};
  final _anchors = <(String, double)>[];
  bool _frameScheduled = false;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_changed);
    widget.scrollController.addListener(_scrolled);
  }

  @override
  void didUpdateWidget(RecentConversationFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?.removeListener(_changed);
      widget.controller?.addListener(_changed);
    }
    if (!identical(oldWidget.scrollController, widget.scrollController)) {
      oldWidget.scrollController.removeListener(_scrolled);
      widget.scrollController.addListener(_scrolled);
    }
    if (oldWidget.online && !widget.online) _captureAnchor();
  }

  void _changed() {
    if (!mounted) return;
    if (widget.controller?.refreshing == true && !_restoring) _captureAnchor();
    setState(() {});
  }

  void _captureAnchor() {
    if (!widget.scrollController.hasClients) return;
    final viewport = widget.scrollController.position.context.notificationContext
        ?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    final top = viewport.localToGlobal(Offset.zero).dy;
    final bottom = top + viewport.size.height;
    final rows = <(String, double, double)>[];
    for (final conversation in widget.controller?.conversations ?? <ConversationSummary>[]) {
      final id = conversationRoutingKey(conversation);
      final box = _rowKeys[id]?.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        final y = box.localToGlobal(Offset.zero).dy;
        rows.add((id, y, y + box.size.height));
      }
    }
    final first = rows.indexWhere((row) => row.$3 > top && row.$2 < bottom);
    if (first < 0) return;
    _anchors
      ..clear()
      ..addAll(rows.skip(first).map((row) => (row.$1, row.$2)))
      ..addAll(rows.take(first).toList().reversed.map((row) => (row.$1, row.$2)));
    widget.controller?.anchorIdentity = rows[first].$1;
    _restoring = true;
  }

  void _scrolled() {
    if (widget.controller?.refreshing == true || _restoring) _captureAnchor();
    _scheduleFrame();
  }

  void _scheduleFrame() {
    if (_frameScheduled) return;
    _frameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _frameScheduled = false;
      if (!mounted || !widget.scrollController.hasClients) return;
      final controller = widget.controller;
      if (_restoring && controller?.refreshing == false && controller?.error == null && widget.online) {
        for (final anchor in _anchors) {
          final box = _rowKeys[anchor.$1]?.currentContext?.findRenderObject();
          if (box is! RenderBox || !box.hasSize) continue;
          final delta = box.localToGlobal(Offset.zero).dy - anchor.$2;
          final position = widget.scrollController.position;
          final target = (position.pixels + delta)
              .clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
          _restoring = false;
          if ((position.pixels - target).abs() > 0.5) widget.scrollController.jumpTo(target);
          break;
        }
        // If every previous identity disappeared, retain the clamped offset.
        _restoring = false;
        _anchors.clear();
        controller?.anchorIdentity = null;
      }
      if (widget.online && controller?.canAutoLoadMore == true &&
          widget.scrollController.position.extentAfter < 240) {
        unawaited(controller!.loadMore());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleFrame();
    final controller = widget.controller;
    if (!widget.online) return const SizedBox.shrink();
    if (controller == null || !controller.supported) {
      return const ListTile(
        leading: Icon(Icons.info_outline),
        title: Text('当前 Gateway / Provider 不支持最近会话'),
        subtitle: Text('仍可从聊天或项目查看完整历史。'),
      );
    }
    final identities = controller.conversations.map(conversationRoutingKey).toSet();
    _rowKeys.removeWhere((id, _) => !identities.contains(id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final conversation in controller.conversations) ...[
          ConversationListItem(
            key: _rowKeys.putIfAbsent(conversationRoutingKey(conversation), GlobalKey.new),
            conversation: conversation,
            onTap: widget.onTap,
          ),
          const SizedBox(height: 8),
        ],
        if (controller.loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (controller.error != null)
          ListTile(
            title: const Text('最近会话加载失败'),
            subtitle: Text(controller.error.toString()),
            trailing: TextButton(
              key: const Key('retry-recent'),
              onPressed: controller.loading ? null : () => unawaited(controller.retry()),
              child: const Text('重试'),
            ),
          )
        else if (controller.loaded && controller.conversations.isEmpty)
          const ListTile(
            title: Text('暂无最近会话'),
            subtitle: Text('历史会话可从项目或聊天中查看。'),
          ),
      ],
    );
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_changed);
    widget.scrollController.removeListener(_scrolled);
    super.dispose();
  }
}
