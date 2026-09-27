<?php

namespace MinistrantManager\MobileAPI\DTO;

/**
 * One entry from the mobile app's `pending_actions` queue, as POSTed to
 * `/api/v1/mobile/actions`. Mirrors the Flutter-side PendingAction row
 * (see mobile app's core/database/tables.dart) field for field.
 */
final class ActionRequest
{
    public function __construct(
        public readonly string $clientActionId,
        public readonly string $type,
        public readonly array $payload,
        public readonly ?int $baseVersion,
        public readonly \DateTimeImmutable $createdAt,
    ) {
    }

    public static function fromArray(array $data): self
    {
        return new self(
            clientActionId: $data['client_action_id'],
            type: $data['type'],
            payload: $data['payload'],
            baseVersion: $data['base_version'] ?? null,
            createdAt: new \DateTimeImmutable($data['created_at']),
        );
    }
}
