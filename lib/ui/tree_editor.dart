import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../room_identity.dart';
import '../room_session.dart';
import '../tree/tree_document.dart';
import '../tree/tree_layout.dart';
import 'person_biography.dart';
import 'tree_search.dart';

const _maleColor = Color(0xFF875826);
const _femaleColor = Color(0xFF28644B);
const _neutralColor = Color(0xFF686C65);
const _siblingColor = Color(0xFF85884A);
const _levelPitch = 176.0;
const _canvasPadding = 24.0;
const _nodeExtent = 108.0;
const _avatarExtent = 60.0;
const _nodeInset = 6.0;
const _minAvatarMm = 4.0;
const _logicalPixelsPerInch = 96.0;
const _millimetersPerInch = 25.4;
// Nominal CSS/Flutter size, not measured physical display density. Round upward
// to a whole percent so the outer avatar never falls below the requested size.
final _minZoom =
    (_minAvatarMm *
            _logicalPixelsPerInch /
            _millimetersPerInch /
            _avatarExtent *
            100)
        .ceil() /
    100;
const _maxZoom = 2.0;

/// A focus-oriented view of the actual room document, not a second family model.
class TreeEditor extends StatefulWidget {
  const TreeEditor({
    super.key,
    required this.session,
    this.initialPersonId,
    this.onPickPerson,
    this.canPickPerson,
  });

  final RoomSession session;
  final String? initialPersonId;
  final ValueChanged<String>? onPickPerson;
  final bool Function(TreePerson)? canPickPerson;

  @override
  State<TreeEditor> createState() => _TreeEditorState();
}

class _TreeEditorState extends State<TreeEditor> {
  final _keyboardFocus = FocusNode(debugLabel: 'Tree canvas shortcuts');
  final _mainScroll = _TreeScrollController();
  final _levelScrolls = <int, _TreeScrollController>{};
  final _scrollRepaint = _ScrollRepaint();
  late TreeDocument _document;
  late Map<String, TreePerson> _people;
  late TreeLayout _layout;
  late String _selectedId;
  List<_BlockConnection> _connections = const [];
  Set<String> _partnerIds = const {};
  TreeTrunkMode _mode = TreeTrunkMode.both;
  _CanvasGeometry? _geometry;
  bool _toolbarExpanded = true;
  bool _biographyOpen = false;
  bool _alignmentPending = true;
  bool _alignmentScheduled = false;
  bool _initialAlignment = true;
  bool _forceAlignment = false;
  bool _hasLayout = false;
  final _pendingCrossAnchors = <int, (double, double)>{};
  (String, double)? _pendingMainAnchor;
  String? _pinnedSelectionId;
  String? _centerSelectionId;
  bool _nodeHovered = false;
  bool _ownsContextMenu = false;
  Future<void> _contextMenuUpdate = Future.value();
  int? _middlePanPointer;
  bool _creatingPerson = false;
  int? _hoveredLevel;
  final _canvasKey = GlobalKey();
  double _zoom = 1;
  double _renderedZoom = 1;
  double _wheelZoomResidual = 0;
  double _crossBefore = 0;
  double _crossAfter = 0;
  double _mainBefore = 0;
  double _mainAfter = 0;
  (_TreeZoomAnchor, Offset)? _pendingZoom;
  final _touches = <int, Offset>{};
  bool _pinching = false;
  bool _suppressNodeTaps = false;
  double _pinchDistance = 1;
  double _pinchZoom = 1;
  _TreeZoomAnchor? _pinchAnchor;

  Offset _canvasPoint(Offset global) {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global) ?? Offset.zero;
  }

  _TreeZoomAnchor? _captureZoomAnchor(Offset focal) {
    final geometry = _geometry;
    if (geometry == null || !_mainScroll.hasClients) return null;
    final main = geometry.horizontal ? focal.dx : focal.dy;
    final cross = geometry.horizontal ? focal.dy : focal.dx;
    return _TreeZoomAnchor(
      horizontal: geometry.horizontal,
      main: _mainScroll.offset + main / _renderedZoom - geometry.mainLeading,
      cross: {
        for (final lane in geometry.levels.values)
          if (_levelScrolls[lane.level.index]?.hasClients ?? false)
            lane.level.index:
                _levelScrolls[lane.level.index]!.offset +
                cross / _renderedZoom -
                lane.origin,
      },
    );
  }

  void _setZoom(
    double value, {
    Offset? focal,
    _TreeZoomAnchor? anchor,
    bool fromWheel = false,
  }) {
    if (!fromWheel) _wheelZoomResidual = 0;
    final next = ((value * 10000).round() / 10000).clamp(_minZoom, _maxZoom);
    if ((next - _zoom).abs() < .00001 && anchor == null) return;
    final geometry = _geometry;
    focal ??= geometry == null
        ? Offset.zero
        : Offset(geometry.viewport.width, geometry.viewport.height) *
              (_renderedZoom / 2);
    anchor ??= _pendingZoom?.$1 ?? _captureZoomAnchor(focal);
    setState(() {
      _zoom = next;
      _pinnedSelectionId = null;
      _centerSelectionId = null;
      if (anchor != null) _pendingZoom = (anchor, focal!);
      _pendingCrossAnchors.clear();
      _pendingMainAnchor = null;
      _alignmentPending = false;
      _forceAlignment = false;
    });
    if (geometry != null && anchor != null) {
      _applyViewOffsets(
        _buildGeometry(
          geometry.viewport * (_renderedZoom / _zoom),
          geometry.horizontal,
        ),
        fromInput: true,
      );
    }
  }

  _CanvasGeometry _buildGeometry(Size viewport, bool horizontal) {
    final transform = _pendingZoom;
    if (transform != null && transform.$1.horizontal == horizontal) {
      final base = _CanvasGeometry(
        layout: _layout,
        viewport: viewport,
        horizontal: horizontal,
      );
      final focal = transform.$2 / _zoom;
      final main =
          base.mainLeading +
          transform.$1.main -
          (horizontal ? focal.dx : focal.dy);
      _mainBefore = math.max(0, -main);
      _mainAfter = math.max(0, main - (base.mainExtent - base.mainViewport));
      _crossBefore = _crossAfter = 0;
      for (final entry in transform.$1.cross.entries) {
        final lane = base.levels[entry.key];
        if (lane == null) continue;
        final target =
            lane.origin + entry.value - (horizontal ? focal.dy : focal.dx);
        _crossBefore = math.max(_crossBefore, -target);
        _crossAfter = math.max(
          _crossAfter,
          target - (lane.crossExtent - lane.viewport),
        );
      }
    }
    final selectedAnchor = _pinnedSelectionId == _selectedId
        ? _pendingCrossAnchors[_layout.positions[_selectedId]?.level]
        : null;
    if (selectedAnchor != null) {
      final base = _CanvasGeometry(
        layout: _layout,
        viewport: viewport,
        horizontal: horizontal,
        crossBefore: _crossBefore,
        crossAfter: _crossAfter,
        mainBefore: _mainBefore,
        mainAfter: _mainAfter,
      );
      final lane = base.levels[_layout.positions[_selectedId]!.level]!;
      final target = lane.origin + selectedAnchor.$1 - selectedAnchor.$2;
      // A visible card can move from the last canonical slot to the first.
      // Extend only presentation padding rather than clamp its requested view
      // anchor. All other rows compensate the same added padding as before.
      _crossBefore += math.max(0, -target);
      _crossAfter += math.max(0, target - (lane.crossExtent - lane.viewport));
    }
    return _CanvasGeometry(
      layout: _layout,
      viewport: viewport,
      horizontal: horizontal,
      crossBefore: _crossBefore,
      crossAfter: _crossAfter,
      mainBefore: _mainBefore,
      mainAfter: _mainAfter,
    );
  }

  void _applyViewOffsets(_CanvasGeometry geometry, {bool fromInput = false}) {
    final transform = _pendingZoom;
    final horizontal = geometry.horizontal;
    if (transform == null || transform.$1.horizontal != horizontal) return;
    final focal = transform.$2 / _zoom;
    _mainScroll.applyViewOffset(
      geometry.mainLeading +
          transform.$1.main -
          (horizontal ? focal.dx : focal.dy),
      viewport: geometry.mainViewport,
      extent: geometry.mainExtent,
      fromInput: fromInput,
    );
    for (final entry in transform.$1.cross.entries) {
      final lane = geometry.levels[entry.key];
      if (lane != null) {
        _levelScrolls[entry.key]?.applyViewOffset(
          lane.origin + entry.value - (horizontal ? focal.dy : focal.dx),
          viewport: lane.viewport,
          extent: lane.crossExtent,
          fromInput: fromInput,
        );
      }
    }
  }

  void _applyLayoutAnchors(_CanvasGeometry geometry, {bool fromInput = false}) {
    for (final entry in _pendingCrossAnchors.entries) {
      final lane = geometry.levels[entry.key];
      if (lane == null) continue;
      _levelScrolls[entry.key]?.applyViewOffset(
        lane.origin + entry.value.$1 - entry.value.$2,
        viewport: lane.viewport,
        extent: lane.crossExtent,
        fromInput: fromInput,
      );
    }
    final anchor = _pendingMainAnchor;
    final position = anchor == null ? null : _layout.positions[anchor.$1];
    final lane = geometry.levels[position?.level];
    if (anchor != null && lane != null) {
      _mainScroll.applyViewOffset(
        lane.mainStart +
            geometry.nodeMainInset +
            _layout.nodeExtent / 2 -
            anchor.$2,
        viewport: geometry.mainViewport,
        extent: geometry.mainExtent,
        fromInput: fromInput,
      );
    }
  }

  void _prepareLayoutAnchors() {
    final geometry = _geometry;
    if (geometry == null) return;
    // Unchanged-size scrollables can skip layout. Apply their correction from
    // input now; changed bounds consume the same staged offset during layout.
    _applyLayoutAnchors(
      _buildGeometry(geometry.viewport, geometry.horizontal),
      fromInput: true,
    );
  }

  void _zoomSignal(PointerSignalEvent event) {
    final double delta;
    if (event is PointerScaleEvent) {
      if (!event.scale.isFinite || event.scale <= 0) return;
      // Flutter web encodes Ctrl-wheel as exp(-deltaY / 200). Recover physical
      // wheel travel instead of multiplying zoom and drifting off the grid.
      delta = -math.log(event.scale) * 200;
    } else if (event is PointerScrollEvent &&
        HardwareKeyboard.instance.isControlPressed) {
      delta = event.scrollDelta.dy;
    } else {
      return;
    }
    if (!delta.isFinite) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _wheelZoom(delta, _canvasPoint(event.position));
      event.respond(allowPlatformDefault: false);
    });
  }

  void _wheelZoom(double delta, Offset focal) {
    if (delta == 0) return;
    final travel = -delta;
    if ((_zoom <= _minZoom && travel < 0) ||
        (_zoom >= _maxZoom && travel > 0)) {
      _wheelZoomResidual = 0;
      return;
    }
    if (_wheelZoomResidual.sign != travel.sign) _wheelZoomResidual = 0;
    _wheelZoomResidual += travel;
    final steps = ((_wheelZoomResidual.abs() + .000001) / 100).floor();
    if (steps == 0) return;
    final direction = _wheelZoomResidual.sign.toInt();
    _wheelZoomResidual -= direction * steps * 100;
    final next = _steppedZoom(_zoom, direction * steps, 5);
    if (next == _minZoom || next == _maxZoom) _wheelZoomResidual = 0;
    _setZoom(next, focal: focal, fromWheel: true);
  }

  void _beginPinch() {
    _wheelZoomResidual = 0;
    final points = _touches.values.take(2).toList();
    _pinchDistance = (points[0] - points[1]).distance;
    if (_pinchDistance < 1) _pinchDistance = 1;
    _pinchZoom = _zoom;
    for (final controller in [_mainScroll, ..._levelScrolls.values]) {
      if (controller.hasClients) controller.jumpTo(controller.offset);
    }
    _pinchAnchor = _captureZoomAnchor((points[0] + points[1]) / 2);
    _suppressNodeTaps = true;
    setState(() => _pinching = true);
  }

  void _touchDown(PointerDownEvent event) {
    if (_touches.isEmpty) _suppressNodeTaps = false;
    if (event.kind != PointerDeviceKind.touch) return;
    _touches[event.pointer] = _canvasPoint(event.position);
    if (_touches.length >= 2) _beginPinch();
  }

  void _touchMove(PointerMoveEvent event) {
    if (!_touches.containsKey(event.pointer)) return;
    _touches[event.pointer] = _canvasPoint(event.position);
    if (!_pinching || _touches.length < 2 || _pinchAnchor == null) return;
    final points = _touches.values.take(2).toList();
    _setZoom(
      _pinchZoom * (points[0] - points[1]).distance / _pinchDistance,
      focal: (points[0] + points[1]) / 2,
      anchor: _pinchAnchor,
    );
  }

  void _touchEnd(PointerEvent event) {
    if (_touches.remove(event.pointer) == null) return;
    if (_touches.length >= 2) {
      _beginPinch();
    } else {
      _pinchAnchor = null;
      if (_touches.isEmpty && _pinching) {
        setState(() => _pinching = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_touches.isEmpty) _suppressNodeTaps = false;
        });
      }
    }
  }

  void _startMiddlePan(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != kMiddleMouseButton) {
      return;
    }
    _middlePanPointer = event.pointer;
    for (final controller in [_mainScroll, ..._levelScrolls.values]) {
      if (controller.hasClients) controller.jumpTo(controller.offset);
    }
  }

  void _moveMiddlePan(PointerMoveEvent event) {
    if (event.pointer != _middlePanPointer || _geometry == null) return;
    if ((event.buttons & kMiddleMouseButton) == 0) {
      _endMiddlePan(event);
      return;
    }
    final pending = _pendingZoom;
    final anchor = pending?.$1 ?? _captureZoomAnchor(Offset.zero);
    if (anchor == null) return;
    // A same-scale focal transform translates every generation equally. Shared
    // padding keeps short rows and rows at their bounds from drifting apart.
    _setZoom(
      _zoom,
      focal: (pending?.$2 ?? Offset.zero) + event.delta,
      anchor: anchor,
    );
  }

  void _endMiddlePan(PointerEvent event) {
    if (event.pointer != _middlePanPointer) return;
    _middlePanPointer = null;
  }

  void _setNodeHovered(bool hovered) {
    if (!kIsWeb) return;
    _nodeHovered = hovered;
    // Serialize platform calls and restore only the setting we changed. Text
    // inputs and the rest of the page keep their normal browser context menu.
    _contextMenuUpdate = _contextMenuUpdate.then((_) async {
      if (_nodeHovered) {
        if (!_ownsContextMenu && BrowserContextMenu.enabled) {
          await BrowserContextMenu.disableContextMenu();
          _ownsContextMenu = true;
        }
      } else if (_ownsContextMenu) {
        await BrowserContextMenu.enableContextMenu();
        _ownsContextMenu = false;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _document = widget.session.tree;
    _selectedId = _defaultSelection();
    _rebuildLayout();
    _mainScroll.addListener(_scrollRepaint.changed);
    widget.session.addListener(_sessionChanged);
  }

  @override
  void didUpdateWidget(covariant TreeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == widget.session) return;
    oldWidget.session.removeListener(_sessionChanged);
    widget.session.addListener(_sessionChanged);
    _document = widget.session.tree;
    _selectedId = _defaultSelection();
    _pinnedSelectionId = null;
    _centerSelectionId = null;
    _hasLayout = false;
    _pendingCrossAnchors.clear();
    _pendingMainAnchor = null;
    _pendingZoom = null;
    _middlePanPointer = null;
    _zoom = _renderedZoom = 1;
    _wheelZoomResidual = 0;
    _crossBefore = _crossAfter = _mainBefore = _mainAfter = 0;
    _forceAlignment = false;
    _touches.clear();
    _pinchAnchor = null;
    _pinching = _suppressNodeTaps = false;
    _initialAlignment = true;
    _requestAlignment();
    _rebuildLayout();
  }

  bool get _picking => widget.onPickPerson != null;

  String _defaultSelection() {
    final initial = widget.initialPersonId;
    if (initial != null && _document.person(initial) != null) return initial;
    final boundId = widget.session.boundPersonId;
    if (boundId != null && _document.person(boundId) != null) return boundId;
    if (_document.person(rootTreePersonId) != null) return rootTreePersonId;
    final ids = _document.people.keys.toList()..sort();
    return ids.firstOrNull ?? rootTreePersonId;
  }

  void _sessionChanged() {
    if (!mounted) return;
    final document = widget.session.tree;
    if (identical(_people, document.people)) {
      if (_picking) setState(() {});
      return;
    }
    final previous = _people[_selectedId];
    final current = document.person(_selectedId);
    final parentsChanged =
        previous?.fatherId != current?.fatherId ||
        previous?.motherId != current?.motherId;
    setState(() {
      _document = document;
      if (current == null) {
        _pinnedSelectionId = null;
        _centerSelectionId = null;
        _selectedId = _defaultSelection();
        _requestAlignment();
      } else if (parentsChanged) {
        // A newly added parent changes the focus geometry. Text/status updates
        // still preserve every independent user-chosen scroll position.
        _initialAlignment = true;
        _requestAlignment();
      }
      _rebuildLayout();
    });
    _prepareLayoutAnchors();
  }

  void _rebuildLayout() {
    final previous = _hasLayout ? _layout : null;
    final geometry = _geometry;
    _people = _document.people;
    _partnerIds = _partnersOf(_document, _selectedId);
    if (_people.isEmpty) {
      _hasLayout = false;
      _geometry = null;
      _connections = const [];
      _pendingCrossAnchors.clear();
      _pendingMainAnchor = null;
      _middlePanPointer = null;
      return;
    }
    _layout = TreeLayout.build(
      _document,
      selectedId: _selectedId,
      mode: _mode,
      nodeExtent: _nodeExtent,
    );
    if (previous != null && geometry != null) {
      final alreadyCaptured = _pendingCrossAnchors.isNotEmpty;
      for (final level in previous.levels) {
        final controller = _levelScrolls[level.index];
        final lane = geometry.levels[level.index];
        if (controller == null || !controller.hasClients || lane == null) {
          continue;
        }
        final translation = _sharedCrossTranslation(previous, _layout, level);
        if (translation == null) continue;
        final pending = _pendingCrossAnchors[level.index];
        if (pending != null) {
          _pendingCrossAnchors[level.index] = (
            pending.$1 + translation,
            pending.$2,
          );
          continue;
        }
        if (alreadyCaptured) continue;
        final center = (level.minCross + level.maxCross) / 2;
        _pendingCrossAnchors[level.index] = (
          center + translation,
          lane.origin + center - controller.offset,
        );
      }
      final anchor = previous.positions[_selectedId];
      final lane = geometry.levels[anchor?.level];
      if (!alreadyCaptured &&
          anchor != null &&
          lane != null &&
          _mainScroll.hasClients) {
        _pendingMainAnchor = (
          anchor.personId,
          lane.mainStart +
              geometry.nodeMainInset +
              previous.nodeExtent / 2 -
              _mainScroll.offset,
        );
      }
    }
    _hasLayout = true;
    for (final level in _layout.levels) {
      _levelScrolls.putIfAbsent(level.index, () {
        return _TreeScrollController()..addListener(_scrollRepaint.changed);
      });
    }
    _connections = _blockConnections(_layout, _document, _selectedId);
  }

  void _requestAlignment() {
    _alignmentPending = true;
  }

  void _alignAll() {
    if (_people.isEmpty) return;
    setState(() {
      _pinnedSelectionId = null;
      _centerSelectionId = null;
      _forceAlignment = true;
      _requestAlignment();
    });
  }

  ({double cross, double main})? _visibleCardAnchor(String id) {
    final geometry = _geometry;
    final position = _layout.positions[id];
    final lane = geometry?.levels[position?.level];
    final controller = _levelScrolls[position?.level];
    if (geometry == null ||
        position == null ||
        lane == null ||
        controller == null ||
        !controller.hasClients ||
        !_mainScroll.hasClients) {
      return null;
    }
    final pending = _pendingCrossAnchors[position.level];
    final cross = pending == null
        ? lane.origin + position.crossCenter - controller.offset
        : pending.$2 + position.crossCenter - pending.$1;
    final mainAnchor = _pendingMainAnchor;
    final mainPosition = mainAnchor == null
        ? null
        : _layout.positions[mainAnchor.$1];
    final main = mainPosition == null
        ? lane.mainStart +
              geometry.nodeMainInset +
              _layout.nodeExtent / 2 -
              _mainScroll.offset
        : mainAnchor!.$2 + (position.level - mainPosition.level) * _levelPitch;
    final half = _layout.nodeExtent / 2;
    if (cross - half < -.01 ||
        cross + half > geometry.crossViewport + .01 ||
        main - half < -.01 ||
        main + half > geometry.mainViewport + .01) {
      return null;
    }
    return (cross: cross, main: main);
  }

  void _select(String id) {
    if (id == _selectedId || _document.person(id) == null) return;
    final anchor = _visibleCardAnchor(id);
    setState(() {
      _selectedId = id;
      _requestAlignment();
      _rebuildLayout();
      _pinnedSelectionId = anchor == null ? null : id;
      // Reordering may reveal a clipped card before deferred alignment runs.
      // Preserve the pre-selection centering request, not its later visibility.
      _centerSelectionId = anchor == null ? id : null;
      if (anchor != null) {
        final position = _layout.positions[id]!;
        // Other rows keep their shared packing origin; only the clicked row
        // follows this card's new slot. Compose with pending anchors when more
        // than one selection arrives before the next layout frame.
        _pendingCrossAnchors[position.level] = (
          position.crossCenter,
          anchor.cross,
        );
        _pendingMainAnchor = (id, anchor.main);
      }
    });
    _prepareLayoutAnchors();
  }

  void _changeMode(TreeTrunkMode mode) {
    if (mode == _mode) return;
    setState(() {
      _pinnedSelectionId = null;
      _centerSelectionId = null;
      _mode = mode;
      _requestAlignment();
      _rebuildLayout();
    });
    _prepareLayoutAnchors();
  }

  KeyEventResult _treeKeyEvent(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (event is! KeyDownEvent ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return KeyEventResult.ignored;
    }
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    if (focusedContext?.findAncestorStateOfType<EditableTextState>() != null) {
      return KeyEventResult.ignored;
    }
    final mode = switch (event.logicalKey) {
      LogicalKeyboardKey.digit1 => TreeTrunkMode.father,
      LogicalKeyboardKey.digit2 => TreeTrunkMode.mother,
      LogicalKeyboardKey.digit3 => TreeTrunkMode.both,
      _ => null,
    };
    if (mode != null) {
      _changeMode(mode);
      return KeyEventResult.handled;
    }
    // Space remains native activation for a focused button. Only the canvas's
    // own focus uses it as Align All; editing/IME and other routes are untouched.
    if (event.logicalKey == LogicalKeyboardKey.space &&
        _keyboardFocus.hasPrimaryFocus) {
      _alignAll();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _scheduleAlignment() {
    if ((!_alignmentPending && _pendingCrossAnchors.isEmpty) ||
        _alignmentScheduled) {
      return;
    }
    _alignmentScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _alignmentScheduled = false;
      if (!mounted || _geometry == null) return;
      final geometry = _geometry!;
      // Preservation offsets were consumed before this frame painted. Only
      // intentional auto-alignment remains a post-frame scroll operation.
      _pendingCrossAnchors.clear();
      _pendingMainAnchor = null;
      if (_alignmentPending) {
        _alignmentPending = false;
        _alignSelection(
          geometry,
          preserveSelectedPosition: _pinnedSelectionId == _selectedId,
          centerSelected: _centerSelectionId == _selectedId,
        );
      }
      _pinnedSelectionId = null;
      _centerSelectionId = null;
      _initialAlignment = false;
      _forceAlignment = false;
    });
  }

  bool _fullyVisible(int level, double start, double end) {
    final controller = _levelScrolls[level];
    if (controller == null || !controller.hasClients) return false;
    return start >= controller.offset + 8 &&
        end <= controller.offset + controller.position.viewportDimension - 8;
  }

  void _move(ScrollController controller, double offset) {
    if (!controller.hasClients) return;
    final target = offset.clamp(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    );
    if ((controller.offset - target).abs() < .5) return;
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    if (_initialAlignment || reduceMotion) {
      controller.jumpTo(target);
    } else {
      // Scroll animations are cancellable by a drag. No state/layout work is
      // performed in their listeners; only the connection painter is invalidated.
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _centerCross(_LevelGeometry geometry, double center) {
    _move(
      _levelScrolls[geometry.level.index]!,
      geometry.origin + center - geometry.viewport / 2,
    );
  }

  void _alignCrossCandidates(
    _LevelGeometry level,
    List<TreeNodePosition> candidates, {
    bool anyVisibleSuffices = false,
  }) {
    if (candidates.isEmpty) return;
    final half = _layout.nodeExtent / 2;
    final start = candidates.map((p) => p.crossCenter - half).reduce(math.min);
    final end = candidates.map((p) => p.crossCenter + half).reduce(math.max);
    final fits = end - start <= level.viewport - 16;
    final visible = anyVisibleSuffices || !fits
        ? candidates.any(
            (p) => _fullyVisible(
              level.level.index,
              level.origin + p.crossCenter - half,
              level.origin + p.crossCenter + half,
            ),
          )
        : _fullyVisible(
            level.level.index,
            level.origin + start,
            level.origin + end,
          );
    if (!_initialAlignment && !_forceAlignment && visible) return;
    var center = (start + end) / 2;
    if (!fits) {
      // Center a real card rather than an empty gap in a very wide family.
      final desired =
          _levelScrolls[level.level.index]!.offset +
          level.viewport / 2 -
          level.origin;
      candidates.sort((a, b) {
        final distance = (a.crossCenter - desired).abs().compareTo(
          (b.crossCenter - desired).abs(),
        );
        return distance != 0 ? distance : a.personId.compareTo(b.personId);
      });
      center = candidates.first.crossCenter;
    }
    _centerCross(level, center);
  }

  void _alignSelection(
    _CanvasGeometry geometry, {
    bool preserveSelectedPosition = false,
    bool centerSelected = false,
  }) {
    final selected = _layout.positions[_selectedId];
    if (selected == null) return;
    final selectedGeometry = geometry.levels[selected.level];
    if (selectedGeometry == null) return;
    final selectedVisible = _fullyVisible(
      selected.level,
      selectedGeometry.origin + selected.crossCenter - _layout.nodeExtent / 2,
      selectedGeometry.origin + selected.crossCenter + _layout.nodeExtent / 2,
    );
    if (!preserveSelectedPosition &&
        (_initialAlignment ||
            _forceAlignment ||
            centerSelected ||
            !selectedVisible)) {
      _centerCross(selectedGeometry, selected.crossCenter);
    }

    final person = _document.person(_selectedId);
    final preferredParents = <String>[
      if (_mode != TreeTrunkMode.mother && person?.fatherId != null)
        person!.fatherId!,
      if (_mode != TreeTrunkMode.father && person?.motherId != null)
        person!.motherId!,
    ];
    // A missing preferred parent does not make the other known parent vanish.
    if (preferredParents.isEmpty) {
      if (person?.fatherId != null) preferredParents.add(person!.fatherId!);
      if (person?.motherId != null) preferredParents.add(person!.motherId!);
    }

    final alignedAncestors = _trunkAncestorsOf(_document, _selectedId, _mode);
    for (final level in geometry.levels.values) {
      if (level.level.index >= selected.level) continue;
      var candidates = _layout.positions.values
          .where(
            (position) =>
                position.level == level.level.index &&
                alignedAncestors.contains(position.personId),
          )
          .toList();
      if (_forceAlignment && candidates.isEmpty) {
        candidates = [
          for (final block in level.level.blocks)
            for (final person in block.people) _layout.positions[person.id]!,
        ];
      }
      _alignCrossCandidates(level, candidates);
    }

    final descendants = _descendantsOf(_document, _selectedId);
    for (final level in geometry.levels.values) {
      if (level.level.index <= selected.level) continue;
      var blocks = level.level.blocks
          .where((block) => block.people.any((p) => descendants.contains(p.id)))
          .toList();
      if (_forceAlignment && blocks.isEmpty) blocks = level.level.blocks;
      _alignCrossCandidates(level, [
        for (final block in blocks)
          for (final person in block.people) _layout.positions[person.id]!,
      ], anyVisibleSuffices: true);
    }

    // Reveal a clipped/explicitly aligned focus together with its preferred
    // parent when they fit. A newly selected, already visible card instead keeps
    // its exact pre-selection position, even if its parent is offscreen.
    var start = selectedGeometry.mainStart + geometry.nodeMainInset;
    var end = start + _layout.nodeExtent;
    final selectedStart = start;
    final selectedEnd = end;
    for (final id in preferredParents) {
      final parent = _layout.positions[id];
      final parentLevel = geometry.levels[parent?.level];
      if (parentLevel == null) continue;
      start = math.min(start, parentLevel.mainStart + geometry.nodeMainInset);
      end = math.max(
        end,
        parentLevel.mainStart + geometry.nodeMainInset + _layout.nodeExtent,
      );
    }
    if (end - start > geometry.mainViewport - 24) {
      start = selectedStart;
      end = selectedEnd;
    }
    final requiredMainVisible =
        _mainScroll.hasClients &&
        start >= _mainScroll.offset + 8 &&
        end <= _mainScroll.offset + geometry.mainViewport - 8;
    if (!preserveSelectedPosition &&
        (_initialAlignment ||
            _forceAlignment ||
            centerSelected ||
            !requiredMainVisible)) {
      _move(_mainScroll, (start + end) / 2 - geometry.mainViewport / 2);
    }
    _scrollRepaint.changed();
  }

  Future<String?> _pickFromTree(
    String initialPersonId,
    bool Function(TreePerson) canPick,
  ) {
    _setNodeHovered(false);
    return Navigator.of(context, rootNavigator: true).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (routeContext) => Scaffold(
          key: const Key('tree-person-picker-route'),
          appBar: AppBar(
            title: const Text('Выбрать из дерева'),
            leading: IconButton(
              tooltip: 'Отмена выбора',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(routeContext).pop(),
            ),
          ),
          body: SafeArea(
            child: TreeEditor(
              session: widget.session,
              initialPersonId: initialPersonId,
              canPickPerson: canPick,
              onPickPerson: (id) => Navigator.of(routeContext).pop(id),
            ),
          ),
        ),
      ),
    );
  }

  void _tapPerson(String id) {
    if (_suppressNodeTaps) return;
    _select(id);
  }

  bool get _canConfirmPerson {
    final person = widget.session.tree.person(_selectedId);
    return person != null && (widget.canPickPerson?.call(person) ?? true);
  }

  void _confirmPerson() {
    if (!_picking || !_canConfirmPerson || _suppressNodeTaps) return;
    widget.onPickPerson!(_selectedId);
  }

  void _openBiography(bool desktop) {
    if (_picking) return;
    if (desktop) {
      setState(() => _biographyOpen = true);
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (routeContext) => Scaffold(
          key: const Key('tree-biography-route'),
          body: SafeArea(
            child: PersonBiography(
              session: widget.session,
              personId: _selectedId,
              fullScreen: true,
              onPickFromTree: _pickFromTree,
              onSelect: (id) {
                _select(id);
                Navigator.of(routeContext).pop();
              },
              onClose: () => Navigator.of(routeContext).pop(),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _setNodeHovered(false);
    widget.session.removeListener(_sessionChanged);
    _keyboardFocus.dispose();
    _mainScroll.dispose();
    for (final controller in _levelScrolls.values) {
      controller.dispose();
    }
    _scrollRepaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      key: const Key('tree-keyboard-focus'),
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _treeKeyEvent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 900;
          return Column(
            children: [
              if (_toolbarExpanded)
                _TreeToolbar(
                  mode: _mode,
                  onAlign: _alignAll,
                  people: _document.people,
                  onSearchSelect: _tapPerson,
                  onToggle: () => setState(() => _toolbarExpanded = false),
                  onMode: _changeMode,
                  zoom: _zoom,
                  onZoom: (value) => _setZoom(value),
                ),
              if (_picking)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('Найдите человека и подтвердите выбор галочкой'),
                ),
              Expanded(
                child: Stack(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _buildCanvas(context, desktop)),
                        if (!_picking && desktop && _biographyOpen)
                          SizedBox(
                            width: 360,
                            child: DecoratedBox(
                              key: const Key('tree-biography-panel'),
                              decoration: BoxDecoration(
                                border: Border(
                                  left: BorderSide(
                                    color: Theme.of(context).dividerColor,
                                  ),
                                ),
                              ),
                              child: PersonBiography(
                                session: widget.session,
                                personId: _selectedId,
                                onSelect: _select,
                                onPickFromTree: _pickFromTree,
                                onClose: () =>
                                    setState(() => _biographyOpen = false),
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (!_toolbarExpanded)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: IconButton.filledTonal(
                          key: const Key('tree-toolbar-toggle'),
                          tooltip: 'Развернуть панель дерева',
                          onPressed: () =>
                              setState(() => _toolbarExpanded = true),
                          icon: const Icon(Icons.tune),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addPersonToEmptyTree(bool desktop) async {
    if (_creatingPerson || !widget.session.canEdit) return;
    setState(() => _creatingPerson = true);
    try {
      final id = 'person-${createRoomId()}';
      await widget.session.applyTreeOperation(
        widget.session.tree.createPerson(id),
      );
      if (!mounted) return;
      _select(id);
      _openBiography(desktop);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось добавить человека: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _creatingPerson = false);
    }
  }

  Widget _buildCanvas(BuildContext context, bool desktop) {
    if (_people.isEmpty) {
      return Center(
        key: const Key('tree-empty'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('В дереве пока никого нет'),
            if (!_picking && widget.session.canEdit) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('tree-add-person'),
                onPressed: _creatingPerson
                    ? null
                    : () => _addPersonToEmptyTree(desktop),
                icon: const Icon(Icons.person_add_alt_outlined),
                label: const Text('Добавить человека'),
              ),
            ],
          ],
        ),
      );
    }
    final horizontal =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(
          constraints.maxWidth / _zoom,
          constraints.maxHeight / _zoom,
        );
        final previous = _geometry;
        if (previous != null && previous.horizontal != horizontal) {
          _pendingZoom = null;
          _crossBefore = _crossAfter = _mainBefore = _mainAfter = 0;
          _pendingCrossAnchors.clear();
          _pendingMainAnchor = null;
          _initialAlignment = true;
          _requestAlignment();
        }
        final geometry = _buildGeometry(viewport, horizontal);
        _applyViewOffsets(geometry);
        _applyLayoutAnchors(geometry);
        _pendingZoom = null;
        _geometry = geometry;
        _renderedZoom = _zoom;
        _scheduleAlignment();
        return Listener(
          key: _canvasKey,
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            _touchDown(event);
            _startMiddlePan(event);
          },
          onPointerMove: (event) {
            _touchMove(event);
            _moveMiddlePan(event);
          },
          onPointerUp: (event) {
            // Wait until tap-outside handling on pointer down has unfocused
            // any text input; otherwise it can override the canvas request.
            _keyboardFocus.requestFocus();
            _touchEnd(event);
            _endMiddlePan(event);
          },
          onPointerCancel: (event) {
            _touchEnd(event);
            _endMiddlePan(event);
          },
          onPointerSignal: _zoomSignal,
          child: ColoredBox(
            key: const Key('tree-canvas'),
            color: Theme.of(context).colorScheme.surface,
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: viewport.width,
                      maxWidth: viewport.width,
                      minHeight: viewport.height,
                      maxHeight: viewport.height,
                      child: Transform.scale(
                        scale: _zoom,
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: viewport.width,
                          height: viewport.height,
                          child: _buildTreeScene(context, geometry, desktop),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 16,
                    right: 16,
                    child: _picking
                        ? IconButton.filledTonal(
                            key: const Key('confirm-tree-person'),
                            onPressed: _canConfirmPerson
                                ? _confirmPerson
                                : null,
                            tooltip: 'Подтвердить выбор',
                            style: IconButton.styleFrom(
                              fixedSize: const Size.square(56),
                              iconSize: 28,
                            ),
                            icon: const Icon(Icons.check),
                          )
                        : IconButton.filledTonal(
                            key: const Key('open-biography'),
                            onPressed: () => _openBiography(desktop),
                            tooltip: 'Биография',
                            style: IconButton.styleFrom(
                              fixedSize: const Size.square(56),
                              iconSize: 28,
                            ),
                            icon: const Icon(Icons.badge_outlined),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTreeScene(
    BuildContext context,
    _CanvasGeometry geometry,
    bool desktop,
  ) {
    final horizontal = geometry.horizontal;
    final bands = [
      for (final level in _layout.levels)
        _GenerationBand(
          key: ValueKey('tree-level-${level.index}'),
          geometry: geometry.levels[level.index]!,
          horizontal: horizontal,
          controller: _levelScrolls[level.index]!,
          mainController: _mainScroll,
          zoom: _zoom,
          onZoomSignal: _zoomSignal,
          positions: _layout.positions,
          nodeExtent: _layout.nodeExtent,
          selectedId: _selectedId,
          partnerIds: _partnerIds,
          onSelect: _tapPerson,
          canPickPerson: _picking ? widget.canPickPerson : null,
          onNodeHover: _setNodeHovered,
          highlighted: _hoveredLevel == level.index,
          onLevelHover: (hovered) {
            final next = hovered
                ? level.index
                : (_hoveredLevel == level.index ? null : _hoveredLevel);
            if (next != _hoveredLevel) setState(() => _hoveredLevel = next);
          },
          onBiography: (id) {
            if (_suppressNodeTaps) return;
            _select(id);
            _openBiography(desktop);
          },
        ),
    ];
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        scrollbars: false,
        physics: _pinching ? const NeverScrollableScrollPhysics() : null,
        dragDevices: {
          ...ScrollConfiguration.of(context).dragDevices,
          PointerDeviceKind.mouse,
        },
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const Key('tree-links'),
                  painter: _TreeLinkPainter(
                    geometry: geometry,
                    layout: _layout,
                    connections: _connections,
                    mainScroll: _mainScroll,
                    levelScrolls: _levelScrolls,
                    repaint: _scrollRepaint,
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Scrollbar(
              controller: _mainScroll,
              notificationPredicate: (notification) => notification.depth == 0,
              child: SingleChildScrollView(
                key: const Key('tree-main-scroll'),
                controller: _mainScroll,
                primary: false,
                scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerSignal: (event) {
                    if (event is PointerScaleEvent ||
                        (event is PointerScrollEvent &&
                            HardwareKeyboard.instance.isControlPressed)) {
                      _zoomSignal(event);
                      return;
                    }
                    if (event is! PointerScrollEvent) return;
                    // Padding has no generation listener. Keep the main-axis
                    // wheel in physical units here as well, before Scrollable.
                    GestureBinding.instance.pointerSignalResolver.register(
                      event,
                      (_) {
                        final delta = horizontal
                            ? event.scrollDelta.dx
                            : event.scrollDelta.dy;
                        if (_mainScroll.hasClients) {
                          _mainScroll.position.pointerScroll(delta / _zoom);
                        }
                        event.respond(allowPlatformDefault: false);
                      },
                    );
                  },
                  child: SizedBox(
                    width: horizontal
                        ? geometry.mainExtent
                        : geometry.viewport.width,
                    height: horizontal
                        ? geometry.viewport.height
                        : geometry.mainExtent,
                    // Retain generation scroll views when rotating. Replacing
                    // Row with Column leaves the old views attached until this
                    // frame ends, so painting sees two clients per controller.
                    child: Flex(
                      direction: horizontal ? Axis.horizontal : Axis.vertical,
                      textDirection: TextDirection.ltr,
                      children: [
                        SizedBox(
                          width: horizontal ? geometry.mainLeading : null,
                          height: horizontal ? null : geometry.mainLeading,
                        ),
                        ...bands,
                        SizedBox(
                          width: horizontal ? geometry.mainTrailing : null,
                          height: horizontal ? null : geometry.mainTrailing,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TreeToolbar extends StatefulWidget {
  const _TreeToolbar({
    required this.mode,
    required this.onAlign,
    required this.people,
    required this.onSearchSelect,
    required this.onToggle,
    required this.onMode,
    required this.zoom,
    required this.onZoom,
  });

  final TreeTrunkMode mode;
  final VoidCallback onAlign;
  final Map<String, TreePerson> people;
  final ValueChanged<String> onSearchSelect;
  final VoidCallback onToggle;
  final ValueChanged<TreeTrunkMode> onMode;
  final double zoom;
  final ValueChanged<double> onZoom;

  @override
  State<_TreeToolbar> createState() => _TreeToolbarState();
}

class _TreeToolbarState extends State<_TreeToolbar> {
  bool _searchFocused = false;

  String _tooltip(String label, String shortcut) =>
      switch (Theme.of(context).platform) {
        TargetPlatform.linux ||
        TargetPlatform.macOS ||
        TargetPlatform.windows => '$label\n$shortcut',
        _ => label,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mobile = MediaQuery.sizeOf(context).width < 900;
    final expandedSearch = mobile && _searchFocused;
    return Material(
      key: const Key('tree-toolbar'),
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: SizedBox(
              height: 40,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final searchWidth = expandedSearch
                      ? constraints.maxWidth
                      : math.min(mobile ? 64.0 : 240.0, constraints.maxWidth);
                  return Row(
                    children: [
                      if (!expandedSearch) ...[
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _iconButton(
                                    key: const Key('tree-toolbar-toggle'),
                                    tooltip: 'Свернуть панель дерева',
                                    onPressed: widget.onToggle,
                                    icon: Icons.expand_less,
                                  ),
                                  _modePicker(context),
                                  _iconButton(
                                    key: const Key('tree-align-all'),
                                    tooltip: _tooltip(
                                      'Выровнять всё',
                                      'Пробел',
                                    ),
                                    onPressed: widget.onAlign,
                                    icon: Icons.center_focus_strong,
                                  ),
                                  _zoomControls(),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      // Keep this keyed slot (and its input/focus/overlay state)
                      // when the other controls disappear on mobile focus.
                      SizedBox(
                        key: const ValueKey('tree-toolbar-search'),
                        width: searchWidth,
                        child: TreePersonSearch(
                          people: widget.people,
                          onSelected: widget.onSearchSelect,
                          compact: mobile && !expandedSearch,
                          showBackButton: expandedSearch,
                          onFocusChanged: (focused) =>
                              setState(() => _searchFocused = focused),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          Divider(height: 1, color: theme.dividerColor),
        ],
      ),
    );
  }

  Widget _modePicker(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 36,
      height: 40,
      child: PopupMenuButton<TreeTrunkMode>(
        key: const Key('tree-mode-picker'),
        tooltip: _tooltip(
          'Линия дерева: ${_modeTitle(widget.mode)}',
          '1 — по отцу\n2 — по матери\n3 — обе линии',
        ),
        initialValue: widget.mode,
        padding: EdgeInsets.zero,
        icon: Icon(_modeIcon(widget.mode), size: 20),
        onSelected: widget.onMode,
        constraints: const BoxConstraints(maxWidth: 340),
        itemBuilder: (context) => [
          for (final candidate in TreeTrunkMode.values)
            PopupMenuItem<TreeTrunkMode>(
              key: ValueKey('tree-mode-${candidate.name}'),
              value: candidate,
              height: 76,
              child: Semantics(
                selected: widget.mode == candidate,
                child: Row(
                  children: [
                    Icon(_modeIcon(candidate), size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _modeTitle(candidate),
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _modeDescription(candidate),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (widget.mode == candidate) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.check, size: 20),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _zoomControls() => Row(
    key: const Key('tree-zoom-controls'),
    mainAxisSize: MainAxisSize.min,
    children: [
      _iconButton(
        key: const Key('tree-zoom-out'),
        tooltip: _tooltip('Уменьшить масштаб', 'Ctrl + колесо вниз'),
        onPressed: widget.zoom <= _minZoom + .0001
            ? null
            : () => widget.onZoom(_steppedZoom(widget.zoom, -1, 10)),
        icon: Icons.remove,
      ),
      _iconButton(
        key: const Key('tree-zoom-in'),
        tooltip: _tooltip('Увеличить масштаб', 'Ctrl + колесо вверх'),
        onPressed: widget.zoom >= _maxZoom - .0001
            ? null
            : () => widget.onZoom(_steppedZoom(widget.zoom, 1, 10)),
        icon: Icons.add,
      ),
      SizedBox(
        width: 44,
        height: 40,
        child: Tooltip(
          message: 'Сбросить масштаб',
          child: TextButton(
            key: const Key('tree-zoom-reset'),
            onPressed: (widget.zoom - 1).abs() < .0001
                ? null
                : () => widget.onZoom(1),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '${(widget.zoom * 100).round()}%',
                key: const Key('tree-zoom-value'),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _iconButton({
    required Key key,
    required String tooltip,
    required VoidCallback? onPressed,
    required IconData icon,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: 20),
    style: IconButton.styleFrom(
      fixedSize: const Size(32, 40),
      minimumSize: const Size(32, 40),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );
}

double _steppedZoom(double zoom, int steps, int percentagePoints) {
  final current = zoom * 100 / percentagePoints;
  final grid = steps > 0
      ? (current + .000001).floor() + steps
      : (current - .000001).ceil() + steps;
  return (grid * percentagePoints / 100).clamp(_minZoom, _maxZoom);
}

String _modeTitle(TreeTrunkMode mode) => switch (mode) {
  TreeTrunkMode.father => 'По отцу',
  TreeTrunkMode.mother => 'По матери',
  TreeTrunkMode.both => 'Обе линии',
};

String _modeDescription(TreeTrunkMode mode) => switch (mode) {
  TreeTrunkMode.father => 'Ствол дерева — предки по отцовской линии',
  TreeTrunkMode.mother => 'Ствол дерева — предки по материнской линии',
  TreeTrunkMode.both => 'Ствол дерева — обе родительские линии',
};

IconData _modeIcon(TreeTrunkMode mode) => switch (mode) {
  TreeTrunkMode.father => Icons.man,
  TreeTrunkMode.mother => Icons.woman,
  TreeTrunkMode.both => Icons.account_tree_outlined,
};

Color _sexColor(TreeSex sex) => switch (sex) {
  TreeSex.male => _maleColor,
  TreeSex.female => _femaleColor,
  TreeSex.unknown => _neutralColor,
};

IconData _sexIcon(TreeSex sex) => switch (sex) {
  TreeSex.male => Icons.male,
  TreeSex.female => Icons.female,
  TreeSex.unknown => Icons.person_outline,
};

class _TreeZoomAnchor {
  const _TreeZoomAnchor({
    required this.horizontal,
    required this.main,
    required this.cross,
  });

  final bool horizontal;
  final double main;
  final Map<int, double> cross;
}

/// Reconcile a view anchor with new scroll bounds during layout, before paint.
/// Keeping this on the controller also survives pinch-time physics replacement.
class _TreeScrollController extends ScrollController {
  double? viewOffset;

  void applyViewOffset(
    double value, {
    required double viewport,
    required double extent,
    bool fromInput = false,
  }) {
    if (fromInput &&
        hasClients &&
        (position.viewportDimension - viewport).abs() < .00001 &&
        (position.maxScrollExtent - math.max(0, extent - viewport)).abs() <
            .00001) {
      // An unchanged-size viewport may skip layout entirely during a pan.
      // Notify paint/semantics from the input phase, never from LayoutBuilder.
      (position as _TreeScrollPosition).applyViewOffset(value);
    }
    viewOffset = hasClients && (offset - value).abs() < .00001 ? null : value;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _TreeScrollPosition(
    controller: this,
    physics: physics,
    context: context,
    oldPosition: oldPosition,
  );
}

class _TreeScrollPosition extends ScrollPositionWithSingleContext {
  _TreeScrollPosition({
    required this.controller,
    required super.physics,
    required super.context,
    super.oldPosition,
  });

  final _TreeScrollController controller;
  bool _correctionNotificationScheduled = false;

  void applyViewOffset(double value) {
    final target = value.clamp(minScrollExtent, maxScrollExtent);
    if ((pixels - target).abs() > .00001) forcePixels(target);
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final target = controller.viewOffset;
    if (target != null) {
      controller.viewOffset = null;
      final corrected = target.clamp(minScrollExtent, maxScrollExtent);
      if ((pixels - corrected).abs() > .00001) {
        correctPixels(corrected);
        if (!_correctionNotificationScheduled) {
          _correctionNotificationScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_correctionNotificationScheduled) return;
            _correctionNotificationScheduled = false;
            // Layout corrections are silent, but scroll semantics must not keep
            // the old offset when an enclosing scrollable subsequently moves.
            notifyListeners();
          });
        }
      }
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }

  @override
  void dispose() {
    _correctionNotificationScheduled = false;
    super.dispose();
  }
}

/// Follow shared row translation, never the movement of a reordered focus or
/// first-visible parent. With the same block membership and span, the packed
/// row's origin is the common translation even when blocks or siblings permute.
/// For changed membership, infer the translation from surviving card cohorts.
double? _sharedCrossTranslation(
  TreeLayout before,
  TreeLayout after,
  TreeGeneration level,
) {
  final next = after.levels.where((l) => l.index == level.index).firstOrNull;
  if (next == null) return null;
  final originShift =
      (next.minCross + next.maxCross - level.minCross - level.maxCross) / 2;
  final nextBlocks = {for (final block in next.blocks) block.id: block};
  final packedStart = level.blocks.first.start;
  final nextPackedStart = next.blocks.first.start;
  final packedEnd = level.blocks.last.start + level.blocks.last.extent;
  final nextPackedEnd = next.blocks.last.start + next.blocks.last.extent;
  final samePackedRow =
      before.nodeExtent == after.nodeExtent &&
      before.gap == after.gap &&
      level.blocks.length == next.blocks.length &&
      ((packedEnd - packedStart) - (nextPackedEnd - nextPackedStart)).abs() <
          .001 &&
      level.blocks.every((block) {
        final current = nextBlocks[block.id];
        return current != null &&
            (block.extent - current.extent).abs() < .001 &&
            setEquals(
              block.people.map((person) => person.id).toSet(),
              current.people.map((person) => person.id).toSet(),
            );
      });
  // Reordered father blocks can form the largest equal-shift card cohort.
  // Anchoring that cohort would pan an otherwise unchanged row along with the
  // reordered block. Preserve its packed origin instead; required parent seams
  // and internal sibling permutations still use the new canonical geometry.
  // Use actual content edges: minCross/maxCross can include a virtual zero
  // outside a one-sided row, whose midpoint would halve its real translation.
  if (samePackedRow) return nextPackedStart - packedStart;
  final shifts = <({double shift, int stableMembers})>[];
  for (final block in level.blocks) {
    final current = nextBlocks[block.id];
    final stable =
        current != null &&
        listEquals(
          block.people.map((p) => p.id).toList(),
          current.people.map((p) => p.id).toList(),
        );
    for (final person in block.people) {
      final old = before.positions[person.id]!;
      final position = after.positions[person.id];
      if (position == null || position.level != level.index) continue;
      shifts.add((
        shift: position.crossCenter - old.crossCenter,
        stableMembers: stable ? block.people.length : 0,
      ));
    }
  }
  if (shifts.isEmpty) return originShift;
  shifts.sort((a, b) => a.shift.compareTo(b.shift));
  var bestShift = originShift;
  var bestCount = 0;
  var bestStable = 0;
  for (var start = 0; start < shifts.length;) {
    final shift = shifts[start].shift;
    var end = start;
    var stable = 0;
    while (end < shifts.length && (shifts[end].shift - shift).abs() < .001) {
      stable = math.max(stable, shifts[end].stableMembers);
      end++;
    }
    final count = end - start;
    if (count > bestCount ||
        (count == bestCount && stable > bestStable) ||
        (count == bestCount &&
            stable == bestStable &&
            (shift - originShift).abs() < (bestShift - originShift).abs())) {
      bestShift = shift;
      bestCount = count;
      bestStable = stable;
    }
    start = end;
  }
  return bestCount > 1 || shifts.length == 1 ? bestShift : originShift;
}

class _CanvasGeometry {
  _CanvasGeometry({
    required TreeLayout layout,
    required this.viewport,
    required this.horizontal,
    double crossBefore = 0,
    double crossAfter = 0,
    double mainBefore = 0,
    double mainAfter = 0,
  }) : nodeExtent = layout.nodeExtent {
    final baseMainExtent = math.max(
      mainViewport,
      layout.levels.length * _levelPitch + _canvasPadding * 2,
    );
    mainExtent = baseMainExtent + mainBefore + mainAfter;
    mainLeading =
        (baseMainExtent - layout.levels.length * _levelPitch) / 2 + mainBefore;
    mainTrailing =
        (baseMainExtent - layout.levels.length * _levelPitch) / 2 + mainAfter;
    for (var i = 0; i < layout.levels.length; i++) {
      final level = layout.levels[i];
      levels[level.index] = _LevelGeometry(
        level: level,
        viewport: crossViewport,
        mainStart: mainLeading + i * _levelPitch,
        nodeExtent: nodeExtent,
        before: crossBefore,
        after: crossAfter,
      );
    }
  }

  final Size viewport;
  final bool horizontal;
  final double nodeExtent;
  final levels = <int, _LevelGeometry>{};
  late final double mainExtent;
  late final double mainLeading;
  late final double mainTrailing;

  double get mainViewport => horizontal ? viewport.width : viewport.height;
  double get crossViewport => horizontal ? viewport.height : viewport.width;
  double get nodeMainInset => (_levelPitch - nodeExtent) / 2;

  Rect personRect(
    TreeNodePosition position,
    double mainOffset,
    double crossOffset,
  ) {
    final level = levels[position.level]!;
    final main = level.mainStart + nodeMainInset - mainOffset;
    final cross =
        level.origin + position.crossCenter - nodeExtent / 2 - crossOffset;
    return horizontal
        ? Rect.fromLTWH(main, cross, nodeExtent, nodeExtent)
        : Rect.fromLTWH(cross, main, nodeExtent, nodeExtent);
  }
}

class _LevelGeometry {
  _LevelGeometry({
    required this.level,
    required this.viewport,
    required this.mainStart,
    required double nodeExtent,
    double before = 0,
    double after = 0,
  }) {
    // Any card, including the first/last sibling, can become the centered focus.
    final padding = math.max(_canvasPadding, (viewport - nodeExtent) / 2);
    final baseExtent = math.max(
      viewport,
      level.maxCross - level.minCross + padding * 2,
    );
    crossExtent = baseExtent + before + after;
    origin =
        (baseExtent - (level.maxCross - level.minCross)) / 2 -
        level.minCross +
        before;
  }

  final TreeGeneration level;
  final double viewport;
  final double mainStart;
  late final double crossExtent;
  late final double origin;
}

class _GenerationBand extends StatelessWidget {
  const _GenerationBand({
    super.key,
    required this.geometry,
    required this.horizontal,
    required this.controller,
    required this.mainController,
    required this.zoom,
    required this.onZoomSignal,
    required this.positions,
    required this.nodeExtent,
    required this.selectedId,
    required this.partnerIds,
    required this.onSelect,
    required this.onBiography,
    required this.onNodeHover,
    required this.highlighted,
    required this.onLevelHover,
    this.canPickPerson,
  });

  final _LevelGeometry geometry;
  final bool horizontal;
  final ScrollController controller;
  final ScrollController mainController;
  final double zoom;
  final ValueChanged<PointerSignalEvent> onZoomSignal;
  final Map<String, TreeNodePosition> positions;
  final double nodeExtent;
  final String selectedId;
  final Set<String> partnerIds;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onBiography;
  final ValueChanged<bool> onNodeHover;
  final bool highlighted;
  final ValueChanged<bool> onLevelHover;
  final bool Function(TreePerson)? canPickPerson;

  @override
  Widget build(BuildContext context) {
    final mainInset = (_levelPitch - nodeExtent) / 2;
    return SizedBox(
      width: horizontal ? _levelPitch : geometry.viewport,
      height: horizontal ? geometry.viewport : _levelPitch,
      child: MouseRegion(
        onEnter: (_) => onLevelHover(true),
        onExit: (_) => onLevelHover(false),
        child: ColoredBox(
          key: ValueKey('tree-level-highlight-${geometry.level.index}'),
          color: highlighted
              ? Theme.of(context).colorScheme.onSurface.withValues(alpha: .035)
              : Colors.transparent,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              key: ValueKey('tree-level-scroll-${geometry.level.index}'),
              controller: controller,
              primary: false,
              scrollDirection: horizontal ? Axis.vertical : Axis.horizontal,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerSignal: (event) {
                  if (event is PointerScaleEvent ||
                      (event is PointerScrollEvent &&
                          HardwareKeyboard.instance.isControlPressed)) {
                    onZoomSignal(event);
                    return;
                  }
                  if (event is! PointerScrollEvent) return;
                  GestureBinding.instance.pointerSignalResolver.register(
                    event,
                    (_) {
                      final vertical = horizontal ? controller : mainController;
                      final sideways = horizontal ? mainController : controller;
                      if (vertical.hasClients && event.scrollDelta.dy != 0) {
                        vertical.position.pointerScroll(
                          event.scrollDelta.dy / zoom,
                        );
                      }
                      if (sideways.hasClients && event.scrollDelta.dx != 0) {
                        sideways.position.pointerScroll(
                          event.scrollDelta.dx / zoom,
                        );
                      }
                      event.respond(allowPlatformDefault: false);
                    },
                  );
                },
                child: SizedBox(
                  width: horizontal ? _levelPitch : geometry.crossExtent,
                  height: horizontal ? geometry.crossExtent : _levelPitch,
                  child: Stack(
                    children: [
                      for (final block in geometry.level.blocks)
                        Positioned(
                          left: horizontal
                              ? mainInset - 6
                              : geometry.origin + block.start - 6,
                          top: horizontal
                              ? geometry.origin + block.start - 6
                              : mainInset - 6,
                          width: horizontal
                              ? nodeExtent + 12
                              : block.extent + 12,
                          height: (horizontal ? block.extent : nodeExtent) + 12,
                          child: DecoratedBox(
                            key: ValueKey('tree-block-${block.id}'),
                            decoration: BoxDecoration(
                              color: switch (block.emphasis) {
                                TreeEmphasis.normal => _siblingColor.withValues(
                                  alpha: .24,
                                ),
                                TreeEmphasis.cousin => _siblingColor.withValues(
                                  alpha: .14,
                                ),
                                TreeEmphasis.distant =>
                                  _neutralColor.withValues(alpha: .24),
                              },
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                        ),
                      for (final block in geometry.level.blocks)
                        for (final person in block.people)
                          Positioned(
                            left: horizontal
                                ? mainInset
                                : geometry.origin +
                                      positions[person.id]!.crossCenter -
                                      nodeExtent / 2,
                            top: horizontal
                                ? geometry.origin +
                                      positions[person.id]!.crossCenter -
                                      nodeExtent / 2
                                : mainInset,
                            width: nodeExtent,
                            height: nodeExtent,
                            child: MouseRegion(
                              onEnter: (_) => onNodeHover(true),
                              onExit: (_) => onNodeHover(false),
                              child: _TreePersonNode(
                                key: ValueKey('tree-person-${person.id}'),
                                person: person,
                                selected: selectedId == person.id,
                                emphasis: partnerIds.contains(person.id)
                                    ? TreeEmphasis.normal
                                    : positions[person.id]!.emphasis,
                                availableForPicking:
                                    canPickPerson?.call(person) ?? true,
                                onSelect: () => onSelect(person.id),
                                onBiography: () => onBiography(person.id),
                              ),
                            ),
                          ),
                      for (final block in geometry.level.blocks)
                        if (surnameForBlock(block.people).isNotEmpty)
                          Positioned(
                            left: horizontal
                                ? mainInset - 4
                                : geometry.origin + block.start - 4,
                            top: horizontal
                                ? geometry.origin +
                                      block.start +
                                      block.extent +
                                      8
                                : mainInset + nodeExtent + 8,
                            width: (horizontal ? nodeExtent : block.extent) + 8,
                            height: 20,
                            child: Center(
                              child: Text(
                                surnameForBlock(block.people),
                                key: ValueKey('tree-block-surname-${block.id}'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: .50),
                                    ),
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TreePersonNode extends StatelessWidget {
  const _TreePersonNode({
    super.key,
    required this.person,
    required this.selected,
    required this.emphasis,
    required this.onSelect,
    required this.onBiography,
    required this.availableForPicking,
  });

  final TreePerson person;
  final bool selected;
  final TreeEmphasis emphasis;
  final bool availableForPicking;
  final VoidCallback onSelect;
  final VoidCallback onBiography;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = person.displayName;
    Widget node = Material(
      color: selected
          ? theme.colorScheme.surfaceContainerLowest.withValues(alpha: .5)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? _sexColor(person.sex) : Colors.transparent,
          width: 1.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSelect,
        onSecondaryTap: onBiography,
        excludeFromSemantics: true,
        child: Padding(
          padding: const EdgeInsets.all(_nodeInset),
          child: Column(
            children: [
              _PersonAvatar(person: person),
              const SizedBox(height: 4),
              Expanded(
                child: Center(
                  child: DecoratedBox(
                    key: ValueKey('tree-name-background-${person.id}'),
                    decoration: BoxDecoration(
                      color: selected
                          ? theme.colorScheme.surfaceContainerLowest
                          : theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 3,
                        vertical: 1,
                      ),
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: _sexColor(person.sex),
                          height: 1.15,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (emphasis != TreeEmphasis.normal) {
      // Filter the whole card: photographs and text must fade with the branch,
      // not just its avatar ring. Names remain legible (no opacity reduction).
      node = ColorFiltered(
        colorFilter: ColorFilter.matrix(
          _saturationMatrix(emphasis == TreeEmphasis.distant ? 0 : .35),
        ),
        child: node,
      );
    }
    if (!availableForPicking) node = Opacity(opacity: .4, child: node);
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: 'Выбрать $label',
      onTap: onSelect,
      child: ExcludeSemantics(child: node),
    );
  }
}

class _PersonAvatar extends StatefulWidget {
  const _PersonAvatar({required this.person});

  final TreePerson person;

  @override
  State<_PersonAvatar> createState() => _PersonAvatarState();
}

class _PersonAvatarState extends State<_PersonAvatar> {
  String? _dataUrl;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _updatePhoto();
  }

  @override
  void didUpdateWidget(covariant _PersonAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updatePhoto();
  }

  void _updatePhoto() {
    final person = widget.person;
    TreePhoto? photo;
    for (final candidate in person.photos) {
      if (candidate.id == person.avatarPhotoId) {
        photo = candidate;
        break;
      }
    }
    if (photo == null && person.photos.isNotEmpty) photo = person.photos.first;
    if (_dataUrl == photo?.dataUrl) return;
    _dataUrl = photo?.dataUrl;
    _bytes = null;
    if (_dataUrl == null) return;
    try {
      final uri = Uri.parse(_dataUrl!);
      final data = uri.data;
      if (data != null && data.mimeType.startsWith('image/')) {
        _bytes = data.contentAsBytes();
      }
    } on FormatException {
      // Broken/unsupported photos retain a useful initials avatar. This is a
      // presentation fallback, not a suppressed persistence/network failure.
      _bytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final person = widget.person;
    final color = _sexColor(person.sex);
    final theme = Theme.of(context);
    final fallback = ColoredBox(
      color: Color.alphaBlend(
        color.withValues(alpha: .13),
        theme.colorScheme.surface,
      ),
      child: Center(
        child: person.name.trim().isEmpty
            ? Icon(Icons.person_outline, color: color, size: 28)
            : Text(
                person.name.trim().characters.first.toUpperCase(),
                style: theme.textTheme.titleLarge?.copyWith(color: color),
              ),
      ),
    );
    return SizedBox.square(
      dimension: _avatarExtent,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: color, width: 3),
              ),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _bytes == null
                      ? fallback
                      : Image.memory(
                          _bytes!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          cacheWidth: 128,
                          errorBuilder: (_, error, stackTrace) => fallback,
                        ),
                ),
              ),
            ),
          ),
          if (person.sex != TreeSex.unknown)
            Positioned(
              bottom: 0,
              right: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.surface,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: Icon(_sexIcon(person.sex), color: color, size: 14),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

List<double> _saturationMatrix(double saturation) {
  final r = .2126 * (1 - saturation);
  final g = .7152 * (1 - saturation);
  final b = .0722 * (1 - saturation);
  return [
    r + saturation,
    g,
    b,
    0,
    0,
    r,
    g + saturation,
    b,
    0,
    0,
    r,
    g,
    b + saturation,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];
}

Set<String> _partnersOf(TreeDocument document, String id) {
  final result = <String>{};
  for (final child in document.people.values) {
    if (child.fatherId == id && child.motherId != null) {
      result.add(child.motherId!);
    }
    if (child.motherId == id && child.fatherId != null) {
      result.add(child.fatherId!);
    }
  }
  return result..remove(id);
}

Set<String> _descendantsOf(TreeDocument document, String id) {
  final children = <String, Set<String>>{};
  for (final person in document.people.values) {
    for (final parent in [person.fatherId, person.motherId]) {
      if (parent != null) children.putIfAbsent(parent, () => {}).add(person.id);
    }
  }
  final result = <String>{};
  final pending = <String>[id];
  while (pending.isNotEmpty) {
    final parent = pending.removeLast();
    for (final child in children[parent] ?? const <String>{}) {
      if (child != id && result.add(child)) pending.add(child);
    }
  }
  return result;
}

Set<String> _ancestorsOf(TreeDocument document, String id) {
  final result = <String>{id};
  final pending = <String>[id];
  while (pending.isNotEmpty) {
    final person = document.person(pending.removeLast());
    for (final parent in [person?.fatherId, person?.motherId]) {
      if (parent != null && result.add(parent)) pending.add(parent);
    }
  }
  return result;
}

/// Go up to the focus's ancestors, then through real children and explicit
/// sibling links. Never traverse upward again through a co-parent: sharing a
/// child does not make an unrelated partner part of the related branch.
Set<String> _bloodRelativesOf(TreeDocument document, Set<String> ancestors) {
  final related = <String, Set<String>>{};
  for (final person in document.people.values) {
    for (final parent in [person.fatherId, person.motherId]) {
      if (parent != null) related.putIfAbsent(parent, () => {}).add(person.id);
    }
  }
  for (final link in document.directSiblingLinks) {
    related.putIfAbsent(link.personId, () => {}).add(link.siblingId);
    related.putIfAbsent(link.siblingId, () => {}).add(link.personId);
  }
  final result = <String>{...ancestors};
  final pending = ancestors.toList();
  while (pending.isNotEmpty) {
    for (final relative in related[pending.removeLast()] ?? const <String>{}) {
      if (result.add(relative)) pending.add(relative);
    }
  }
  return result;
}

Set<String> _trunkAncestorsOf(
  TreeDocument document,
  String id,
  TreeTrunkMode mode,
) {
  if (mode == TreeTrunkMode.both) return _ancestorsOf(document, id);
  final result = <String>{};
  TreePerson? person = document.person(id);
  while (person != null && result.add(person.id)) {
    final parent = mode == TreeTrunkMode.mother
        ? person.motherId ?? person.fatherId
        : person.fatherId ?? person.motherId;
    person = parent == null ? null : document.person(parent);
  }
  return result;
}

class _BlockConnection {
  const _BlockConnection({
    required this.parentId,
    required this.blockId,
    this.targetPersonId,
  });

  final String parentId;
  final String blockId;
  // Ancestral links point to the relevant person; descendants to the whole block.
  final String? targetPersonId;
}

// Block member order can change at a parent boundary; edge identities cannot.
int _compareConnectionPeople(TreePerson a, TreePerson b) =>
    compareTreePeopleByBirth(a, b);

List<_BlockConnection> _blockConnections(
  TreeLayout layout,
  TreeDocument document,
  String selectedId,
) {
  final incoming = <String, Set<String>>{};
  for (final link in layout.links) {
    final parent = layout.positions[link.parentId];
    final child = layout.positions[link.childId];
    if (parent == null ||
        child == null ||
        child.emphasis == TreeEmphasis.distant) {
      continue;
    }
    incoming.putIfAbsent(link.blockId, () => {}).add(link.parentId);
  }
  final result = <_BlockConnection>[];
  final descendants = _descendantsOf(document, selectedId);
  final ancestors = _ancestorsOf(document, selectedId);
  final bloodRelatives = _bloodRelativesOf(document, ancestors);
  final selected = document.person(selectedId)!;
  final selectedParents = {
    if (selected.fatherId case final father?) father,
    if (selected.motherId case final mother?) mother,
  };
  for (final level in layout.levels) {
    for (final block in level.blocks) {
      final parents = incoming[block.id];
      if (parents == null || parents.isEmpty) continue;
      if (block.people.any((person) => ancestors.contains(person.id))) {
        // Both real parent links survive for the focus and all its ancestors,
        // independently of the preferred trunk. Ranks are absolute, not 0-based
        // around the focus, so ancestry is tested by identity rather than rank.
        final ancestralPeople =
            block.people.where((p) => ancestors.contains(p.id)).toList()
              ..sort(_compareConnectionPeople);
        final target =
            ancestralPeople.where((p) => p.id == selectedId).firstOrNull ??
            ancestralPeople.first;
        for (final parent in parents) {
          result.add(
            _BlockConnection(
              parentId: parent,
              blockId: block.id,
              targetPersonId: target.id,
            ),
          );
        }
        continue;
      }
      if (parents.contains(selectedId) ||
          parents.any(selectedParents.contains)) {
        // Immediate children and full/half siblings expose both actual parents,
        // while other context blocks keep one relevant connection.
        for (final parent in parents) {
          result.add(_BlockConnection(parentId: parent, blockId: block.id));
        }
        continue;
      }
      final byAge = parents.toList()
        ..sort(
          (a, b) => _compareConnectionPeople(
            document.person(a)!,
            document.person(b)!,
          ),
        );
      final relevant =
          byAge.where(ancestors.contains).firstOrNull ??
          byAge.where(descendants.contains).firstOrNull ??
          byAge.where(bloodRelatives.contains).firstOrNull ??
          byAge.first;
      result.add(_BlockConnection(parentId: relevant, blockId: block.id));
    }
  }
  result.sort((a, b) {
    var order = a.blockId.compareTo(b.blockId);
    if (order == 0) {
      order = (a.targetPersonId ?? '').compareTo(b.targetPersonId ?? '');
    }
    return order != 0 ? order : a.parentId.compareTo(b.parentId);
  });
  return result;
}

/// All geometry stays in model coordinates; only this inexpensive projection
/// runs during scrolling. In particular, a scroll never rebuilds TreeLayout.
class _TreeLinkPainter extends CustomPainter {
  _TreeLinkPainter({
    required this.geometry,
    required this.layout,
    required this.connections,
    required this.mainScroll,
    required this.levelScrolls,
    required Listenable repaint,
  }) : super(repaint: repaint) {
    for (final level in layout.levels) {
      for (final block in level.blocks) {
        blocks[block.id] = block;
        for (final person in block.people) {
          parentColors[person.id] = switch (person.sex) {
            TreeSex.male => const Color(0xFFAE742C),
            TreeSex.female => const Color(0xFF338B64),
            TreeSex.unknown => const Color(0xFF8A9087),
          };
        }
      }
    }
  }

  final _CanvasGeometry geometry;
  final TreeLayout layout;
  final List<_BlockConnection> connections;
  final ScrollController mainScroll;
  final Map<int, ScrollController> levelScrolls;
  final blocks = <String, TreeSiblingBlock>{};
  final parentColors = <String, Color>{};

  double _offset(ScrollController? controller) =>
      controller != null && controller.hasClients ? controller.offset : 0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final main = _offset(mainScroll);
    for (final connection in connections) {
      final parent = layout.positions[connection.parentId]!;
      final target = blocks[connection.blockId]!;
      final parentRect = geometry.personRect(
        parent,
        main,
        _offset(levelScrolls[parent.level]),
      );
      final child = layout
          .positions[connection.targetPersonId ?? target.people.first.id]!;
      final childOffset = _offset(levelScrolls[child.level]);
      final forward = child.level > parent.level;
      final radius = _avatarExtent / 2 * (forward ? 1 : -1);
      final anchor = geometry.horizontal
          ? Offset(radius, 0)
          : Offset(0, radius);
      final parentCenter = Offset(
        parentRect.center.dx,
        parentRect.top + _nodeInset + _avatarExtent / 2,
      );
      final from = parentCenter + anchor;
      final Offset to;
      if (connection.targetPersonId != null) {
        final childRect = geometry.personRect(child, main, childOffset);
        to =
            Offset(
              childRect.center.dx,
              childRect.top + _nodeInset + _avatarExtent / 2,
            ) -
            anchor;
      } else {
        final lane = geometry.levels[child.level]!;
        final cross =
            lane.origin + target.start + target.extent / 2 - childOffset;
        final mainEdge =
            lane.mainStart +
            geometry.nodeMainInset -
            main +
            (forward ? -6 : layout.nodeExtent + 6);
        to = geometry.horizontal
            ? Offset(mainEdge, cross)
            : Offset(cross, mainEdge);
      }
      final distance = geometry.horizontal
          ? (to.dx - from.dx).abs()
          : (to.dy - from.dy).abs();
      final bend = math.max(24.0, distance * .48) * (forward ? 1 : -1);
      final path = Path()..moveTo(from.dx, from.dy);
      if (geometry.horizontal) {
        path.cubicTo(
          from.dx + bend,
          from.dy,
          to.dx - bend,
          to.dy,
          to.dx,
          to.dy,
        );
      } else {
        path.cubicTo(
          from.dx,
          from.dy + bend,
          to.dx,
          to.dy - bend,
          to.dx,
          to.dy,
        );
      }
      var color = parentColors[parent.personId] ?? _neutralColor;
      final muted =
          parent.emphasis == TreeEmphasis.cousin ||
          target.emphasis == TreeEmphasis.cousin;
      if (muted) color = Color.lerp(_neutralColor, color, .35)!;
      paint.color = color.withValues(alpha: muted ? .40 : .60);
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TreeLinkPainter oldDelegate) =>
      geometry != oldDelegate.geometry ||
      layout != oldDelegate.layout ||
      connections != oldDelegate.connections;
}

class _ScrollRepaint extends ChangeNotifier {
  void changed() => notifyListeners();
}
