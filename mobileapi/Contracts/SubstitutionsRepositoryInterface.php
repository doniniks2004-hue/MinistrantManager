<?php

namespace MinistrantManager\MobileAPI\Contracts;

use MinistrantManager\MobileAPI\DTO\DeviceContext;

interface SubstitutionsRepositoryInterface
{
    public function bootstrap(DeviceContext $ctx): array;
}
