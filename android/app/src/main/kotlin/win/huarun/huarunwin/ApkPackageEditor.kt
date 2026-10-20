package win.huarun.huarunwin

import com.reandroid.apk.ApkModule
import com.reandroid.arsc.chunk.xml.ResXmlAttribute
import com.reandroid.arsc.chunk.xml.ResXmlElement
import com.reandroid.arsc.value.ValueType
import java.io.File

/** Binary resource editing via ARSCLib, as used by REAndroid/APKEditor.
 * Does not rename DEX classes or patch application/native code.
 */
class ApkPackageEditor {
    fun rewrite(input: File, output: File, packageName: String): String {
        requireValidPackageName(packageName)
        ApkModule.loadApkFile(input).use { apk ->
            val manifest = requireNotNull(apk.androidManifest) { "无法读取 APK 清单。" }
            val root = requireNotNull(manifest.manifestElement) { "APK 清单无效。" }
            val original = requireNotNull(manifest.packageName) { "无法读取原始包名。" }
            require(packageName != original) { "新包名必须与原始包名不同。" }
            val elements = manifest.recursiveElements().asSequence().toList()
            require(!manifest.isSplit && elements.none { it.name == "uses-split" } &&
                root.androidAttribute("sharedUserId") == null &&
                (manifest.applicationElement?.androidAttribute("isSplitRequired")?.data ?: 0) == 0 &&
                root.searchAttributeByName("requiredSplitTypes") == null &&
                elements.none { it.name == "meta-data" &&
                    it.androidAttribute("name")?.valueAsString == "com.android.vending.splits.required" &&
                    (it.androidAttribute("value")?.data ?: 0) != 0 } &&
                elements.none { it.name in setOf("instrumentation", "overlay", "static-library", "sdk-library") }) {
                "修改包名仅支持普通单文件 APK，不支持拆分包、共享用户或系统组件。"
            }
            val application = requireNotNull(manifest.applicationElement) { "APK 没有应用入口。" }
            val appElements = listOf(application) + application.recursiveElements().asSequence().toList()

            // Preserve original class identities before changing the application ID.
            // ARSCLib.ensureFullClassNames only handles leading dots and all name
            // attributes; component-only expansion also handles bare class names.
            for (element in appElements) {
                val names = when (element.name) {
                    "application" -> listOf("name", "backupAgent", "appComponentFactory", "manageSpaceActivity", "zygotePreloadName")
                    "activity" -> listOf("name", "parentActivityName")
                    "activity-alias" -> listOf("name", "targetActivity", "parentActivityName")
                    "service", "receiver", "provider" -> listOf("name")
                    else -> emptyList()
                }
                for (name in names) {
                    element.androidAttribute(name)?.let { attribute ->
                        val value = literal(attribute)
                        if (value.isNotEmpty()) attribute.setValueAsString(when {
                            value.startsWith(".") -> original + value
                            '.' !in value -> "$original.$value"
                            else -> value
                        })
                    }
                }
            }

            fun renamed(value: String) = if (value == original || value.startsWith("$original.")) {
                packageName + value.removePrefix(original)
            } else { "$packageName.$value" }

            // Rewrite only identifiers declared by this APK; external permission
            // names and queried packages remain external references.
            val permissions = mutableMapOf<String, String>()
            for (element in elements) {
                if (element.name !in setOf("permission", "permission-tree", "permission-group")) continue
                element.androidAttribute("name")?.let { attribute ->
                    val value = literal(attribute)
                    require(value.isNotBlank()) { "APK 权限声明无效。" }
                    permissions[value] = renamed(value)
                    attribute.setValueAsString(permissions.getValue(value))
                }
            }
            for (element in elements) {
                for (name in listOf("permission", "readPermission", "writePermission", "permissionGroup")) {
                    element.androidAttribute(name)?.let { attribute ->
                        val value = literal(attribute)
                        permissions[value]?.let(attribute::setValueAsString)
                    }
                }
                if (element.name in setOf("uses-permission", "uses-permission-sdk-23", "uses-permission-sdk-m")) {
                    element.androidAttribute("name")?.let { attribute ->
                        permissions[literal(attribute)]?.let(attribute::setValueAsString)
                    }
                }
            }
            for (element in appElements) {
                if (element.name == "provider") {
                    element.androidAttribute("authorities")?.let { attribute ->
                        val authorities = literal(attribute).split(';')
                        require(authorities.all { it.isNotBlank() }) { "APK Provider 标识无效。" }
                        attribute.setValueAsString(authorities.joinToString(";") { renamed(it.trim()) })
                    }
                }
                for (name in listOf("process", "taskAffinity")) {
                    element.androidAttribute(name)?.let { attribute ->
                        val value = literal(attribute)
                        if (value.isNotEmpty() && !value.startsWith(":")) {
                            attribute.setValueAsString(renamed(value))
                        }
                    }
                }
            }
            // Load without framework resolution; retain resource IDs and payloads.
            apk.getTableBlock(false)
            apk.setPackageName(packageName)
            manifest.refresh()
            apk.getTableBlock(false)?.refresh()
            apk.setApkSignatureBlock(null)
            // apksig removes old v1 signatures when signing the rewritten archive.
            val writer = apk.createApkFileWriter(output)
            writer.zipAligner.apply {
                clearFileAlignment()
                setDefaultAlignment(4)
                setFileAlignment({ it.startsWith("lib/") && it.endsWith(".so") }, 16384)
            }
            check(!Thread.currentThread().isInterrupted) { "修改包名已中断。" }
            writer.write()
            return original
        }
    }

    private fun ResXmlElement.androidAttribute(name: String) = searchAttribute(ANDROID_NAMESPACE, name)

    private fun literal(attribute: ResXmlAttribute): String {
        if (attribute.valueType == ValueType.NULL) return ""
        require(attribute.valueType == ValueType.STRING) {
            "此 APK 的身份或组件字段使用资源引用，暂不支持修改包名，原始 APK 已保留。"
        }
        return requireNotNull(attribute.valueAsString) { "APK 清单字段无效。" }
    }

    companion object {
        private const val ANDROID_NAMESPACE = "http://schemas.android.com/apk/res/android"
        fun requireValidPackageName(value: String) {
            // resources.arsc has a fixed 128 UTF-16 code-unit package name field.
            require(value.length <= 127 && value.matches(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+"))) {
                "包名需包含至少两段，以点分隔；每段以英文字母开头，只能含字母、数字和下划线，最长 127 字符。"
            }
        }
    }
}
