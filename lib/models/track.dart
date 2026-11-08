class Track {
  const Track({required this.id, required this.name, required this.size, required this.mimeType, this.revision = ''});
  final String id, name, mimeType, revision;
  final int size;
  factory Track.fromJson(Map<String, dynamic> json) => Track(
    id: (json['id'] ?? json['file_id'] ?? '').toString(),
    name: (json['name'] ?? json['filename'] ?? 'Neznáma skladba').toString(),
    size: (json['size'] as num?)?.toInt() ?? 0,
    mimeType: (json['mime_type'] ?? '').toString(),
    revision: (json['etag'] ?? json['updated_at'] ?? json['modified_at'] ?? json['last_modified'] ?? '').toString(),
  );
}
