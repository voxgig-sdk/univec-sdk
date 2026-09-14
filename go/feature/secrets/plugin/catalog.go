// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/catalog.go)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The definition catalog (§10.1).
 *
 * A definition is registered once and may back many instances. Option
 * shapes are validated AT REGISTRATION, not when a document happens to
 * exercise a key — so a malformed shape fails once, and in the same
 * place everywhere (§9.4). */

package plugin

// Definition is what a plugin author writes.
//
// GO RETURNS ERRORS FROM LIFECYCLE CALLBACKS (§18, P4). The canonical
// throws; a Go callback returns `error`, and the host treats a non-nil
// return exactly as the canonical treats a throw — including
// `plugin_activate_failed`'s unwind and the `failed` status.
type Definition struct {
	Name        string
	Shape       any
	Define      func(inst *Inst) error
	Activate    func(inst *Inst) error
	Deactivate  func(inst *Inst) error
	Close       func(inst *Inst) error
	Reconfigure func(inst *Inst, options map[string]any, previous map[string]any) error
}

type Catalog struct {
	defs map[string]Definition
}

// MakeCatalog builds a catalog, adding each definition in turn.
//
// GO IS TIER S (§10.3): "package `init()` registration ... or an
// explicit list handed to makeHost", and both spellings land here. A Go
// developer's experience is "add the import, add one line to the config"
// rather than "write a factory".
func MakeCatalog(defs ...Definition) (*Catalog, error) {
	c := &Catalog{defs: map[string]Definition{}}
	for _, d := range defs {
		if err := c.Add(d); nil != err {
			return nil, err
		}
	}
	return c, nil
}

func (c *Catalog) Add(def Definition) error {
	if !CheckName(def.Name) {
		return Fail("plugin_definition_name", "invalid definition name: "+def.Name, nil)
	}
	// Validate the shape HERE. Deferring it to resolution time means a
	// malformed shape surfaces at a different moment in every host that
	// loads it, which is the divergence the stated domain exists to
	// prevent.
	if nil != def.Shape {
		if err := CheckShape(def.Shape); nil != err {
			return err
		}
	}
	c.defs[def.Name] = def
	return nil
}

func (c *Catalog) Get(name string) (Definition, bool) {
	d, ok := c.defs[name]
	return d, ok
}

func (c *Catalog) Has(name string) bool {
	_, ok := c.defs[name]
	return ok
}

func (c *Catalog) Names() []string {
	return sortedkeys(c.defs)
}
