import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class FullscreenImageViewer extends StatefulWidget {
  final String title;
  final ImageProvider image;

  const FullscreenImageViewer({
    super.key,
    required this.title,
    required this.image,
  });

  factory FullscreenImageViewer.file({
    required String title,
    required String path,
  }) =>
      FullscreenImageViewer(
        title: title,
        image: FileImage(File(path)),
      );

  factory FullscreenImageViewer.memory({
    required String title,
    required Uint8List bytes,
  }) =>
      FullscreenImageViewer(
        title: title,
        image: MemoryImage(bytes),
      );

  @override
  State<FullscreenImageViewer> createState() => _FullscreenImageViewerState();
}

class _FullscreenImageViewerState extends State<FullscreenImageViewer> {
  final TransformationController _controller = TransformationController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _reset() => _controller.value = Matrix4.identity();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Restablecer zoom',
            onPressed: _reset,
            icon: const Icon(Icons.fit_screen_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: InteractiveViewer(
                  transformationController: _controller,
                  minScale: 0.7,
                  maxScale: 8,
                  boundaryMargin: const EdgeInsets.all(120),
                  clipBehavior: Clip.none,
                  child: Image(
                    image: widget.image,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 12,
              child: IgnorePointer(
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Text(
                        'Pellizca para ampliar · Arrastra para mover',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
