<?php
declare(strict_types=1);

// Univec SDK utility: prepare_body

class UnivecPrepareBody
{
    public static function call(UnivecContext $ctx): mixed
    {
        if ($ctx->op->input === 'data') {
            return ($ctx->utility->transform_request)($ctx);
        }
        return null;
    }
}
