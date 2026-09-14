// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Definition.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;

namespace Voxgig.Plugin
{
    /// <summary>
    /// What a catalog registers: a name, an option shape, and the
    /// lifecycle callbacks (§10.1).
    ///
    /// <para>A DEFINITION IS DATA WITH FUNCTIONS IN IT, not a class to
    /// extend. A document could produce one, which is the property that
    /// makes a catalog a data structure rather than a compile-time
    /// registry - and an abstract base class would make every plugin a
    /// subclass of this library.</para>
    /// </summary>
    public sealed class Definition
    {
        /// A lifecycle callback. It THROWS on failure, as the canonical raises.
        public delegate void Callback(Inst inst);

        /// §9.4's cheap path: the host hands the new options and the old ones.
        public delegate void ReconfigureFn(Inst inst, object now, object previous);

        public readonly string Name;
        public object Shape;
        public Callback Define;
        public Callback Activate;
        public Callback Deactivate;
        public Callback Close;
        public ReconfigureFn Reconfigure;

        public Definition(string name)
        {
            Name = name;
        }

        /// The callback for a phase, by the name the log and the corpus use.
        public Callback CallbackFor(string at)
        {
            switch (at)
            {
                case "define": return Define;
                case "activate": return Activate;
                case "deactivate": return Deactivate;
                case "close": return Close;
                default: return null;
            }
        }
    }
}
