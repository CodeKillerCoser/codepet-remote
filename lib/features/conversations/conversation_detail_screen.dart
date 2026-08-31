import 'dart:async';

import 'package:flutter/material.dart';

import '../../gateway/gateway_client.dart';
import '../../gateway/models.dart';

class ConversationDetailScreen extends StatefulWidget {
  const ConversationDetailScreen({
    super.key,
    required this.client,
    required this.conversation,
  });

  final GatewayClient client;
  final ConversationSummary conversation;

  @override
  State<ConversationDetailScreen> createState() =>
      _ConversationDetailScreenState();
}

class _ConversationDetailScreenState extends State<ConversationDetailScreen> {
  final ScrollController _scrollController = ScrollController();
  final List<GatewayEvent> _pendingEvents = [];
  StreamSubscription<GatewayEvent>? _eventSubscription;
  ConversationDetail? _detail;
  String? _error;

  @override
  void initState() {
    super.initState();
    _eventSubscription = widget.client.events.listen(
      _applyEvent,
      onError: (Object error) {
        if (mounted) {
          setState(() {
            _error = '事件流异常：$error';
          });
        }
      },
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
    });
    try {
      var detail = await widget.client.getConversation(widget.conversation);
      for (final event in _pendingEvents) {
        detail = detail.apply(event);
      }
      _pendingEvents.clear();
      if (!mounted) {
        return;
      }
      setState(() {
        _detail = detail;
      });
      _scrollToBottom();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
        });
      }
    }
  }

  void _applyEvent(GatewayEvent event) {
    if (!mounted) {
      return;
    }
    final detail = _detail;
    if (detail == null) {
      _pendingEvents.add(event);
      return;
    }
    final next = detail.apply(event);
    if (identical(next, detail)) {
      return;
    }
    setState(() {
      _detail = next;
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _detail?.summary.title ?? widget.conversation.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final detail = _detail;
    if (detail == null && _error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (detail == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    return ListView(
      key: const Key('conversation-detail'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        _ConversationMetadata(summary: detail.summary),
        if (_error != null) ...[
          const SizedBox(height: 12),
          MaterialBanner(
            content: Text(_error!),
            actions: [
              TextButton(onPressed: _load, child: const Text('重新加载')),
            ],
          ),
        ],
        const SizedBox(height: 20),
        Text(
          '消息与事件',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 12),
        if (detail.messages.isEmpty)
          const _NoHistoryNotice()
        else
          for (final message in detail.messages) ...[
            _MessageBubble(message: message),
            const SizedBox(height: 10),
          ],
        if (detail.lastEventSequence != null) ...[
          const SizedBox(height: 6),
          Center(
            child: Text(
              '事件序号 ${detail.lastEventSequence}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ConversationMetadata extends StatelessWidget {
  const _ConversationMetadata({required this.summary});

  final ConversationSummary summary;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: summary.status == ConversationStatus.running
                        ? Colors.green
                        : colorScheme.outline,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _statusLabel(summary.status),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  summary.permissionLevel.wireValue,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            if (summary.preview != null && summary.preview!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(summary.preview!),
            ],
            if (summary.model != null || summary.reasoningEffort != null) ...[
              const SizedBox(height: 10),
              Text(
                [summary.model, summary.reasoningEffort]
                    .whereType<String>()
                    .join(' · '),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
            if (summary.workspaceRoot != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.folder_outlined, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      summary.workspaceRoot!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NoHistoryNotice extends StatelessWidget {
  const _NoHistoryNotice();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Gateway v1 当前不返回历史消息正文；这里会展示连接后收到的流式事件。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final GatewayMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.84,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: isUser
                ? colorScheme.primaryContainer
                : colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isUser ? 16 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isUser ? '你' : 'Host',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 4),
              Text(message.content),
              if (message.isStreaming) ...[
                const SizedBox(height: 8),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _statusLabel(ConversationStatus status) {
  return switch (status) {
    ConversationStatus.idle => '空闲',
    ConversationStatus.running => '运行中',
    ConversationStatus.waitingApproval => '等待审批',
    ConversationStatus.error => '错误',
    ConversationStatus.archived => '已归档',
  };
}
