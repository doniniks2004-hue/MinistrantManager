<?php

namespace MinistrantManager\MobileAPI\Controllers;

use Illuminate\Http\Request;
use MinistrantManager\MobileAPI\Actions\ActionDispatcher;
use MinistrantManager\MobileAPI\DTO\ActionRequest;
use MinistrantManager\MobileAPI\DTO\DeviceContext;

/** NOT INTEGRATED (see docs/TESTING.md). `POST /api/v1/mobile/actions`. */
class ActionsController
{
    public function __construct(private readonly ActionDispatcher $dispatcher)
    {
    }

    public function store(Request $request)
    {
        $ctx = new DeviceContext(
            installationId: $request->attributes->get('installation_id'),
            parishId: $request->attributes->get('device_parish_id'),
            parishSlug: $request->attributes->get('parish_slug'),
            platform: $request->header('X-Platform', 'unknown'),
        );

        $results = [];
        foreach ($request->input('actions', []) as $actionData) {
            $actionRequest = ActionRequest::fromArray($actionData);
            $results[] = $this->dispatcher->dispatch($actionRequest, $ctx)->toArray();
        }

        return response()->json(['results' => $results]);
    }
}
