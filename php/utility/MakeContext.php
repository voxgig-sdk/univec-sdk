<?php
declare(strict_types=1);

// Univec SDK utility: make_context

require_once __DIR__ . '/../core/Context.php';

class UnivecMakeContext
{
    public static function call(array $ctxmap, ?UnivecContext $basectx): UnivecContext
    {
        return new UnivecContext($ctxmap, $basectx);
    }
}
