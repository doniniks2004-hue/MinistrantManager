<?php

namespace MinistrantManager\MobileAPI\Repositories\Fake;

use MinistrantManager\MobileAPI\Actions\ActionHandlerInterface;
use MinistrantManager\MobileAPI\DTO\ActionRequest;
use MinistrantManager\MobileAPI\DTO\DeviceContext;

/**
 * TEST FIXTURE — illustrates a versioned handler (spec §14). buildChanges()
 * is PURE — no storage access — and returns the payload's "changes" map;
 * ActionDispatcher passes it straight to
 * VersionedRecordRepositoryInterface::applyVersionedUpdate(), which is
 * the only place the actual write happens. apply() is irrelevant here and
 * throws, mirroring how a real versioned handler (Iteration 2) should be
 * written.
 */
class FakeScheduleEditHandler implements ActionHandlerInterface
{
    public function isVersioned(): bool
    {
        return true;
    }

    public function recordId(ActionRequest $request): string
    {
        return $request->payload['record_id'];
    }

    public function buildChanges(ActionRequest $request, DeviceContext $ctx): array
    {
        return $request->payload['changes'] ?? [];
    }

    public function apply(ActionRequest $request, DeviceContext $ctx): void
    {
        throw new \LogicException('versioned handler never needs apply() — use buildChanges()');
    }
}
