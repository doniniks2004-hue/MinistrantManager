<?php

namespace MinistrantManager\MobileAPI\Contracts;

use MinistrantManager\MobileAPI\DTO\DeviceContext;

interface AttendanceRepositoryInterface
{
    public function bootstrap(DeviceContext $ctx): array;
}
