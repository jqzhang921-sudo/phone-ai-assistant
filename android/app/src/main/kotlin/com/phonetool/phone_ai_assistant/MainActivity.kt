package com.phonetool.phone_ai_assistant

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private var audioRecord: AudioRecord? = null
    private var recordFile: File? = null
    private val isRecording = AtomicBoolean(false)
    private var calendar: CalendarChannel? = null

    companion object {
        private const val CHANNEL = "voice_recorder"
        private const val SAMPLE_RATE = 16000
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> {
                    val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
                    result.success(granted)
                }
                "start" -> startRecording(result)
                "stop" -> stopRecording(result)
                "cancel" -> {
                    cancelRecording()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        val cal = CalendarChannel(this)
        calendar = cal
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CalendarChannel.CHANNEL)
            .setMethodCallHandler { call, result -> cal.handle(call, result) }
    }

    // 日历权限是异步申请的，结果得转回 CalendarChannel 挂起的那个 result
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (calendar?.onPermissionResult(requestCode, grantResults) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun startRecording(result: MethodChannel.Result) {
        if (isRecording.get()) {
            result.success(null) // 已在录音
            return
        }
        val dir = cacheDir
        val file = File(dir, "stt_voice.wav")
        val bufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (bufferSize <= 0) {
            result.error("RECORD", "无法获取录音缓冲区大小", null)
            return
        }
        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize
            )
        } catch (e: Exception) {
            result.error("RECORD", "初始化录音失败: ${e.message}", null)
            return
        }

        try {
            recorder.startRecording()
        } catch (e: Exception) {
            recorder.release()
            result.error("RECORD", "启动录音失败: ${e.message}", null)
            return
        }

        audioRecord = recorder
        recordFile = file
        isRecording.set(true)

        // 后台线程持续读 PCM 数据写入文件
        Thread {
            val out = FileOutputStream(file)
            val buf = ByteArray(bufferSize)
            try {
                while (isRecording.get()) {
                    val read = recorder.read(buf, 0, buf.size)
                    if (read > 0) {
                        out.write(buf, 0, read)
                    }
                }
                out.flush()
            } catch (e: IOException) {
                // 忽略：停止时会关闭
            } finally {
                try {
                    out.close()
                } catch (_: IOException) {}
            }
        }.start()

        result.success(file.absolutePath)
    }

    private fun stopRecording(result: MethodChannel.Result) {
        if (!isRecording.get()) {
            result.error("RECORD", "当前没有在录音", null)
            return
        }
        isRecording.set(false)
        val recorder = audioRecord
        val file = recordFile
        audioRecord = null
        recordFile = null

        try {
            recorder?.stop()
        } catch (_: Exception) {}
        recorder?.release()

        if (file == null || !file.exists() || file.length() < 1000) {
            result.error("RECORD", "录音太短，没有录到内容", null)
            return
        }

        // PCM → WAV（加 44 字节头）
        try {
            val pcm = file.readBytes()
            val wav = pcmToWav(pcm, SAMPLE_RATE)
            FileOutputStream(file).use { it.write(wav) }
            result.success(file.absolutePath)
        } catch (e: Exception) {
            result.error("RECORD", "转 WAV 失败: ${e.message}", null)
        }
    }

    private fun cancelRecording() {
        isRecording.set(false)
        try {
            audioRecord?.stop()
        } catch (_: Exception) {}
        audioRecord?.release()
        audioRecord = null
        recordFile?.delete()
        recordFile = null
    }

    private fun pcmToWav(pcm: ByteArray, sampleRate: Int): ByteArray {
        val dataSize = pcm.size
        val totalSize = 44 + dataSize
        val wav = ByteArray(totalSize)
        // RIFF header
        writeString(wav, 0, "RIFF")
        writeIntLE(wav, 4, totalSize - 8)
        writeString(wav, 8, "WAVE")
        // fmt chunk
        writeString(wav, 12, "fmt ")
        writeIntLE(wav, 16, 16)             // fmt chunk size
        writeShortLE(wav, 20, 1)            // PCM format
        writeShortLE(wav, 22, 1)            // mono
        writeIntLE(wav, 24, sampleRate)     // sample rate
        writeIntLE(wav, 28, sampleRate * 2) // byte rate
        writeShortLE(wav, 32, 2)            // block align
        writeShortLE(wav, 34, 16)           // bits per sample
        // data chunk
        writeString(wav, 36, "data")
        writeIntLE(wav, 40, dataSize)
        System.arraycopy(pcm, 0, wav, 44, dataSize)
        return wav
    }

    private fun writeString(buf: ByteArray, offset: Int, s: String) {
        val bytes = s.toByteArray(Charsets.US_ASCII)
        System.arraycopy(bytes, 0, buf, offset, bytes.size)
    }

    private fun writeIntLE(buf: ByteArray, offset: Int, value: Int) {
        buf[offset] = (value and 0xFF).toByte()
        buf[offset + 1] = ((value shr 8) and 0xFF).toByte()
        buf[offset + 2] = ((value shr 16) and 0xFF).toByte()
        buf[offset + 3] = ((value shr 24) and 0xFF).toByte()
    }

    private fun writeShortLE(buf: ByteArray, offset: Int, value: Int) {
        buf[offset] = (value and 0xFF).toByte()
        buf[offset + 1] = ((value shr 8) and 0xFF).toByte()
    }

    override fun onDestroy() {
        cancelRecording()
        super.onDestroy()
    }
}
