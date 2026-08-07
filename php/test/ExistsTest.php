<?php
declare(strict_types=1);

// Univec SDK exists test

require_once __DIR__ . '/../univec_sdk.php';

use PHPUnit\Framework\TestCase;

class ExistsTest extends TestCase
{
    public function test_create_test_sdk(): void
    {
        $testsdk = UnivecSDK::test(null, null);
        $this->assertNotNull($testsdk);
    }
}
