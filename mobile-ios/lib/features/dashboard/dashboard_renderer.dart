import 'package:flutter/material.dart';
import 'module_version_gate.dart';

/// Client-side counterpart to MobileAPI's Config\ServerDrivenUiSchema
/// (spec §17 / decision #13). The known-component list here MUST stay in
/// sync with that PHP-side contract — component names are the wire
/// format both sides agree on, schema_version 1.
///
/// Hard safety rule (decision #13, non-negotiable): the server sends
/// DATA and DECLARATIVE component selection ONLY. This renderer NEVER
/// evaluates a string as code — no js-in-webview, no template
/// interpolation that could smuggle in Dart/JS, nothing. An unrecognized
/// `component` value renders `_UnsupportedComponentFallback` and logs
/// the name; it never throws, so one bad/future component in the config
/// can't take down the whole dashboard.
class DashboardRenderer extends StatelessWidget {
  const DashboardRenderer({super.key, required this.config, required this.deviceAppVersion});

  final Map<String, dynamic> config;
  final String deviceAppVersion;

  static const _knownComponents = {
    'card', 'stat_card', 'text', 'info_box', 'status_badge',
    'list', 'event_list', 'calendar', 'button', 'tabs', 'simple_form',
  };

  @override
  Widget build(BuildContext context) {
    final dashboard = config['dashboard'] as Map<String, dynamic>? ?? {};
    final modules = (config['modules'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final items = (dashboard['items'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>()
      ..sort((a, b) => (a['order'] as int? ?? 0).compareTo(b['order'] as int? ?? 0));

    final modulesById = {for (final m in modules) m['id'] as String: m};
    final columns = dashboard['columns'] as int? ?? 1;

    final tiles = items
        .where((item) => item['enabled'] != false)
        .map((item) => _buildModuleTile(modulesById[item['module_id']], item))
        .toList();

    if (tiles.isEmpty) {
      return const Center(child: Text('Brak skonfigurowanych modułów.', style: TextStyle(color: Colors.grey)));
    }

    return GridView.count(
      crossAxisCount: columns.clamp(1, 4),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      children: tiles,
    );
  }

  Widget _buildModuleTile(Map<String, dynamic>? module, Map<String, dynamic> item) {
    if (module == null) {
      // The dashboard references a module_id that isn't in the modules
      // list at all — a config-authoring mistake, not a client bug.
      // Fails safe, same principle as an unknown component.
      return _UnsupportedComponentFallback(label: item['title'] as String? ?? item['module_id'] as String? ?? '?');
    }

    final minVersion = module['min_app_version'] as String?;
    if (minVersion != null && ModuleVersionGate.isOlderThan(deviceAppVersion, minVersion)) {
      // Spec §18: module exists and is a known component, but THIS
      // device's app build is too old for it. Never silently hide it —
      // tell the user an update unlocks it.
      return _UpdateRequiredTile(title: item['title'] as String? ?? module['id'] as String);
    }

    final component = module['component'] as String? ?? '';
    if (!_knownComponents.contains(component)) {
      // ignore: avoid_print
      print('Ministrant Manager: unsupported dashboard component "$component" for module "${module['id']}" — showing fallback.');
      return _UnsupportedComponentFallback(label: item['title'] as String? ?? module['id'] as String? ?? component);
    }

    // Iteration 1 scope: render a title/icon placeholder tile per known
    // component type. Each component's REAL data-bound rendering (e.g.
    // event_list actually listing db.events rows) is an Iteration 2/3
    // concern once real bootstrap data flows through — this proves the
    // config->component->safe-render pipeline end-to-end without
    // depending on data this iteration doesn't have.
    return _ModuleTile(
      title: item['title'] as String? ?? module['id'] as String,
      icon: _iconFor(item['icon'] as String?),
    );
  }

  IconData _iconFor(String? name) {
    switch (name) {
      case 'calendar':
        return Icons.calendar_today;
      case 'star':
        return Icons.star;
      case 'megaphone':
        return Icons.campaign;
      case 'swap':
        return Icons.swap_horiz;
      default:
        return Icons.widgets_outlined;
    }
  }
}

class _ModuleTile extends StatelessWidget {
  const _ModuleTile({required this.title, required this.icon});
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: () {}, // Iteration 2/3: navigate to the real module screen
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 32),
            const SizedBox(height: 8),
            Text(title, textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }
}

class _UpdateRequiredTile extends StatelessWidget {
  const _UpdateRequiredTile({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.grey.shade100,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.lock_outline, size: 28, color: Colors.grey),
          const SizedBox(height: 8),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 4),
          const Text('Zaktualizuj aplikację, aby korzystać z tej funkcji.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
      ),
    );
  }
}

class _UnsupportedComponentFallback extends StatelessWidget {
  const _UnsupportedComponentFallback({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.grey.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.help_outline, size: 28, color: Colors.grey),
          const SizedBox(height: 8),
          Text(label, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ]),
      ),
    );
  }
}
