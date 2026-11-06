# Keep the app's own classes: services, receivers and tiles are named in the manifest, and some
# Bluetooth calls go through reflection. Libraries are still shrunk.
-keep class nz.galaxybridge.watch.** { *; }
-dontwarn com.google.errorprone.annotations.**
