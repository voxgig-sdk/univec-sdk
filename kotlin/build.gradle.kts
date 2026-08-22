plugins {
    kotlin("jvm") version "2.2.0"
}

group = "com.voxgig"
version = "0.1.1"

repositories {
    mavenCentral()
}

dependencies {
    testImplementation(kotlin("test"))
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
