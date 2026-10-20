package win.huarun.huarunwin

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.bouncycastle.asn1.nist.NISTObjectIdentifiers
import org.bouncycastle.asn1.pkcs.PKCSObjectIdentifiers
import org.bouncycastle.asn1.x509.AlgorithmIdentifier
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.cert.jcajce.JcaX509ExtensionUtils
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.bouncycastle.pkcs.PKCS12PfxPduBuilder
import org.bouncycastle.pkcs.jcajce.JcaPKCS12SafeBagBuilder
import org.bouncycastle.pkcs.jcajce.JcePKCS12MacCalculatorBuilder
import org.bouncycastle.pkcs.jcajce.JcePKCSPBEOutputEncryptorBuilder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.InputStream
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.interfaces.RSAPrivateKey
import java.security.spec.PKCS8EncodedKeySpec
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.security.auth.x500.X500Principal

/** Portable personal signing identities, encrypted locally by a device-bound wrapping key. */
class ApkSigningKeys(
    private val context: Context,
    private val wrappingAlias: String = "win.huarun.apk.storage.v1",
    private val legacyPrefix: String = LEGACY_PREFIX,
) {
    data class Identity(val privateKey: PrivateKey, val certificate: X509Certificate)

    private val preferences = context.getSharedPreferences("apk_signing", Context.MODE_PRIVATE)
    private val provider by lazy { BouncyCastleProvider() }
    private val random = SecureRandom()
    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun folder(): File = File(context.noBackupFilesDir.canonicalFile, "apk-signing").apply {
        require(canonicalFile == absoluteFile) { "密钥目录无效。" }
        check(isDirectory || mkdir()) { "无法创建密钥目录。" }
    }

    fun keys(): List<Map<String, Any>> {
        val legacy = store()
        val identities = legacy.aliases().toList().filter { it.startsWith(legacyPrefix) }
            .map { describe(it, legacy.getCertificate(it) as X509Certificate) }
        val portable = folder().listFiles().orEmpty().filter { it.name.endsWith(".key") }
            .map { file ->
                val fingerprint = file.name.removeSuffix(".key")
                val id = PORTABLE_PREFIX + fingerprint
                runCatching { describe(id, identity(id).certificate) }.getOrElse {
                    mapOf("id" to id, "label" to "个人密钥 ${fingerprint.take(8)}",
                        "certificateSha256" to fingerprint, "exportable" to true, "available" to false)
                }
            }
        val preferred = preferences.getString("preferred", null)
        val present = (portable + identities).map { it.getValue("id") as String }.toSet()
        val known = preferences.getStringSet("known", emptySet()).orEmpty() + listOfNotNull(preferred)
        val missing = (known - present).map { id ->
            val fingerprint = if (id.startsWith(PORTABLE_PREFIX)) id.removePrefix(PORTABLE_PREFIX)
                else preferences.getString("certificate.$id", "").orEmpty()
            mapOf("id" to id, "label" to if (id.startsWith(PORTABLE_PREFIX)) "个人密钥 ${fingerprint.take(8)}" else "本机密钥",
                "certificateSha256" to fingerprint, "exportable" to id.startsWith(PORTABLE_PREFIX), "available" to false)
        }
        return (portable + identities + missing).sortedWith(compareBy<Map<String, Any>> { it["id"] != preferred }
            .thenBy { it["exportable"] != true }.thenByDescending { it["id"] as String })
    }

    // Called only after the user confirms signing. A missing known key must never be replaced.
    fun resolve(keyId: String? = null, expectedCertificate: String? = null): Map<String, Any> = synchronized(KEY_LOCK) {
        require((keyId == null) == (expectedCertificate == null)) { "请重新选择签名密钥。" }
        val id = keyId ?: keys().firstOrNull()?.getValue("id") as String?
        val created = id == null
        val key = if (id == null) create() else describe(id, identity(id, expectedCertificate).certificate)
        prefer(key.getValue("id") as String)
        key + ("created" to created)
    }

    fun create(): Map<String, Any> = synchronized(KEY_LOCK) {
        val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val now = System.currentTimeMillis()
        val name = X500Principal("CN=HuarunWin Personal APK Signing")
        val holder = JcaX509v3CertificateBuilder(name, BigInteger(128, random),
            Date(now - 300000L), Date(now + 50L * 365 * 86400000L), name, pair.public)
            .build(JcaContentSignerBuilder("SHA256withRSA").setProvider(provider).build(pair.private))
        val certificate = certificate(holder.encoded)
        save(Identity(pair.private, certificate))
    }

    fun identity(id: String, expectedCertificate: String? = null): Identity {
        val identity = if (id.startsWith(legacyPrefix)) {
            val store = store()
            val certificate = store.getCertificate(id) as? X509Certificate
                ?: error("本机签名密钥已不可用，请重新选择密钥。")
            Identity(store.getKey(id, null) as? PrivateKey ?: error("无法读取本机签名密钥。"), certificate)
        } else {
            val file = file(id)
            require(file.isFile && file.length() <= MAX_BACKUP_BYTES) { "签名密钥已不可用，请导入备份恢复。" }
            val encrypted = AtomicFile(file).openRead().use { it.readBytes() }
            require(encrypted.size > 12) { "签名密钥文件损坏，请导入备份恢复。" }
            val wrapping = store().getKey(wrappingAlias, null) as? SecretKey
                ?: error("本机密钥保护已不可用，请导入备份恢复。")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, wrapping, GCMParameterSpec(128, encrypted.copyOfRange(0, 12)))
                updateAAD(id.toByteArray(Charsets.UTF_8))
            }
            val plain = cipher.doFinal(encrypted, 12, encrypted.size - 12)
            try {
                DataInputStream(ByteArrayInputStream(plain)).use { input ->
                    fun part(): ByteArray {
                        val size = input.readInt()
                        require(size in 1..MAX_BACKUP_BYTES && size <= input.available()) { "签名密钥文件损坏。" }
                        return ByteArray(size).also { input.readFully(it) }
                    }
                    val encoded = part()
                    val privateKey = try { KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(encoded)) }
                        finally { encoded.fill(0) }
                    val certificate = certificate(part())
                    require(input.available() == 0 && id == PORTABLE_PREFIX + digest(certificate.encoded)) { "签名密钥不匹配。" }
                    Identity(privateKey, certificate)
                }
            } finally { plain.fill(0) }
        }
        require(expectedCertificate == null || digest(identity.certificate.encoded) == expectedCertificate) {
            "签名密钥已变化，请重新选择。"
        }
        return identity
    }

    fun export(id: String, expectedCertificate: String, password: CharArray): ByteArray {
        require(id.startsWith(PORTABLE_PREFIX)) { "此密钥仅限本机使用，无法导出。" }
        require(password.size >= 8) { "备份密码至少需要 8 个字符。" }
        val identity = identity(id, expectedCertificate)
        fun encryptor() = JcePKCSPBEOutputEncryptorBuilder(NISTObjectIdentifiers.id_aes256_CBC)
            .setProvider(provider).setPRF(AlgorithmIdentifier(PKCSObjectIdentifiers.id_hmacWithSHA256))
            .setIterationCount(210000).build(password)
        val attributes = org.bouncycastle.asn1.DERBMPString("huarunwin-signing")
        val localKeyId = JcaX509ExtensionUtils().createSubjectKeyIdentifier(identity.certificate.publicKey)
        val keyBag = JcaPKCS12SafeBagBuilder(identity.privateKey, encryptor())
            .addBagAttribute(PKCSObjectIdentifiers.pkcs_9_at_friendlyName, attributes)
            .addBagAttribute(PKCSObjectIdentifiers.pkcs_9_at_localKeyId, localKeyId).build()
        val certBag = JcaPKCS12SafeBagBuilder(identity.certificate)
            .addBagAttribute(PKCSObjectIdentifiers.pkcs_9_at_friendlyName, attributes)
            .addBagAttribute(PKCSObjectIdentifiers.pkcs_9_at_localKeyId, localKeyId).build()
        return PKCS12PfxPduBuilder().addData(keyBag).addEncryptedData(encryptor(), arrayOf(certBag))
            .build(JcePKCS12MacCalculatorBuilder(NISTObjectIdentifiers.id_sha256)
                .setProvider(provider).setIterationCount(210000), password).encoded
    }

    fun exported(id: String, expectedCertificate: String): Map<String, Any> {
        val certificate = identity(id, expectedCertificate).certificate
        check(preferences.edit().putLong("exported.$id", System.currentTimeMillis()).commit()) { "备份已导出，但无法记录导出时间。" }
        return describe(id, certificate)
    }

    fun import(input: InputStream, password: CharArray): Map<String, Any> {
        val data = input.readBytesLimited()
        val keystore = KeyStore.getInstance("PKCS12", provider)
        try {
            keystore.load(ByteArrayInputStream(data), password)
            val aliases = keystore.aliases().toList().filter { keystore.isKeyEntry(it) }
            require(aliases.size == 1) { "请选择仅包含一把签名私钥的 PKCS#12（.p12）备份。" }
            val key = keystore.getKey(aliases.single(), password) as? RSAPrivateKey
                ?: error("请选择包含 RSA 签名私钥的 .p12 备份。")
            require(key.modulus.bitLength() in 2048..8192) { "签名私钥应为 2048 至 8192 位 RSA。" }
            val certificate = keystore.getCertificate(aliases.single()) as? X509Certificate
                ?: error("备份缺少签名证书。")
            val challenge = ByteArray(32).also { random.nextBytes(it) }
            val signature = Signature.getInstance("SHA256withRSA").apply { initSign(key); update(challenge) }.sign()
            require(Signature.getInstance("SHA256withRSA").run { initVerify(certificate); update(challenge); verify(signature) }) {
                "备份中的私钥与证书不匹配。"
            }
            return save(Identity(key, certificate))
        } catch (error: java.io.IOException) {
            throw IllegalArgumentException("无法读取密钥备份，请检查密码与 .p12 文件是否正确。", error)
        } finally { data.fill(0) }
    }

    fun prefer(id: String, onlyIfUnset: Boolean = false) = synchronized(KEY_LOCK) {
        val certificate = identity(id).certificate
        val editor = preferences.edit()
            .putStringSet("known", preferences.getStringSet("known", emptySet()).orEmpty() + id)
            .putString("certificate.$id", digest(certificate.encoded))
        if (!onlyIfUnset || preferences.getString("preferred", null) == null) editor.putString("preferred", id)
        check(editor.commit()) { "无法保存默认签名密钥，请重试。" }
    }

    private fun save(identity: Identity): Map<String, Any> = synchronized(KEY_LOCK) {
        val id = PORTABLE_PREFIX + digest(identity.certificate.encoded)
        val target = file(id)
        if (target.exists()) {
            // A valid duplicate keeps its metadata; a verified backup can repair an unreadable local copy.
            runCatching { identity(id).certificate }.getOrNull()?.let { return@synchronized describe(id, it) }
        }
        val wrapping = store().getKey(wrappingAlias, null) as? SecretKey
            ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(wrappingAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            }.generateKey()
        val plain = ByteArrayOutputStream().also { bytes ->
            DataOutputStream(bytes).use { output ->
                val encoded = identity.privateKey.encoded
                try { output.writeInt(encoded.size); output.write(encoded) } finally { encoded.fill(0) }
                val certificate = identity.certificate.encoded
                output.writeInt(certificate.size); output.write(certificate)
            }
        }.toByteArray()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, wrapping)
            updateAAD(id.toByteArray(Charsets.UTF_8))
        }
        val encrypted = try { cipher.iv + cipher.doFinal(plain) } finally { plain.fill(0) }
        val atomic = AtomicFile(target)
        val stream = atomic.startWrite()
        try { stream.write(encrypted); atomic.finishWrite(stream) }
        catch (error: Exception) { atomic.failWrite(stream); throw error }
        check(preferences.edit().putStringSet("known",
            preferences.getStringSet("known", emptySet()).orEmpty() + id).commit()) { "无法记录签名密钥，请重试。" }
        describe(id, identity.certificate)
    }

    private fun file(id: String): File {
        require(id.startsWith(PORTABLE_PREFIX) && id.removePrefix(PORTABLE_PREFIX).matches(Regex("[0-9a-f]{64}"))) { "签名密钥标识无效。" }
        return File(folder(), id.removePrefix(PORTABLE_PREFIX) + ".key").apply {
            require(canonicalFile == absoluteFile) { "签名密钥路径无效。" }
        }
    }

    private fun describe(id: String, certificate: X509Certificate): Map<String, Any> {
        val fingerprint = digest(certificate.encoded)
        val portable = id.startsWith(PORTABLE_PREFIX)
        val label = if (portable) "个人密钥 ${fingerprint.take(8)}" else "本机密钥 " +
            SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.ROOT).format(Date(id.removePrefix(legacyPrefix).substringBefore('.').toLong()))
        return buildMap {
            put("id", id); put("label", label); put("certificateSha256", fingerprint); put("exportable", portable)
            val exported = preferences.getLong("exported.$id", 0)
            if (exported > 0) put("lastExportedAt", exported)
        }
    }

    private fun certificate(encoded: ByteArray) = CertificateFactory.getInstance("X.509")
        .generateCertificate(ByteArrayInputStream(encoded)) as X509Certificate

    private fun InputStream.readBytesLimited(): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = read(buffer)
            if (count < 0) break
            require(output.size() + count <= MAX_BACKUP_BYTES) { "密钥备份过大，请选择 .p12 文件。" }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    companion object {
        private val KEY_LOCK = Any()
        private const val LEGACY_PREFIX = "win.huarun.apk.signing."
        private const val PORTABLE_PREFIX = "win.huarun.apk.portable."
        private const val MAX_BACKUP_BYTES = 1024 * 1024
        private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256")
            .digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
