import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/layout/app_layout.dart';

enum SnapSheetSize {
  small('小半屏', .35),
  large('大半屏', .70),
  full('全屏', 1);

  const SnapSheetSize(this.label, this.fraction);
  final String label;
  final double fraction;
}

/// Material's sheet route and DraggableScrollableSheet own resizing/snapping.
/// Only the handle scrolls the sheet; an embedded terminal keeps its own scroll.
Future<T?> showSnapBottomSheet<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  List<Widget> actions = const [],
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  requestFocus: false,
  enableDrag: false,
  showDragHandle: false,
  backgroundColor: Colors.transparent,
  shape: const RoundedRectangleBorder(),
  constraints: const BoxConstraints(maxWidth: double.infinity),
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SnapBottomSheet(title: title, actions: actions, builder: builder),
  ),
);

class SnapBottomSheet extends StatefulWidget {
  const SnapBottomSheet({
    super.key,
    required this.title,
    required this.builder,
    this.actions = const [],
  });
  final String title;
  final WidgetBuilder builder;
  final List<Widget> actions;
  @override
  State<SnapBottomSheet> createState() => _SnapBottomSheetState();
}

class _SnapBottomSheetState extends State<SnapBottomSheet> {
  final _controller = DraggableScrollableController();
  SnapSheetSize _restoreSize = SnapSheetSize.small;
  bool _fullScreen = false;
  bool _programmaticResize = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Keep controls usable in landscape and with the IME visible.
      final minimum = (160 / math.max(1, constraints.maxHeight)).clamp(
        .35,
        1.0,
      );
      final large = math.max(minimum, SnapSheetSize.large.fraction);
      final sizes = {minimum, large, 1.0}.toList()..sort();
      double extentFor(SnapSheetSize size) => math.max(minimum, size.fraction);
      Future<void> animateTo(SnapSheetSize size) => _controller.animateTo(
        extentFor(size),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      Future<void> toggleFullscreen() async {
        final target = _fullScreen ? _restoreSize : SnapSheetSize.full;
        _programmaticResize = true;
        try {
          await animateTo(target);
        } finally {
          _programmaticResize = false;
        }
      }

      return NotificationListener<DraggableScrollableNotification>(
        onNotification: (event) {
          final previousRestore = _restoreSize;
          if (!_programmaticResize && (event.extent - minimum).abs() < .02) {
            _restoreSize = SnapSheetSize.small;
          } else if (!_programmaticResize &&
              (event.extent - large).abs() < .02) {
            _restoreSize = SnapSheetSize.large;
          }
          final full = event.extent >= .98;
          if (_fullScreen != full || previousRestore != _restoreSize) {
            setState(() => _fullScreen = full);
          }
          return false;
        },
        child: DraggableScrollableSheet(
          key: const Key('snap-bottom-sheet'),
          controller: _controller,
          initialChildSize: minimum,
          minChildSize: minimum,
          maxChildSize: 1,
          snap: true,
          snapSizes: sizes,
          shouldCloseOnMinExtent: false,
          expand: false,
          builder: (context, scrollController) => Material(
            color: Theme.of(context).colorScheme.surface,
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(_fullScreen ? 0 : AppLayout.bubbleRadius),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  SizedBox(
                    height: 20,
                    child: ListView(
                      key: const Key('snap-sheet-drag-handle'),
                      controller: scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.zero,
                      children: [
                        Semantics(
                          label: '拖动调整面板大小',
                          increasedValue:
                              (_restoreSize == SnapSheetSize.small
                                      ? SnapSheetSize.large
                                      : SnapSheetSize.full)
                                  .label,
                          decreasedValue:
                              (_fullScreen
                                      ? SnapSheetSize.large
                                      : SnapSheetSize.small)
                                  .label,
                          value:
                              (_fullScreen ? SnapSheetSize.full : _restoreSize)
                                  .label,
                          onIncrease: _fullScreen
                              ? null
                              : () => animateTo(
                                  _restoreSize == SnapSheetSize.small
                                      ? SnapSheetSize.large
                                      : SnapSheetSize.full,
                                ),
                          onDecrease: _fullScreen
                              ? () => animateTo(SnapSheetSize.large)
                              : _restoreSize == SnapSheetSize.large
                              ? () => animateTo(SnapSheetSize.small)
                              : null,
                          child: SizedBox(
                            height: 20,
                            child: Center(
                              child: Container(
                                width: 32,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  borderRadius: BorderRadius.circular(
                                    AppLayout.pillRadius,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: AppLayout.controlHeight,
                    child: Padding(
                      padding: const EdgeInsets.only(left: AppLayout.space16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          ...widget.actions,
                          IconButton(
                            key: const Key('toggle-snap-sheet-fullscreen'),
                            tooltip: _fullScreen ? '还原为半屏' : '全屏',
                            onPressed: minimum == 1 ? null : toggleFullscreen,
                            icon: Icon(
                              _fullScreen
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                            ),
                          ),
                          IconButton(
                            key: const Key('close-snap-sheet'),
                            tooltip: '收起面板',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(child: widget.builder(context)),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
