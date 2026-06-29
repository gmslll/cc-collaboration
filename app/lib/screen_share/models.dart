class ShareSource {
  final String id;
  final String name;
  final String type;

  const ShareSource({
    required this.id,
    required this.name,
    required this.type,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
  };

  static ShareSource? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = (value['id'] ?? '').toString();
    final name = (value['name'] ?? '').toString();
    final type = (value['type'] ?? '').toString();
    if (id.isEmpty || name.isEmpty) return null;
    return ShareSource(
      id: id,
      name: name,
      type: type.isEmpty ? 'unknown' : type,
    );
  }
}
