import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/settings/settings_bloc.dart';
import '../blocs/settings/settings_event.dart';
import '../blocs/settings/settings_state.dart';
import '../core/l10n/s.dart';

class SiteModeTile extends StatelessWidget {
  const SiteModeTile({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<SettingsBloc, SettingsState>(
          buildWhen: (a, b) =>
              a.useExHentai != b.useExHentai ||
              a.pendingSite != b.pendingSite ||
              a.siteSwitchError != b.siteSwitchError ||
              a.locale != b.locale,
          builder: (context, state) {
            final s = S.of(context);
            return ListTile(
              leading: state.switchingSite
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(state.displayedSite ? Icons.lock : Icons.public,
                      color: state.displayedSite ? Colors.deepPurple : null),
              title: Text(state.displayedSite ? 'ExHentai' : 'E-Hentai'),
              subtitle: Text(state.switchingSite
                  ? s.siteSwitching
                  : state.siteSwitchError != null
                      ? s.siteSwitchFailed
                      : state.displayedSite
                          ? s.exhentaiRequiresIgneous
                          : 'e-hentai.org'),
              trailing: Switch(
                key: const ValueKey('site-mode-switch'),
                value: state.displayedSite,
                onChanged: state.switchingSite
                    ? null
                    : (value) =>
                        context.read<SettingsBloc>().add(ToggleSiteMode(value)),
              ),
            );
          });
}
