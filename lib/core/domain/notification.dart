import 'dart:convert';

import 'models.dart';

enum InterventionKind { approval, input, decision }

enum InterventionStatus { pending, resolved, cancelled, expired }

enum NoticeKind { outcome, intervention }

class NotificationTarget {
  const NotificationTarget({
    required this.deviceId,
    required this.providerId,
    required this.conversationId,
    this.turnId,
    this.requestId,
  });
  final String deviceId;
  final String providerId;
  final String conversationId;
  final String? turnId;
  final String? requestId;
  String get conversationKey =>
      jsonEncode([deviceId, providerId, conversationId]);
  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'providerId': providerId,
    'conversationId': conversationId,
    'turnId': turnId,
    'requestId': requestId,
  };
  static NotificationTarget? parse(String? payload) {
    try {
      if (payload == null || payload.length > 16384) return null;
      final map = jsonDecode(payload) as Map<String, dynamic>;
      String requiredValue(String key) {
        final value = map[key];
        if (value is! String || value.isEmpty || value.length > 4096) {
          throw const FormatException('Invalid notification target');
        }
        return value;
      }

      return NotificationTarget(
        deviceId: requiredValue('deviceId'),
        providerId: requiredValue('providerId'),
        conversationId: requiredValue('conversationId'),
        turnId: map['turnId'] as String?,
        requestId: map['requestId'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

class TaskOutcome {
  const TaskOutcome({
    required this.target,
    required this.status,
    required this.at,
  });
  final NotificationTarget target;
  final TurnStatus status;
  final DateTime at;
}

class InterventionRequest {
  const InterventionRequest({
    required this.target,
    required this.kind,
    required this.status,
    required this.at,
    this.summary,
  });
  final NotificationTarget target;
  final InterventionKind kind;
  final InterventionStatus status;
  final DateTime at;
  final String? summary;
}

class RemoteNotice {
  const RemoteNotice({
    required this.id,
    required this.target,
    required this.kind,
    required this.title,
    required this.body,
    required this.preview,
    this.silent = false,
  });
  final int id;
  final NotificationTarget target;
  final NoticeKind kind;
  final String title;
  final String body;
  final bool preview;
  final bool silent;
}

class NotificationPreferences {
  const NotificationPreferences({
    this.outcomes = false,
    this.interventions = false,
    this.preview = false,
    this.keepConnected = false,
  });
  final bool outcomes;
  final bool interventions;
  final bool preview;
  final bool keepConnected;
  Map<String, Object?> toJson() => {
    'outcomes': outcomes,
    'interventions': interventions,
    'preview': preview,
    'keepConnected': keepConnected,
  };
  factory NotificationPreferences.fromJson(Map<String, dynamic> map) =>
      NotificationPreferences(
        outcomes: map['outcomes'] == true,
        interventions: map['interventions'] == true,
        preview: map['preview'] == true,
        keepConnected: map['keepConnected'] == true,
      );
  NotificationPreferences copyWith({
    bool? outcomes,
    bool? interventions,
    bool? preview,
    bool? keepConnected,
  }) => NotificationPreferences(
    outcomes: outcomes ?? this.outcomes,
    interventions: interventions ?? this.interventions,
    preview: preview ?? this.preview,
    keepConnected: keepConnected ?? this.keepConnected,
  );
}
