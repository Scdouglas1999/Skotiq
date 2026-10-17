package com.skotiq.mobile

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Android half of the `skotiq/updater` MethodChannel. The Dart half is
 * packages/skotiq_updater/lib/src/services/android_installer.dart.
 *
 * Desktop Skotiq applies an update itself: it exits and a small helper
 * binary swaps the install directory. An Android app cannot do that — only
 * the system may replace a package — so this side hands the already-verified
 * APK to Android's installer and lets the OS take over.
 *
 * What this bridge does NOT do is decide whether the APK is trustworthy. Dart
 * has already checked it against a vendor-signed manifest by the time it gets
 * here, and Android then refuses any APK not signed with the same key as the
 * installed app. This code only carries a file path across.
 */
object UpdateInstallerBridge {

    const val CHANNEL = "skotiq/updater"

    private const val TAG = "UpdateInstaller"

    /**
     * Authority of the FileProvider declared in AndroidManifest.xml. The
     * installer runs in another process, so it cannot read a `file://` path
     * inside this app's private storage; a `content://` URI from our own
     * provider plus a read grant is the supported way to hand it over.
     */
    private const val PROVIDER_AUTHORITY_SUFFIX = ".updateprovider"

    fun attach(context: Context, channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            handle(context, call, result)
        }
    }

    private fun handle(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "canRequestPackageInstalls" -> {
                result.success(canRequestPackageInstalls(context))
            }

            "openInstallPermissionSettings" -> {
                try {
                    openInstallPermissionSettings(context)
                    result.success(null)
                } catch (e: Throwable) {
                    Log.e(TAG, "Could not open install-permission settings", e)
                    result.error(
                        "settings_unavailable",
                        e.message ?: "Could not open the install-permission screen.",
                        null,
                    )
                }
            }

            "installApk" -> {
                val apkPath = call.argument<String>("apkPath")
                if (apkPath.isNullOrBlank()) {
                    result.error(
                        "invalid_arguments",
                        "installApk requires an apkPath.",
                        null,
                    )
                    return
                }
                installApk(context, apkPath, result)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Android 8 introduced a per-app "install unknown apps" setting. Below
     * that the install is governed by a device-wide setting this app cannot
     * read meaningfully, so report true and let the installer itself object.
     */
    private fun canRequestPackageInstalls(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return context.packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermissionSettings(context: Context) {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${context.packageName}"),
            )
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    private fun installApk(
        context: Context,
        apkPath: String,
        result: MethodChannel.Result,
    ) {
        val apk = File(apkPath)
        if (!apk.isFile) {
            result.error(
                "apk_missing",
                "No APK at $apkPath.",
                null,
            )
            return
        }

        // Check before launching rather than after. Without the grant the
        // installer opens and immediately dies, which reads to the user as
        // the update having failed for no reason.
        if (!canRequestPackageInstalls(context)) {
            result.error(
                "install_permission_denied",
                "Skotiq is not allowed to install apps on this device yet.",
                null,
            )
            return
        }

        val uri = try {
            FileProvider.getUriForFile(
                context,
                context.packageName + PROVIDER_AUTHORITY_SUFFIX,
                apk,
            )
        } catch (e: IllegalArgumentException) {
            // Thrown when the APK is outside every <paths> entry the provider
            // declares. That is a packaging mistake in this app, not
            // something the user can act on, so say so plainly.
            Log.e(TAG, "APK is outside the FileProvider's configured paths", e)
            result.error(
                "provider_path_not_shareable",
                "The staged APK is in a location this app cannot share with " +
                    "the installer ($apkPath).",
                null,
            )
            return
        }

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
            putExtra(Intent.EXTRA_RETURN_RESULT, false)
        }

        try {
            context.startActivity(intent)
            result.success(null)
        } catch (e: Throwable) {
            Log.e(TAG, "Could not start the package installer", e)
            result.error(
                "installer_unavailable",
                e.message ?: "Could not start the Android package installer.",
                null,
            )
        }
    }
}
