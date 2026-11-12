@file:Suppress("DEPRECATION") // API 21-22 require the legacy Keystore key-pair spec.

package com.oviewer.oviewer

import android.content.Context
import android.os.Build
import android.security.KeyPairGeneratorSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Calendar
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import javax.security.auth.x500.X500Principal

internal interface UploadTransferSealer {
    fun seal(value: String): String
    fun open(value: String): String
    fun revoke()
}

/** API 21-22 wrap an AES key with AndroidKeyStore RSA; API 23+ keep AES there.
 * No plaintext fallback: a locked/unavailable keystore suspends preparation. */
internal class UploadTransferSecrets(private val context: Context, private val directory: File) : UploadTransferSealer {
    companion object { private const val ALIAS = "oviewer.upload.transport.v1" }
    private val store get() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    @Synchronized private fun key(): SecretKey {
        val keys = store
        if (Build.VERSION.SDK_INT >= 23) {
            if (!keys.containsAlias(ALIAS)) {
                KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                    init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setRandomizedEncryptionRequired(true).build())
                }.generateKey()
            }
            return (keys.getEntry(ALIAS, null) as KeyStore.SecretKeyEntry).secretKey
        }
        if (!keys.containsAlias(ALIAS)) {
            val start = Calendar.getInstance()
            val end = Calendar.getInstance().apply { add(Calendar.YEAR, 30) }
            @Suppress("DEPRECATION")
            val spec = KeyPairGeneratorSpec.Builder(context).setAlias(ALIAS)
                .setSubject(X500Principal("CN=OViewer Upload Transport"))
                .setSerialNumber(BigInteger.ONE).setStartDate(start.time).setEndDate(end.time).build()
            KeyPairGenerator.getInstance("RSA", "AndroidKeyStore").apply { initialize(spec) }.generateKeyPair()
        }
        directory.mkdirs()
        val wrapped = AtomicFile(File(directory, "transport-key.bin"))
        val pair = keys.getEntry(ALIAS, null) as KeyStore.PrivateKeyEntry
        val rsa = Cipher.getInstance("RSA/ECB/PKCS1Padding")
        val raw: ByteArray
        if (wrapped.baseFile.exists() || File(wrapped.baseFile.path + ".bak").exists()) {
            rsa.init(Cipher.DECRYPT_MODE, pair.privateKey)
            raw = rsa.doFinal(wrapped.readFully())
        } else {
            raw = ByteArray(32).also { SecureRandom().nextBytes(it) }
            rsa.init(Cipher.ENCRYPT_MODE, pair.certificate.publicKey)
            val stream = wrapped.startWrite()
            try { stream.write(rsa.doFinal(raw)); wrapped.finishWrite(stream) }
            catch (error: Exception) { wrapped.failWrite(stream); raw.fill(0); throw error }
        }
        return SecretKeySpec(raw, "AES").also { raw.fill(0) }
    }

    override fun seal(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(byteArrayOf(1, cipher.iv.size.toByte()) + cipher.iv + ciphertext, Base64.NO_WRAP)
    }

    override fun open(value: String): String {
        val bytes = Base64.decode(value, Base64.NO_WRAP)
        require(bytes.size >= 30 && bytes[0] == 1.toByte())
        val ivLength = bytes[1].toInt() and 255
        require(ivLength in 12..16 && bytes.size > ivLength + 18)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(2, 2 + ivLength)))
        return cipher.doFinal(bytes.copyOfRange(2 + ivLength, bytes.size)).toString(Charsets.UTF_8)
    }

    @Synchronized override fun revoke() {
        val keys = store
        if (keys.containsAlias(ALIAS)) keys.deleteEntry(ALIAS)
        AtomicFile(File(directory, "transport-key.bin")).delete()
    }
}
