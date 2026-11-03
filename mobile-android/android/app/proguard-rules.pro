# ML Kit discovers these registrars by name from AndroidManifest metadata.
# R8 full mode must preserve both the names AND their reflective constructors.
-keep class * implements com.google.firebase.components.ComponentRegistrar {
    public <init>();
}
