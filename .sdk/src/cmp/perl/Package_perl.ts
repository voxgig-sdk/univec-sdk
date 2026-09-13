
import {
  Content,
  File,
  cmp,
  collectDeps,
  pkgDescription,
  targetFeatures,
} from '@voxgig/sdkgen'


import type {
  Model,
} from '@voxgig/apidef'


// Perl package manifest: a minimal ExtUtils::MakeMaker Makefile.PL,
// mirroring the struct perl port. The SDK is pure-Perl with zero non-core
// runtime deps (HTTP::Tiny transport, vendored Voxgig::Struct), so the
// manifest carries metadata only; any model-declared deps become PREREQ_PM.
const Package = cmp(async function Package(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  // CPAN-style distribution name, namespaced to model.origin
  // (e.g. "Voxgig::SDK::Solar" -> dist voxgig-sdk-solar).
  const Name = model.const.Name

  // THE PERL FLOOR IS A FUNCTION OF THE FEATURE SET, not a constant.
  //
  // The base SDK is pure 5.018 perl. The secrets feature is not: the
  // vendored voxgig/plugin runtime it depends on opens with
  // `use builtin qw(is_bool)`, which is 5.36's and is the only way that
  // port can tell `true` from `1`. Shipping 5.018 in the manifest of an
  // SDK that cannot run on 5.018 installs cleanly and then dies at
  // require time, so the floor moves with the feature.
  const secrets = null != (targetFeatures(model, target) as any).secrets
  const minperl = secrets ? '5.036' : '5.018'

  const deps = collectDeps(model, target.name, target.deps, ctx$.log)
  const prereq = deps
    .map((d: any) => `        '${d.name}' => '${d.version || '0'}',`)
    .join('\n')

  File({ name: 'Makefile.PL' }, () => {
    Content(`use strict;
use warnings;
use ExtUtils::MakeMaker;

# CPAN distribution metadata for the ${Name} SDK.
#
# NOTE: \`perl Makefile.PL\` (run by ExtUtils::MakeMaker) GENERATES a file
# named \`Makefile\`, which would clobber this port's hand-written
# \`Makefile\`. Never run it in place - the \`publish\` target in the
# hand-written Makefile copies the dist sources into a throwaway
# \`.release/\` directory and builds there instead.

WriteMakefile(
    NAME             => '${Name}SDK',
    VERSION_FROM     => 'lib/${Name}SDK.pm',
    ABSTRACT         => '${pkgDescription(model, target.name)}',
    AUTHOR           => 'Voxgig',
    LICENSE          => 'mit',
    MIN_PERL_VERSION => '${minperl}',
${prereq ? `    PREREQ_PM        => {\n${prereq}\n    },\n` : ''});
`)
  })
})


export {
  Package
}
