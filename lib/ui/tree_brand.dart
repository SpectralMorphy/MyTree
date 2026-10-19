import 'package:flutter/material.dart';

class TreeMark extends StatefulWidget {
  const TreeMark({super.key, this.size = 112, this.animate = false});

  final double size;
  final bool animate;

  @override
  State<TreeMark> createState() => _TreeMarkState();
}

class _TreeMarkState extends State<TreeMark>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  late final _scale = Tween<double>(
    begin: 0.96,
    end: 1.04,
  ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateAnimation();
  }

  @override
  void didUpdateWidget(TreeMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAnimation();
  }

  void _updateAnimation() {
    if (widget.animate && !MediaQuery.disableAnimationsOf(context)) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0.5;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: _scale,
    child: Image.asset(
      'assets/tree-mark.png',
      width: widget.size,
      height: widget.size,
      semanticLabel: 'MyTree — семейное дерево',
    ),
  );
}

class RoomLoadingView extends StatelessWidget {
  const RoomLoadingView({
    super.key,
    required this.status,
    this.error,
    this.requiresOnlineMember = false,
    this.onRetry,
    this.onOpenLocal,
    this.onExit,
  });

  final String status;
  final String? error;
  final bool requiresOnlineMember;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenLocal;
  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('room-loading'),
    child: SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TreeMark(size: 128, animate: error == null),
            const SizedBox(height: 28),
            Text(
              error == null
                  ? 'Открываем комнату'
                  : 'Не удалось открыть комнату',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                error ?? status,
                key: const Key('initial-sync-status'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: error == null
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ),
            if (error == null) ...[
              const SizedBox(height: 24),
              const SizedBox(
                width: 144,
                child: LinearProgressIndicator(minHeight: 3),
              ),
            ],
            if (requiresOnlineMember) ...[
              const SizedBox(height: 20),
              Text(
                'Первое подключение требует онлайн-участника. Комната сохраняется только после получения её данных.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (error != null && onRetry != null) ...[
              const SizedBox(height: 24),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Повторить подключение'),
              ),
            ],
            if (error != null && onOpenLocal != null)
              TextButton(
                onPressed: onOpenLocal,
                child: const Text('Открыть локальную копию'),
              ),
            if (onExit != null) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: onExit,
                child: const Text('Вернуться в меню'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
