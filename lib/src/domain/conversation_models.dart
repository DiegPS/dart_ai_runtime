enum AiConversationStatus {
  idle,
  connecting,
  sending,
  streaming,
  canceling,
  error,
}

typedef AiConversationHistoryPromptBuilder = String Function(
  String currentPrompt,
  List<AiChatMessage> previousMessages,
);

class AiChatMessage {
  const AiChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.isStreaming = false,
    this.isCancelled = false,
  });

  final String id;
  final String role;
  final String content;
  final DateTime timestamp;
  final bool isStreaming;
  final bool isCancelled;
}

class AiConversationState {
  const AiConversationState({
    this.sessionId,
    this.messages = const [],
    this.status = AiConversationStatus.idle,
    this.streamedText = '',
    this.error,
  });

  final String? sessionId;
  final List<AiChatMessage> messages;
  final AiConversationStatus status;
  final String streamedText;
  final Object? error;

  bool get isBusy => switch (status) {
    AiConversationStatus.connecting ||
    AiConversationStatus.sending ||
    AiConversationStatus.streaming ||
    AiConversationStatus.canceling => true,
    _ => false,
  };

  AiConversationState copyWith({
    String? sessionId,
    bool clearSession = false,
    List<AiChatMessage>? messages,
    AiConversationStatus? status,
    String? streamedText,
    Object? error,
    bool clearError = false,
  }) => AiConversationState(
    sessionId: clearSession ? null : sessionId ?? this.sessionId,
    messages: messages ?? this.messages,
    status: status ?? this.status,
    streamedText: streamedText ?? this.streamedText,
    error: clearError ? null : error ?? this.error,
  );
}

abstract interface class AiConversationHistoryStore {
  Future<List<AiChatMessage>> load();
  Future<void> save(List<AiChatMessage> messages);
  Future<void> clear();
}
