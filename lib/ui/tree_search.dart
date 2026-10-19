import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tree/tree_document.dart';

/// Searches full birth names and years, with unknown birth dates oldest/first.
/// Equal/missing dates use normalized given name (trim, lowercase, ё = е), then ID.
List<TreePerson> searchTreePeople(
  Map<String, TreePerson> people,
  String query,
) {
  final normalized = _normalize(query).trim();
  if (normalized.isEmpty) return [];
  final tokens = normalized.split(RegExp(r'\s+', unicode: true));
  final matches = people.values.where((person) {
    final text = _normalize('${person.fullName} ${person.lifeYears}');
    return tokens.every(text.contains);
  }).toList();
  matches.sort(compareTreePeopleByBirth);
  return matches;
}

String _normalize(String text) => text.toLowerCase().replaceAll('ё', 'е');

/// A toolbar-sized person search. Selection browses by id, without editing data.
class TreePersonSearch extends StatefulWidget {
  const TreePersonSearch({
    super.key,
    required this.people,
    required this.onSelected,
    this.compact = false,
    this.showBackButton = false,
    this.onFocusChanged,
  });

  final Map<String, TreePerson> people;
  final ValueChanged<String> onSelected;
  final bool compact;
  final bool showBackButton;
  final ValueChanged<bool>? onFocusChanged;

  @override
  State<TreePersonSearch> createState() => _TreePersonSearchState();
}

class _TreePersonSearchState extends State<TreePersonSearch> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _overlay = OverlayPortalController();
  final _scroll = ScrollController();
  final _highlightedOptionKey = GlobalKey();
  String _lastText = '';
  String? _highlightedId;
  bool _dismissed = false;

  List<TreePerson> get _matches => searchTreePeople(widget.people, _text.text);

  @override
  void initState() {
    super.initState();
    _text.addListener(_textChanged);
    _focus.addListener(_focusChanged);
  }

  void _textChanged() {
    // Caret/composing updates must not reopen a dismissed menu or reset focus.
    if (_lastText == _text.text) return;
    _lastText = _text.text;
    setState(() {
      _highlightedId = null;
      _dismissed = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _syncOverlay();
  }

  void _focusChanged() {
    if (_focus.hasFocus) _dismissed = false;
    _syncOverlay();
    widget.onFocusChanged?.call(_focus.hasFocus);
  }

  void _syncOverlay() {
    final show = _focus.hasFocus && _text.text.trim().isNotEmpty && !_dismissed;
    if (show && !_overlay.isShowing) _overlay.show();
    if (!show && _overlay.isShowing) _overlay.hide();
  }

  int _highlightIndex(List<TreePerson> options) {
    final index = options.indexWhere((person) => person.id == _highlightedId);
    return index < 0 ? 0 : index;
  }

  void _moveHighlight(int delta) {
    final options = _matches;
    if (options.isEmpty) return;
    final index = _overlay.isShowing
        ? (_highlightIndex(options) + delta).clamp(0, options.length - 1)
        : 0;
    setState(() {
      _highlightedId = options[index].id;
      _dismissed = false;
    });
    _syncOverlay();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_overlay.isShowing) return;
      final optionContext = _highlightedOptionKey.currentContext;
      if (optionContext != null) {
        Scrollable.ensureVisible(optionContext, alignment: .5);
      }
    });
  }

  void _submit() {
    if (!_overlay.isShowing) return;
    final options = _matches;
    if (options.isNotEmpty) _select(options[_highlightIndex(options)].id);
  }

  void _select(String id) {
    // An overlay callback can outlive the map from which its row was built.
    if (!widget.people.containsKey(id) ||
        !_matches.any((person) => person.id == id)) {
      return;
    }
    _text.clear();
    _focus.unfocus();
    _syncOverlay();
    widget.onSelected(id);
  }

  KeyEventResult _keyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_text.value.composing.isValid && !_text.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (widget.showBackButton) {
        _focus.unfocus();
        return KeyEventResult.handled;
      }
      if (_overlay.isShowing) {
        _dismissed = true;
        _overlay.hide();
        return KeyEventResult.handled;
      }
    }
    if (_text.text.trim().isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveHighlight(event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1);
      return KeyEventResult.handled;
    }
    if ((event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        _overlay.isShowing) {
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // Do not let an ancestor tree canvas interpret gestures over the input as zoom.
  void _blockCanvasZoom(PointerSignalEvent event) {
    if (event is PointerScaleEvent ||
        (event is PointerScrollEvent &&
            HardwareKeyboard.instance.isControlPressed)) {
      GestureBinding.instance.pointerSignalResolver.register(event, (signal) {
        if (signal is PointerScrollEvent) {
          signal.respond(allowPlatformDefault: false);
        }
      });
    }
  }

  Widget _buildOptions(BuildContext context, OverlayChildLayoutInfo layout) {
    // Read MediaQuery so a resized viewport or software keyboard relays layout.
    MediaQuery.of(context);
    final view = MediaQueryData.fromView(View.of(context));
    final field = MatrixUtils.transformRect(
      layout.childPaintTransform,
      Offset.zero & layout.childSize,
    );
    const gap = 6.0;
    const margin = 8.0;
    final top = view.padding.top + margin;
    // Scaffold may already have consumed viewInsets. Using the actual view's
    // visible bottom also avoids subtracting the keyboard twice in a small overlay.
    final bottom =
        math.min(
          layout.overlaySize.height,
          view.size.height - view.viewInsets.bottom - view.padding.bottom,
        ) -
        margin;
    final below = math.max(0.0, bottom - field.bottom - gap);
    final above = math.max(0.0, field.top - top - gap);
    final opensUp = below < 120 && above > below;
    final maxHeight = math.min(260.0, opensUp ? above : below);
    final width = math.min(
      field.width,
      math.max(0.0, layout.overlaySize.width - margin * 2),
    );
    if (maxHeight < 1 || width < 1) return const SizedBox.shrink();
    final left = field.left
        .clamp(
          margin,
          math.max(margin, layout.overlaySize.width - width - margin),
        )
        .toDouble();
    final options = _matches;
    final highlighted = _highlightIndex(options);
    final theme = Theme.of(context);
    return Positioned(
      left: left,
      top: opensUp ? null : math.max(top, field.bottom + gap),
      bottom: opensUp
          ? layout.overlaySize.height - math.min(bottom, field.top - gap)
          : null,
      width: width,
      child: TextFieldTapRegion(
        child: ExcludeFocus(
          child: Listener(
            onPointerSignal: _blockCanvasZoom,
            child: Material(
              elevation: 6,
              clipBehavior: Clip.antiAlias,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: EdgeInsets.zero,
                  child: options.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('Ничего не найдено'),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var index = 0; index < options.length; index++)
                              _option(
                                options[index],
                                index == highlighted,
                                theme,
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

  Widget _option(TreePerson person, bool highlighted, ThemeData theme) {
    final details = person.lifeYears;
    return Semantics(
      key: ValueKey('tree-search-option-${person.id}'),
      button: true,
      selected: highlighted,
      label: '${person.fullName}, $details',
      excludeSemantics: true,
      onTap: () => _select(person.id),
      child: InkWell(
        onTap: () => _select(person.id),
        canRequestFocus: false,
        child: Container(
          key: highlighted ? _highlightedOptionKey : null,
          color: highlighted ? theme.colorScheme.secondaryContainer : null,
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                person.fullName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 2),
              Text(
                details,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !widget.showBackButton,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && widget.showBackButton) _focus.unfocus();
    },
    child: OverlayPortal.overlayChildLayoutBuilder(
      controller: _overlay,
      overlayChildBuilder: _buildOptions,
      child: Focus(
        onKeyEvent: _keyEvent,
        child: Listener(
          onPointerSignal: _blockCanvasZoom,
          child: SizedBox(
            height: 36,
            child: TextField(
              key: const Key('tree-search-field'),
              controller: _text,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              style: widget.compact
                  ? const TextStyle(color: Colors.transparent)
                  : null,
              onSubmitted: (_) => _submit(),
              onTapOutside: (_) => _focus.unfocus(),
              onTap: () {
                _dismissed = false;
                _syncOverlay();
              },
              decoration: InputDecoration(
                hintText: 'Поиск по дереву',
                hintStyle: widget.compact
                    ? const TextStyle(color: Colors.transparent)
                    : null,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                prefixIconConstraints: BoxConstraints(
                  minWidth: widget.compact ? 64 : 32,
                  minHeight: 32,
                ),
                prefixIcon: widget.showBackButton
                    ? IconButton(
                        key: const Key('tree-search-back'),
                        tooltip: 'Закрыть поиск',
                        onPressed: _focus.unfocus,
                        style: IconButton.styleFrom(
                          fixedSize: const Size(32, 32),
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.arrow_back, size: 20),
                      )
                    : const Icon(Icons.search, size: 20),
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
                suffixIcon: _text.text.isEmpty || widget.compact
                    ? null
                    : IconButton(
                        tooltip: 'Очистить поиск',
                        onPressed: () {
                          _text.clear();
                          _focus.requestFocus();
                        },
                        style: IconButton.styleFrom(
                          fixedSize: const Size(32, 32),
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.clear, size: 20),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _text.removeListener(_textChanged);
    _focus.removeListener(_focusChanged);
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }
}
