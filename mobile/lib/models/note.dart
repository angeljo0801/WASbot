class Note {
  final int id;
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
    this.mediaPath,
  });

  factory Note.fromJson(Map<String, dynamic> json) => Note(
        id: (json['id'] as num).toInt(),
        title: (json['title'] ?? 'Nota').toString(),
        content: (json['content'] ?? '').toString(),
        originalText: (json['original_text'] ?? '').toString(),
        category: (json['category'] ?? 'Inbox').toString(),
        tags: ((json['tags'] as List?) ?? const []).map((e) => e.toString()).toList(),
        source: (json['source'] ?? 'manual').toString(),
        messageType: (json['message_type'] ?? 'text').toString(),
        status: (json['status'] ?? 'ready').toString(),
        aiProvider: (json['ai_provider'] ?? 'rules').toString(),
        mediaPath: json['media_path']?.toString(),
        createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()) ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
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
