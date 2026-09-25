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
  final String sender;
  final String messageSid;
  final String replyStatus;
  final String replyText;
  final String replyError;
  final DateTime? repliedAt;
  final String customerName;
  final String customerPhone;
  final List<String> photoPaths;
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
    this.sender = '',
    this.messageSid = '',
    this.replyStatus = 'none',
    this.replyText = '',
    this.replyError = '',
    this.repliedAt,
    this.customerName = '',
    this.customerPhone = '',
    this.photoPaths = const <String>[],
  });

  bool get isLocalRecord => id < 0;
  bool get pendingSync => status == 'pending_sync';
  bool get isPurchase => category == 'Compras';

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
        sender: (json['sender'] ?? '').toString(),
        messageSid: (json['message_sid'] ?? '').toString(),
        replyStatus: (json['reply_status'] ?? 'none').toString(),
        replyText: (json['reply_text'] ?? '').toString(),
        replyError: (json['reply_error'] ?? '').toString(),
        repliedAt: DateTime.tryParse((json['replied_at'] ?? '').toString()),
        customerName: (json['customer_name'] ?? '').toString(),
        customerPhone: (json['customer_phone'] ?? '').toString(),
        photoPaths: ((json['photo_paths'] as List?) ?? const [])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList(),
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
    String? sender,
    String? messageSid,
    String? replyStatus,
    String? replyText,
    String? replyError,
    DateTime? repliedAt,
    String? customerName,
    String? customerPhone,
    List<String>? photoPaths,
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
        sender: sender ?? this.sender,
        messageSid: messageSid ?? this.messageSid,
        replyStatus: replyStatus ?? this.replyStatus,
        replyText: replyText ?? this.replyText,
        replyError: replyError ?? this.replyError,
        repliedAt: repliedAt ?? this.repliedAt,
        customerName: customerName ?? this.customerName,
        customerPhone: customerPhone ?? this.customerPhone,
        photoPaths: photoPaths ?? this.photoPaths,
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
        'sender': sender,
        'message_sid': messageSid,
        'reply_status': replyStatus,
        'reply_text': replyText,
        'reply_error': replyError,
        'replied_at': repliedAt?.toIso8601String(),
        'customer_name': customerName,
        'customer_phone': customerPhone,
        'photo_paths': photoPaths,
        'created_at': createdAt.toIso8601String(),
      };
}
