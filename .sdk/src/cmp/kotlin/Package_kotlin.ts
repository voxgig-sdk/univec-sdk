
import {
  Content,
  File,
  cmp,
  collectDeps,
  packageVersion,
} from '@voxgig/sdkgen'


import type {
  Model,
} from '@voxgig/apidef'


import { gradleGroup } from './utility_kotlin'


// Generates the Gradle build files (build.gradle.kts + settings.gradle.kts),
// the kotlin analog of go.mod. Runtime dependencies come from collectDeps (the
// kotlin target ships none by default — struct is vendored and JSON/HTTP are
// JVM/JDK built-ins); JUnit + kotlin-test are the only test-scope deps.
const Package = cmp(async function Package(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const group = gradleGroup(model)
  const artifactId = `${model.name}-sdk`

  // Dep name convention: "group:artifact" with an explicit version.
  const deps: { group: string, artifact: string, version: string, kind: string }[] = []
  for (const d of collectDeps(model, target.name, target.deps, ctx$.log)) {
    const [dgroup, dartifact] = String(d.name).split(':')
    if (dgroup && dartifact && d.version) {
      deps.push({
        group: dgroup,
        artifact: dartifact,
        version: d.version,
        kind: d.raw?.kind || 'prod',
      })
    }
  }

  File({ name: 'settings.gradle.kts' }, () => {
    Content(`rootProject.name = "${artifactId}"
`)
  })

  File({ name: 'build.gradle.kts' }, () => {
    Content(`plugins {
    kotlin("jvm") version "2.2.0"
}

group = "${group}"
version = "${packageVersion(model, target.name)}"

repositories {
    mavenCentral()
}

dependencies {
`)

    for (const d of deps) {
      const conf = 'dev' === d.kind || 'test' === d.kind
        ? 'testImplementation' : 'implementation'
      Content(`    ${conf}("${d.group}:${d.artifact}:${d.version}")
`)
    }

    Content(`    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter-api:5.10.1")
    testRuntimeOnly("org.junit.jupiter:junit-jupiter-engine:5.10.1")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

// The runtime source keeps the same flat layout as the other statically-typed
// targets (core/, utility/, feature/, entity/), with tests in test/.
sourceSets["main"].kotlin.setSrcDirs(listOf("core", "utility", "feature", "entity"))
sourceSets["main"].java.setSrcDirs(emptyList<String>())
sourceSets["main"].resources.setSrcDirs(emptyList<String>())
sourceSets["test"].kotlin.setSrcDirs(listOf("test"))
sourceSets["test"].java.setSrcDirs(emptyList<String>())
sourceSets["test"].resources.setSrcDirs(emptyList<String>())

tasks.test {
    useJUnitPlatform()
}

// Keep the Java and Kotlin compile tasks on the same bytecode target (the
// empty compileJava task otherwise defaults to the JDK version and clashes).
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}
`)
  })
})


export {
  Package
}
