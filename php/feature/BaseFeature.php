<?php
declare(strict_types=1);

// Univec SDK base feature

class UnivecBaseFeature
{
    public string $version;
    public string $name;
    public bool $active;

    // Positions this feature when added via the client `extend` option:
    // "__before__" / "__after__" / "__replace__" name an already-added
    // feature (mirrors the ts feature `_options`). Declared so setting it
    // on an extension instance avoids the dynamic-property deprecation.
    public ?array $_options = null;

    public function __construct()
    {
        $this->version = '0.0.1';
        $this->name = 'base';
        $this->active = true;
    }

    public function get_version(): string { return $this->version; }
    public function get_name(): string { return $this->name; }
    public function get_active(): bool { return $this->active; }

    public function init(UnivecContext $ctx, array $options): void {}
    public function PostConstruct(UnivecContext $ctx): void {}
    public function PostConstructEntity(UnivecContext $ctx): void {}
    public function SetData(UnivecContext $ctx): void {}
    public function GetData(UnivecContext $ctx): void {}
    public function GetMatch(UnivecContext $ctx): void {}
    public function SetMatch(UnivecContext $ctx): void {}
    public function PrePoint(UnivecContext $ctx): void {}
    public function PreSpec(UnivecContext $ctx): void {}
    public function PreRequest(UnivecContext $ctx): void {}
    public function PreResponse(UnivecContext $ctx): void {}
    public function PreResult(UnivecContext $ctx): void {}
    public function PreDone(UnivecContext $ctx): void {}
    public function PreUnexpected(UnivecContext $ctx): void {}
}
