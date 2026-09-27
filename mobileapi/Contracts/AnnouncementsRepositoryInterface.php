<?php

namespace MinistrantManager\MobileAPI\Contracts;

use MinistrantManager\MobileAPI\DTO\DeviceContext;

interface AnnouncementsRepositoryInterface
{
    public function bootstrap(DeviceContext $ctx): array;
}
