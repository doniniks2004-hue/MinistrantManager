<?php

namespace MinistrantManager\MobileAPI\Contracts;

use MinistrantManager\MobileAPI\DTO\DeviceContext;

interface PointsRepositoryInterface
{
    public function bootstrap(DeviceContext $ctx): array;
}
