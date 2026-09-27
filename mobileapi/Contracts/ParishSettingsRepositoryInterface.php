<?php

namespace MinistrantManager\MobileAPI\Contracts;

use MinistrantManager\MobileAPI\DTO\DeviceContext;

interface ParishSettingsRepositoryInterface
{
    public function bootstrap(DeviceContext $ctx): array;
}
