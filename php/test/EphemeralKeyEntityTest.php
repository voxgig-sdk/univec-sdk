<?php
declare(strict_types=1);

// EphemeralKey entity test

require_once __DIR__ . '/../univec_sdk.php';
require_once __DIR__ . '/Runner.php';

use PHPUnit\Framework\TestCase;
use Voxgig\Struct\Struct as Vs;

class EphemeralKeyEntityTest extends TestCase
{
    public function test_create_instance(): void
    {
        $testsdk = UnivecSDK::test(null, null);
        $ent = $testsdk->EphemeralKey(null);
        $this->assertNotNull($ent);
    }

    public function test_basic_flow(): void
    {
        $setup = ephemeral_key_basic_setup(null);
        // Per-op sdk-test-control.json skip.
        $_live = !empty($setup["live"]);
        foreach (["create"] as $_op) {
            [$_shouldSkip, $_reason] = Runner::is_control_skipped("entityOp", "ephemeral_key." . $_op, $_live ? "live" : "unit");
            if ($_shouldSkip) {
                $this->markTestSkipped($_reason ?? "skipped via sdk-test-control.json");
                return;
            }
        }
        // The basic flow consumes synthetic IDs from the fixture. In live mode
        // without an *_ENTID env override, those IDs hit the live API and 4xx.
        if (!empty($setup["synthetic_only"])) {
            $this->markTestSkipped("live entity test uses synthetic IDs from fixture — set UNIVEC_TEST_EPHEMERAL_KEY_ENTID JSON to run live");
            return;
        }
        $client = $setup["client"];

        // CREATE
        $ephemeral_key_ref01_ent = $client->EphemeralKey(null);
        $ephemeral_key_ref01_data = Helpers::to_map(Vs::getprop(
            Vs::getpath($setup["data"], "new.ephemeral_key"), "ephemeral_key_ref01"));

        $ephemeral_key_ref01_data_result = $ephemeral_key_ref01_ent->create($ephemeral_key_ref01_data, null);
        $ephemeral_key_ref01_data = Helpers::to_map($ephemeral_key_ref01_data_result);
        $this->assertNotNull($ephemeral_key_ref01_data);

    }
}

function ephemeral_key_basic_setup($extra)
{
    Runner::load_env_local();

    $entity_data_file = __DIR__ . '/../../.sdk/test/entity/ephemeral_key/EphemeralKeyTestData.json';
    $entity_data_source = file_get_contents($entity_data_file);
    $entity_data = json_decode($entity_data_source, true);

    $options = [];
    $options["entity"] = $entity_data["existing"];

    $client = UnivecSDK::test($options, $extra);

    // Generate idmap.
    $idmap = [];
    foreach (["ephemeral_key01", "ephemeral_key02", "ephemeral_key03"] as $k) {
        $idmap[$k] = strtoupper($k);
    }

    // Detect ENTID env override before envOverride consumes it. When live
    // mode is on without a real override, the basic test runs against synthetic
    // IDs from the fixture and 4xx's. Surface this so the test can skip.
    $entid_env_raw = getenv("UNIVEC_TEST_EPHEMERAL_KEY_ENTID");
    $idmap_overridden = $entid_env_raw !== false && str_starts_with(trim($entid_env_raw), "{");

    $env = Runner::env_override([
        "UNIVEC_TEST_EPHEMERAL_KEY_ENTID" => $idmap,
        "UNIVEC_TEST_LIVE" => "FALSE",
        "UNIVEC_TEST_EXPLAIN" => "FALSE",
        "UNIVEC_APIKEY" => "NONE",
    ]);

    $idmap_resolved = Helpers::to_map(
        $env["UNIVEC_TEST_EPHEMERAL_KEY_ENTID"]);
    if ($idmap_resolved === null) {
        $idmap_resolved = Helpers::to_map($idmap);
    }

    if ($env["UNIVEC_TEST_LIVE"] === "TRUE") {
        $merged_opts = Vs::merge([
            [
                "apikey" => $env["UNIVEC_APIKEY"],
            ],
            $extra ?? [],
        ]);
        $client = new UnivecSDK(Helpers::to_map($merged_opts));
    }

    $live = $env["UNIVEC_TEST_LIVE"] === "TRUE";
    return [
        "client" => $client,
        "data" => $entity_data,
        "idmap" => $idmap_resolved,
        "env" => $env,
        "explain" => $env["UNIVEC_TEST_EXPLAIN"] === "TRUE",
        "live" => $live,
        "synthetic_only" => $live && !$idmap_overridden,
        "now" => (int)(microtime(true) * 1000),
    ];
}
