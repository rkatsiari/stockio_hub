import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/offline_media_service.dart';

class OfflineImageWidget extends StatefulWidget {
  final String tenantId;
  final String productId;
  final String? imageUrl;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final Widget? placeholder;
  final Widget? errorWidget;
  final bool tryNetworkIfMissing;
  final bool persistNetworkImageLocally;

  const OfflineImageWidget({
    super.key,
    required this.tenantId,
    required this.productId,
    required this.imageUrl,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.borderRadius,
    this.placeholder,
    this.errorWidget,
    this.tryNetworkIfMissing = true,
    this.persistNetworkImageLocally = true,
  });

  @override
  State<OfflineImageWidget> createState() => _OfflineImageWidgetState();
}

class _OfflineImageWidgetState extends State<OfflineImageWidget> {
  File? _localFile;
  bool _loading = true;
  bool _networkFailed = false;
  StreamSubscription? _prefetchSubscription;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant OfflineImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = oldWidget.tenantId != widget.tenantId ||
        oldWidget.productId != widget.productId ||
        oldWidget.imageUrl != widget.imageUrl;

    if (changed) {
      _load();
    }
  }

  @override
  void dispose() {
    _prefetchSubscription?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setStateSafe(() {
      _loading = true;
      _networkFailed = false;
      _localFile = null;
    });

    if (!kIsWeb) {
      final local = await OfflineMediaService.instance.getLocalImageFile(
        tenantId: widget.tenantId,
        productId: widget.productId,
      );

      if (!mounted) return;

      if (local != null) {
        setState(() {
          _localFile = local;
          _loading = false;
        });

        if (widget.persistNetworkImageLocally &&
            (widget.imageUrl?.trim().isNotEmpty ?? false)) {
          unawaited(_refreshLocalCopyInBackground());
        }
        return;
      }
    }

    if (widget.tryNetworkIfMissing &&
        (widget.imageUrl?.trim().isNotEmpty ?? false)) {
      if (!kIsWeb && widget.persistNetworkImageLocally) {
        final downloaded = await OfflineMediaService.instance.ensureOfflineImage(
          tenantId: widget.tenantId,
          productId: widget.productId,
          imageUrl: widget.imageUrl,
        );

        if (!mounted) return;

        if (downloaded != null) {
          setState(() {
            _localFile = downloaded;
            _loading = false;
          });
          return;
        }
      }

      setStateSafe(() {
        _loading = false;
      });
      return;
    }

    setStateSafe(() {
      _loading = false;
    });
  }

  Future<void> _refreshLocalCopyInBackground() async {
    try {
      await OfflineMediaService.instance.ensureOfflineImage(
        tenantId: widget.tenantId,
        productId: widget.productId,
        imageUrl: widget.imageUrl,
      );
    } catch (_) {
      // Silent background refresh
    }
  }

  void setStateSafe(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  Widget _defaultPlaceholder() {
    return Container(
      width: widget.width,
      height: widget.height,
      color: Colors.grey.shade200,
      alignment: Alignment.center,
      child: const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  Widget _defaultError() {
    return Container(
      width: widget.width,
      height: widget.height,
      color: Colors.grey.shade200,
      alignment: Alignment.center,
      child: const Icon(
        Icons.image_not_supported_outlined,
        size: 28,
        color: Colors.grey,
      ),
    );
  }

  Widget _wrap(Widget child) {
    if (widget.borderRadius == null) return child;

    return ClipRRect(
      borderRadius: widget.borderRadius!,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return _wrap(widget.placeholder ?? _defaultPlaceholder());
    }

    if (!kIsWeb && _localFile != null) {
      return _wrap(
        Image.file(
          _localFile!,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          errorBuilder: (_, __, ___) {
            return widget.errorWidget ?? _defaultError();
          },
        ),
      );
    }

    final imageUrl = widget.imageUrl?.trim() ?? '';
    if (imageUrl.isNotEmpty && !_networkFailed) {
      return _wrap(
        Image.network(
          imageUrl,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return widget.placeholder ?? _defaultPlaceholder();
          },
          errorBuilder: (context, error, stackTrace) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_networkFailed) {
                setState(() {
                  _networkFailed = true;
                });
              }
            });
            return widget.errorWidget ?? _defaultError();
          },
        ),
      );
    }

    return _wrap(widget.errorWidget ?? _defaultError());
  }
}