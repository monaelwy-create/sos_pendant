package com.example.sos_guardian

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import androidx.core.app.ActivityCompat
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "sos_guardian/native"
    private val smsCode = 7001
    private val callCode = 7002
    private var pendingSms: Triple<String,String,MethodChannel.Result>? = null
    private var pendingCall: String? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
            when (call.method) {
                "sendSms" -> sendSms(call.argument<String>("phone") ?: "", call.argument<String>("body") ?: "", result)
                "makeCall" -> { makeCall(call.argument<String>("phone") ?: ""); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun sendSms(phone: String, body: String, result: MethodChannel.Result) {
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            pendingSms = Triple(phone, body, result)
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.SEND_SMS), smsCode)
            return
        }
        try {
            val list = SubscriptionManager.getActiveSubscriptionInfoList()
            val sms = if (!list.isNullOrEmpty()) SmsManager.getSmsManagerForSubscriptionId(list[0].subscriptionId) else SmsManager.getDefault()
            val parts = sms.divideMessage(body)
            sms.sendMultipartTextMessage(phone, null, parts, null, null)
            result.success(mapOf("success" to true, "message" to "SMS handed to Android SmsManager"))
        } catch (e: Exception) {
            result.success(mapOf("success" to false, "message" to (e.message ?: e.toString())))
        }
    }

    private fun makeCall(phone: String) {
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.CALL_PHONE) != PackageManager.PERMISSION_GRANTED) {
            pendingCall = phone
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CALL_PHONE), callCode)
            return
        }
        try { startActivity(Intent(Intent.ACTION_CALL, Uri.parse("tel:${Uri.encode(phone)}"))) } catch (_: Exception) {}
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, results)
        if (requestCode == smsCode) {
            val p = pendingSms; pendingSms = null
            if (p != null && results.firstOrNull() == PackageManager.PERMISSION_GRANTED) sendSms(p.first, p.second, p.third)
            else p?.third?.success(mapOf("success" to false, "message" to "SEND_SMS permission denied"))
        } else if (requestCode == callCode) {
            val p = pendingCall; pendingCall = null
            if (p != null && results.firstOrNull() == PackageManager.PERMISSION_GRANTED) makeCall(p)
        }
    }
}
