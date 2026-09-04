import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/gateway/generated_gateway_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mapper = GeneratedGatewayMapper();

  test('maps every canonical conversation item variant', () {
    final items = <Map<String, Object?>>[
      {
        ..._base('message', 'message'),
        'role': 'assistant',
        'contents': _allContents,
      },
      {..._base('reasoning', 'reasoning'), 'contents': const []},
      {
        ..._base('command', 'command'),
        'title': 'Run checks',
        'tool': _tool(
          input: {
            'kind': 'command',
            'command': 'dart test',
            'cwd': '/workspace',
          },
          outcome: {
            'kind': 'success',
            'content': [
              {'contentId': 'command:output', 'kind': 'output', 'text': 'ok'},
            ],
            'exitCode': 0,
          },
        ),
      },
      {
        ..._base('file', 'file-change'),
        'title': 'Changed files',
        'contents': [
          {
            'contentId': 'file:summary',
            'kind': 'activity-summary',
            'text': 'lib/main.dart',
          },
        ],
      },
      {
        ..._base('tool', 'tool'),
        'tool': _tool(
          input: {
            'kind': 'structured',
            'value': {'query': 'needle'},
          },
          outcome: {
            'kind': 'failure',
            'content': [
              {
                'contentId': 'tool:diagnostic',
                'kind': 'output',
                'text': 'not found',
              },
            ],
            'error': {'code': 'missing', 'message': 'Search failed'},
          },
        ),
      },
      {
        ..._base('approval', 'approval'),
        'relatedItem': _resource('command'),
        'approval': {
          'resource': _resource('approval'),
          'conversation': _resource('conversation'),
          'turn': _resource('turn'),
          'kind': 'command-execution',
          'title': 'Approve',
          'status': 'pending',
          'decisions': ['approve', 'deny'],
        },
      },
      _base('unknown', 'unknown'),
    ];

    final mapped = [
      for (var index = 0; index < items.length; index++)
        mapper.message(sdk.ConversationItem.fromJson(items[index]), index),
    ];

    expect(mapped.map((item) => item.kind), [
      'message',
      'reasoning',
      'command',
      'file-change',
      'tool',
      'approval',
      'unknown',
    ]);
    expect(mapped[0].contentIds, [
      'content:text',
      'content:reasoning',
      'content:output',
      'content:activity',
      'content:json',
      'content:image',
      'content:audio',
      'content:link',
      'content:embedded',
    ]);
    expect(mapped[0].contents[4].value, {'answer': 42});
    expect(mapped[0].contents[5].uri, 'https://example.com/image.png');
    expect(mapped[0].contents.first.truncation?.originalBytes, 100);
    expect(mapped[0].contents.first.truncation?.retainedBytes, 10);
    expect(mapped[0].contents.first.truncation?.strategy, 'head-tail');

    final command = mapped[2].tool!;
    expect(command.input, isA<GatewayCommandToolInput>());
    expect(command.outcome, isA<GatewayToolSuccess>());
    expect(mapped[2].contentIds, ['command:output']);

    final tool = mapped[4].tool!;
    expect(tool.input, isA<GatewayStructuredToolInput>());
    expect(tool.outcome, isA<GatewayToolFailure>());
    expect((tool.outcome as GatewayToolFailure).error.message, 'Search failed');
    expect(mapped[4].contentIds, ['tool:diagnostic']);
  });

  test('maps opaque tool input without treating size as semantics', () {
    final item = sdk.ConversationItem.fromJson({
      ..._base('opaque', 'tool'),
      'tool': _tool(input: {
        'kind': 'opaque',
        'value': 'raw provider syntax',
        'mimeType': 'text/plain',
        'truncation': {
          'originalBytes': 500,
          'retainedBytes': 19,
          'strategy': 'tail',
        },
      }),
    });

    final input = mapper.message(item, 0).tool!.input as GatewayOpaqueToolInput;
    expect(input.value, 'raw provider syntax');
    expect(input.mimeType, 'text/plain');
    expect(input.truncation?.strategy, 'tail');
  });
}

Map<String, Object?> _base(String id, String kind) => {
      'resource': _resource(id),
      'turn': _resource('turn'),
      'conversation': _resource('conversation'),
      'kind': kind,
      'status': 'completed',
    };

Map<String, Object?> _resource(String id) => {
      'providerId': 'provider',
      'nativeResourceId': id,
    };

Map<String, Object?> _tool({
  required Map<String, Object?> input,
  Map<String, Object?>? outcome,
}) {
  final result = <String, Object?>{
      'callId': 'call',
      'name': 'tool',
      'category': 'other',
      'origin': {'kind': 'builtin'},
      'input': input,
    };
  if (outcome != null) result['outcome'] = outcome;
  return result;
}

const _allContents = <Map<String, Object?>>[
  {
    'contentId': 'content:text',
    'kind': 'text',
    'text': 'hello',
    'truncation': {
      'originalBytes': 100,
      'retainedBytes': 10,
      'strategy': 'head-tail',
    },
  },
  {
    'contentId': 'content:reasoning',
    'kind': 'reasoning-summary',
    'text': 'thinking',
  },
  {'contentId': 'content:output', 'kind': 'output', 'text': 'output'},
  {
    'contentId': 'content:activity',
    'kind': 'activity-summary',
    'text': 'activity',
  },
  {
    'contentId': 'content:json',
    'kind': 'structured-json',
    'value': {'answer': 42},
  },
  {
    'contentId': 'content:image',
    'kind': 'image',
    'uri': 'https://example.com/image.png',
  },
  {
    'contentId': 'content:audio',
    'kind': 'audio',
    'uri': 'https://example.com/audio.mp3',
  },
  {
    'contentId': 'content:link',
    'kind': 'resource-link',
    'uri': 'https://example.com/resource',
  },
  {
    'contentId': 'content:embedded',
    'kind': 'embedded-resource',
    'text': 'embedded',
  },
];
