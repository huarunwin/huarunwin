package win.huarun.huarunwin

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.reandroid.apk.ApkModule
import com.reandroid.arsc.chunk.TableBlock
import com.reandroid.arsc.chunk.xml.AndroidManifestBlock
import com.reandroid.arsc.chunk.xml.ResXmlElement
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class ApkPackageEditorTest {
    private val folder = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,
        "package-editor-test-${System.nanoTime()}").apply { mkdirs() }
    private val source = File(folder, "source.apk")
    private val output = File(folder, "modified.apk")

    @After fun clean() { folder.deleteRecursively() }

    private fun ResXmlElement.attribute(name: String, id: Int, value: String) {
        getOrCreateAndroidAttribute(name, id).setValueAsString(value)
    }

    private fun fixture(sharedUser: Boolean = false) {
        ApkModule().use { apk ->
            val manifest = AndroidManifestBlock()
            manifest.setPackageName("test.original")
            manifest.setVersionCode(100)
            manifest.setVersionName("1.0")
            val app = manifest.orCreateApplicationElement
            app.attribute("name", android.R.attr.name, ".App")
            app.attribute("taskAffinity", android.R.attr.taskAffinity, "test.original.tasks")
            app.newElement("activity").apply {
                attribute("name", android.R.attr.name, "MainActivity")
                attribute("parentActivityName", android.R.attr.parentActivityName, ".Parent")
            }
            app.newElement("activity-alias").apply {
                attribute("name", android.R.attr.name, ".Alias")
                attribute("targetActivity", android.R.attr.targetActivity, ".MainActivity")
            }
            app.newElement("provider").apply {
                attribute("name", android.R.attr.name, ".Provider")
                attribute("authorities", android.R.attr.authorities, "test.original.files;vendor.provider")
                attribute("readPermission", android.R.attr.readPermission, "test.original.ACCESS")
                attribute("process", android.R.attr.process, ":private")
            }
            val root = manifest.manifestElement
            root.newElement("permission").attribute("name", android.R.attr.name, "test.original.ACCESS")
            manifest.addUsesPermission("test.original.ACCESS")
            manifest.addUsesPermission("android.permission.INTERNET")
            if (sharedUser) root.attribute("sharedUserId", android.R.attr.sharedUserId, "test.shared")
            apk.setManifest(manifest)
            val table = TableBlock()
            table.newPackage(0x7f, "test.original")
            apk.setTableBlock(table)
            apk.writeApk(source)
        }
    }

    @Test fun preservesClassesWhileSeparatingProviderAndPermissionIdentity() {
        fixture()
        val before = ApkResigner.sha256(source)
        assertEquals("test.original", ApkPackageEditor().rewrite(source, output, "test.personal"))
        assertEquals(before, ApkResigner.sha256(source))
        ApkModule.loadApkFile(output).use { apk ->
            val manifest = apk.androidManifest
            assertEquals("test.personal", manifest.packageName)
            assertEquals("test.personal", apk.getTableBlock(false).packageArray.get(0).name)
            assertEquals("1.0", manifest.versionName)
            val elements = manifest.recursiveElements().asSequence().toList()
            fun attr(tag: String, name: String) = elements.first { it.name == tag }
                .searchAttribute("http://schemas.android.com/apk/res/android", name).valueAsString
            assertEquals("test.original.App", attr("application", "name"))
            assertEquals("test.original.MainActivity", attr("activity", "name"))
            assertEquals("test.original.Parent", attr("activity", "parentActivityName"))
            assertEquals("test.original.MainActivity", attr("activity-alias", "targetActivity"))
            assertEquals("test.personal.files;test.personal.vendor.provider", attr("provider", "authorities"))
            assertEquals("test.personal.ACCESS", attr("provider", "readPermission"))
            assertEquals(":private", attr("provider", "process"))
            assertEquals("test.personal.tasks", attr("application", "taskAffinity"))
            val permissions = elements.filter { it.name == "uses-permission" }.map {
                it.searchAttribute("http://schemas.android.com/apk/res/android", "name").valueAsString
            }
            assertTrue(permissions.contains("test.personal.ACCESS"))
            assertTrue(permissions.contains("android.permission.INTERNET"))
        }
    }

    @Test fun rejectsUnsupportedSharedIdentityWithoutWritingOutput() {
        fixture(sharedUser = true)
        val before = ApkResigner.sha256(source)
        assertTrue(runCatching { ApkPackageEditor().rewrite(source, output, "test.personal") }.isFailure)
        assertEquals(before, ApkResigner.sha256(source))
        assertFalse(output.exists())
    }
}
