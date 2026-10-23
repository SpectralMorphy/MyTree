import 'package:flutter/material.dart';

enum PersonEndDateMode { date, ongoing, unknown }

typedef PersonEndDate = ({PersonEndDateMode mode, DateTime? date});

String personDateLabel(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year.toString().padLeft(4, '0')}';

Future<DateTime?> pickPersonDate(BuildContext context, DateTime? current) =>
    showDatePicker(
      context: context,
      initialDate: current ?? DateTime(1970),
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
      helpText: 'Выберите дату',
    );

class PersonEndDateChoices extends StatefulWidget {
  const PersonEndDateChoices({
    super.key,
    required this.value,
    required this.ongoingLabel,
    required this.keyPrefix,
    this.onChanged,
  });

  final PersonEndDate value;
  final String ongoingLabel;
  final String keyPrefix;
  final ValueChanged<PersonEndDate>? onChanged;

  @override
  State<PersonEndDateChoices> createState() => _PersonEndDateChoicesState();
}

class _PersonEndDateChoicesState extends State<PersonEndDateChoices> {
  bool _picking = false;

  Future<void> _select(PersonEndDateMode mode) async {
    if (_picking || widget.onChanged == null) return;
    if (mode != PersonEndDateMode.date) {
      widget.onChanged!((mode: mode, date: widget.value.date));
      return;
    }
    setState(() => _picking = true);
    try {
      final date = await pickPersonDate(context, widget.value.date);
      if (date != null && mounted) {
        widget.onChanged?.call((mode: mode, date: date));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final mode in PersonEndDateMode.values) ...[
        if (mode != PersonEndDateMode.date) const SizedBox(width: 4),
        Expanded(
          child: ChoiceChip(
            key: Key('${widget.keyPrefix}-${mode.name}'),
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(switch (mode) {
                PersonEndDateMode.date =>
                  widget.value.date == null
                      ? 'Дата'
                      : personDateLabel(widget.value.date!),
                PersonEndDateMode.ongoing => widget.ongoingLabel,
                PersonEndDateMode.unknown => 'Не известно',
              }),
            ),
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            showCheckmark: false,
            selected: widget.value.mode == mode,
            onSelected: _picking || widget.onChanged == null
                ? null
                : (_) => _select(mode),
          ),
        ),
      ],
    ],
  );
}

Future<PersonEndDate?> showPersonEndDateDialog(
  BuildContext context, {
  required PersonEndDate value,
}) => showDialog<PersonEndDate>(
  context: context,
  builder: (context) => AlertDialog(
    key: const Key('person-death-dialog'),
    title: const Text('Дата смерти'),
    content: SizedBox(
      width: 360,
      child: PersonEndDateChoices(
        value: value,
        ongoingLabel: 'Жив',
        keyPrefix: 'person-death-choice',
        onChanged: (value) => Navigator.pop(context, value),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
    ],
  ),
);
