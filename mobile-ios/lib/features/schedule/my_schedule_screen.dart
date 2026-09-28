import 'package:flutter/material.dart';
import '../../core/database/app_database.dart';

/// "Mój grafik" (milestone scope). Point 6, non-negotiable: this screen
/// reads ONLY `AppDatabase.watchMySchedule()` — a Drift Stream — and never
/// makes an HTTP call itself. The background sync that actually updates
/// the underlying SQLite rows is triggered elsewhere (HomeScreen, on
/// init/resume) — this screen just reacts when those rows change.
/// Never: tap -> request -> spinner -> data. Always: SQLite -> UI
/// immediately, network updates SQLite in the background, Drift's stream
/// wakes the UI up when that happens.
class MyScheduleScreen extends StatelessWidget {
  const MyScheduleScreen({
    super.key,
    required this.db,
    required this.onLogout,
    this.showOfflineBanner = false,
    this.lastSyncAt,
    this.showSyncFailedBanner = false,
  });

  final AppDatabase db;
  final VoidCallback onLogout;
  final bool showOfflineBanner;
  final DateTime? lastSyncAt;
  final bool showSyncFailedBanner;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mój grafik'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Wyloguj',
            onPressed: () => _confirmLogout(context),
          ),
        ],
      ),
      body: Column(
        children: [
          if (showOfflineBanner)
            Container(
              width: double.infinity,
              color: Colors.amber.shade100,
              padding: const EdgeInsets.all(12),
              child: Text(
                '⚠ OFFLINE — dane z ${lastSyncAt != null ? _formatSyncTimestamp(lastSyncAt!) : "poprzedniej synchronizacji"}',
                textAlign: TextAlign.center,
              ),
            )
          else if (showSyncFailedBanner)
            Container(
              width: double.infinity,
              color: Colors.red.shade100,
              padding: const EdgeInsets.all(12),
              child: const Text(
                'Nie udało się zaktualizować danych. Pokazujemy ostatnią znaną wersję grafiku.',
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(child: _buildScheduleList()),
        ],
      ),
    );
  }

  Widget _buildScheduleList() {
    return StreamBuilder<List<MyScheduleEntry>>(
        stream: db.watchMySchedule(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            // First frame only, before the stream's initial value arrives
            // — not a network spinner, this resolves near-instantly from
            // local SQLite even fully offline.
            return const Center(child: CircularProgressIndicator());
          }

          final entries = List<MyScheduleEntry>.from(snapshot.data!)
            ..sort((a, b) => a.event.eventDate.compareTo(b.event.eventDate));

          if (entries.isEmpty) {
            return const _EmptyState();
          }

          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final tomorrow = today.add(const Duration(days: 1));

          final past = <MyScheduleEntry>[];
          final todayEntries = <MyScheduleEntry>[];
          final upcoming = <MyScheduleEntry>[];

          for (final entry in entries) {
            final d = entry.event.eventDate.toLocal();
            final dateOnly = DateTime(d.year, d.month, d.day);
            if (dateOnly.isBefore(today)) {
              past.add(entry);
            } else if (dateOnly.isBefore(tomorrow)) {
              todayEntries.add(entry);
            } else {
              upcoming.add(entry);
            }
          }
          // Most-recent-first for "Ostatnie" (past), soonest-first for the rest.
          past.sort((a, b) => b.event.eventDate.compareTo(a.event.eventDate));

          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              if (todayEntries.isNotEmpty) _SectionHeader('Dzisiaj'),
              ...todayEntries.map((e) => _ScheduleTile(entry: e)),
              if (upcoming.isNotEmpty) _SectionHeader('Nadchodzące'),
              ...upcoming.map((e) => _ScheduleTile(entry: e)),
              if (past.isNotEmpty) _SectionHeader('Ostatnie'),
              ...past.take(20).map((e) => _ScheduleTile(entry: e)),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wyloguj się?'),
        content: const Text('Będziesz musiał/a zalogować się ponownie, żeby zobaczyć swój grafik.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ANULUJ')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('WYLOGUJ')),
        ],
      ),
    );
    if (confirmed == true) onLogout();
  }

  String _formatSyncTimestamp(DateTime dt) {
    final local = dt.toLocal();
    two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}, ${two(local.hour)}:${two(local.minute)}';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
      ),
    );
  }
}

class _ScheduleTile extends StatelessWidget {
  const _ScheduleTile({required this.entry});
  final MyScheduleEntry entry;

  @override
  Widget build(BuildContext context) {
    final date = entry.event.eventDate.toLocal();
    final dateStr = _formatDate(date);
    final timeStr = _formatTime(date);
    final sourceLabel = entry.event.source == 'weekday_events' ? 'Msza w tygodniu' : 'Msza niedzielna/świąteczna';
    final description = entry.event.description;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.church_outlined),
        title: Text(description?.isNotEmpty == true ? description! : sourceLabel),
        subtitle: Text('$dateStr, godz. $timeStr\n$sourceLabel${_statusSuffix()}'),
        isThreeLine: true,
      ),
    );
  }

  String _statusSuffix() {
    if (entry.schedule.status == 'substitution_needed') return '\n⚠ Szukane zastępstwo';
    return '';
  }

  String _formatDate(DateTime d) {
    const months = [
      'stycznia', 'lutego', 'marca', 'kwietnia', 'maja', 'czerwca',
      'lipca', 'sierpnia', 'września', 'października', 'listopada', 'grudnia',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  String _formatTime(DateTime d) {
    two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.event_available_outlined, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            const Text(
              'Nie masz obecnie zaplanowanych służb.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
