import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Pins a disclosure header within its own content, without a second overlay.
class StickyDetailHeader extends MultiChildRenderObjectWidget {
  StickyDetailHeader({super.key, required Widget header, required Widget content})
      : super(children: [content, header]);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderStickyDetailHeader(Scrollable.maybeOf(context)?.position);

  @override
  void updateRenderObject(BuildContext context, covariant RenderStickyDetailHeader renderObject) {
    renderObject.position = Scrollable.maybeOf(context)?.position;
  }
}

class _StickyDetailParentData extends ContainerBoxParentData<RenderBox> {}

class RenderStickyDetailHeader extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _StickyDetailParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _StickyDetailParentData> {
  RenderStickyDetailHeader(this._position);
  ScrollPosition? _position;

  set position(ScrollPosition? value) {
    if (_position == value) return;
    if (attached) _position?.removeListener(_scrolled);
    _position = value;
    if (attached) _position?.addListener(_scrolled);
    markNeedsPaint();
  }

  void _scrolled() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _position?.addListener(_scrolled);
  }

  @override
  void detach() {
    _position?.removeListener(_scrolled);
    super.detach();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _StickyDetailParentData) {
      child.parentData = _StickyDetailParentData();
    }
  }

  @override
  void performLayout() {
    final childConstraints = BoxConstraints.tightFor(width: constraints.maxWidth);
    lastChild!.layout(childConstraints, parentUsesSize: true);
    firstChild!.layout(childConstraints, parentUsesSize: true);
    size = constraints.constrain(Size(constraints.maxWidth,
      firstChild!.size.height + lastChild!.size.height));
    (firstChild!.parentData! as _StickyDetailParentData).offset =
        Offset(0, lastChild!.size.height);
  }

  Offset get _headerOffset {
    final viewport = RenderAbstractViewport.maybeOf(this);
    if (viewport == null) return Offset.zero;
    final top = MatrixUtils.transformPoint(getTransformTo(viewport), Offset.zero).dy;
    return Offset(0, (-top).clamp(0.0, (size.height - lastChild!.size.height).clamp(0.0, double.infinity)));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    context.paintChild(firstChild!, offset +
      (firstChild!.parentData! as _StickyDetailParentData).offset);
    context.paintChild(lastChild!, offset + _headerOffset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in [lastChild!, firstChild!]) {
      final offset = child == lastChild ? _headerOffset :
        (child.parentData! as _StickyDetailParentData).offset;
      if (result.addWithPaintOffset(offset: offset, position: position,
        hitTest: (result, position) => child.hitTest(result, position: position))) {
        return true;
      }
    }
    return false;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = child == lastChild ? _headerOffset :
      (child.parentData! as _StickyDetailParentData).offset;
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }
}
