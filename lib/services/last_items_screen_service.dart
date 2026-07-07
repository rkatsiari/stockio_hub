class LastItemsScreenService {
  static String? _folderId;
  static String? _folderName;

  static String? get folderId => _folderId;
  static String? get folderName => _folderName;

  static bool get hasFolder =>
      (_folderId ?? '').trim().isNotEmpty &&
          (_folderName ?? '').trim().isNotEmpty;

  static void remember({
    required String folderId,
    required String folderName,
  }) {
    final cleanId = folderId.trim();
    final cleanName = folderName.trim();

    if (cleanId.isEmpty || cleanName.isEmpty) return;

    _folderId = cleanId;
    _folderName = cleanName;
  }
}