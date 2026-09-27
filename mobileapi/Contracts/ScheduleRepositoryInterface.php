<?php

namespace MinistrantManager\MobileAPI\Contracts;

use MinistrantManager\MobileAPI\DTO\DeviceContext;

interface ScheduleRepositoryInterface
{
    public function bootstrap(DeviceContext $ctx): array;
}
