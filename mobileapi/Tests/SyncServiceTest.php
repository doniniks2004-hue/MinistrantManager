<?php
require __DIR__ . '/autoload.php';

use MinistrantManager\MobileAPI\DTO\SyncChange;
use MinistrantManager\MobileAPI\Repositories\Fake\FakeSyncChangeLogRepository;
use MinistrantManager\MobileAPI\Sync\SyncService;

function assertTrue(bool $cond, string $msg): void {
    if (!$cond) { fwrite(STDERR, "FAIL: $msg\n"); exit(1); }
    echo "PASS: $msg\n";
}
function assertEquals($expected, $actual, string $msg): void {
    if ($expected !== $actual) {
        fwrite(STDERR, "FAIL: $msg (expected " . var_export($expected, true) . ", got " . var_export($actual, true) . ")\n");
        exit(1);
    }
    echo "PASS: $msg\n";
}

$repo = new FakeSyncChangeLogRepository();
$service = new SyncService($repo);

$repo->append('chwk', new SyncChange('event', 'e1', 'create', 1, new DateTimeImmutable(), ['id' => 'e1', 'title' => 'Triduum']));
$repo->append('chwk', new SyncChange('event', 'e2', 'create', 1, new DateTimeImmutable(), ['id' => 'e2', 'title' => 'Roraty']));
$repo->append('chwk', new SyncChange('announcement', 'a1', 'create', 1, new DateTimeImmutable(), ['id' => 'a1', 'body' => 'Witamy']));

// First page from scratch (cursor = null, as after bootstrap)
$page1 = $service->incrementalSync('chwk', null);
assertEquals(2, count($page1['changes']['event']), 'first sync page picks up both created events');
assertEquals(1, count($page1['changes']['announcement']), 'first sync page picks up the created announcement');
assertTrue(empty($page1['deleted']), 'no deletes yet — deleted bucket is empty');

// Now event e1 gets deleted (tombstone) and e2 gets updated, AFTER the cursor from page1.
$repo->append('chwk', new SyncChange('event', 'e1', 'delete', null, new DateTimeImmutable()));
$repo->append('chwk', new SyncChange('event', 'e2', 'update', 2, new DateTimeImmutable(), ['id' => 'e2', 'title' => 'Roraty (zmieniona godzina)']));

$page2 = $service->incrementalSync('chwk', $page1['cursor']);
assertEquals(['e1'], $page2['deleted']['event'], 'page2 reports e1 as deleted — client must remove it locally, not just skip an update');
assertEquals(1, count($page2['changes']['event']), 'page2 reports exactly the one updated event (e2), not e1 again');
assertEquals('Roraty (zmieniona godzina)', $page2['changes']['event'][0]['title'], 'updated event carries the new data');

// A parish with zero changes since a fresh cursor gets an empty-but-valid response, not an error.
$page3 = $service->incrementalSync('chwk', $page2['cursor']);
assertTrue(empty($page3['changes']), 'no-op sync (nothing changed) returns empty changes, not an error');
assertEquals(false, $page3['has_more'], 'has_more is false when there is genuinely nothing new');

// Isolation: a different parish's log is untouched by chwk's changes.
$page1_other = $service->incrementalSync('xyz-parish', null);
assertTrue(empty($page1_other['changes']), 'a different parish (xyz-parish) sees none of chwk\'s changes — tenant isolation holds at the sync layer too');

echo "\n=== Iteration 1.1 point 1: bootstrap cursor contract ===\n";

// Simulate: some changes already existed BEFORE this device's bootstrap ran.
$repo2 = new FakeSyncChangeLogRepository();
$service2 = new SyncService($repo2);
$repo2->append('xyz', new SyncChange('event', 'pre1', 'create', 1, new DateTimeImmutable(), ['id' => 'pre1']));
$repo2->append('xyz', new SyncChange('event', 'pre2', 'create', 1, new DateTimeImmutable(), ['id' => 'pre2']));

$bootstrapCursor = $service2->bootstrapCursor('xyz');
assertTrue($bootstrapCursor !== null && $bootstrapCursor !== '', 'bootstrapCursor() returns a real, non-null/non-empty value — THE Iteration 1.1 point 1 bug');

// A change happens AFTER the bootstrap snapshot was taken.
$repo2->append('xyz', new SyncChange('event', 'post1', 'create', 1, new DateTimeImmutable(), ['id' => 'post1']));

$firstRealSync = $service2->incrementalSync('xyz', $bootstrapCursor);
assertEquals(1, count($firstRealSync['changes']['event']), 'the first /mobile/sync?cursor=<bootstrap cursor> returns ONLY the post-bootstrap change, not pre1/pre2 again');
assertEquals('post1', $firstRealSync['changes']['event'][0]['id'], 'the one change returned is exactly the post-bootstrap one');

echo "\n=== Iteration 1.1 point 2: real has_more / pagination ===\n";

// A parish with more changes than fit in one page.
$repo3 = new FakeSyncChangeLogRepository();
$service3 = new SyncService($repo3);
foreach (range(1, 5) as $i) {
    $repo3->append('big-parish', new SyncChange('event', "e$i", 'create', 1, new DateTimeImmutable(), ['id' => "e$i"]));
}

// Simulate a small page size by calling the repository directly with limit=2
// (SyncService.incrementalSync doesn't take a limit param itself — it
// delegates to the repository's default; this proves the REPOSITORY's
// hasMore semantics are correct, which is what SyncService then just
// passes through unchanged).
$firstSmallPage = $repo3->changesSince('big-parish', null, limit: 2);
assertEquals(2, count($firstSmallPage['changes']), 'first small page returns exactly 2 of 5 changes');
assertTrue($firstSmallPage['hasMore'], 'hasMore is TRUE after a full page when 3 more rows genuinely remain — the exact case count($changes)>0 got right by accident but for the wrong reason');

$secondSmallPage = $repo3->changesSince('big-parish', $firstSmallPage['nextCursor'], limit: 2);
assertEquals(2, count($secondSmallPage['changes']), 'second small page returns the next 2');
assertTrue($secondSmallPage['hasMore'], 'hasMore is still TRUE — 1 row remains');

$thirdSmallPage = $repo3->changesSince('big-parish', $secondSmallPage['nextCursor'], limit: 2);
assertEquals(1, count($thirdSmallPage['changes']), 'third page returns the final 1 change (a non-empty page)');
assertEquals(false, $thirdSmallPage['hasMore'], 'hasMore is FALSE on the last page even though changes is non-empty — THE Iteration 1.1 point 2 bug (old code: count($changes)>0 would have wrongly said true here)');

echo "\nAll SyncService tests passed (tombstones + incremental paging + tenant isolation + bootstrap cursor + real has_more).\n";
