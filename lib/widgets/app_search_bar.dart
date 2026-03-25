import 'package:flutter/material.dart';

class AppSearchBar extends StatefulWidget {
  final String hint;
  final void Function(String value) onChanged;
  final VoidCallback? onClear;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  const AppSearchBar({
    super.key,
    required this.hint,
    required this.onChanged,
    this.onClear,
    this.controller,
    this.focusNode,
  });

  @override
  State<AppSearchBar> createState() => _AppSearchBarState();
}

class _AppSearchBarState extends State<AppSearchBar> {
  TextEditingController? _internalController;

  TextEditingController get _effectiveController {
    return widget.controller ?? (_internalController ??= TextEditingController());
  }

  void _handleControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _effectiveController.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant AppSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);

    final oldController = oldWidget.controller ?? _internalController;
    final newController = widget.controller ?? _internalController;

    if (!identical(oldController, newController)) {
      oldController?.removeListener(_handleControllerChanged);
      _effectiveController.addListener(_handleControllerChanged);
    }
  }

  @override
  void dispose() {
    (widget.controller ?? _internalController)
        ?.removeListener(_handleControllerChanged);
    _internalController?.dispose();
    super.dispose();
  }

  void _handleClear() {
    _effectiveController.clear();
    widget.onChanged("");
    widget.onClear?.call();
    widget.focusNode?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _effectiveController.text.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: TextField(
        controller: _effectiveController,
        focusNode: widget.focusNode,
        textInputAction: TextInputAction.search,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.text,
        onChanged: widget.onChanged,
        decoration: InputDecoration(
          hintText: widget.hint,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: hasText
              ? IconButton(
            onPressed: _handleClear,
            icon: const Icon(Icons.close),
          )
              : null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          filled: true,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 14,
          ),
        ),
      ),
    );
  }
}