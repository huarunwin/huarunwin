package win.huarun.huarunwin

import android.content.Context
import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.android.apksig.ApkVerifier
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.KeyStore

@RunWith(AndroidJUnit4::class)
class ApkSigningKeysTest {
    private val base = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var folder: File
    private lateinit var first: Context
    private lateinit var second: Context
    private lateinit var keys: ApkSigningKeys
    private lateinit var other: ApkSigningKeys
    private val token = System.nanoTime().toString()
    private val firstAlias = "huarun-qa-signing-$token-first"
    private val secondAlias = "huarun-qa-signing-$token-second"
    private val legacyPrefix = "huarun-qa-legacy-$token."
    private val password = "密钥备份 Test 2026!".toCharArray()

    @Before fun prepare() {
        folder = File(base.cacheDir, "signing-backup-test-$token").apply { mkdirs() }
        fun isolated(name: String) = object : ContextWrapper(base) {
            override fun getNoBackupFilesDir() = File(folder, name).apply { mkdirs() }
            override fun getSharedPreferences(unused: String, mode: Int) =
                base.getSharedPreferences("signing-qa-$token-$name", mode)
        }
        first = isolated("first")
        second = isolated("second")
        keys = ApkSigningKeys(first, firstAlias, legacyPrefix)
        other = ApkSigningKeys(second, secondAlias, legacyPrefix)
    }

    @After fun clean() {
        KeyStore.getInstance("AndroidKeyStore").apply {
            load(null); deleteEntry(firstAlias); deleteEntry(secondAlias)
        }
        for (name in listOf("first", "second")) base.deleteSharedPreferences("signing-qa-$token-$name")
        if (::folder.isInitialized) folder.deleteRecursively()
        password.fill('\u0000')
    }

    private fun localFile(key: Map<String, Any>) =
        File(first.noBackupFilesDir, "apk-signing/${key.getValue("certificateSha256")}.key")

    @Test fun defaultIsCreatedOnlyWhenResolvedAndReusedAfterRestart() {
        assertTrue(keys.keys().isEmpty())
        assertFalse(File(first.noBackupFilesDir, "apk-signing").listFiles().orEmpty().any { it.name.endsWith(".key") })
        val created = keys.resolve()
        assertEquals(true, created["created"])
        assertEquals(true, created["exportable"])
        val restarted = ApkSigningKeys(first, firstAlias, legacyPrefix)
        val reused = restarted.resolve()
        assertEquals(false, reused["created"])
        assertEquals(created["id"], reused["id"])
        assertEquals(created["certificateSha256"], reused["certificateSha256"])
        assertEquals(1, restarted.keys().size)
        assertNotEquals(created["id"], other.resolve()["id"])
    }

    @Test fun concurrentDefaultRequestsCreateOneIdentity() {
        val executor = java.util.concurrent.Executors.newFixedThreadPool(4)
        try {
            val results = executor.invokeAll((1..4).map {
                java.util.concurrent.Callable { ApkSigningKeys(first, firstAlias, legacyPrefix).resolve() }
            }).map { it.get() }
            assertEquals(1, results.count { it["created"] == true })
            assertEquals(1, results.map { it["id"] }.distinct().size)
            assertEquals(1, keys.keys().size)
        } finally { executor.shutdownNow() }
    }

    @Test fun confirmedSelectionBecomesDefaultAndMissingKeyRequiresBackup() {
        val original = keys.resolve()
        val alternative = keys.create()
        // Merely creating a key in management does not change the confirmed default.
        assertEquals(original["id"], keys.resolve()["id"])
        val selected = keys.resolve(alternative["id"] as String, alternative["certificateSha256"] as String)
        assertEquals(false, selected["created"])
        assertEquals(alternative["id"], ApkSigningKeys(first, firstAlias, legacyPrefix).resolve()["id"])
        assertTrue(localFile(alternative).delete())
        assertEquals(false, keys.keys().first()["available"])
        assertTrue(runCatching { keys.resolve() }.isFailure)
        assertTrue(runCatching { keys.resolve(alternative["id"] as String, alternative["certificateSha256"] as String) }.isFailure)
        assertEquals(2, keys.keys().size)
        // Recovery must restore the original identity; another key is only used explicitly.
        assertEquals(original["id"], keys.resolve(original["id"] as String, original["certificateSha256"] as String)["id"])
    }

    @Test fun corruptedOrUnrememberedMissingIdentityIsNeverAutomaticallyReplaced() {
        val key = keys.create()
        val backup = keys.export(key["id"] as String, key["certificateSha256"] as String, password)
        localFile(key).writeBytes(ByteArray(200))
        assertTrue(runCatching { keys.resolve() }.isFailure)
        assertTrue(localFile(key).delete())
        assertTrue(runCatching { keys.resolve() }.isFailure)
        assertEquals(false, keys.keys().single()["available"])
        keys.import(ByteArrayInputStream(backup), password)
        assertEquals(key["id"], keys.resolve()["id"])
    }

    @Test fun completingAnOlderTaskDoesNotReplaceTheConfirmedDefault() {
        val older = keys.resolve()
        val selected = keys.create()
        keys.resolve(selected["id"] as String, selected["certificateSha256"] as String)
        val input = File(InstrumentationRegistry.getInstrumentation().context.applicationInfo.sourceDir)
            .copyTo(File(folder, "older-task.apk"))
        ApkResigner(first, keys).resign(input, File(folder, "older-task-signed.apk"),
            older["id"] as String, ApkResigner.sha256(input), older["certificateSha256"] as String)
        assertEquals(selected["id"], ApkSigningKeys(first, firstAlias, legacyPrefix).resolve()["id"])
    }

    @Test fun restoresSameSigningIdentityWithDifferentDeviceProtectionAndSignsRealApk() {
        val key = keys.create()
        val id = key.getValue("id") as String
        val fingerprint = key.getValue("certificateSha256") as String
        assertEquals(true, key["exportable"])
        val backup = keys.export(id, fingerprint, password)
        // Verify a genuine standard PKCS#12 private-key entry, not just certificate export.
        val standard = KeyStore.getInstance("PKCS12", BouncyCastleProvider()).apply {
            load(ByteArrayInputStream(backup), password)
        }
        val alias = standard.aliases().toList().single { standard.isKeyEntry(it) }
        assertNotNull(standard.getKey(alias, password))
        assertArrayEquals(keys.identity(id).certificate.encoded, standard.getCertificate(alias).encoded)

        val input = File(InstrumentationRegistry.getInstrumentation().context.applicationInfo.sourceDir)
            .copyTo(File(folder, "source.apk"))
        val before = ApkResigner.sha256(input)
        val firstOutput = File(folder, "first.apk")
        ApkResigner(first, keys).resign(input, firstOutput, id, before, fingerprint)
        assertTrue(localFile(key).delete())
        KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(firstAlias) }
        assertTrue(runCatching { keys.identity(id) }.isFailure)

        val restored = other.import(ByteArrayInputStream(backup), password)
        assertEquals(id, restored["id"])
        assertEquals(fingerprint, restored["certificateSha256"])
        val secondOutput = File(folder, "second.apk")
        ApkResigner(second, other).resign(input, secondOutput, id, before, fingerprint)
        val original = ApkVerifier.Builder(firstOutput).setMinCheckedPlatformVersion(21).build().verify()
        val recovered = ApkVerifier.Builder(secondOutput).setMinCheckedPlatformVersion(21).build().verify()
        assertTrue(original.errors.toString(), original.isVerified)
        assertTrue(recovered.errors.toString(), recovered.isVerified)
        assertTrue(recovered.isVerifiedUsingV1Scheme)
        assertTrue(recovered.isVerifiedUsingV2Scheme)
        assertTrue(recovered.isVerifiedUsingV3Scheme)
        assertArrayEquals(original.signerCertificates.single().encoded, recovered.signerCertificates.single().encoded)
        assertEquals(before, ApkResigner.sha256(input))
    }

    @Test fun localStorageIsEncryptedAndDuplicateImportPreservesIdentityAndExportHistory() {
        val key = keys.create()
        val id = key.getValue("id") as String
        val fingerprint = key.getValue("certificateSha256") as String
        val identity = keys.identity(id)
        val stored = localFile(key).readBytes()
        fun contains(needle: ByteArray) = (0..stored.size - needle.size).any { offset ->
            needle.indices.all { stored[offset + it] == needle[it] }
        }
        assertFalse(contains(identity.privateKey.encoded))
        assertFalse(contains(identity.certificate.encoded))
        val backup = keys.export(id, fingerprint, password)
        assertNull(keys.keys().single { it["id"] == id }["lastExportedAt"])
        val exported = keys.exported(id, fingerprint)
        assertTrue(exported["lastExportedAt"] is Long)
        val imported = keys.import(ByteArrayInputStream(backup), password)
        assertEquals(exported, imported)
        assertEquals(1, keys.keys().count { it["id"] == id })
        assertArrayEquals(stored, localFile(key).readBytes())
    }

    @Test fun wrongPasswordCorruptionCertificateOnlyAndOversizedFilesCannotChangeKeys() {
        val key = keys.create()
        val id = key.getValue("id") as String
        val fingerprint = key.getValue("certificateSha256") as String
        val before = localFile(key).readBytes()
        val backup = keys.export(id, fingerprint, password)
        assertTrue(runCatching { keys.import(ByteArrayInputStream(backup), "wrong-password".toCharArray()) }.isFailure)
        val tampered = backup.copyOf().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() }
        assertTrue(runCatching { keys.import(ByteArrayInputStream(tampered), password) }.isFailure)
        assertTrue(runCatching { keys.import(ByteArrayInputStream(ByteArray(1024 * 1024 + 1)), password) }.isFailure)
        val certificates = KeyStore.getInstance("PKCS12", BouncyCastleProvider()).apply {
            load(null, password); setCertificateEntry("certificate-only", keys.identity(id).certificate)
        }
        val bytes = ByteArrayOutputStream().also { certificates.store(it, password) }.toByteArray()
        assertTrue(runCatching { keys.import(ByteArrayInputStream(bytes), password) }.isFailure)
        assertArrayEquals(before, localFile(key).readBytes())
        assertEquals(1, keys.keys().count { it["id"] == id })
        assertNull(keys.keys().single { it["id"] == id }["lastExportedAt"])
    }

    @Test fun verifiedBackupCanRepairCorruptLocalCopyWithoutChangingCertificate() {
        val key = keys.create()
        val id = key.getValue("id") as String
        val fingerprint = key.getValue("certificateSha256") as String
        val backup = keys.export(id, fingerprint, password)
        localFile(key).writeBytes(ByteArray(200))
        assertTrue(runCatching { keys.identity(id) }.isFailure)
        assertEquals(false, keys.keys().single { it["id"] == id }["available"])
        val restored = keys.import(ByteArrayInputStream(backup), password)
        assertEquals(id, restored["id"])
        assertEquals(fingerprint, restored["certificateSha256"])
        assertNotNull(keys.identity(id, fingerprint).privateKey)
    }

    @Test fun exportRejectsWeakPasswordChangedCertificateAndLegacyKeys() {
        val key = keys.create()
        val id = key.getValue("id") as String
        val fingerprint = key.getValue("certificateSha256") as String
        assertTrue(runCatching { keys.export(id, fingerprint, "short".toCharArray()) }.isFailure)
        assertTrue(runCatching { keys.export(id, "0".repeat(64), password) }.isFailure)
        assertTrue(runCatching { keys.export("win.huarun.apk.signing.legacy", fingerprint, password) }.isFailure)
        assertNull(keys.keys().single { it["id"] == id }["lastExportedAt"])
    }
}
