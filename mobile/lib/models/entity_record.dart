class EntityRecord {
  final String id;
  final String name;
  final String normalizedName;
  final String type;
  final List<String> aliases;
  final DateTime updatedAt;
  final int noteCount;

  const EntityRecord({
    required this.id,
    required this.name,
    required this.normalizedName,
    required this.type,
    required this.aliases,
    required this.updatedAt,
    this.noteCount = 0,
  });

  factory EntityRecord.fromMap(Map<String, dynamic> map) => EntityRecord(
        id: (map['id'] ?? '').toString(),
        name: (map['name'] ?? '').toString(),
        normalizedName: (map['normalized_name'] ?? '').toString(),
        type: (map['type'] ?? 'persona').toString(),
        aliases: ((map['aliases'] as List?) ?? const [])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList(),
        updatedAt: DateTime.tryParse((map['updated_at'] ?? '').toString()) ??
            DateTime.now(),
        noteCount: (map['note_count'] as num?)?.toInt() ?? 0,
      );
}
