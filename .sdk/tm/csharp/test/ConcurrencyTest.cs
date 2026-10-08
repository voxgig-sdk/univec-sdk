// Requests in flight at once on one client. Each resolves its operation
// through the cache the client's root context shares with every request, and
// registers and cleans secrets through the one registry the client holds.

using System.Collections.Concurrent;

using Xunit;

using UnivecSdk;

namespace UnivecSdk.Test;

public class ConcurrencyTest
{
    private const int Rounds = 200;
    private const int Width = 8;
    private const int Ops = 32;

    private static Dictionary<string, object?> Answer(string url, Dictionary<string, object?> fetchdef)
    {
        return new Dictionary<string, object?>
        {
            ["status"] = 200,
            ["statusText"] = "OK",
            ["headers"] = new Dictionary<string, object?>(),
            ["json"] = (Func<object?>)(() => new Dictionary<string, object?> { ["ok"] = true }),
        };
    }

    // A live client whose transport answers at once.
    private static UnivecSDK LiveClient()
    {
        return new UnivecSDK(new Dictionary<string, object?>
        {
            ["base"] = "http://concurrency.test/api",
            ["allow"] = new Dictionary<string, object?> { ["op"] = "direct" },
            ["system"] = new Dictionary<string, object?>
            {
                ["fetch"] = (Func<string, Dictionary<string, object?>,
                    Dictionary<string, object?>>)Answer,
            },
        });
    }

    // Runs body on Width threads released together, and returns what they threw.
    private static List<Exception> AtOnce(Action<int> body)
    {
        var start = new Barrier(Width);
        var thrown = new ConcurrentQueue<Exception>();
        var threads = new List<Thread>();
        for (var i = 0; i < Width; i++)
        {
            var n = i;
            var thread = new Thread(() =>
            {
                try
                {
                    start.SignalAndWait();
                    body(n);
                }
                catch (Exception e)
                {
                    thrown.Enqueue(e);
                }
            });
            thread.Start();
            threads.Add(thread);
        }
        threads.ForEach(t => t.Join());
        return thrown.ToList();
    }

    [Fact]
    public void ConcurrentFirstRequestsSucceed()
    {
        for (var round = 0; round < Rounds; round++)
        {
            // A fresh client each round, so every request in it is a first request.
            var client = LiveClient();
            var results = new Dictionary<string, object?>?[Width];
            var thrown = AtOnce(n =>
                results[n] = client.Direct(new Dictionary<string, object?> { ["path"] = "p" + n }));

            Assert.True(0 == thrown.Count, "round " + round + " threw:\n" + string.Join("\n", thrown));
            for (var n = 0; n < Width; n++)
            {
                var res = results[n];
                Assert.True(Equals(true, res?["ok"]), "round " + round + ", request " + n +
                    " failed: " + (res?.GetValueOrDefault("err") ?? "no result"));
            }
        }
    }

    [Fact]
    public void ConcurrentResolutionsShareOneCachedOperation()
    {
        for (var round = 0; round < Rounds; round++)
        {
            var client = LiveClient();
            var utility = client.GetUtility();
            var root = client.GetRootCtx();
            var ops = new Operation?[Width, Ops];
            var thrown = AtOnce(n =>
            {
                for (var k = 0; k < Ops; k++)
                {
                    ops[n, k] = utility.MakeContext(
                        new Dictionary<string, object?> { ["opname"] = "op" + k }, root).Op;
                }
            });

            Assert.True(0 == thrown.Count, "round " + round + " threw:\n" + string.Join("\n", thrown));
            for (var k = 0; k < Ops; k++)
            {
                var cached = utility.MakeContext(
                    new Dictionary<string, object?> { ["opname"] = "op" + k }, root).Op;
                for (var n = 0; n < Width; n++)
                {
                    Assert.True(ReferenceEquals(cached, ops[n, k]),
                        "round " + round + ": op" + k + " resolved to more than one Operation");
                }
            }
        }
    }

    private static string AddedSecret(int round, int n, int k)
    {
        return "ADDED-SECRET-" + round + "-" + n + "-" + k;
    }

    // Registers thread n's secrets, then counts the thread out of registering.
    private static void RegisterSecrets(Utility utility, Context root, int round, int n,
        CountdownEvent registering)
    {
        try
        {
            for (var k = 0; k < Ops; k++)
            {
                utility.CleanAdd(root, AddedSecret(round, n, k));
            }
        }
        finally
        {
            registering.Signal();
        }
    }

    private static void AssertEverySecretMasked(Utility utility, Context root, int round)
    {
        for (var n = 0; n < Width / 2; n++)
        {
            for (var k = 0; k < Ops; k++)
            {
                var added = AddedSecret(round, n, k);
                Assert.True("[redacted]" == utility.Clean(root, added) as string,
                    "round " + round + ": " + added + " was registered but not masked");
            }
        }
    }

    // Secrets registered on some threads while others clean: every clean
    // masks what was registered before it, the longer secret whole, and no
    // registration is lost.
    [Fact]
    public void ConcurrentRegistrationKeepsEverySecretMasked()
    {
        for (var round = 0; round < Rounds / 4; round++)
        {
            var client = LiveClient();
            var utility = client.GetUtility();
            var root = client.GetRootCtx();
            var inner = "INNER-SECRET-" + round;
            utility.CleanAdd(root, inner);
            utility.CleanAdd(root, "OUTER-" + inner + "-TAIL");
            var text = "a " + inner + " b OUTER-" + inner + "-TAIL c";
            Assert.Equal("a [redacted] b [redacted] c", utility.Clean(root, text));

            var registering = new CountdownEvent(Width / 2);
            var wrong = new ConcurrentQueue<string>();
            var thrown = AtOnce(n =>
            {
                if (n < Width / 2)
                {
                    RegisterSecrets(utility, root, round, n, registering);
                    return;
                }
                while (!registering.IsSet)
                {
                    var got = utility.Clean(root, text) as string;
                    if ("a [redacted] b [redacted] c" != got)
                    {
                        wrong.Enqueue(got ?? "null");
                    }
                }
            });

            Assert.True(0 == thrown.Count, "round " + round + " threw:\n" + string.Join("\n", thrown));
            Assert.True(wrong.IsEmpty, "round " + round + " cleaned to: " + string.Join(" | ", wrong));
            AssertEverySecretMasked(utility, root, round);
        }
    }

    // Requests on one client while secrets register on it: each request
    // copies the client's options, the registry among them.
    [Fact]
    public void ConcurrentRequestsSurviveRegistration()
    {
        for (var round = 0; round < Rounds / 4; round++)
        {
            var client = LiveClient();
            var utility = client.GetUtility();
            var root = client.GetRootCtx();
            var registering = new CountdownEvent(Width / 2);
            var failed = new ConcurrentQueue<string>();
            var thrown = AtOnce(n =>
            {
                if (n < Width / 2)
                {
                    RegisterSecrets(utility, root, round, n, registering);
                    return;
                }
                while (!registering.IsSet)
                {
                    var res = client.Direct(new Dictionary<string, object?> { ["path"] = "p" + n });
                    if (!Equals(true, res.GetValueOrDefault("ok")))
                    {
                        failed.Enqueue(Convert.ToString(res.GetValueOrDefault("err")) ?? "no error");
                        return;
                    }
                }
            });

            Assert.True(0 == thrown.Count, "round " + round + " threw:\n" + string.Join("\n", thrown));
            Assert.True(failed.IsEmpty, "round " + round + ", a request failed: " + string.Join(" | ", failed));
            AssertEverySecretMasked(utility, root, round);
        }
    }
}
