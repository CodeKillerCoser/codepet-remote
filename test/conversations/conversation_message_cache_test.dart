import 'package:codepet_remote/application/conversations/conversation_message_cache.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

ConversationSummary conversation(String id) => ConversationSummary(
  id: id, providerId: 'provider', title: id, status: ConversationStatus.idle,
  permissionLevel: 'default', createdAt: DateTime(2026), updatedAt: DateTime(2026),
);

void main() {
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
