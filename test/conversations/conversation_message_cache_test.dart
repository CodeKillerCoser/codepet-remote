import 'dart:async';
import 'package:codepet_remote/application/conversations/conversation_message_cache.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

ConversationSummary conversation(String id) => ConversationSummary(
  id: id, providerId: 'provider', title: id, status: ConversationStatus.idle,
  permissionLevel: 'default', createdAt: DateTime(2026), updatedAt: DateTime(2026),
);

void main() {
  GatewayMessage message(String id, String text) => GatewayMessage(
    id: id, itemId: id, turnId: 'turn', role: MessageRole.assistant,
    kind: 'message', content: text, createdAt: DateTime(2026), isStreaming: false);

  test('empty updates require no control and merge latest items without clearing history', () async {
    final source = ConversationMessageSource(ConversationDetail(summary: conversation('a'),
      committedMessages: [message('old', 'older page'), message('latest', 'before')]), 'runtime', DateTime(2026));
    addTearDown(source.dispose);
    source.nextCursor = 'older-cursor';
    var calls = 0;
    source.loadLatest = () async { calls++; return ConversationDetail(summary: conversation('a'),
      committedMessages: [message('latest', 'after'), message('new', 'new output')]); };
    const hint = ConversationItemUpsertedEvent(eventCursor: 'hint', conversationId: 'a', item: null);
    source.interactionAcquired = true;
    source.applyEvent(hint);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
    source.interactionAcquired = false;
    source.applyEvent(const ConversationItemUpsertedEvent(eventCursor: 'other', conversationId: 'b', item: null));
    source.applyEvent(ConversationItemUpsertedEvent(eventCursor: 'canonical', conversationId: 'a', item: message('canonical', 'stream')));
    expect(calls, 0);
    source.applyEvent(hint);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(source.detail.committedMessages.map((m) => m.content), ['older page', 'after', 'stream', 'new output']);
    expect(source.nextCursor, 'older-cursor');
  });

  test('invalidation requests coalesce and acquiring control discards in-flight results', () async {
    final source = ConversationMessageSource(ConversationDetail(summary: conversation('a')), 'runtime', DateTime(2026));
    addTearDown(source.dispose);
    final pending = Completer<ConversationDetail>();
    var calls = 0;
    source.loadLatest = () { calls++; return pending.future; };
    const hint = ConversationItemUpsertedEvent(eventCursor: 'hint', conversationId: 'a', item: null);
    source.applyEvent(hint); source.applyEvent(hint); source.applyEvent(hint);
    expect(calls, 1);
    source.interactionAcquired = true;
    pending.complete(ConversationDetail(summary: conversation('a'), committedMessages: [message('stale', 'stale')]));
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(source.detail.committedMessages, isEmpty);
  });

  test('a hint during fetch schedules one trailing fetch; failure keeps old messages', () async {
    final source = ConversationMessageSource(ConversationDetail(summary: conversation('a'),
      committedMessages: [message('old', 'keep')]), 'runtime', DateTime(2026));
    addTearDown(source.dispose);
    final pending = Completer<ConversationDetail>();
    var calls = 0;
    source.loadLatest = () { calls++; if (calls == 1) return pending.future; throw StateError('offline'); };
    const hint = ConversationItemUpsertedEvent(eventCursor: 'hint', conversationId: 'a', item: null);
    source.applyEvent(hint); source.applyEvent(hint); source.applyEvent(hint);
    pending.complete(ConversationDetail(summary: conversation('a'), committedMessages: [message('new', 'new')]));
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    expect(source.detail.committedMessages.map((m) => m.content), ['keep', 'new']);
    expect(source.historyError, contains('offline'));
  });

  test('new canonical output during a pull is not overwritten by its older snapshot', () async {
    final source = ConversationMessageSource(ConversationDetail(summary: conversation('a')), 'runtime', DateTime(2026));
    addTearDown(source.dispose);
    final pending = Completer<ConversationDetail>();
    source.loadLatest = () => pending.future;
    source.applyEvent(const ConversationItemUpsertedEvent(eventCursor: 'hint', conversationId: 'a', item: null));
    source.applyEvent(ConversationItemUpsertedEvent(eventCursor: 'live', conversationId: 'a', item: message('one', 'fresh')));
    pending.complete(ConversationDetail(summary: conversation('a'), committedMessages: [message('one', 'stale')]));
    await Future<void>.delayed(Duration.zero);
    expect(source.detail.committedMessages.single.content, 'fresh');
    expect(source.detail.lastEventCursor, 'live');
  });

  test('external session end clears a stale active turn without removing output', () {
    final running = TurnTask(id: 'turn', providerId: 'provider', conversationId: 'a', status: TurnStatus.running, updatedAt: DateTime(2026));
    final source = ConversationMessageSource(ConversationDetail(summary: conversation('a').withTurn(running),
      turns: [running], committedMessages: [message('one', 'keep output').copyWith(isStreaming: true)]), 'runtime', DateTime(2026));
    addTearDown(source.dispose);
    source.applyEvent(ConversationUpsertedEvent(eventCursor: 'ended', conversation: conversation('a')));
    expect(source.detail.effectiveStatus, ConversationStatus.idle);
    expect(source.detail.activeTurn, isNull);
    expect(source.detail.committedMessages.single.content, 'keep output');
    expect(source.detail.committedMessages.single.isStreaming, isFalse);
  });

  test('LRU promotes visits, ignores background output and pins visible sources', () {
    final cache = ConversationMessageCache(capacity: 2);
    addTearDown(cache.clear);
    final a = cache.acquire(conversation('a'), 'runtime');
    cache.release(a);
    final b = cache.acquire(conversation('b'), 'runtime');
    cache.release(b);
    expect(cache.acquire(conversation('a'), 'runtime'), same(a));
    cache.release(a);
    b.applyEvent(const TurnOutputDeltaEvent(eventCursor: 'b-output', providerId: 'provider',
      conversationId: 'b', turnId: 'turn', itemId: 'item', contentId: 'text', kind: 'text', delta: 'background'));
    final c = cache.acquire(conversation('c'), 'runtime');
    expect(b.closed, isTrue);
    expect(a.closed, isFalse);
    final d = cache.acquire(conversation('d'), 'runtime');
    expect(a.closed, isTrue);
    expect(c.closed, isFalse);
    expect(d.closed, isFalse);
    cache.release(c);
    cache.release(d);
  });

  test('idle expiry and changed runtime discard sources; reopening starts empty', () {
    var now = DateTime(2026);
    final cache = ConversationMessageCache(now: () => now);
    addTearDown(cache.clear);
    final a = cache.acquire(conversation('a'), 'old-runtime');
    now = now.add(const Duration(hours: 1));
    cache.prune();
    expect(a.closed, isFalse);
    cache.release(a);
    now = now.add(const Duration(minutes: 16));
    cache.prune();
    expect(a.closed, isTrue);
    final replacement = cache.acquire(conversation('a'), 'old-runtime');
    expect(replacement.initialized, isFalse);
    cache.release(replacement);
    final nextRuntime = cache.acquire(conversation('a'), 'new-runtime');
    expect(replacement.closed, isTrue);
    expect(nextRuntime, isNot(same(replacement)));
    cache.invalidateProvider('provider');
    expect(nextRuntime.closed, isTrue);
  });
}
