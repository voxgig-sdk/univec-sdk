<?php
declare(strict_types=1);

// Univec SDK utility: transform_request

require_once __DIR__ . '/../core/Helpers.php';
require_once __DIR__ . '/Param.php';

class UnivecTransformRequest
{
    public static function call(UnivecContext $ctx): mixed
    {
        $spec = $ctx->spec;
        $point = $ctx->point;
        if ($spec) {
            $spec->step = 'reqform';
        }
        $data = self::omit($ctx->reqdata, self::routed_arg_names($ctx));
        $transform = UnivecHelpers::to_map(\Voxgig\Struct\Struct::getprop($point, 'transform'));
        if (!$transform) {
            return self::strip_action($data);
        }
        $reqform = \Voxgig\Struct\Struct::getprop($transform, 'req');
        if (!$reqform) {
            return self::strip_action($data);
        }
        return self::strip_action(\Voxgig\Struct\Struct::transform(['reqdata' => $data], $reqform));
    }

    // `$action` selects the point (see MakePoint); it is never an API field,
    // so the body is a copy without it. Arrays are values, so the unset
    // never reaches the caller's copy.
    private static function strip_action(mixed $reqdata): mixed
    {
        return self::omit($reqdata, ['$action']);
    }

    // A header, cookie or query argument travels where PrepareHeaders or
    // PrepareQuery sends it, so the body is built from the request data
    // without it, unless the point marks it as a field the body keeps.
    private static function routed_arg_names(UnivecContext $ctx): array
    {
        $args = array_merge(UnivecParam::callArgs($ctx, 'header'),
            UnivecParam::callArgs($ctx, 'cookie'), UnivecParam::callArgs($ctx, 'query'));
        return array_values(array_filter(array_map(fn($arg) => $arg[0], $args),
            fn($name) => !self::field_arg($ctx, $name)));
    }

    private static function field_arg(UnivecContext $ctx, string $name): bool
    {
        foreach (['header', 'cookie', 'query'] as $kind) {
            $defs = $ctx->point ? \Voxgig\Struct\Struct::getpath($ctx->point, 'args.' . $kind) : null;
            foreach (is_array($defs) ? $defs : [] as $ad) {
                if ($name === \Voxgig\Struct\Struct::getprop($ad, 'name') &&
                    true === \Voxgig\Struct\Struct::getprop($ad, 'field')) {
                    return true;
                }
            }
        }
        return false;
    }

    private static function omit(mixed $reqdata, array $names): mixed
    {
        if (!is_array($reqdata)) {
            return $reqdata;
        }
        foreach ($names as $name) {
            unset($reqdata[$name]);
        }
        return $reqdata;
    }
}
