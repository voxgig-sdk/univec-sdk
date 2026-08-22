
import {
  Content,
  File,
  Folder,
  cmp,
  collectDeps,
  pkgDescription,
  repoInfo,
  packageVersion,
} from '@voxgig/sdkgen'


import type {
  Model,
} from '@voxgig/apidef'


// Emits the two MSBuild project files (the C# twin of Package_go's go.mod):
//   <Name>SDK.csproj       - the library, compiling everything except test/
//   test/<Name>SDKTest.csproj - the xunit test project (mirrors the
//                            voxgig/struct csharp two-csproj layout)
// PackageReference entries come from collectDeps (feature + target deps);
// the runtime itself is BCL-only.
const Package = cmp(async function Package(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const Name = model.const.Name
  const { repoUrl } = repoInfo(model)

  const deps: Record<string, string> = {}
  for (const d of collectDeps(model, target.name, target.deps, ctx$.log)) {
    deps[d.name] = d.source === 'target' ? (d.version || '0.0.0') : d.version
  }

  const depRefs = Object.entries(deps)
    .map(([name, version]) =>
      `    <PackageReference Include="${name}" Version="${version}" />`)
    .join('\n')
  const depGroup = depRefs
    ? `  <ItemGroup>\n${depRefs}\n  </ItemGroup>\n`
    : ''

  File({ name: Name + 'SDK.csproj' }, () => {
    Content(`<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <LangVersion>12</LangVersion>
    <AssemblyName>${Name}SDK</AssemblyName>
    <RootNamespace>${Name}Sdk</RootNamespace>
    <!-- Loose-object-model port: suppress repetitive nullability noise. -->
    <NoWarn>$(NoWarn);CS8600;CS8601;CS8602;CS8603;CS8604;CS8618;CS8625;CS1591</NoWarn>

    <!-- NuGet package metadata (publication pending; see Makefile). -->
    <Version>${packageVersion(model, target.name)}</Version>
    <PackageId>${Name}.Sdk</PackageId>
    <Authors>Voxgig</Authors>
    <Description>${pkgDescription(model, target.name)}</Description>
    <PackageLicenseExpression>MIT</PackageLicenseExpression>
    <RepositoryUrl>${repoUrl}</RepositoryUrl>
  </PropertyGroup>
  <ItemGroup>
    <Compile Remove="test/**" />
  </ItemGroup>
${depGroup}</Project>
`)
  })

  Folder({ name: 'test' }, () => {
    File({ name: Name + 'SDKTest.csproj' }, () => {
      Content(`<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <LangVersion>12</LangVersion>
    <IsPackable>false</IsPackable>
    <NoWarn>$(NoWarn);CS8600;CS8601;CS8602;CS8603;CS8604;CS8618;CS8625;xUnit1004</NoWarn>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk"    Version="17.8.0" />
    <PackageReference Include="xunit"                     Version="2.6.6" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.5.6" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="../${Name}SDK.csproj" />
  </ItemGroup>
</Project>
`)
    })
  })
})


export {
  Package
}
