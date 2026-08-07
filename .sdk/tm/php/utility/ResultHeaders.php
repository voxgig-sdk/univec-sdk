<?php
declare(strict_types=1);

// Univec SDK utility: result_headers

class UnivecResultHeaders
{
    public static function call(UnivecContext $ctx): ?UnivecResult
    {
        $response = $ctx->response;
        $result = $ctx->result;
        if ($result) {
            if ($response && is_array($response->headers)) {
                $result->headers = $response->headers;
            } else {
                $result->headers = [];
            }
        }
        return $result;
    }
}
