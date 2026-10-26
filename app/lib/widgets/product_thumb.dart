import 'dart:io';

import 'package:flutter/material.dart';

/// 商品小图；没有图片时显示占位图标。
class ProductThumb extends StatelessWidget {
  final String? path;
  final double size;
  const ProductThumb(this.path, {super.key, this.size = 48});

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.image_outlined, size: size * 0.5, color: Colors.grey),
    );
    if (path == null) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        File(path!),
        key: ValueKey(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * 3).round(),
        errorBuilder: (_, __, ___) => placeholder,
      ),
    );
  }
}
