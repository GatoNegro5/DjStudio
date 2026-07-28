allprojects {
    repositories {
        google()
        mavenCentral()
    }
    
    // Inyección de Intercepción Global
    configurations.all {
        resolutionStrategy.eachDependency {
            if (requested.group == "com.arthenica" && requested.name == "ffmpeg-kit-min-gpl") {
                useVersion("6.0-1")
            }
        }
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
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
subprojects {
    fun applyNamespace() {
        val androidExtension = extensions.findByName("android")
        if (androidExtension != null) {
            try {
                val getNamespace = androidExtension.javaClass.getMethod("getNamespace")
                if (getNamespace.invoke(androidExtension) == null) {
                    val setNamespace = androidExtension.javaClass.getMethod("setNamespace", String::class.java)
                    setNamespace.invoke(androidExtension, project.group.toString())
                }
            } catch (e: Exception) {
                // Silenciamos excepciones de reflection para no bloquear módulos válidos
            }
        }
    }

    // Validación de estado para evitar colisiones del ciclo de vida
    if (state.executed) {
        applyNamespace()
    } else {
        afterEvaluate { applyNamespace() }
    }
}
