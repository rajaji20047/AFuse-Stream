/// Vega provider repositories: the manifest entries, the installed records
/// and the repository state (Phase 3 of the Vega bridge).
///
/// A Vega repository is a fork of `vega-org/providers-template` (or the de
/// facto `Zenda-Cross/vega-providers`): its root `manifest.json` is a JSON
/// array, one entry per provider. The entry's `value` is the provider's
/// folder name under `providers/` and the name of its `dist/<value>/`
/// bundles. Vega versions are free-form strings (`2.52`, `1.2`) — see
/// [compareVegaVersions], not the integer versions `.sky` plugins use.
library;

/// Compares two Vega version strings, numeric-aware per segment.
///
/// `2.52` > `2.5`, `1.0` < `1.0.1`, `1.0` == `1.0`. A segment that parses
/// as an integer on both sides compares numerically; anything else compares
/// lexicographically. A version that is a prefix of the other is the older
/// one. Pure, so it is unit-testable without any app state.
int compareVegaVersions(String a, String b) {
  final aParts = a.split('.');
  final bParts = b.split('.');
  final length = aParts.length < bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < length; i++) {
    final aSeg = aParts[i];
    final bSeg = bParts[i];
    if (aSeg == bSeg) continue;
    final aNum = int.tryParse(aSeg);
    final bNum = int.tryParse(bSeg);
    if (aNum != null && bNum != null) return aNum.compareTo(bNum);
    return aSeg.compareTo(bSeg);
  }
  return aParts.length.compareTo(bParts.length);
}

/// One provider listed in a Vega repository's `manifest.json`.
class VegaManifestEntry {
  /// Human-readable name shown in the app.
  final String displayName;

  /// Internal id; must exactly match the `providers/<value>/` folder name
  /// and the `dist/<value>/` bundle directory.
  final String value;

  /// Free-form version string; a bump drives the auto-update.
  final String version;

  /// Optional icon URL (may be empty).
  final String icon;

  /// Scope, usually `"global"`.
  final String type;

  /// `true` hides and disables the provider in the app.
  final bool disabled;

  /// `true` means the provider exposes a settings UI (`settings.ts`).
  final bool hasSettings;

  const VegaManifestEntry({
    required this.displayName,
    required this.value,
    required this.version,
    this.icon = '',
    this.type = 'global',
    this.disabled = false,
    this.hasSettings = false,
  });

  /// The provider's package name in Fuse's provider list, matching
  /// [VegaBasedProvider.packageName] (`vega.<value>`).
  String get packageName => 'vega.$value';

  factory VegaManifestEntry.fromJson(Map<String, dynamic> json) {
    final value = (json['value'] as String? ?? '').trim();
    final version = (json['version'] as String? ?? '').trim();
    return VegaManifestEntry(
      displayName: (json['display_name'] as String? ?? '').trim(),
      value: value,
      version: version.isEmpty ? '0' : version,
      icon: (json['icon'] as String? ?? '').trim(),
      type: (json['type'] as String? ?? 'global').trim(),
      disabled: json['disabled'] == true,
      hasSettings: json['hasSettings'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'display_name': displayName,
    'value': value,
    'version': version,
    'icon': icon,
    'type': type,
    'disabled': disabled,
    'hasSettings': hasSettings,
  };

  VegaManifestEntry copyWith({
    String? displayName,
    String? value,
    String? version,
    String? icon,
    String? type,
    bool? disabled,
    bool? hasSettings,
  }) => VegaManifestEntry(
    displayName: displayName ?? this.displayName,
    value: value ?? this.value,
    version: version ?? this.version,
    icon: icon ?? this.icon,
    type: type ?? this.type,
    disabled: disabled ?? this.disabled,
    hasSettings: hasSettings ?? this.hasSettings,
  );
}

/// A Vega provider repository the user added: where its manifest lives, what
/// the user called it, and what it listed when last read.
class VegaRepo {
  /// Canonical manifest URL (resolved at add time: a username becomes its
  /// `raw.githubusercontent.com/.../manifest.json`).
  final String manifestUrl;

  /// What the user entered: a GitHub username, or `user/repo` for a full
  /// repo URL. Shown as the repository's name (a Vega manifest carries no
  /// repository name of its own).
  final String label;

  /// Entries the manifest listed when last read (manifest-disabled entries
  /// included; the UI hides those).
  final List<VegaManifestEntry> entries;

  /// When the manifest was last fetched successfully, or null when it never
  /// was (added while offline, or every fetch failed).
  final DateTime? fetchedAt;

  const VegaRepo({
    required this.manifestUrl,
    required this.label,
    this.entries = const [],
    this.fetchedAt,
  });

  /// Entries the app shows: manifest-disabled providers are hidden, never
  /// listed as installable.
  List<VegaManifestEntry> get visibleEntries =>
      entries.where((e) => !e.disabled).toList(growable: false);

  Map<String, dynamic> toJson() => {
    'manifestUrl': manifestUrl,
    'label': label,
    'entries': [for (final e in entries) e.toJson()],
    'fetchedAt': fetchedAt?.toIso8601String(),
  };

  factory VegaRepo.fromJson(Map<String, dynamic> json) => VegaRepo(
    manifestUrl: (json['manifestUrl'] as String? ?? '').trim(),
    label: (json['label'] as String? ?? '').trim(),
    entries: _readEntries(json['entries']),
    fetchedAt: switch (json['fetchedAt']) {
      final String s => DateTime.tryParse(s),
      _ => null,
    },
  );

  /// One malformed entry must not empty the whole repository.
  static List<VegaManifestEntry> _readEntries(dynamic raw) {
    final out = <VegaManifestEntry>[];
    if (raw is! List) return out;
    for (final e in raw) {
      if (e is! Map) continue;
      try {
        out.add(VegaManifestEntry.fromJson(Map<String, dynamic>.from(e)));
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  VegaRepo copyWith({
    String? manifestUrl,
    String? label,
    List<VegaManifestEntry>? entries,
    DateTime? fetchedAt,
  }) => VegaRepo(
    manifestUrl: manifestUrl ?? this.manifestUrl,
    label: label ?? this.label,
    entries: entries ?? this.entries,
    fetchedAt: fetchedAt ?? this.fetchedAt,
  );
}

/// One installed Vega provider: what was installed, where it came from, and
/// the SHA-256 of each bundle file, so the runtime can tell a tampered or
/// half-written install from a good one. Persisted as `meta.json` beside
/// the bundles under `extensions/vega/<value>/`.
class VegaInstalledProvider {
  /// The manifest entry as installed (display name, value, version).
  final VegaManifestEntry entry;

  /// The manifest URL of the repository it came from: only that
  /// repository's listing may update it.
  final String repositoryUrl;

  /// When it was installed (or last updated).
  final DateTime installedAt;

  /// Module name -> SHA-256 hex of the installed `dist` bundle.
  final Map<String, String> moduleSha256;

  const VegaInstalledProvider({
    required this.entry,
    required this.repositoryUrl,
    required this.installedAt,
    this.moduleSha256 = const {},
  });

  String get packageName => entry.packageName;
  String get value => entry.value;

  Map<String, dynamic> toJson() => {
    'entry': entry.toJson(),
    'repositoryUrl': repositoryUrl,
    'installedAt': installedAt.toIso8601String(),
    'moduleSha256': moduleSha256,
  };

  factory VegaInstalledProvider.fromJson(Map<String, dynamic> json) {
    final entryRaw = json['entry'];
    if (entryRaw is! Map) {
      throw const FormatException('Vega install record has no entry');
    }
    final sha = json['moduleSha256'];
    return VegaInstalledProvider(
      entry: VegaManifestEntry.fromJson(
        Map<String, dynamic>.from(entryRaw),
      ),
      repositoryUrl: (json['repositoryUrl'] as String? ?? '').trim(),
      installedAt:
          DateTime.tryParse(json['installedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      moduleSha256: sha is Map
          ? {
              for (final e in sha.entries)
                if (e.value is String) '${e.key}': e.value as String,
            }
          : const {},
    );
  }

  VegaInstalledProvider copyWith({
    VegaManifestEntry? entry,
    String? repositoryUrl,
    DateTime? installedAt,
    Map<String, String>? moduleSha256,
  }) => VegaInstalledProvider(
    entry: entry ?? this.entry,
    repositoryUrl: repositoryUrl ?? this.repositoryUrl,
    installedAt: installedAt ?? this.installedAt,
    moduleSha256: moduleSha256 ?? this.moduleSha256,
  );
}

/// The Vega repository state: the sources the user added, what each lists,
/// what is installed, and what has an update waiting.
class VegaState {
  const VegaState({
    this.isLoading = false,
    this.repos = const [],
    this.available = const {},
    this.installed = const [],
    this.updates = const {},
    this.installing = const {},
    this.disabled = const {},
    this.error,
  });

  /// True while the first load is running. Starts false (unlike the
  /// CloudStream store): `build()` does no I/O, so the Extensions screen
  /// never watches a spinner that cannot finish in a test harness.
  final bool isLoading;

  /// Repositories the user added, in the order they were added.
  final List<VegaRepo> repos;

  /// What each repository lists, by manifest URL.
  final Map<String, List<VegaManifestEntry>> available;

  /// Installed providers, in install order.
  final List<VegaInstalledProvider> installed;

  /// Newer versions waiting, by package name (`vega.<value>`).
  final Map<String, VegaManifestEntry> updates;

  /// Provider values being installed or updated right now.
  final Set<String> installing;

  /// Package names the user disabled: installed on disk, not published to
  /// the provider list. Mirrors the `.sky` sub-provider enable toggle.
  final Set<String> disabled;

  /// The last load error, if the last load failed outright. Cleared on the
  /// next successful load; a failed manifest refresh for one repository
  /// does not set this (that repository keeps its last listing).
  final String? error;

  bool get hasInstalled => installed.isNotEmpty;

  VegaInstalledProvider? installedFor(String value) {
    for (final p in installed) {
      if (p.value == value) return p;
    }
    return null;
  }

  VegaManifestEntry? updateFor(String packageName) => updates[packageName];

  bool isDisabled(String packageName) => disabled.contains(packageName);

  bool isInstalling(String value) => installing.contains(value);

  VegaState copyWith({
    bool? isLoading,
    List<VegaRepo>? repos,
    Map<String, List<VegaManifestEntry>>? available,
    List<VegaInstalledProvider>? installed,
    Map<String, VegaManifestEntry>? updates,
    Set<String>? installing,
    Set<String>? disabled,
    String? error,
    bool clearError = false,
  }) => VegaState(
    isLoading: isLoading ?? this.isLoading,
    repos: repos ?? this.repos,
    available: available ?? this.available,
    installed: installed ?? this.installed,
    updates: updates ?? this.updates,
    installing: installing ?? this.installing,
    disabled: disabled ?? this.disabled,
    error: clearError ? null : (error ?? this.error),
  );
}
