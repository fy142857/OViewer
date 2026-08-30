import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get_it/get_it.dart';
import '../../blocs/auth/auth_bloc.dart';
import '../../blocs/auth/auth_state.dart';
import '../../blocs/settings/settings_bloc.dart';
import '../../blocs/settings/settings_event.dart';
import '../../blocs/settings/settings_state.dart';
import '../../core/constants/api_endpoints.dart';
import '../../core/l10n/s.dart';
import '../../core/network/eh_image_cache_manager.dart';
import '../../repositories/download_repository.dart';
import 'my_tags_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _downloadSize = '0 B';

  @override
  void initState() {
    super.initState();
    _calculateSizes();
  }

  Future<void> _calculateSizes() async {
    try {
      final dlRepo = GetIt.I<DownloadRepository>();
      final bytes = await dlRepo.getTotalDownloadSize();
      setState(() => _downloadSize = _formatBytes(bytes));
    } catch (_) {
      setState(() => _downloadSize = '0 B');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.settings)),
      body: BlocBuilder<SettingsBloc, SettingsState>(
        builder: (context, state) {
          final s = S.of(context);
          return ListView(
            children: [
              // ---- Appearance ----
              _sectionHeader(s.appearance),
              ListTile(
                leading: const Icon(Icons.palette),
                title: Text(s.theme),
                subtitle: Text(_themeLabel(state.themeMode, s)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showThemeDialog(context, state.themeMode),
              ),
              ListTile(
                leading: const Icon(Icons.language),
                title: Text(s.language),
                subtitle: Text(state.locale == 'zh' ? '中文' : 'English'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showLanguageDialog(context, state.locale),
              ),
              ListTile(
                leading: const Icon(Icons.view_list),
                title: Text(s.galleryDisplay),
                subtitle:
                    Text(state.displayMode == 0 ? s.listView : s.gridView),
                trailing: Switch(
                  value: state.displayMode == 1,
                  onChanged: (val) {
                    context
                        .read<SettingsBloc>()
                        .add(UpdateDisplayMode(val ? 1 : 0));
                  },
                ),
              ),

              // ---- Site ----
              _sectionHeader(s.site),
              ListTile(
                leading: Icon(
                  state.useExHentai ? Icons.lock : Icons.public,
                  color: state.useExHentai ? Colors.deepPurple : null,
                ),
                title: Text(state.useExHentai ? 'ExHentai' : 'E-Hentai'),
                subtitle: Text(state.useExHentai
                    ? s.exhentaiRequiresIgneous
                    : 'e-hentai.org'),
                trailing: Switch(
                  value: state.useExHentai,
                  onChanged: (val) {
                    context.read<SettingsBloc>().add(ToggleSiteMode(val));
                  },
                ),
              ),
              BlocBuilder<AuthBloc, AuthState>(
                builder: (context, authState) {
                  return ListTile(
                    leading: const Icon(Icons.label_off),
                    title: Text(s.myTags),
                    subtitle: Text(state.hiddenTags.isEmpty
                        ? s.configureTagFilters
                        : s.hiddenTagsCount(state.hiddenTags.length)),
                    trailing: const Icon(Icons.chevron_right),
                    enabled: authState.isLoggedIn,
                    onTap: authState.isLoggedIn
                        ? () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => BlocProvider.value(
                                  value: context.read<SettingsBloc>(),
                                  child: const MyTagsScreen(),
                                ),
                              ),
                            );
                          }
                        : null,
                  );
                },
              ),
              BlocBuilder<AuthBloc, AuthState>(
                builder: (context, authState) {
                  return ListTile(
                    leading: const Icon(Icons.translate),
                    title: Text(s.titleLanguage),
                    subtitle: Text(s.titleLanguageHint),
                    trailing: const Icon(Icons.chevron_right),
                    enabled: authState.isLoggedIn,
                    onTap: authState.isLoggedIn
                        ? () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    _UConfigScreen(title: s.titleLanguage),
                              ),
                            );
                          }
                        : null,
                  );
                },
              ),
              BlocBuilder<AuthBloc, AuthState>(
                builder: (context, authState) {
                  return ListTile(
                    leading: const Icon(Icons.photo_size_select_large),
                    title: Text(s.imageSizeSettings),
                    subtitle: Text(s.imageSizeSettingsHint),
                    trailing: const Icon(Icons.chevron_right),
                    enabled: authState.isLoggedIn,
                    onTap: authState.isLoggedIn
                        ? () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    _UConfigScreen(title: s.imageSizeSettings),
                              ),
                            );
                          }
                        : null,
                  );
                },
              ),

              // ---- Reading ----
              _sectionHeader(s.reading),
              ListTile(
                leading: const Icon(Icons.auto_stories),
                title: Text(s.defaultReadingMode),
                subtitle: Text(_readingModeLabel(state.readingMode, s)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showReadingModeDialog(context, state.readingMode),
              ),

              // ---- Network ----
              _sectionHeader(s.network),
              SwitchListTile(
                secondary: const Icon(Icons.wifi_find),
                title: Text(s.autoDetectProxy),
                subtitle: Text(
                  state.autoProxy
                      ? (state.detectedProxy != null
                          ? s.autoProxyDetected(state.detectedProxy!)
                          : state.vpnActive
                              ? s.vpnDetectedNoProxy
                              : s.noProxyVpnDetected)
                      : s.disabled,
                ),
                value: state.autoProxy,
                onChanged: (val) {
                  context.read<SettingsBloc>().add(ToggleAutoProxy(val));
                },
              ),
              ListTile(
                leading: const Icon(Icons.vpn_key),
                title: Text(s.manualProxy),
                subtitle: Text(state.proxyUrl ?? s.notConfigured),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showProxyDialog(context, state.proxyUrl),
              ),
              if (state.effectiveProxy != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    s.activeProxy(state.effectiveProxy!),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    state.vpnActive ? s.vpnModeNoProxy : s.noProxyActive,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: state.vpnActive
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),

              // ---- Storage ----
              _sectionHeader(s.storage),
              ListTile(
                leading: const Icon(Icons.cached),
                title: Text(s.imageCache),
                subtitle: Text(s.tapToClear),
                trailing: TextButton(
                  onPressed: () async {
                    await EhImageCacheManager.instance.emptyCache();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(s.cacheCleared)),
                      );
                    }
                  },
                  child: Text(s.clear),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.sd_storage),
                title: Text(s.cacheSizeLimit),
                subtitle: Text('${state.cacheLimitMB} MB'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showCacheLimitDialog(context, state.cacheLimitMB),
              ),
              ListTile(
                leading: const Icon(Icons.download),
                title: Text(s.downloadsStorage),
                subtitle: Text(_downloadSize),
              ),

              // ---- About ----
              _sectionHeader(s.about),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('OViewer'),
                subtitle: Text('Version 1.0.0\n${s.appDescription}'),
              ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }

  String _themeLabel(int mode, S s) {
    switch (mode) {
      case 1:
        return s.light;
      case 2:
        return s.dark;
      default:
        return s.followSystem;
    }
  }

  String _readingModeLabel(int mode, S s) {
    switch (mode) {
      case 1:
        return s.rightToLeft;
      case 2:
        return s.verticalScroll;
      default:
        return s.leftToRight;
    }
  }

  void _showThemeDialog(BuildContext context, int current) {
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(s.theme),
        children: [
          for (final entry
              in {0: s.followSystem, 1: s.light, 2: s.dark}.entries)
            RadioListTile<int>(
              value: entry.key,
              groupValue: current,
              title: Text(entry.value),
              onChanged: (val) {
                context.read<SettingsBloc>().add(UpdateThemeMode(val!));
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  void _showLanguageDialog(BuildContext context, String current) {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Language / 语言'),
        children: [
          RadioListTile<String>(
            value: 'zh',
            groupValue: current,
            title: const Text('中文'),
            onChanged: (val) {
              context.read<SettingsBloc>().add(UpdateLocale(val!));
              Navigator.pop(ctx);
            },
          ),
          RadioListTile<String>(
            value: 'en',
            groupValue: current,
            title: const Text('English'),
            onChanged: (val) {
              context.read<SettingsBloc>().add(UpdateLocale(val!));
              Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  void _showReadingModeDialog(BuildContext context, int current) {
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(s.defaultReadingMode),
        children: [
          for (final entry in {
            0: s.leftToRight,
            1: s.rightToLeft,
            2: s.verticalScroll,
          }.entries)
            RadioListTile<int>(
              value: entry.key,
              groupValue: current,
              title: Text(entry.value),
              onChanged: (val) {
                context.read<SettingsBloc>().add(UpdateReadingMode(val!));
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  void _showProxyDialog(BuildContext context, String? current) {
    final s = S.of(context);
    final controller = TextEditingController(text: current);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.httpProxy),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.enterProxyUrl,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: 'socks5://127.0.0.1:1080',
                helperText: s.supportsHttpSocks5,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              context.read<SettingsBloc>().add(const UpdateProxy(null));
              Navigator.pop(ctx);
            },
            child: Text(s.clear),
          ),
          FilledButton(
            onPressed: () {
              final url = controller.text.trim();
              context.read<SettingsBloc>().add(
                    UpdateProxy(url.isNotEmpty ? url : null),
                  );
              Navigator.pop(ctx);
            },
            child: Text(s.save),
          ),
        ],
      ),
    );
  }

  void _showCacheLimitDialog(BuildContext context, int current) {
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(s.cacheSizeLimit),
        children: [
          for (final mb in [100, 200, 500, 1000, 2000])
            RadioListTile<int>(
              value: mb,
              groupValue: current,
              title: Text('$mb MB'),
              onChanged: (val) {
                context.read<SettingsBloc>().add(UpdateCacheLimit(val!));
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }
}

class _UConfigScreen extends StatelessWidget {
  final String title;
  const _UConfigScreen({required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(
          url: Uri.parse(ApiEndpoints.userConfig),
        ),
        initialOptions: InAppWebViewGroupOptions(
          crossPlatform: InAppWebViewOptions(
            javaScriptEnabled: true,
          ),
        ),
      ),
    );
  }
}
