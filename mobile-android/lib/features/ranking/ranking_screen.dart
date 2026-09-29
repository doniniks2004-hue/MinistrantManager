import 'package:flutter/material.dart';
import '../../core/database/app_database.dart';

/// "Ranking" (hybrid dashboard milestone, P1 native + offline). Reads
/// ONLY Drift — the server computes the ranking fresh on every sync
/// (LegacyMysqlRankingRepository), this screen just displays the last
/// cached snapshot. Never a local source of truth for standings.
class RankingScreen extends StatelessWidget {
  const RankingScreen({super.key, required this.db});

  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ranking')),
      body: StreamBuilder<List<RankingEntry>>(
        stream: db.watchRanking(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snapshot.data!;
          if (entries.isEmpty) {
            return const Center(child: Text('Ranking jest pusty.', style: TextStyle(color: Colors.grey)));
          }

          RankingEntry? myEntry;
          for (final e in entries) {
            if (e.isCurrentUser) {
              myEntry = e;
              break;
            }
          }

          return Column(
            children: [
              if (myEntry != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _StatColumn(label: 'Twoje miejsce', value: '#${myEntry.position}'),
                      _StatColumn(label: 'Twoje punkty', value: '${myEntry.totalPoints}'),
                    ],
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final entry = entries[i];
                    final isTopThree = entry.position <= 3;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isTopThree ? Colors.amber.shade200 : null,
                        child: Text('${entry.position}'),
                      ),
                      title: Text(
                        entry.fullName,
                        style: TextStyle(fontWeight: entry.isCurrentUser ? FontWeight.bold : FontWeight.normal),
                      ),
                      trailing: Text('${entry.totalPoints} pkt', style: const TextStyle(fontWeight: FontWeight.bold)),
                      tileColor: entry.isCurrentUser ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3) : null,
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

class _StatColumn extends StatelessWidget {
  const _StatColumn({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 4),
        Text(value, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
      ],
    );
  }
}
