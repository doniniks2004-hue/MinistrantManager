<?php

namespace MinistrantManager\MobileAPI\Repositories\Fake;

use MinistrantManager\MobileAPI\Actions\ActionHandlerInterface;
use MinistrantManager\MobileAPI\DTO\ActionRequest;
use MinistrantManager\MobileAPI\DTO\DeviceContext;

/**
 * TEST FIXTURE — illustrates a non-versioned handler (spec §14). apply()
 * is the actual mutation; buildChanges()/recordId() are irrelevant here
 * and throw, mirroring how a real non-versioned handler (Iteration 2)
 * should be written.
 */
class FakeAttendanceHandler implements ActionHandlerInterface
{
    public array $applied = []; // records every actual apply() call, for test assertions

    public function isVersioned(): bool
    {
        return false;
    }

    public function recordId(ActionRequest $request): string
    {
        throw new \LogicException('non-versioned handler never needs recordId()');
    }

    public function buildChanges(ActionRequest $request, DeviceContext $ctx): array
    {
        throw new \LogicException('non-versioned handler never needs buildChanges() — use apply()');
    }

    public function apply(ActionRequest $request, DeviceContext $ctx): void
    {
        $this->applied[] = $request->payload;
    }
}
