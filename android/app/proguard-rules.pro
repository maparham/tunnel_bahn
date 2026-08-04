# gomobile / JNI bridge classes are kept via consumer rules bundled in
# libs/libtunnelbahn.aar (-keep class go.** and tunnelbahn.**). No rules
# needed here for the Go bridge.

# kotlinx.serialization: keep generated serializers and @Serializable metadata.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**

-if @kotlinx.serialization.Serializable class **
-keepclassmembers class <1> {
    static <1>$Companion Companion;
}
-if @kotlinx.serialization.Serializable class ** {
    static **$* *;
}
-keepclassmembers class <2>$<3> {
    kotlinx.serialization.KSerializer serializer(...);
}
-keepclasseswithmembers class ** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Tink (via androidx.security-crypto) references compile-only annotations that
# are absent at runtime. Harmless to R8; silence the warnings.
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
