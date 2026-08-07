<?php
declare(strict_types=1);

// Univec SDK feature factory

require_once __DIR__ . '/feature/BaseFeature.php';
require_once __DIR__ . '/feature/TestFeature.php';


class UnivecFeatures
{
    public static function make_feature(string $name)
    {
        switch ($name) {
            case "base":
                return new UnivecBaseFeature();
            case "test":
                return new UnivecTestFeature();
            default:
                return new UnivecBaseFeature();
        }
    }
}
