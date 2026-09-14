// The plugin definitions the model selected for the `secrets`
// feature, and the modules they live in (generated - see Main_rust).
//
// Upstream sekreto's contract since its registry was retired: a provider
// kind not handed to the constructor is unknown to that Sekreto. So this
// list IS the SDK's provider vocabulary, and a kind nobody selected is
// neither declared nor compiled.

use crate::feature::secrets::plugin::catalog::Definition;

pub mod httpjson;
pub mod boru;
pub mod hashicorp;

pub fn definitions() -> Vec<Definition> {
    vec![
        boru::plugin(),
        hashicorp::plugin(),
    ]
}
