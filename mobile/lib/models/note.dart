class Note {
  final int id;
  final int? remoteId;
  final String title;
  final String content;
  final String originalText;
  final String category;
  final List<String> tags;
  final String source;
  final String messageType;
  final String status;
  final String aiProvider;
  final String? mediaPath;
  final DateTime createdAt;

  Note({
    required this.id,
    required this.title,
    required this.content,
    required this.originalText,
    required this.category,
    required this.tags,
    required this.source,
    required this.messageType,
    required this.status,
    required this.aiProvider,
    required this.createdAt,
    this.remoteId,
    this.mediaPath,
  });

  bool get isLocalRecord => id < 0;
  bool get pendingSync => status == 'pending_sync';

  factory Note.fromJson(Map<String, dynamic> json) => Note(
        id: (json['id'] as num).toInt(),
        remoteId: json['remote_id'] is num ? (json['remote_id'] as num).toInt() : null,
        title: (json['title'] ?? 'Nota').toString(),
        content: (json['content'] ?? '').toString(),
        originalText: (json['original_text'] ?? '').toString(),
        category: (json['category'] ?? 'Inbox').toString(),
        tags: ((json['tags'] as List?) ?? const []).map((e) => e.toString()).toList(),
        source: (json['source'] ?? 'manual').toString(),
        messageType: (json['message_type'] ?? 'text').toString(),
        status: (json['status'] ?? 'ready').toString(),
        aiProvider: (json['ai_provider'] ?? json['ai_source'] ?? 'rules').toString(),
        mediaPath: json['media_path']?.toString(),
        createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()) ?? DateTime.now(),
      );

  Note copyWith({
    int? remoteId,
    String? title,
    String? content,
    String? originalText,
    String? category,
    List<String>? tags,
    String? source,
    String? messageType,
    String? status,
    String? aiProvider,
    String? mediaPath,
    DateTime? createdAt,
  }) =>
      Note(
        id: id,
        remoteId: remoteId ?? this.remoteId,
        title: title ?? this.title,
        content: content ?? this.content,
        originalText: originalText ?? this.originalText,
        category: category ?? this.category,
        tags: tags ?? this.tags,
        source: source ?? this.source,
        messageType: messageType ?? this.messageType,
        status: status ?? this.status,
        aiProvider: aiProvider ?? this.aiProvider,
        mediaPath: mediaPath ?? this.mediaPath,
        createdAt: createdAt ?? this.createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'remote_id': remoteId,
        'title': title,
        'content': content,
        'original_text': originalText,
        'category': category,
        'tags': tags,
        'source': source,
        'message_type': messageType,
        'status': status,
        'ai_provider': aiProvider,
        'media_path': mediaPath,
        'created_at': createdAt.toIso8601String(),
      };
}
