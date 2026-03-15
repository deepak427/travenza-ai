class Guide {
  final String id;
  final String name;
  final String description;
  final String voice;

  Guide({
    required this.id,
    required this.name,
    required this.description,
    required this.voice,
  });

  factory Guide.fromJson(String id, Map<String, dynamic> json) {
    return Guide(
      id: id,
      name: json['name'],
      description: json['description'],
      voice: json['voice'],
    );
  }
}
