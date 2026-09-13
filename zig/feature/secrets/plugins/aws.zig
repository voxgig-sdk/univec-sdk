// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/plugins/aws.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! AWS Secrets Manager and SSM Parameter Store - one sekreto plugin,
//! two kinds: `awssecrets` and `awsparams`.
//!
//! Requests are SigV4-signed in-tree (sigv4.zig, beside this file): the
//! HMAC-SHA256 that needs lives here and not in the core, so a chain
//! that never names AWS never links a hash function.

const std = @import("std");

const sekreto = @import("sekreto");
const httpjson = @import("httpjson.zig");
const sigv4 = @import("sigv4.zig");

const Allocator = std.mem.Allocator;
const Answer = sekreto.Answer;
const Found = sekreto.Found;
const Provider = sekreto.Provider;
const ProviderSpec = sekreto.ProviderSpec;

/// Region and credentials, from config first and the standard AWS_*
/// environment variables second. Missing either is an error: an AWS store
/// with no credentials could not answer.
const AwsAuth = struct {
    region: []const u8,
    keyid: []const u8,
    secret: []const u8,
    session: []const u8,
};

/// The common half of both AWS providers.
const Aws = struct {
    config: sekreto.Config,
    region: []const u8,
    keyid: []const u8,
    secret: []const u8,
    session: []const u8,
    addr: []const u8,
    prefix: []const u8,

    fn auth(self: Aws, alloc: Allocator) Allocator.Error!Answer(AwsAuth) {
        const region = httpjson.firstof(self.config, self.region, &.{ "AWS_REGION", "AWS_DEFAULT_REGION" });
        const keyid = httpjson.firstof(self.config, self.keyid, &.{"AWS_ACCESS_KEY_ID"});
        const secret = httpjson.firstof(self.config, self.secret, &.{"AWS_SECRET_ACCESS_KEY"});
        const session = httpjson.firstof(self.config, self.session, &.{"AWS_SESSION_TOKEN"});

        if (0 == region.len) {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: aws: no region (set region or AWS_REGION)",
                .{},
            ) };
        }

        if (0 == keyid.len or 0 == secret.len) {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: aws: no credentials (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)",
                .{},
            ) };
        }

        return .{ .ok = .{ .region = region, .keyid = keyid, .secret = secret, .session = session } };
    }

    /// One signed call to an AWS JSON-1.1 API.
    fn call(
        self: Aws,
        alloc: Allocator,
        service: []const u8,
        target: []const u8,
        payload: []const u8,
    ) Allocator.Error!httpjson.Result {
        const credentials = switch (try self.auth(alloc)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        // The China partition lives under its own suffix; every other
        // commercial region is plain amazonaws.com.
        const suffix: []const u8 = if (std.mem.startsWith(u8, credentials.region, "cn-"))
            ".amazonaws.com.cn"
        else
            ".amazonaws.com";

        const addr = if (0 != self.addr.len)
            self.addr
        else
            try std.fmt.allocPrint(alloc, "https://{s}.{s}{s}", .{ service, credentials.region, suffix });

        switch (try sekreto.checkaddr(alloc, addr)) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        const url = try std.fmt.allocPrint(alloc, "{s}/", .{httpjson.trimslash(addr)});

        const unsigned = [_]sigv4.Pair{
            .{ .name = "content-type", .value = "application/x-amz-json-1.1" },
            .{ .name = "x-amz-target", .value = target },
        };

        const signed = try sigv4.sign(alloc, .{
            .method = "POST",
            .url = url,
            .headers = &unsigned,
            .body = payload,
            .service = service,
            .region = credentials.region,
            .keyid = credentials.keyid,
            .secret = credentials.secret,
            .session = credentials.session,
            .datetime = try awsnow(alloc, self.config.io),
        });

        var headers: std.ArrayList(httpjson.Header) = .empty;
        for (unsigned) |header| {
            try headers.append(alloc, .{ .name = header.name, .value = header.value });
        }
        for (signed) |header| {
            try headers.append(alloc, .{ .name = header.name, .value = header.value });
        }

        return httpjson.fetchjson(alloc, self.config.io, .POST, url, headers.items, payload);
    }
};

/// The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now.
fn awsnow(alloc: Allocator, io: std.Io) Allocator.Error![]const u8 {
    const seconds: u64 = @intCast(@divTrunc(httpjson.nowms(io), 1000));

    const day = std.time.epoch.EpochSeconds{ .secs = seconds };
    const yearday = day.getEpochDay().calculateYearDay();
    const monthday = yearday.calculateMonthDay();
    const clock = day.getDaySeconds();

    return std.fmt.allocPrint(alloc, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        yearday.year,
        monthday.month.numeric(),
        monthday.day_index + 1,
        clock.getHoursIntoDay(),
        clock.getMinutesIntoHour(),
        clock.getSecondsIntoMinute(),
    });
}

/// Does this AWS error body name one of the not-found types? Those are a
/// miss; every other failure is a store that could not answer.
fn awsmiss(body: ?std.json.Value, want: []const u8) bool {
    const errtype = httpjson.jstr(httpjson.jget(body, "__type")) orelse return false;
    return null != std.mem.indexOf(u8, errtype, want);
}

/// AWS Secrets Manager.
///
/// `api.token` reads the secret named `api` (the vaultref path, so
/// `db.pass.main` reads `db/pass`) and takes the `token` field of its JSON
/// SecretString - the AWS idiom of one JSON map per secret. A SecretString
/// that is not JSON is the value itself, under the conventional field
/// `value`. Requests are SigV4-signed in-tree; see sigv4.zig.
pub const AwsSecretsProvider = struct {
    aws: Aws,

    pub fn lookup(self: *AwsSecretsProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        const ref = switch (try sekreto.vaultref(alloc, name)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        const payload = try httpjson.jsonobject(alloc, &.{.{ .key = "SecretId", .value = ref.path }});

        const res = switch (try self.aws.call(alloc, "secretsmanager", "secretsmanager.GetSecretValue", payload)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        if (400 == res.status and awsmiss(res.body, "ResourceNotFoundException")) {
            return .{ .ok = null };
        }

        if (200 != res.status) {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: aws secretsmanager error: {d}",
                .{res.status},
            ) };
        }

        const text = httpjson.jstr(httpjson.jget(res.body, "SecretString")) orelse {
            // A binary secret has no fields to address; only the
            // conventional `value` field can mean "the bytes themselves".
            const binary = httpjson.jstr(httpjson.jget(res.body, "SecretBinary")) orelse return .{ .ok = null };
            if (!std.mem.eql(u8, "value", ref.field)) {
                return .{ .ok = null };
            }
            // A payload that will not decode was reported as null - a
            // MISS - so the chain carried on to a weaker store. A store
            // that answered incoherently could not answer.
            return .{ .ok = try sekreto.unbase64(alloc, binary) orelse
                return .{ .err = try sekreto.fail(alloc, "sekreto: aws secretsmanager: undecodable secret", .{}) } };
        };

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch {
            // A plain-string secret is the whole value; it has no named
            // fields.
            return .{ .ok = if (std.mem.eql(u8, "value", ref.field)) text else null };
        };

        if (.object == parsed.value) {
            return .{ .ok = httpjson.jstr(httpjson.jget(parsed.value, ref.field)) };
        }

        return .{ .ok = if (std.mem.eql(u8, "value", ref.field)) text else null };
    }

    pub fn describe(self: *AwsSecretsProvider, alloc: Allocator) Allocator.Error![]const u8 {
        // sekreto.Config only, never the environment: describe() feeds the spec's
        // sources group, which must answer the same everywhere.
        return std.fmt.allocPrint(alloc, "awssecrets:{s}", .{self.aws.region});
    }

    pub fn deinit(_: *AwsSecretsProvider, _: Allocator) void {}
};

/// AWS SSM Parameter Store.
///
/// `db.pass.main` reads the parameter `/db/pass/main` (under an optional
/// prefix path), decrypted. Parameter Store carries flat strings, so there
/// is no field indirection.
pub const AwsParamsProvider = struct {
    aws: Aws,

    pub fn lookup(self: *AwsParamsProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        const param = switch (try sekreto.awsparam(alloc, name, self.aws.prefix)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        const payload = try std.fmt.allocPrint(
            alloc,
            "{{\"Name\":{s},\"WithDecryption\":true}}",
            .{try httpjson.jsonstring(alloc, param)},
        );

        const res = switch (try self.aws.call(alloc, "ssm", "AmazonSSM.GetParameter", payload)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        if (400 == res.status and awsmiss(res.body, "ParameterNotFound")) {
            return .{ .ok = null };
        }

        if (200 != res.status) {
            return .{ .err = try sekreto.fail(alloc, "sekreto: aws ssm error: {d}", .{res.status}) };
        }

        return .{ .ok = httpjson.jstr(httpjson.jget(httpjson.jget(res.body, "Parameter"), "Value")) };
    }

    pub fn describe(self: *AwsParamsProvider, alloc: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(alloc, "awsparams:{s}{s}", .{ self.aws.region, self.aws.prefix });
    }

    pub fn deinit(_: *AwsParamsProvider, _: Allocator) void {}
};

fn awsof(config: sekreto.Config, spec: ProviderSpec) Aws {
    return .{
        .config = config,
        .region = spec.region,
        .keyid = spec.keyid,
        .secret = spec.secret,
        .session = spec.session,
        .addr = spec.addr,
        .prefix = spec.prefix,
    };
}

fn makesecrets(alloc: Allocator, config: sekreto.Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    return .{ .ok = try sekreto.provide(alloc, AwsSecretsProvider, .{ .aws = awsof(config, spec) }) };
}

fn makeparams(alloc: Allocator, config: sekreto.Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    return .{ .ok = try sekreto.provide(alloc, AwsParamsProvider, .{ .aws = awsof(config, spec) }) };
}

/// The `awssecrets` kind.
pub const awssecrets: sekreto.Definition = sekreto.providerplugin("awssecrets", makesecrets);

/// The `awsparams` kind.
pub const awsparams: sekreto.Definition = sekreto.providerplugin("awsparams", makeparams);
