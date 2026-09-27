// VENDORED: @voxgig/plugin sdk-20260925-1316-0 (rust/src/catalog.rs)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

use std::collections::BTreeMap;
use std::rc::Rc;

use super::config::check_shape;
use super::host::Inst;
use super::refs::check_name;
use super::types::{fail, PluginError};
use super::value::Value;

/// A lifecycle callback. It RETURNS its failure rather than raising one -
/// go's deliberate change (§18, P4), kept here for the same reason: the
/// corpus compares by code, which survives the change intact.
pub type Callback = Rc<dyn Fn(&Inst) -> Result<(), PluginError>>;

pub type Reconfigure = Rc<dyn Fn(&Inst, &Value, &Value) -> Result<(), PluginError>>;

#[derive(Clone)]
pub struct Definition {
    pub name: String,
    pub shape: Value,
    pub define: Option<Callback>,
    pub activate: Option<Callback>,
    pub deactivate: Option<Callback>,
    pub close: Option<Callback>,
    pub reconfigure: Option<Reconfigure>,
}

impl Definition {
    pub fn named(name: &str) -> Definition {
        Definition {
            name: name.to_string(),
            shape: Value::Null,
            define: None,
            activate: None,
            deactivate: None,
            close: None,
            reconfigure: None,
        }
    }

    /// The callback for a phase, by the name the log and the corpus use.
    pub fn callback(&self, at: &str) -> Option<Callback> {
        match at {
            "define" => self.define.clone(),
            "activate" => self.activate.clone(),
            "deactivate" => self.deactivate.clone(),
            "close" => self.close.clone(),
            _ => None,
        }
    }
}

#[derive(Clone, Default)]
pub struct Catalog {
    defs: BTreeMap<String, Rc<Definition>>,
}

impl Catalog {
    pub fn new() -> Catalog {
        Catalog {
            defs: BTreeMap::new(),
        }
    }

    pub fn add(&mut self, definition: Definition) -> Result<(), PluginError> {
        if !check_name(&Value::str(&definition.name)) {
            return fail(
                "plugin_definition_name",
                &format!("invalid definition name: {}", definition.name),
                Value::Null,
            );
        }
        // Validate the shape HERE. Deferring it to resolution time means a
        // malformed shape surfaces at a different moment in every host
        // that loads it, which is the divergence the stated domain exists
        // to prevent.
        check_shape(&definition.shape)?;
        self.defs
            .insert(definition.name.clone(), Rc::new(definition));
        Ok(())
    }

    pub fn get(&self, name: &str) -> Option<Rc<Definition>> {
        self.defs.get(name).cloned()
    }

    pub fn has(&self, name: &str) -> bool {
        self.defs.contains_key(name)
    }

    pub fn names(&self) -> Vec<String> {
        self.defs.keys().cloned().collect()
    }
}

pub fn make_catalog(definitions: Vec<Definition>) -> Result<Catalog, PluginError> {
    let mut catalog = Catalog::new();
    for d in definitions {
        catalog.add(d)?;
    }
    Ok(catalog)
}
