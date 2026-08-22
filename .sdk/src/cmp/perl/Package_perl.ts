
import {
  Content,
  File,
  cmp,
  collectDeps,
  pkgDescription,
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
    MIN_PERL_VERSION => '5.018',
${prereq ? `    PREREQ_PM        => {\n${prereq}\n    },\n` : ''});
`)
  })
})


export {
  Package
}
