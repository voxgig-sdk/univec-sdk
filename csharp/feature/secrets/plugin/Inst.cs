// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Inst.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// <summary>
    /// What a definition's callbacks see.
    ///
    /// <para>Deliberately not the internal record: a plugin that could
    /// reach <c>status</c> could also write it.</para>
    /// </summary>
    public sealed class Inst
    {
        public readonly Host HostRef;
        public readonly string Ref;
        public readonly string Name;
        public readonly string Tag;

        private readonly Entry entry;

        internal Inst(Host host, Entry entry)
        {
            HostRef = host;
            this.entry = entry;
            Ref = entry.Ref;
            var parsed = Refs.ParseRef(entry.Ref);
            Name = Types.Str(parsed["name"]);
            Tag = Types.Str(parsed["tag"]);
        }

        /// <summary>
        /// The resolved options, READ FRESH. <c>Apply</c> and
        /// <c>Options</c> replace the map wholesale, so a callback that
        /// cached this at <c>define</c> would hold the values a later
        /// document already changed.
        /// </summary>
        public object Options()
        {
            return entry.Options;
        }

        /// The instance's own state (§5.4), LIVE.
        public SortedDictionary<string, object> State()
        {
            return entry.State;
        }

        /// <summary>
        /// Foreign resources the host did not hand out are registered
        /// explicitly (§8.3); host calls are recorded automatically.
        /// SYMMETRIC WITH <c>Acquire</c>, and it has to be: <c>open</c>
        /// counts the resources CURRENTLY HELD.
        /// </summary>
        public void Release(Entry.ScopeFn func)
        {
            // §8.3: "`inst.release` outside `activate` is
            // `plugin_release_scope`". A flag saying merely that a
            // transition is running is true in `define` too, and a scope
            // entry registered there is never unwound.
            if ("activate" != HostRef.Phase())
            {
                Types.Fail("plugin_release_scope", "release called outside activate", null);
            }
            var done = false;
            entry.Scope.Add(() =>
            {
                if (done)
                {
                    return;
                }
                done = true;
                HostRef.OpenDec();
                func();
            });
            HostRef.OpenInc();
        }

        /// <summary>
        /// The synthetic counter the driver owns, so "what is open" is
        /// data rather than an assertion each port words differently.
        /// Returns its own release, so a plugin can hand one back early;
        /// unwinding it twice is a no-op.
        /// </summary>
        public Entry.ScopeFn Acquire()
        {
            // §8.1: resources are "acquired during `activate` - the
            // scope's actual job". Same reason as `Release` above.
            if ("activate" != HostRef.Phase())
            {
                Types.Fail("plugin_release_scope", "acquire called outside activate", null);
            }
            var done = false;
            Entry.ScopeFn rel = () =>
            {
                if (done)
                {
                    return;
                }
                done = true;
                HostRef.OpenDec();
            };
            entry.Scope.Add(rel);
            HostRef.OpenInc();
            return rel;
        }

        /// <summary>
        /// Bind into a host point. Declared in <c>define</c>; the host
        /// inserts it only after <c>activate</c> returns successfully
        /// (§8.1), which is why a failing activate leaves no live binding
        /// behind.
        /// </summary>
        public void Bind(string point, Point.BindFn func, object band)
        {
            // §12 has carried `plugin_bind_scope` - "binding declared
            // outside `define`" - since before anything raised it. §8.1
            // puts binding DECLARATION in `define` and INSERTION at a
            // successful activate, and the guard was the half nobody
            // wrote.
            if ("define" != HostRef.Phase())
            {
                Types.Fail("plugin_bind_scope", "bind called outside define: " + point,
                           Types.Details("ref", Ref, "point", point));
            }
            if (!HostRef.HasPoint(point))
            {
                Types.Fail("plugin_point_unknown", "no such point: " + point,
                           Types.Details("point", point));
            }
            entry.Bindings.Add(new Point.Bound(Ref, point, func, Types.AsInt(band) ?? 0));
        }

        /// Published for other plugins and for the application (§11).
        public void Export(string key, object value)
        {
            entry.Exports[key] = value;
        }

        /// What this instance can do for others (§11.1).
        public void Provides(object prov)
        {
            entry.Provides.Add(prov);
        }

        /// <summary>
        /// Where this binding landed (§6.6) - the plugin-side counterpart
        /// to a host pin. THE HOST DOES NOT POLICE THIS; it just makes the
        /// fact available.
        /// </summary>
        public object Position(string point)
        {
            return HostRef.PositionOf(Ref, point);
        }

        /// <summary>
        /// AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE OWNS
        /// THE INNER ONE'S LIFETIME. Registering the teardown in the
        /// instance scope is what makes that true rather than
        /// aspirational.
        /// </summary>
        public Host Nest(object nestopts)
        {
            if (!HostRef.InTransition())
            {
                Types.Fail("plugin_release_scope",
                           "nest called outside a lifecycle callback", null);
            }
            var inner = new Host(nestopts);
            entry.Scope.Add(() => inner.Close());
            entry.Inner = inner;
            return inner;
        }
    }
}
