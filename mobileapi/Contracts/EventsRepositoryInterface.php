<?php

namespace MinistrantManager\MobileAPI\Contracts;

use MinistrantManager\MobileAPI\DTO\DeviceContext;

interface EventsRepositoryInterface
{
    /** @return array<int, array> list of event records for bootstrap payload */
    public function bootstrap(DeviceContext $ctx): array;
}
