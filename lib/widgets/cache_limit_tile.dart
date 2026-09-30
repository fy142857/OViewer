import 'package:flutter/material.dart';
import '../core/l10n/s.dart';

class CacheLimitTile extends StatefulWidget {
  final int limitMB;
  final Future<void> Function(int) onApply;
  const CacheLimitTile(
      {super.key, required this.limitMB, required this.onApply});

  @override
  State<CacheLimitTile> createState() => _CacheLimitTileState();
}

class _CacheLimitTileState extends State<CacheLimitTile> {
  bool _busy = false;
  bool _applying = false;

  Future<void> _choose() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final s = S.of(context);
      final mb = await showDialog<int>(
          context: context,
          builder: (ctx) => SimpleDialog(
                title: Text(s.cacheSizeLimit),
                children: [
                  for (final size in [100, 200, 500, 1000, 2000])
                    RadioListTile<int>(
                        value: size,
                        groupValue: widget.limitMB,
                        title: Text('$size MB'),
                        onChanged: (value) => Navigator.pop(ctx, value))
                ],
              ));
      if (mb == null) return;
      if (!mounted) return;
      if (mb < widget.limitMB) {
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                  title: Text(s.cacheSizeLimit),
                  content: Text(s.lowerCacheLimitWarning),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(s.cancel)),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(s.confirm)),
                  ],
                ));
        if (!mounted || confirmed != true) return;
      }
      setState(() => _applying = true);
      await widget.onApply(mb);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).cacheLimitApplyFailed)));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _applying = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
        key: const ValueKey('cache-limit'),
        leading: const Icon(Icons.sd_storage),
        title: Text(S.of(context).cacheSizeLimit),
        subtitle: Text('${widget.limitMB} MB'),
        trailing: _applying
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.chevron_right),
        onTap: _busy ? null : _choose,
      );
}
