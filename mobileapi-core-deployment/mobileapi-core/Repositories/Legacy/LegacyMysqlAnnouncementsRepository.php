<?php

namespace MinistrantManager\MobileAPI\Repositories\Legacy;

use mysqli;

/**
 * Hybrid dashboard milestone, P1 native module. Real schema: `announcements`
 * (id, title, content, author_id, created_at) — `author_id` resolved
 * server-side via a JOIN against `users` so the client never needs a
 * people catalog just to show who wrote an announcement (same principle
 * as schedule's server-side user filtering).
 *
 * Deliberately no formal Contracts/ interface for this one (unlike
 * Events/Schedule) — a single parish-agnostic read query with no
 * per-parish variation to abstract over yet; adding the interface layer
 * now would be ceremony without payoff (review round: "nie próbuj
 * przepisać wszystkiego").
 */
final class LegacyMysqlAnnouncementsRepository
{
    public function __construct(private readonly mysqli $conn)
    {
    }

    /** @return list<array<string, mixed>> */
    public function recent(int $limit = 50): array
    {
        $stmt = $this->conn->prepare(
            'SELECT a.id, a.title, a.content, a.created_at, u.full_name AS author_name
             FROM announcements a
             LEFT JOIN users u ON u.id = a.author_id
             ORDER BY a.created_at DESC
             LIMIT ?'
        );
        $stmt->bind_param('i', $limit);
        $stmt->execute();
        $result = $stmt->get_result();

        $rows = [];
        while ($row = $result->fetch_assoc()) {
            $rows[] = [
                'id' => 'announcements:' . $row['id'],
                'raw_id' => (int) $row['id'],
                'title' => $row['title'],
                'content' => $row['content'],
                'author_name' => $row['author_name'],
                'created_at' => $this->toIso8601($row['created_at']),
            ];
        }
        $stmt->close();

        return $rows;
    }

    private function toIso8601(string $mysqlDatetime): string
    {
        // Same approach as LegacyMysqlEventsRepository's own toIso8601() —
        // legacy DATETIME columns are timezone-naive, implicitly
        // Europe/Warsaw; DateTimeImmutable computes the correct DST-aware
        // offset (+01:00 winter / +02:00 summer) rather than a fixed
        // string that would be wrong half the year.
        $dt = \DateTimeImmutable::createFromFormat('Y-m-d H:i:s', $mysqlDatetime, new \DateTimeZone('Europe/Warsaw'));
        return $dt->format(DATE_ATOM);
    }
}
