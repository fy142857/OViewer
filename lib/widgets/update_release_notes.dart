import 'package:flutter/material.dart';
import '../core/l10n/s.dart';

class UpdateReleaseNotes extends StatelessWidget {
  const UpdateReleaseNotes(this.notes, {super.key});

  final String notes;

  @override
  Widget build(BuildContext context) {
    if (notes.trim().isEmpty) return Text(S.of(context).updateNoNotes);
    final lines = notes.split('\n');
    return Text.rich(TextSpan(children: [
      for (var i = 0; i < lines.length; i++)
        TextSpan(
          text: '${i == 0 ? '' : '\n'}${lines[i]}',
          style: const {'新增', '修复', '变更', 'added', 'fixed', 'changed'}
                  .contains(lines[i].trim().toLowerCase())
              ? const TextStyle(fontWeight: FontWeight.bold)
              : null,
        ),
    ]));
  }
}
