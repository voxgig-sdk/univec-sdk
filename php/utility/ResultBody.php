<?php
declare(strict_types=1);

// Univec SDK utility: result_body

class UnivecResultBody
{
    public static function call(UnivecContext $ctx): ?UnivecResult
    {
        $response = $ctx->response;
        $result = $ctx->result;
        if ($result && $response && $response->json_func && $response->body) {
            $result->body = ($response->json_func)();
        }
        return $result;
    }
}
