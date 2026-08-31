import 'dart:async';

import 'package:flutter/material.dart';

import '../../gateway/gateway_client.dart';
import '../../gateway/models.dart';
import 'conversation_detail_screen.dart';

class ConversationListScreen extends StatefulWidget {
  const ConversationListScreen({
    super.key,
    required this.client,
    required this.handshake,
    required this.connection,
    required this.onDisconnect,
  });

  final GatewayClient client;
  final GatewayHandshake handshake;
  final DeviceConnection connection;
  final Future<void> Function() onDisconnect;

  @override
  State<ConversationListScreen> createState() =>
      _ConversationListScreenState();
}

class _ConversationListScreenState extends State<ConversationListScreen> {
  StreamSubscription<GatewayEvent>? _eventSubscription;
  List<ConversationSummary> _conversations = const [];
  bool _isLoading = true;
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
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final page = await widget.client.listConversations();
      if (!mounted) {
        return;
      }
      setState(() {
        _conversations = _sorted(page.conversations);
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _applyEvent(GatewayEvent event) {
    if (event is! ConversationUpsertedEvent || !mounted) {
      return;
    }
    final conversations = [..._conversations];
    final index = conversations.indexWhere(
      (conversation) => conversation.id == event.conversation.id,
    );
    if (index == -1) {
      conversations.add(event.conversation);
    } else {
      conversations[index] = event.conversation;
    }
    setState(() {
      _conversations = _sorted(conversations);
    });
  }

  List<ConversationSummary> _sorted(
    Iterable<ConversationSummary> conversations,
  ) {
    return conversations.toList(growable: false)
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
  }

  Future<void> _openConversation(ConversationSummary conversation) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => ConversationDetailScreen(
          client: widget.client,
          conversation: conversation,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('会话'),
        actions: [
          IconButton(
            tooltip: '断开连接',
            onPressed: widget.onDisconnect,
            icon: const Icon(Icons.link_off_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          _ConnectionBanner(
            deviceName: widget.connection.deviceName,
            serverName: widget.handshake.serverName,
            serverVersion: widget.handshake.serverVersion,
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading && _conversations.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _conversations.isEmpty) {
      return _ErrorState(message: _error!, onRetry: _load);
    }
    if (_conversations.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 160),
            Icon(Icons.forum_outlined, size: 44),
            SizedBox(height: 12),
            Center(child: Text('还没有可展示的会话')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        key: const Key('conversation-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _conversations.length + (_error == null ? 0 : 1),
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (_error != null && index == 0) {
            return MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(onPressed: _load, child: const Text('重试')),
              ],
            );
          }
          final dataIndex = _error == null ? index : index - 1;
          final conversation = _conversations[dataIndex];
          return _ConversationCard(
            conversation: conversation,
            onTap: () => _openConversation(conversation),
          );
        },
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({
    required this.deviceName,
    required this.serverName,
    required this.serverVersion,
  });

  final String deviceName;
  final String serverName;
  final String serverVersion;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, size: 18, color: colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  deviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  '$serverName · $serverVersion',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationCard extends StatelessWidget {
  const _ConversationCard({
    required this.conversation,
    required this.onTap,
  });

  final ConversationSummary conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = conversation.preview;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      child: InkWell(
        key: Key('conversation-${conversation.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StatusDot(status: conversation.status),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _relativeTime(conversation.updatedAt),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    if (preview != null && preview.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _MetadataChip(
                          label: _statusLabel(conversation.status),
                        ),
                        if (conversation.model != null)
                          _MetadataChip(label: conversation.model!),
                        if (conversation.workspaceRoot != null)
                          const _MetadataChip(label: '项目会话'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final ConversationStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      ConversationStatus.running => Colors.green,
      ConversationStatus.waitingApproval => Colors.orange,
      ConversationStatus.waitingUserInput => Colors.amber,
      ConversationStatus.error => Theme.of(context).colorScheme.error,
      ConversationStatus.archived => Colors.grey,
      ConversationStatus.idle => Theme.of(context).colorScheme.outline,
    };
    return Container(
      width: 10,
      height: 10,
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _MetadataChip extends StatelessWidget {
  const _MetadataChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 42,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
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
    ConversationStatus.waitingUserInput => '等待输入',
    ConversationStatus.error => '错误',
    ConversationStatus.archived => '已归档',
  };
}

String _relativeTime(DateTime time) {
  final difference = DateTime.now().toUtc().difference(time.toUtc());
  if (difference.inMinutes < 1) {
    return '刚刚';
  }
  if (difference.inHours < 1) {
    return '${difference.inMinutes} 分钟前';
  }
  if (difference.inDays < 1) {
    return '${difference.inHours} 小时前';
  }
  return '${difference.inDays} 天前';
}
