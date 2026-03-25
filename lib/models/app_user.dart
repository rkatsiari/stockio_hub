class AppUser {
  //represent one user
  final String uid; //firebase auth user
  final String name;
  final String email;
  final String role;
  final String tenantId; //the company that the use belong to

  AppUser({ //constructor with all fields required
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
    required this.tenantId,
  });

  //factory constructor
  factory AppUser.fromMap(String uid, Map<String, dynamic> data) {
    return AppUser(
      uid: uid,
      name: (data['name'] ?? '').toString(),
      email: (data['email'] ?? '').toString(),
      role: (data['role'] ?? '').toString(),
      tenantId: (data['tenantId'] ?? '').toString(),
    );
  }

  //getter - make sure tenantId is not null
  bool get hasValidTenantId => tenantId.trim().isNotEmpty;

  // convert it into map
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'email': email,
      'role': role,
      'tenantId': tenantId,
    };
  }
}