<?php

namespace MinistrantManager\MobileAPI\Contracts;

use MinistrantManager\MobileAPI\DTO\DeviceContext;

/**
 * Spec decision #6: the phone NEVER computes ranking — it only ever
 * displays whatever the existing Ministrant Manager already computed.
 * This method returns that pre-computed result as-is.
 */
interface RankingRepositoryInterface
{
    public function bootstrap(DeviceContext $ctx): array;
}
