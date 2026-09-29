import 'package:flutter/material.dart';
import '../../core/database/app_database.dart';

/// "Historia punktów" (hybrid dashboard milestone, P1 native + offline).
/// Reads ONLY Drift — same rule as every other native screen. The
/// current total is read from the current user's own RankingEntry row
/// (isCurrentUser==true) rather than duplicating a separate "total"
/// value — both come from the exact same server-side SUM(points_value),
/// so storing it twice would just be two copies of the same number.
class PointsScreen extends StatelessWidget {
  const PointsScreen({super.key, required this.db});

  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Historia punktów')),
      body: StreamBuilder<List<RankingEntry>>(
        stream: db.watchRanking(),
        builder: (context, rankingSnapshot) {
          RankingEntry? myEntry;
          if (rankingSnapshot.hasData) {
            for (final entry in rankingSnapshot.data!) {
              if (entry.isCurrentUser) {
                myEntry = entry;
                break;
              }
            }
          }
          return Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Column(
                  children: [
                    Text('Aktualna liczba punktów', style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 4),
                    Text(
                      myEntry != null ? '${myEntry.totalPoints}' : '—',
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<List<Point>>(
                  stream: db.watchPoints(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final items = snapshot.data!;
                    if (items.isEmpty) {
                      return const Center(
                        child: Text('Brak historii punktów.', style: TextStyle(color: Colors.grey)),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: items.length,
                      itemBuilder: (context, i) => _PointTile(point: items[i]),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PointTile extends StatelessWidget {
  const _PointTile({required this.point});
  final Point point;

  @override
  Widget build(BuildContext context) {
    final positive = point.pointsValue >= 0;
    final date = point.createdAt.toLocal();
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: positive ? Colors.green.shade100 : Colors.red.shade100,
        child: Icon(positive ? Icons.add : Icons.remove, color: positive ? Colors.green.shade800 : Colors.red.shade800),
      ),
      title: Text(point.reason?.isNotEmpty == true ? point.reason! : _eventTypeLabel(point.eventType)),
      subtitle: Text(
        [
          '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}',
          if (point.assignerName != null) point.assignerName!,
        ].join(' • '),
      ),
      trailing: Text(
        '${positive ? '+' : ''}${point.pointsValue}',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 16,
          color: positive ? Colors.green.shade800 : Colors.red.shade800,
        ),
      ),
    );
  }

  String _eventTypeLabel(String? eventType) {
    switch (eventType) {
      case 'mass':
        return 'Msza';
      case 'devotion':
        return 'Nabożeństwo';
      case 'triduum':
        return 'Triduum';
      default:
        return 'Inne';
    }
  }
}
