import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:raja/l10n/generated/app_localizations.dart';

import '../../../core/extensions/models/vega_models.dart';
import '../../../core/extensions/vega_repository.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/widgets/app_snack_bar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/text_input_dialog.dart';
import '../screens/vega_settings_dialog.dart';
import 'cloudstream_plugin_section.dart' show RepositoryGroupHeader;

/// The Vega repositories, under the one "Vega" section header — the
/// JavaScript providers from the Vega app's provider system, installed
/// from a GitHub source (a username whose repository is named exactly
/// `vega-providers`, or a full repository URL).
///
/// The section stays visible even with nothing in it yet, so the add flow
/// is always reachable. A spinner while the first load is still running.
class VegaRepositoriesSection extends ConsumerWidget {
  const VegaRepositoriesSection({super.key});

  /// This section's add flow: a GitHub username, a `user/repo`, or a full
  /// repository/manifest URL. A source that is already there is refreshed
  /// in place instead of a duplicate card.
  Future<void> _showAddSourceDialog(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final input = await TextInputDialog.show(
      context,
      title: l10n.vegaAddSource,
      hintText: l10n.vegaSourceHint,
      keyboardType: TextInputType.url,
      confirmLabel: l10n.add,
      showPasteButton: true,
      width: 480,
    );
    if (input == null || input.isEmpty || !context.mounted) return;
    try {
      final count = await ref
          .read(vegaRepositoryProvider.notifier)
          .addSource(input);
      messenger.showSnackBar(
        appSnackBar(content: Text(l10n.vegaSourceAdded(count))),
      );
    } catch (error) {
      messenger.showSnackBar(
        appSnackBar(
          content: Text(l10n.vegaCouldNotAdd(_errorMessage(error))),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(vegaRepositoryProvider);
    if (state.isLoading && state.repos.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(LayoutConstants.spacingMd),
        child: Center(child: AppLoadingIndicator()),
      );
    }
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RepositoryGroupHeader(
          icon: Icons.extension_rounded,
          label: l10n.vegaSection,
        ),
        for (final repo in state.repos) _VegaRepositoryCard(repo: repo),
        // The section stays when its last source is removed: the header
        // and the add row remain, so a source can be added back into
        // this section.
        if (state.repos.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LayoutConstants.spacingMd,
              vertical: LayoutConstants.spacingSm,
            ),
            child: Text(
              l10n.vegaNoReposYet,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Card(
          margin: const EdgeInsets.symmetric(
            horizontal: LayoutConstants.spacingMd,
            vertical: LayoutConstants.spacingSm,
          ),
          child: ListTile(
            leading: Icon(
              Icons.add_circle_outline,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(
              l10n.vegaAddSource,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            onTap: () => unawaited(_showAddSourceDialog(context, ref)),
          ),
        ),
      ],
    );
  }
}

/// The installed Vega providers, for the Installed tab, under the one
/// "Vega" group. Nothing when there are none.
class VegaInstalledSection extends ConsumerWidget {
  const VegaInstalledSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(
      vegaRepositoryProvider.select((s) => s.installed),
    );
    if (installed.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: LayoutConstants.spacingMd,
        vertical: LayoutConstants.spacingXs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LayoutConstants.spacingMd,
              vertical: LayoutConstants.spacingSm + 4,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.extension_rounded,
                  color: theme.colorScheme.primary,
                  size: 22,
                ),
                const SizedBox(width: LayoutConstants.spacingSm),
                Text(
                  l10n.vegaSection,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          for (final provider in installed)
            _VegaProviderTile(
              entry: provider.entry,
              installed: provider,
              manifestUrl: provider.repositoryUrl,
            ),
        ],
      ),
    );
  }
}

class _VegaRepositoryCard extends ConsumerWidget {
  const _VegaRepositoryCard({required this.repo});

  final VegaRepo repo;

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.removeRepoConfirm(repo.label)),
        content: Text(l10n.vegaRemoveRepoWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (remove != true || !context.mounted) return;
    await ref
        .read(vegaRepositoryProvider.notifier)
        .removeSource(repo.manifestUrl);
  }

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(vegaRepositoryProvider.notifier)
          .refreshSource(repo.manifestUrl);
    } catch (error) {
      messenger.showSnackBar(
        appSnackBar(content: Text(_errorMessage(error))),
      );
    }
  }

  Future<void> _installAll(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(vegaRepositoryProvider.notifier)
          .installAll(repo.manifestUrl);
      // Nothing on success: the rows change to installed in place. One
      // bad download does not keep the rest back, so a failure here is
      // only ever the whole source failing.
    } catch (error) {
      messenger.showSnackBar(
        appSnackBar(content: Text(_errorMessage(error))),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(vegaRepositoryProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final visible = repo.visibleEntries;
    final installedCount = visible
        .where((e) => state.installedFor(e.value) != null)
        .length;
    final uninstalledCount = visible.length - installedCount;

    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: LayoutConstants.spacingMd,
        vertical: LayoutConstants.spacingXs,
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey('vega_repo_${repo.manifestUrl}'),
        shape: const Border(),
        collapsedShape: const Border(),
        initiallyExpanded: visible.length <= 12,
        title: Text(
          repo.label,
          style: theme.textTheme.titleMedium?.copyWith(
            color: cs.primary,
            fontWeight: FontWeight.bold,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          l10n.vegaRepositorySummary(visible.length, installedCount),
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LayoutConstants.spacingSm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    repo.manifestUrl,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: l10n.cloudStreamRefreshRepository,
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: () => unawaited(_refresh(context, ref)),
                ),
                IconButton(
                  tooltip: l10n.removeRepository,
                  icon: Icon(Icons.delete_outline, color: cs.error),
                  onPressed: () => unawaited(_confirmRemove(context, ref)),
                ),
              ],
            ),
          ),
          if (uninstalledCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LayoutConstants.spacingSm,
                vertical: LayoutConstants.spacingXs,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: () => unawaited(_installAll(context, ref)),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(l10n.downloadAllProviders),
                ),
              ),
            ),
          const Divider(height: 1),
          if (visible.isEmpty)
            ListTile(
              title: Text(
                l10n.vegaEmptyRepo,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            )
          else
            for (final entry in visible)
              _VegaProviderTile(
                entry: entry,
                installed: state.installedFor(entry.value),
                manifestUrl: repo.manifestUrl,
              ),
        ],
      ),
    );
  }
}

class _VegaProviderTile extends ConsumerWidget {
  const _VegaProviderTile({
    required this.entry,
    required this.installed,
    required this.manifestUrl,
  });

  final VegaManifestEntry entry;
  final VegaInstalledProvider? installed;
  final String manifestUrl;

  Future<void> _install(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref
          .read(vegaRepositoryProvider.notifier)
          .installProvider(entry, manifestUrl);
    } catch (error) {
      messenger.showSnackBar(
        appSnackBar(
          content: Text(
            l10n.vegaCouldNotInstall(
              entry.displayName,
              _errorMessage(error),
            ),
          ),
        ),
      );
    }
  }

  Future<void> _update(
    BuildContext context,
    WidgetRef ref,
    VegaInstalledProvider installed,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref
          .read(vegaRepositoryProvider.notifier)
          .updateProvider(installed);
    } catch (error) {
      messenger.showSnackBar(
        appSnackBar(
          content: Text(
            l10n.vegaCouldNotInstall(
              entry.displayName,
              _errorMessage(error),
            ),
          ),
        ),
      );
    }
  }

  Future<void> _uninstall(
    BuildContext context,
    WidgetRef ref,
    VegaInstalledProvider installed,
  ) async {
    await ref
        .read(vegaRepositoryProvider.notifier)
        .uninstallProvider(installed);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final installed = this.installed;
    // Only what this tile shows: a repository's tiles otherwise all
    // rebuild on every change.
    final busy = ref.watch(
      vegaRepositoryProvider.select((s) => s.isInstalling(entry.value)),
    );
    final newer = installed == null
        ? null
        : ref.watch(
            vegaRepositoryProvider.select(
              (s) => s.updateFor(installed.packageName),
            ),
          );
    final disabled = installed == null
        ? false
        : ref.watch(
            vegaRepositoryProvider.select(
              (s) => s.isDisabled(installed.packageName),
            ),
          );
    final notifier = ref.read(vegaRepositoryProvider.notifier);

    final status = [
      'v${installed?.entry.version ?? entry.version}',
      if (newer != null) '→ v${newer.version}',
      if (disabled) l10n.disabled,
    ].join(' · ');

    return ListTile(
      key: ValueKey('vega_provider_${entry.packageName}'),
      leading: _VegaProviderIcon(url: entry.icon, name: entry.displayName),
      title: Text(
        entry.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        status,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: disabled ? TextStyle(color: cs.onSurfaceVariant) : null,
      ),
      trailing: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: AppLoadingIndicator(
                constraints: BoxConstraints(maxWidth: 24, maxHeight: 24),
              ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (installed == null)
                  IconButton(
                    key: ValueKey('vega_install_${entry.value}'),
                    tooltip: l10n.install,
                    icon: const Icon(Icons.download_rounded),
                    onPressed: () => unawaited(_install(context, ref)),
                  )
                else ...[
                  // The provider's own settings, when its manifest says
                  // it has any. A disabled provider's settings are not
                  // reachable: its runtime is not published, so the
                  // dialog could not read them.
                  if (entry.hasSettings && !disabled)
                    IconButton(
                      key: ValueKey('vega_settings_${entry.value}'),
                      tooltip: l10n.pluginSettings(entry.displayName),
                      icon: const Icon(Icons.tune_rounded),
                      onPressed: () => unawaited(
                        VegaSettingsDialog.open(context, installed),
                      ),
                    ),
                  // A labelled one-tap Update (it was an unlabelled
                  // icon). The install replaces the bundles in place:
                  // the old runtime is disposed, the files swapped and
                  // the new code loaded — no uninstall first, no app
                  // restart.
                  if (newer != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: FilledButton.tonal(
                        key: ValueKey('vega_update_${entry.value}'),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(0, 34),
                        ),
                        onPressed: () => unawaited(
                          _update(context, ref, installed),
                        ),
                        child: Text(l10n.cloudStreamUpdate),
                      ),
                    ),
                  // Switched off, the provider loads nothing: what
                  // would load it waits for the switch (Uninstall
                  // doesn't).
                  Switch(
                    value: !disabled,
                    onChanged: (enabled) => unawaited(
                      notifier.setProviderEnabled(
                        installed.packageName,
                        enabled,
                      ),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('vega_uninstall_${entry.value}'),
                    tooltip: l10n.cloudStreamUninstall,
                    icon: Icon(Icons.delete_outline, color: cs.error),
                    onPressed: () => unawaited(
                      _uninstall(context, ref, installed),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

/// A provider's manifest icon, or its first letter on the accent tint
/// when it has none (or it fails to load).
class _VegaProviderIcon extends StatelessWidget {
  const _VegaProviderIcon({required this.url, required this.name});

  final String? url;
  final String name;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fallback = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(color: cs.primary, fontWeight: FontWeight.bold),
      ),
    );
    final icon = url;
    if (icon == null || icon.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        icon,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : fallback,
      ),
    );
  }
}

/// The fetcher's message without the `Exception: ` prefix the `toString`
/// of an [Exception] adds — the same strip the CloudStream flow applies,
/// so a snackbar reads "Could not load the Vega manifest (HTTP 404)"
/// rather than "Exception: Could not load …".
String _errorMessage(Object error) {
  const prefix = 'Exception: ';
  final text = error.toString();
  return text.startsWith(prefix) ? text.substring(prefix.length) : text;
}
