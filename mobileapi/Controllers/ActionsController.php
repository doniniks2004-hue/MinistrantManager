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
        // Review round (final micro-round, point 3): this endpoint will
        // soon front real Ministrant Manager data — a malformed request
        // (missing UUID, wrong types, no created_at) previously fell
        // straight through to ActionRequest::fromArray() with no
        // validation at all, risking an uncaught TypeError/500 instead of
        // a clean, expected 422. `max:100` also caps how many actions one
        // request can smuggle in a single batch.
        $validated = $request->validate([
            'actions' => ['required', 'array', 'max:100'],
            'actions.*.client_action_id' => ['required', 'uuid'],
            'actions.*.type' => ['required', 'string', 'max:128'],
            'actions.*.payload' => ['required', 'array'],
            'actions.*.base_version' => ['nullable', 'integer', 'min:0'],
            'actions.*.created_at' => ['required', 'date'],
        ]);

        $ctx = new DeviceContext(
            installationId: $request->attributes->get('installation_id'),
            parishId: $request->attributes->get('device_parish_id'),
            parishSlug: $request->attributes->get('parish_slug'),
            platform: $request->header('X-Platform', 'unknown'),
        );

        $results = [];
        foreach ($validated['actions'] as $actionData) {
            $actionRequest = ActionRequest::fromArray($actionData);
            $results[] = $this->dispatcher->dispatch($actionRequest, $ctx)->toArray();
        }

        return response()->json(['results' => $results]);
    }
}
