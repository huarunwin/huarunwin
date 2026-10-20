# Bouncy Castle registers algorithms using class names and loads provider
# mappings reflectively. Keep those names and implementations in release APKs.
-keep class org.bouncycastle.jcajce.provider.** { *; }
-keep class org.bouncycastle.jce.provider.** { *; }
-keep class org.bouncycastle.pqc.jcajce.provider.** { *; }

# apksig encodes and decodes ASN.1 structures through annotated fields.
-keepattributes RuntimeVisibleAnnotations,Signature
-keep @interface com.android.apksig.internal.asn1.Asn1Class
-keep @interface com.android.apksig.internal.asn1.Asn1Field
-keep @com.android.apksig.internal.asn1.Asn1Class class * { *; }

# Optional LDAP certificate stores use JNDI, which Android does not provide.
# APK signing and PKCS#12 backup do not use these stores.
-dontwarn javax.naming.**
