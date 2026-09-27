<?php
require __DIR__ . '/autoload.php';

use MinistrantManager\MobileAPI\Actions\ActionDispatcher;
use MinistrantManager\MobileAPI\Actions\ActionHandlerInterface;
use MinistrantManager\MobileAPI\DTO\ActionRequest;
use MinistrantManager\MobileAPI\DTO\DeviceContext;
use MinistrantManager\MobileAPI\Repositories\Fake\FakeVersionedRecordRepository;
use MinistrantManager\MobileAPI\Repositories\Fake\SqliteActionLogRepository;

/**
 * One "device" pushing the SAME pending action (identical
 * client_action_id) as another process running concurrently. The
 * increment handler is intentionally slow-ish (a real DB write plus a
 * small sleep) to widen the race window — exactly the "check happens,
 * then mutation happens" gap that a broken idempotency implementation
 * would let both processes fall into.
 */
class IncrementCounterHandler implements ActionHandlerInterface
{
    public function __construct(private readonly string $dbPath)
    {
    }

    public function isVersioned(): bool
    {
        return false;
    }

    public function recordId(ActionRequest $request): string
    {
        throw new LogicException('non-versioned');
    }

    public function buildChanges(ActionRequest $request, DeviceContext $ctx): array
    {
        throw new LogicException('non-versioned');
    }

    public function apply(ActionRequest $request, DeviceContext $ctx): void
    {
        $pdo = new PDO("sqlite:{$this->dbPath}");
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec('PRAGMA busy_timeout = 5000;');
        // Widen the race window deliberately — see class docblock.
        usleep(30000);
        $pdo->exec('UPDATE counter SET value = value + 1 WHERE id = 1');
    }
}

[$dbPath, $clientActionId, $resultPath] = [$argv[1], $argv[2], $argv[3]];

$actionLog = new SqliteActionLogRepository($dbPath);
$versioned = new FakeVersionedRecordRepository(); // unused — this test is the non-versioned path
$dispatcher = new ActionDispatcher($actionLog, $versioned);
$dispatcher->registerHandler('counter.increment', new IncrementCounterHandler($dbPath));

$ctx = new DeviceContext(installationId: 'inst', parishId: 'p1', parishSlug: 'chwk', platform: 'android');
$request = new ActionRequest(
    clientActionId: $clientActionId,
    type: 'counter.increment',
    payload: [],
    baseVersion: null,
    createdAt: new DateTimeImmutable(),
);

$result = $dispatcher->dispatch($request, $ctx);

file_put_contents($resultPath, json_encode(['pid' => getmypid(), 'status' => $result->status]));
