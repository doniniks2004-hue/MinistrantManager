import 'package:flutter/material.dart';
import '../../core/database/app_database.dart';

/// "Obecności" (hybrid dashboard milestone, P1 native + offline —
/// final P1 module). Review round: "UI może wyglądać spójnie, ale
/// adapter musi wiedzieć, z którego źródła pochodzi rekord" — this
/// screen combines TWO genuinely distinct legacy sources under one
/// consistent tab UI, but never merges them into one data model:
///   - "Msze" — schedule.is_present (already synced via ScheduleAssignments,
///     no separate table/endpoint for this half at all)
///   - "Zbiórki" — gathering_attendance (a real, separate table with its
///     own points/excuse semantics)
class AttendanceScreen extends StatelessWidget {
  const AttendanceScreen({super.key, required this.db});

  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Obecności'),
          bottom: const TabBar(tabs: [Tab(text: 'Msze'), Tab(text: 'Zbiórki')]),
        ),
        body: TabBarView(
          children: [
            _MassAttendanceTab(db: db),
            _GatheringAttendanceTab(db: db),
          ],
        ),
      ),
    );
  }
}

class _MassAttendanceTab extends StatelessWidget {
  const _MassAttendanceTab({required this.db});
  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MyScheduleEntry>>(
      stream: db.watchMassAttendanceHistory(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final items = snapshot.data!;
        if (items.isEmpty) {
          return const Center(child: Text('Brak historii obecności na mszach.', style: TextStyle(color: Colors.grey)));
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final entry = items[i];
            final date = entry.event.eventDate.toLocal();
            final present = entry.schedule.isPresent;
            return ListTile(
              leading: Icon(
                present ? Icons.check_circle : Icons.cancel,
                color: present ? Colors.green : Colors.red.shade300,
              ),
              title: Text(
                entry.event.description?.isNotEmpty == true
                    ? entry.event.description!
                    : (entry.event.source == 'weekday_events' ? 'Msza w tygodniu' : 'Msza niedzielna'),
              ),
              subtitle: Text('${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}'),
              trailing: Text(present ? 'Obecny' : 'Nieobecny', style: TextStyle(color: present ? Colors.green : Colors.red.shade300)),
            );
          },
        );
      },
    );
  }
}

class _GatheringAttendanceTab extends StatelessWidget {
  const _GatheringAttendanceTab({required this.db});
  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<GatheringAttendanceRecord>>(
      stream: db.watchGatheringAttendance(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final items = snapshot.data!;
        if (items.isEmpty) {
          return const Center(child: Text('Brak historii obecności na zbiórkach.', style: TextStyle(color: Colors.grey)));
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final r = items[i];
            final date = r.gatheringDate.toLocal();
            final statusLabel = r.wasPresent ? 'Obecny' : (r.isExcused ? 'Usprawiedliwiony' : 'Nieobecny');
            final statusColor = r.wasPresent ? Colors.green : (r.isExcused ? Colors.orange : Colors.red.shade300);
            return ListTile(
              leading: Icon(
                r.wasPresent ? Icons.check_circle : (r.isExcused ? Icons.info : Icons.cancel),
                color: statusColor,
              ),
              title: Text(r.gatheringTitle),
              subtitle: Text([
                '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}',
                if (r.notes?.isNotEmpty == true) r.notes!,
              ].join(' • ')),
              trailing: Text(
                r.pointsAwarded != 0 ? '$statusLabel (${r.pointsAwarded > 0 ? '+' : ''}${r.pointsAwarded})' : statusLabel,
                style: TextStyle(color: statusColor),
              ),
            );
          },
        );
      },
    );
  }
}
