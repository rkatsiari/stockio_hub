import 'package:flutter/material.dart';

class FolderGridTile extends StatelessWidget {
  final String folderName;
  final String breadcrumb;
  final VoidCallback onTap;

  final bool isAdmin;
  final VoidCallback? onRename;
  final VoidCallback? onMove;
  final VoidCallback? onDelete;

  final double iconSize;

  const FolderGridTile({
    super.key,
    required this.folderName,
    required this.breadcrumb,
    required this.onTap,
    required this.isAdmin,
    this.onRename,
    this.onMove,
    this.onDelete,
    this.iconSize = 120,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.folder, size: iconSize, color: Colors.blueGrey),
                const SizedBox(height: 6),
                Text(
                  folderName,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
                if (breadcrumb.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                    child: Text(
                      breadcrumb,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (isAdmin)
          Positioned(
            top: -6,
            right: -6,
            child: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == "rename") onRename?.call();
                if (value == "move") onMove?.call();
                if (value == "delete") onDelete?.call();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: "rename", child: Text("Rename")),
                PopupMenuItem(value: "move", child: Text("Move")),
                PopupMenuItem(value: "delete", child: Text("Delete")),
              ],
            ),
          ),
      ],
    );
  }
}
