import 'package:flutter/material.dart';
import '../../core/database/app_database.dart';

/// "Ogłoszenia" (hybrid dashboard milestone, P1 native + offline). Reads
/// ONLY `AppDatabase.watchAnnouncements()` — same non-negotiable rule as
/// MyScheduleScreen: never HTTP directly, background sync updates
/// SQLite, this screen just reacts.
class AnnouncementsScreen extends StatelessWidget {
  const AnnouncementsScreen({super.key, required this.db});

  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ogłoszenia')),
      body: StreamBuilder<List<Announcement>>(
        stream: db.watchAnnouncements(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snapshot.data!;
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.campaign_outlined, size: 48, color: Colors.grey.shade400),
                    const SizedBox(height: 16),
                    const Text('Brak ogłoszeń.', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final a = items[i];
              final date = a.createdAt.toLocal();
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(a.content),
                      const SizedBox(height: 12),
                      Text(
                        [
                          '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}',
                          if (a.authorName != null) a.authorName!,
                        ].join(' • '),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
