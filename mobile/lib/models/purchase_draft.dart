import 'dart:convert';

class PurchaseDraft {
  final String id;
  final String noteKey;
  final String customerName;
  final String customerPhone;
  final String store;
  final String orderNumber;
  final String description;
  final double total;
  final double subtotal;
  final double tax;
  final double shipping;
  final double discount;
  final List<Map<String, dynamic>> items;
  final String ocrText;
  final double confidence;
  final List<String> warnings;
  final String mediaPath;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PurchaseDraft({
    required this.id,
    required this.noteKey,
    required this.customerName,
    required this.customerPhone,
    required this.store,
    required this.orderNumber,
    required this.description,
    required this.total,
    required this.subtotal,
    required this.tax,
    required this.shipping,
    required this.discount,
    required this.items,
    required this.ocrText,
    required this.confidence,
    required this.warnings,
    required this.mediaPath,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get pending => status == 'pending';

  PurchaseDraft copyWith({
    String? customerName,
    String? customerPhone,
    String? store,
    String? orderNumber,
    String? description,
    double? total,
    double? subtotal,
    double? tax,
    double? shipping,
    double? discount,
    List<Map<String, dynamic>>? items,
    String? ocrText,
    double? confidence,
    List<String>? warnings,
    String? mediaPath,
    String? status,
    DateTime? updatedAt,
  }) => PurchaseDraft(
        id: id,
        noteKey: noteKey,
        customerName: customerName ?? this.customerName,
        customerPhone: customerPhone ?? this.customerPhone,
        store: store ?? this.store,
        orderNumber: orderNumber ?? this.orderNumber,
        description: description ?? this.description,
        total: total ?? this.total,
        subtotal: subtotal ?? this.subtotal,
        tax: tax ?? this.tax,
        shipping: shipping ?? this.shipping,
        discount: discount ?? this.discount,
        items: items ?? this.items,
        ocrText: ocrText ?? this.ocrText,
        confidence: confidence ?? this.confidence,
        warnings: warnings ?? this.warnings,
        mediaPath: mediaPath ?? this.mediaPath,
        status: status ?? this.status,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'note_key': noteKey,
        'customer_name': customerName,
        'customer_phone': customerPhone,
        'store': store,
        'order_number': orderNumber,
        'description': description,
        'total': total,
        'subtotal': subtotal,
        'tax': tax,
        'shipping': shipping,
        'discount': discount,
        'items': items,
        'ocr_text': ocrText,
        'confidence': confidence,
        'warnings': warnings,
        'media_path': mediaPath,
        'status': status,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory PurchaseDraft.fromJson(Map<String, dynamic> json) => PurchaseDraft(
        id: (json['id'] ?? '').toString(),
        noteKey: (json['note_key'] ?? '').toString(),
        customerName: (json['customer_name'] ?? '').toString(),
        customerPhone: (json['customer_phone'] ?? '').toString(),
        store: (json['store'] ?? 'Otra tienda').toString(),
        orderNumber: (json['order_number'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
        total: (json['total'] as num?)?.toDouble() ?? 0,
        subtotal: (json['subtotal'] as num?)?.toDouble() ?? 0,
        tax: (json['tax'] as num?)?.toDouble() ?? 0,
        shipping: (json['shipping'] as num?)?.toDouble() ?? 0,
        discount: (json['discount'] as num?)?.toDouble() ?? 0,
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
        ocrText: (json['ocr_text'] ?? '').toString(),
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        warnings: ((json['warnings'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        mediaPath: (json['media_path'] ?? '').toString(),
        status: (json['status'] ?? 'pending').toString(),
        createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()) ??
            DateTime.now(),
        updatedAt: DateTime.tryParse((json['updated_at'] ?? '').toString()) ??
            DateTime.now(),
      );

  String encode() => jsonEncode(toJson());

  factory PurchaseDraft.decode(String value) =>
      PurchaseDraft.fromJson(jsonDecode(value) as Map<String, dynamic>);
}
