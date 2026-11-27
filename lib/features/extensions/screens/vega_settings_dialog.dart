import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:raja/l10n/generated/app_localizations.dart';

import '../../../core/extensions/models/extension_plugin.dart';
import '../../../core/extensions/models/vega_models.dart';
import '../../../core/extensions/providers/vega_based_provider.dart';
import '../../../core/extensions/vega_repository.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/storage/extension_repository.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../shared/widgets/custom_widgets.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/text_input_dialog.dart';
import '../../settings/presentation/widgets/settings_widgets.dart';

/// Width of the panel. Wide enough for a settings row - icon, title,
/// subtitle and a trailing switch - without the subtitle wrapping on every
/// line. The "Add Repository" dialog uses 480 for one text field; a form
/// needs more.
const double _kDialogWidth = 560;

/// Horizontal inset of the content inside that width.
///
/// [SettingsGroup] already insets itself by [LayoutConstants.spacingMd], so
/// this is the remainder that puts its titles on the same 24 dp gutter
/// AlertDialog gives its own title.
const double _kContentInset = 8;

/// A Vega provider's own settings, in the app's dialog panel.
///
/// The Vega analogue of [PluginSettingsDialog], but Vega-only: the
/// definitions come from the provider's `getSettingsSchema()` (via
/// [VegaBasedProvider.getSettings]), and the values live in the provider's
/// kvStore — `<namespace>::<key>` in the extensions box — NOT the
/// `<packageName>:<key>` the `.sky` dialog writes. The two keyings are
/// different stores by design: the Vega context bundle's kvStore reads and
/// writes `<namespace>::<key>` through the engine's `get_storage` /
/// `set_storage` bridge, so a setting saved here is the same setting the
/// provider's JavaScript reads.
///
/// Encoding matches what the Vega app's kvStore holds (see the context
/// bundle's `kvStore.set` / `kvStore.get`): values are stored JSON-encoded.
/// A toggle is the raw JSON boolean (`'true'` / `'false'` — a JSON string
/// `'"true"'` would make even `'false'` truthy in JavaScript); a select or
/// text value is `jsonEncode(value)` (a JSON string round-trip — writing it
/// raw would change the type of a value that looks like JSON, e.g. `"123"`);
/// a toggle group is the JSON map as-is. Number fields are normalized to
/// `text` by the provider, so they read back as strings, which JavaScript
/// arithmetic coerces the usual way (`timeout * 1000`). The dialog also
/// maintains the provider's key index (see
/// [VegaBasedProvider.kvIndexKeyFor]), so `kvStore.keys()` lists
/// dialog-written settings too.
///
/// A saved setting whose definition has `reloadOnChange` reloads the
/// provider from disk, so the next call runs with the new values.
class VegaSettingsDialog extends ConsumerStatefulWidget {
  final VegaInstalledProvider installed;

  const VegaSettingsDialog({super.key, required this.installed});

  static Future<void> open(
    BuildContext context,
    VegaInstalledProvider installed,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Theme.of(
        context,
      ).colorScheme.scrim.withValues(alpha: 0.65),
      builder: (_) => VegaSettingsDialog(installed: installed),
    );
  }

  @override
  ConsumerState<VegaSettingsDialog> createState() =>
      _VegaSettingsDialogState();
}

class _VegaSettingsDialogState extends ConsumerState<VegaSettingsDialog> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<PluginSettingDefinition> _definitions = const [];
  final Map<String, String> _values = {};
  final Map<String, TextEditingController> _controllers = {};

  String get _displayName => widget.installed.entry.displayName;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final provider = ref
          .read(vegaRepositoryProvider.notifier)
          .providerForValue(widget.installed.value);
      if (provider == null) {
        throw Exception('Vega provider is not running');
      }
      final definitions = await provider.getSettings();
      final storage = ref.read(extensionRepositoryProvider);

      for (final controller in _controllers.values) {
        controller.dispose();
      }
      _controllers.clear();
      _values.clear();

      for (final definition in definitions) {
        // The kvStore value, decoded back to the form the form edits: a
        // JSON string decodes to its string, a JSON boolean to
        // 'true'/'false', a JSON map to the map string.
        final raw = storage.getExtensionData(
          VegaBasedProvider.kvKeyFor(
            widget.installed.value,
            definition.key,
          ),
        );
        var value = _decodeKvValue(raw) ?? definition.defaultValue;

        if (definition.type == PluginSettingType.select &&
            definition.options.isNotEmpty &&
            !definition.options.any((option) => option.value == value)) {
          value = definition.options.first.value;
        }
        if (definition.type == PluginSettingType.toggleGroup) {
          value = _normalizedToggleGroupValue(definition, value);
        }

        _values[definition.key] = value;
        if (definition.type == PluginSettingType.text ||
            definition.type == PluginSettingType.url) {
          _controllers[definition.key] = TextEditingController(text: value);
        }
      }

      if (!mounted) return;
      setState(() {
        _definitions = definitions;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  /// The form's value for a stored kvStore entry: `JSON.parse` the way
  /// the bundle's `kvStore.get` does, so a JSON string comes back as its
  /// string and a JSON boolean as 'true'/'false'. A value that does not
  /// parse is a raw string from an older write; it is used as-is.
  String? _decodeKvValue(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is String) return decoded;
      if (decoded is bool) return decoded ? 'true' : 'false';
      if (decoded is Map || decoded is List) return jsonEncode(decoded);
      if (decoded is num) return decoded.toString();
      return raw;
    } catch (_) {
      return raw;
    }
  }

  /// Writes one setting into the provider's kvStore and keeps the key
  /// index current, so `kvStore.keys()` lists it. The index is a JSON
  /// array of key names under the reserved index key (see the context
  /// bundle's `KV_INDEX_KEY`).
  Future<void> _writeKvValue(
    ExtensionRepository storage,
    String key,
    String jsonValue,
  ) async {
    final namespace = widget.installed.value;
    await storage.setExtensionData(
      VegaBasedProvider.kvKeyFor(namespace, key),
      jsonValue,
    );
    final indexKey = VegaBasedProvider.kvIndexKeyFor(namespace);
    final rawIndex = storage.getExtensionData(indexKey);
    final keys = <String>{};
    if (rawIndex != null) {
      try {
        final decoded = jsonDecode(rawIndex);
        if (decoded is List) {
          keys.addAll(decoded.whereType<String>());
        }
      } catch (_) {
        // A corrupt index is rebuilt from this key alone.
      }
    }
    if (keys.add(key)) {
      await storage.setExtensionData(indexKey, jsonEncode(keys.toList()));
    }
  }

  Future<void> _save() async {
    if (_saving || _loading) return;
    setState(() => _saving = true);
    try {
      final storage = ref.read(extensionRepositoryProvider);
      var shouldReload = false;
      for (final definition in _definitions) {
        var value =
            _controllers[definition.key]?.text ??
            _values[definition.key] ??
            definition.defaultValue;

        if (definition.type == PluginSettingType.url) {
          value = _normalizedUrl(value);
        } else if (definition.type == PluginSettingType.toggleGroup) {
          value = _normalizedToggleGroupValue(definition, value);
        }

        // Stored JSON-encoded, the way kvStore.set stores it. A toggle's
        // 'true'/'false' and a toggle group's JSON map already ARE JSON,
        // so they go in as-is; a select/text value is jsonEncode'd into
        // a JSON string.
        final jsonValue = switch (definition.type) {
          PluginSettingType.toggle || PluginSettingType.toggleGroup => value,
          _ => jsonEncode(value),
        };
        await _writeKvValue(storage, definition.key, jsonValue);
        _values[definition.key] = value;
        shouldReload = shouldReload || definition.reloadOnChange;
      }

      if (shouldReload) {
        await ref
            .read(vegaRepositoryProvider.notifier)
            .reloadProvider(widget.installed.value);
      }

      if (!mounted) return;
      ref.read(notificationServiceProvider).showExtension(
        AppLocalizations.of(context)!.vegaSettingsSaved,
        title: _displayName,
        icon: Icons.extension_rounded,
      );
    } catch (error) {
      if (!mounted) return;
      ref.read(notificationServiceProvider).showError(
        'Failed to save settings: $error',
        title: _displayName,
        icon: Icons.extension_rounded,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _normalizedUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';

    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(value)) {
      value = 'https://$value';
    }

    value = value.replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(value);

    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const FormatException('Enter a valid HTTP or HTTPS URL');
    }

    return uri.origin;
  }

  bool _boolValue(String key) {
    final value = (_values[key] ?? '').trim().toLowerCase();
    return value == 'true' || value == '1' || value == 'yes' || value == 'on';
  }

  bool _boolFromDynamic(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    if (value == null) return fallback;

    final normalized = value.toString().trim().toLowerCase();
    if (const {'true', '1', 'yes', 'on'}.contains(normalized)) return true;
    if (const {'false', '0', 'no', 'off'}.contains(normalized)) return false;
    return fallback;
  }

  Map<String, bool> _toggleGroupValues(
    PluginSettingDefinition definition, [
    String? rawValue,
  ]) {
    final values = <String, bool>{
      for (final option in definition.options) option.value: option.defaultBool,
    };

    final raw = rawValue ?? _values[definition.key] ?? definition.defaultValue;
    if (raw.trim().isEmpty) return values;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final option in definition.options) {
          values[option.value] = _boolFromDynamic(
            decoded[option.value],
            fallback: option.defaultBool,
          );
        }
      }
    } catch (_) {
      // Invalid or legacy values fall back to each option's default.
    }

    return values;
  }

  String _normalizedToggleGroupValue(
    PluginSettingDefinition definition,
    String rawValue,
  ) {
    return jsonEncode(_toggleGroupValues(definition, rawValue));
  }

  String _toggleGroupSummary(PluginSettingDefinition definition) {
    final values = _toggleGroupValues(definition);
    final enabled = [
      for (final option in definition.options)
        if (values[option.value] ?? option.defaultBool) option.label,
    ];
    return enabled.join(', ');
  }

  void _setToggleValue(String key, bool value) {
    if (_saving) return;
    setState(() => _values[key] = value ? 'true' : 'false');
  }

  Future<void> _showSelectDialog(PluginSettingDefinition definition) async {
    if (_saving || definition.options.isEmpty) return;

    final current = _values[definition.key] ?? definition.defaultValue;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(definition.title),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value == null || !mounted) return;
            setState(() => _values[definition.key] = value);
            Navigator.of(dialogContext).pop();
          },
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: definition.options
                  .map(
                    (option) => ListTile(
                      title: Text(option.label),
                      leading: Radio<String>(value: option.value),
                      onTap: () {
                        if (!mounted) return;
                        setState(() {
                          _values[definition.key] = option.value;
                        });
                        Navigator.of(dialogContext).pop();
                      },
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showToggleGroupDialog(
    PluginSettingDefinition definition,
  ) async {
    if (_saving || definition.options.isEmpty) return;

    final values = _toggleGroupValues(definition);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              surfaceTintColor: Colors.transparent,
              title: Text(definition.title),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: definition.options
                      .map((option) {
                        final description = option.description?.trim();
                        return SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(option.label),
                          subtitle: description == null || description.isEmpty
                              ? null
                              : Text(description),
                          value: values[option.value] ?? option.defaultBool,
                          onChanged: (enabled) {
                            values[option.value] = enabled;
                            setDialogState(() {});

                            if (!mounted) return;
                            setState(() {
                              _values[definition.key] = jsonEncode(values);
                            });
                          },
                        );
                      })
                      .toList(growable: false),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(AppLocalizations.of(dialogContext)!.close),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showTextDialog(PluginSettingDefinition definition) async {
    if (_saving) return;

    final value = await TextInputDialog.show(
      context,
      title: definition.title,
      // Stored verbatim: the old dialog never trimmed, and a provider may
      // rely on the exact text - a separator or a deliberate trailing
      // space.
      trim: false,
      initialText:
          _controllers[definition.key]?.text ??
          _values[definition.key] ??
          definition.defaultValue,
      keyboardType: definition.type == PluginSettingType.url
          ? TextInputType.url
          : TextInputType.text,
      helperText: definition.description,
      confirmLabel: AppLocalizations.of(context)!.save,
      allowEmpty: true,
    );

    if (value == null || !mounted) return;
    setState(() {
      _values[definition.key] = value;
      _controllers[definition.key]?.text = value;
    });
  }

  IconData _iconForSetting(PluginSettingDefinition definition) {
    switch (definition.type) {
      case PluginSettingType.toggle:
        return Icons.toggle_on_rounded;
      case PluginSettingType.toggleGroup:
        return Icons.tune_rounded;
      case PluginSettingType.select:
        return Icons.dns_rounded;
      case PluginSettingType.text:
        return Icons.text_fields_rounded;
      case PluginSettingType.url:
        return Icons.link_rounded;
    }
  }

  String _selectedOptionLabel(PluginSettingDefinition definition) {
    final value = _values[definition.key] ?? definition.defaultValue;
    for (final option in definition.options) {
      if (option.value == value) return option.label;
    }
    return value;
  }

  String? _settingSubtitle(PluginSettingDefinition definition) {
    final l10n = AppLocalizations.of(context)!;
    final description = definition.description?.trim();

    final value = switch (definition.type) {
      PluginSettingType.toggle => _boolValue(definition.key)
          ? l10n.enabled
          : l10n.disabled,
      PluginSettingType.toggleGroup => _toggleGroupSummary(definition),
      PluginSettingType.select => _selectedOptionLabel(definition),
      PluginSettingType.text || PluginSettingType.url =>
        _controllers[definition.key]?.text ??
            _values[definition.key] ??
            definition.defaultValue,
    };

    if (description != null && description.isNotEmpty && value.isNotEmpty) {
      return '$value\n$description';
    }
    if (value.isNotEmpty) return value;
    return description;
  }

  Widget _buildSettingTile(
    PluginSettingDefinition definition, {
    required bool isLast,
  }) {
    switch (definition.type) {
      case PluginSettingType.toggle:
        final value = _boolValue(definition.key);
        return SettingsTile(
          icon: _iconForSetting(definition),
          title: definition.title,
          subtitle: definition.description,
          trailing: Switch(
            value: value,
            onChanged: _saving
                ? null
                : (next) => _setToggleValue(definition.key, next),
          ),
          onTap: _saving ? null : () => _setToggleValue(definition.key, !value),
          isLast: isLast,
        );

      case PluginSettingType.toggleGroup:
        return SettingsTile(
          icon: _iconForSetting(definition),
          title: definition.title,
          subtitle: _settingSubtitle(definition),
          onTap: _saving ? null : () => _showToggleGroupDialog(definition),
          isLast: isLast,
        );

      case PluginSettingType.select:
        return SettingsTile(
          icon: _iconForSetting(definition),
          title: definition.title,
          subtitle: _settingSubtitle(definition),
          onTap: _saving ? null : () => _showSelectDialog(definition),
          isLast: isLast,
        );

      case PluginSettingType.text:
      case PluginSettingType.url:
        return SettingsTile(
          icon: _iconForSetting(definition),
          title: definition.title,
          subtitle: _settingSubtitle(definition),
          onTap: _saving ? null : () => _showTextDialog(definition),
          isLast: isLast,
        );
    }
  }

  Widget _buildContent() {
    // shrinkWrap, because this is a dialog and not a page: an unbounded
    // ListView takes every pixel its parent will give it. It still scrolls
    // once the content is taller than the room AlertDialog allows it.
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: LayoutConstants.spacingMd),
        children: [
          if (_definitions.isNotEmpty)
            SettingsGroup(
              filled: false,
              children: List.generate(
                _definitions.length,
                (index) => _buildSettingTile(
                  _definitions[index],
                  isLast: index == _definitions.length - 1,
                ),
              ),
            ),
          // No save button here: a dialog has an action bar and two of
          // them is one too many.
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final theme = Theme.of(context);
    final Widget body;
    if (_loading) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: AppLoadingIndicator(),
        ),
      );
    } else if (_error != null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 12),
            CustomButton(
              isPrimary: true,
              onPressed: _load,
              child: Text(l10n.retry),
            ),
          ],
        ),
      );
    } else if (_definitions.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          l10n.vegaNoSettings,
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    } else {
      body = _buildContent();
    }

    // The same AlertDialog every other dialog in the app uses - the one
    // "Add Repository" opens - rather than the glass panel the source
    // sheets are drawn in. This is a form, not a source list.
    return AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.pluginSettings(_displayName)),
      contentPadding: const EdgeInsets.fromLTRB(
        _kContentInset,
        4,
        _kContentInset,
        0,
      ),
      // Less the inset, so [_kDialogWidth] is the width of the PANEL rather
      // than of the box inside it.
      content: SizedBox(width: _kDialogWidth - _kContentInset * 2, child: body),
      actions: [
        CustomButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            l10n.close,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 8),
        CustomButton(
          isPrimary: true,
          onPressed: _loading || _saving ? null : _save,
          child: _saving
              ? const AppLoadingIndicator(
                  constraints: BoxConstraints.tightFor(width: 20, height: 20),
                )
              : Text(l10n.save),
        ),
      ],
    );
  }
}
