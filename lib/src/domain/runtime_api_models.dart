class AiModelInfo {
  const AiModelInfo({
    required this.id,
    required this.name,
    required this.providerId,
    required this.isFree,
    this.supportsReasoning = false,
    this.isDefault = false,
  });

  final String id;
  final String name;
  final String providerId;
  final bool isFree;
  final bool supportsReasoning;
  final bool isDefault;

  String get key =>
      '${Uri.encodeComponent(providerId)}/${Uri.encodeComponent(id)}';
}

class AiProviderInfo {
  const AiProviderInfo({
    required this.id,
    required this.name,
    required this.connected,
    required this.models,
  });

  final String id;
  final String name;
  final bool connected;
  final List<AiModelInfo> models;
}

class AiAuthMethod {
  const AiAuthMethod({
    required this.providerId,
    required this.type,
    required this.label,
    required this.index,
    this.prompts = const [],
  });

  final String providerId;
  final String type;
  final String label;
  final int index;
  final List<AiAuthPrompt> prompts;
}

class AiAuthPrompt {
  const AiAuthPrompt({
    required this.key,
    required this.type,
    required this.label,
    this.placeholder,
    this.options = const {},
    this.whenKey,
    this.whenValue,
    this.whenNot = false,
  });

  final String key;
  final String type;
  final String label;
  final String? placeholder;
  final Map<String, String> options;
  final String? whenKey;
  final String? whenValue;
  final bool whenNot;

  bool visible(Map<String, String> inputs) =>
      whenKey == null ||
      (whenNot ? inputs[whenKey] != whenValue : inputs[whenKey] == whenValue);

  factory AiAuthPrompt.fromJson(Map<Object?, Object?> raw) {
    final condition = raw['when'];
    return AiAuthPrompt(
      key: raw['key'].toString(),
      type: raw['type'].toString(),
      label: raw['message']?.toString() ?? raw['key'].toString(),
      placeholder: raw['placeholder']?.toString(),
      options: {
        if (raw['options'] is List<Object?>)
          for (final option
              in (raw['options'] as List<Object?>)
                  .whereType<Map<Object?, Object?>>())
            option['value'].toString(): option['label'].toString(),
      },
      whenKey: condition is Map<Object?, Object?>
          ? condition['key']?.toString()
          : null,
      whenValue: condition is Map<Object?, Object?>
          ? condition['value']?.toString()
          : null,
      whenNot: condition is Map<Object?, Object?> && condition['op'] == 'neq',
    );
  }
}

class AiOAuthAuthorization {
  const AiOAuthAuthorization({
    required this.method,
    this.url,
    this.instructions,
  });

  final String method;
  final Uri? url;
  final String? instructions;
}

class AiSession {
  const AiSession({required this.id, this.title});

  final String id;
  final String? title;

  factory AiSession.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Runtime session response has no id.');
    }
    return AiSession(id: id, title: json['title']?.toString());
  }
}

class AiPrompt {
  const AiPrompt({
    required this.providerId,
    required this.modelId,
    required this.system,
    required this.text,
    this.messageId,
    this.toolPermissions = const {'*': false},
  });

  final String providerId;
  final String modelId;
  final String system;
  final String text;
  final String? messageId;

  /// Explicit OpenCode permission patterns. Tools are denied by default.
  final Map<String, bool> toolPermissions;

  Map<String, Object> toJson() => {
    'messageID': ?messageId,
    'model': {'providerID': providerId, 'modelID': modelId},
    'system': system,
    'tools': toolPermissions,
    'parts': [
      {'type': 'text', 'text': text},
    ],
  };
}

class AiRuntimeEvent {
  const AiRuntimeEvent({
    required this.type,
    required this.properties,
    required this.raw,
  });

  final String type;
  final Map<String, dynamic> properties;
  final Map<String, dynamic> raw;

  factory AiRuntimeEvent.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'] is Map
        ? Map<String, dynamic>.from(json['payload'] as Map)
        : json;
    return AiRuntimeEvent(
      type: payload['type']?.toString() ?? 'unknown',
      properties: payload['properties'] is Map
          ? Map<String, dynamic>.from(payload['properties'] as Map)
          : const {},
      raw: json,
    );
  }

  String? get textDelta {
    if (type != 'message.part.delta' && type != 'message.part.updated') {
      return null;
    }
    if (properties['field'] != null && properties['field'] != 'text') {
      return null;
    }
    return properties['delta'] is String ? properties['delta'] as String : null;
  }

  String? get fullPartText {
    if (type != 'message.part.updated') return null;
    final part = properties['part'];
    return part is Map && part['type'] == 'text' && part['text'] is String
        ? part['text'] as String
        : null;
  }

  String? get sessionId {
    final id =
        properties['sessionID'] ??
        properties['sessionId'] ??
        properties['id'] ??
        (properties['info'] is Map
            ? (properties['info'] as Map)['sessionID']
            : null) ??
        (properties['part'] is Map
            ? (properties['part'] as Map)['sessionID']
            : null) ??
        raw['sessionID'];
    return id?.toString();
  }

  String? get messageId {
    if (!type.startsWith('message.')) return null;
    final id =
        properties['messageID'] ??
        properties['messageId'] ??
        (properties['info'] is Map
            ? (properties['info'] as Map)['id']
            : null) ??
        (properties['part'] is Map
            ? (properties['part'] as Map)['messageID']
            : null) ??
        raw['messageID'];
    return id?.toString();
  }

  String? get partId {
    if (!type.startsWith('message.part.')) return null;
    final id =
        properties['partID'] ??
        properties['partId'] ??
        (properties['part'] is Map
            ? (properties['part'] as Map)['id']
            : null) ??
        raw['partID'];
    return id?.toString();
  }

  String? get role {
    final value =
        properties['role'] ??
        (properties['info'] is Map
            ? (properties['info'] as Map)['role']
            : null) ??
        (properties['part'] is Map
            ? (properties['part'] as Map)['role']
            : null) ??
        raw['role'];
    return value?.toString();
  }

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  bool get isCompleted {
    if (type == 'message.completed' || type == 'session.idle') return true;
    if (type == 'message.status' && properties['status'] == 'completed') {
      return true;
    }
    final status = properties['status'];
    if (type == 'session.status' &&
        (status == 'idle' || status is Map && status['type'] == 'idle')) {
      return true;
    }
    final info = properties['info'];
    return type == 'message.updated' &&
        info is Map &&
        info['finish'] != null &&
        info['finish'].toString() != 'null';
  }

  bool get isError =>
      type.toLowerCase().contains('error') || properties.containsKey('error');
}
