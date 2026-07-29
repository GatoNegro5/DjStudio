allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// ARQUITECTURA SANEADA: Interceptor de Namespaces Legacy para AGP 8+
subprojects {
    // 1. Inyectamos el hook ESTRICTAMENTE ANTES de forzar la evaluación
    afterEvaluate {
        val androidExt = extensions.findByName("android")
        if (androidExt != null) {
            try {
                val namespaceProp = androidExt.javaClass.getMethod("getNamespace").invoke(androidExt)
                if (namespaceProp == null) {
                    val fallbackNamespace = if (project.group.toString().isNotBlank()) {
                        project.group.toString()
                    } else {
                        "com.plugin.${project.name.replace("[^a-zA-Z0-9_]".toRegex(), "_")}"
                    }
                    androidExt.javaClass.getMethod("setNamespace", String::class.java).invoke(androidExt, fallbackNamespace)
                }
            } catch (e: Exception) {
                // Silencioso. Evita colapsar si el módulo no expone la API nativa.
            }
        }
    }
    
    // 2. La dependencia de ejecución va al final, disparando el hook superior
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}