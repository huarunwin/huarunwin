package win.huarun.huarunwin

import android.app.Activity
import android.content.Intent
import android.provider.Settings
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.android.apksig.ApkSigner
import com.android.apksig.ApkVerifier
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Date
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import javax.security.auth.x500.X500Principal

@RunWith(AndroidJUnit4::class)
class ApkInstallerTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val base = instrumentation.targetContext
    private val folder = File(base.filesDir, "downloads/installer-qa-${System.nanoTime()}")
    private lateinit var apk: File
    private lateinit var installer: ApkInstaller
    private val requests = LinkedBlockingQueue<Intent>()
    private val permissionRequests = LinkedBlockingQueue<Pair<Intent, Int>>()
    private class Reply : MethodChannel.Result {
        private val done = CountDownLatch(1)
        var value: Any? = null
        var error: String? = null
        override fun success(result: Any?) { value = result; done.countDown() }
        override fun error(code: String, message: String?, details: Any?) { error = code; done.countDown() }
        override fun notImplemented() { error = "notImplemented"; done.countDown() }
        fun await(): Reply { assertTrue(done.await(30, TimeUnit.SECONDS)); return this }
    }
    @Before fun prepare() {
        folder.mkdirs()
        apk = File(folder, "fixture.apk")
        File(instrumentation.context.applicationInfo.sourceDir).copyTo(apk)
        instrumentation.runOnMainSync {
            val activity = object : Activity() {
                init { attachBaseContext(base) }
                override fun startActivity(intent: Intent) { requests.add(intent) }
                override fun startActivityForResult(intent: Intent, requestCode: Int) {
                    permissionRequests.add(intent to requestCode)
                }
            }
            installer = ApkInstaller(activity)
        }
    }
    @After fun clean() {
        if (::installer.isInitialized) instrumentation.runOnMainSync { installer.dispose() }
        folder.deleteRecursively()
    }
    private fun open(hash: String): Reply {
        val reply = Reply()
        instrumentation.runOnMainSync {
            installer.onMethodCall(MethodCall("openPackage", mapOf("path" to apk.path, "expectedSha256" to hash)), reply)
        }
        return reply.await()
    }
    @Suppress("DEPRECATION")
    @Test fun externalInstallerChoicesExcludeOurActivityAndRetainReadGrant() {
        val digest = MessageDigest.getInstance("SHA-256").digest(apk.readBytes()).joinToString("") { "%02x".format(it) }
        val reply = open(digest)
        assertNull(reply.error)
        assertEquals(true, reply.value)
        val chooser = requests.poll(10, TimeUnit.SECONDS)!!
        val first = chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
        val all = listOf(first) + chooser.getParcelableArrayExtra(Intent.EXTRA_INITIAL_INTENTS).orEmpty().map { it as Intent }
        assertTrue(all.isNotEmpty())
        all.forEach {
            assertNotEquals(base.packageName, it.component!!.packageName)
            assertNotEquals(0, it.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
            assertEquals("content", it.data!!.scheme)
        }
    }
    @Test fun changedApkCannotReachAnyOtherInstaller() {
        assertEquals("changed", open("0".repeat(64)).error)
        assertTrue(requests.isEmpty())
        assertTrue(apk.isFile)
    }

    @Suppress("DEPRECATION")
    @Test fun appExternalDownloadsCanBeInspectedAndSharedWithReadAccess() {
        val external = File(requireNotNull(base.getExternalFilesDir(null)),
            "downloads/installer-qa-${System.nanoTime()}").apply { mkdirs() }
        try {
            apk = apk.copyTo(File(external, "fixture.apk"))
            val inspected = Reply()
            instrumentation.runOnMainSync {
                installer.onMethodCall(MethodCall("inspectApk", mapOf("path" to apk.path)), inspected)
            }
            assertNull(inspected.await().error)
            assertEquals(instrumentation.context.packageName, (inspected.value as Map<*, *>)["packageName"])
            assertNull(open(digest()).error)
            val chooser = requests.poll(10, TimeUnit.SECONDS)!!
            val intent = chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
            assertNotEquals(0, intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val bytes = base.contentResolver.openInputStream(intent.data!!)!!.use { it.readBytes() }
            assertArrayEquals(apk.readBytes(), bytes)
        } finally {
            external.deleteRecursively()
        }
    }

    @Test fun unrelatedAppExternalFilesAreNotAcceptedAsManagedPackages() {
        val outside = File(requireNotNull(base.getExternalFilesDir(null)),
            "outside-qa-${System.nanoTime()}.apk")
        try {
            apk.copyTo(outside)
            apk = outside
            assertEquals("installation", open(digest()).error)
            assertTrue(requests.isEmpty())
        } finally {
            outside.delete()
        }
    }

    private fun digest() = MessageDigest.getInstance("SHA-256").digest(apk.readBytes())
        .joinToString("") { "%02x".format(it) }

    @Suppress("DEPRECATION")
    private fun ownApk(): String {
        File(base.applicationInfo.sourceDir).copyTo(apk, overwrite = true)
        return base.packageManager.getPackageInfo(base.packageName, 0).versionName!!
    }

    private fun update(version: String, hash: String = digest()): Reply {
        val reply = Reply()
        instrumentation.runOnMainSync {
            installer.onMethodCall(MethodCall("installSelfUpdate", mapOf(
                "path" to apk.path, "expectedSha256" to hash, "version" to version,
            )), reply)
        }
        return reply
    }

    @Test fun selfUpdateRejectsAnotherPackageBeforeRequestingPermission() {
        assertEquals("update_identity", update("0.1.0").await().error)
        assertTrue(permissionRequests.isEmpty())
        assertTrue(apk.isFile)
    }

    @Test fun selfUpdateRejectsMismatchedVersionBeforeRequestingPermission() {
        val version = ownApk()
        assertEquals("update_identity", update("$version-incorrect").await().error)
        assertTrue(permissionRequests.isEmpty())
    }

    @Test fun selfUpdateRechecksTheExpectedDigest() {
        val version = ownApk()
        assertEquals("changed", update(version, "0".repeat(64)).await().error)
        assertTrue(permissionRequests.isEmpty())
    }

    @Test fun selfUpdateRejectsInvalidApkSignatures() {
        val version = ownApk()
        val changed = File(folder, "unsigned.apk")
        // The central directory excludes APK alignment padding that a streaming
        // ZIP reader can mistake for extra, empty-name entries.
        ZipFile(apk).use { source ->
            ZipOutputStream(changed.outputStream()).use { output ->
                for (entry in source.entries().asSequence()) {
                    output.putNextEntry(ZipEntry(entry.name))
                    source.getInputStream(entry).use { it.copyTo(output) }
                    output.closeEntry()
                }
                output.putNextEntry(ZipEntry("assets/changed-after-signing.txt"))
                output.write("invalid signature".toByteArray())
                output.closeEntry()
            }
        }
        assertFalse(ApkVerifier.Builder(changed).build().verify().isVerified)
        changed.copyTo(apk, overwrite = true)
        // Android can reject missing signing blocks while reading PackageInfo,
        // before the client's independent signature verification is reached.
        assertTrue(update(version).await().error in setOf("package", "update_signature"))
        assertTrue(permissionRequests.isEmpty())
        assertTrue(apk.isFile)
    }

    @Test fun selfUpdateRejectsAValidApkSignedWithAnotherCertificate() {
        val version = ownApk()
        val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val name = X500Principal("CN=HuarunWin Self Update Test")
        val now = System.currentTimeMillis()
        val holder = JcaX509v3CertificateBuilder(name, BigInteger.ONE,
            Date(now - 300000), Date(now + 86400000), name, pair.public)
            .build(JcaContentSignerBuilder("SHA256withRSA")
                .setProvider(BouncyCastleProvider()).build(pair.private))
        val certificate = CertificateFactory.getInstance("X.509")
            .generateCertificate(holder.encoded.inputStream()) as X509Certificate
        val signer = ApkSigner.SignerConfig.Builder("fixture", pair.private, listOf(certificate)).build()
        val other = File(folder, "other-certificate.apk")
        ApkSigner.Builder(listOf(signer)).setInputApk(apk).setOutputApk(other)
            .setV1SigningEnabled(true).setV2SigningEnabled(true).setV3SigningEnabled(true)
            .setV4SigningEnabled(false).build().sign()
        assertTrue(ApkVerifier.Builder(other).build().verify().isVerified)
        other.copyTo(apk, overwrite = true)
        assertEquals("update_signature", update(version).await().error)
        assertTrue(permissionRequests.isEmpty())
        assertTrue(apk.isFile)
    }

    @Test fun validSelfUpdateReachesPermissionAndDenialRetainsTheApk() {
        assertFalse("Use a fresh QA application without install-source permission",
            base.packageManager.canRequestPackageInstalls())
        val reply = update(ownApk())
        val request = permissionRequests.poll(30, TimeUnit.SECONDS)!!
        assertEquals(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, request.first.action)
        assertEquals("package:${base.packageName}", request.first.data.toString())
        instrumentation.runOnMainSync {
            installer.onActivityResult(request.second, Activity.RESULT_CANCELED, null)
        }
        assertEquals("install_permission_denied", reply.await().error)
        assertTrue(apk.isFile)
        assertTrue(requests.isEmpty())
    }
}
