// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/catalog.go)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package plugin

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
