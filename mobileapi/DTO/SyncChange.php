<?php

namespace MinistrantManager\MobileAPI\DTO;

/**
 * One row of the incremental-sync change feed (spec §10 / decision #7:
 * mobile sync owns its own change log / tombstones, independent of
 * whether every underlying MM table has soft-deletes). `operation` is one
 * of "create", "update", "delete". For "delete", `data` is null — the
 * client only needs entityType+entityId to remove its local copy.
 */
final class SyncChange
{
    public function __construct(
        public readonly string $entityType, // "event", "announcement", "schedule_assignment", ...
        public readonly string $entityId,
        public readonly string $operation,
        public readonly ?int $version,
        public readonly \DateTimeImmutable $changedAt,
        public readonly ?array $data = null,
    ) {
    }

    public function toArray(): array
    {
        return [
            'entity_type' => $this->entityType,
            'entity_id' => $this->entityId,
            'operation' => $this->operation,
            'version' => $this->version,
            'changed_at' => $this->changedAt->format(DATE_ATOM),
            'data' => $this->data,
        ];
    }
}
