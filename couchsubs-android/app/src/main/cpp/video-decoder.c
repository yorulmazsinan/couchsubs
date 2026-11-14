// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// chiaki-ng android/app/src/main/cpp/video-decoder.c'den uyarlandı (Florian Märkl ve chiaki-ng katkıcıları).
// Değişiklikler: yüzey değiştirme yok, yeni geri çağrı imzası (frames_lost, frame_recovered), düşük gecikme isteği.

#include "video-decoder.h"

#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <android/native_window_jni.h>

#include <string.h>

#define INPUT_BUFFER_TIMEOUT_MS 10

static void *output_thread_func(void *user);

ChiakiErrorCode couchsubs_video_decoder_init(CouchSubsVideoDecoder *decoder, ChiakiLog *log, int32_t width, int32_t height)
{
	memset(decoder, 0, sizeof(*decoder));
	decoder->log = log;
	decoder->target_width = width;
	decoder->target_height = height;
	return chiaki_mutex_init(&decoder->codec_mutex, false);
}

static void kill_decoder(CouchSubsVideoDecoder *decoder)
{
	chiaki_mutex_lock(&decoder->codec_mutex);
	decoder->shutdown_output = true;
	ssize_t index = AMediaCodec_dequeueInputBuffer(decoder->codec, 1000);
	if(index >= 0)
	{
		AMediaCodec_queueInputBuffer(decoder->codec, (size_t)index, 0, 0, decoder->timestamp_cur++, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
		AMediaCodec_stop(decoder->codec);
		chiaki_mutex_unlock(&decoder->codec_mutex);
		chiaki_thread_join(&decoder->output_thread, NULL);
	}
	else
	{
		CHIAKI_LOGE(decoder->log, "Video decoder: no input buffer for shutdown");
		AMediaCodec_stop(decoder->codec);
		chiaki_mutex_unlock(&decoder->codec_mutex);
		chiaki_thread_join(&decoder->output_thread, NULL);
	}
	AMediaCodec_delete(decoder->codec);
	decoder->codec = NULL;
	decoder->shutdown_output = false;
}

void couchsubs_video_decoder_fini(CouchSubsVideoDecoder *decoder)
{
	if(decoder->codec)
		kill_decoder(decoder);
	if(decoder->window)
	{
		ANativeWindow_release(decoder->window);
		decoder->window = NULL;
	}
	chiaki_mutex_fini(&decoder->codec_mutex);
}

bool couchsubs_video_decoder_start(CouchSubsVideoDecoder *decoder, JNIEnv *env, jobject surface)
{
	if(!surface)
		return false;
	chiaki_mutex_lock(&decoder->codec_mutex);
	bool ok = false;
	decoder->window = ANativeWindow_fromSurface(env, surface);
	if(!decoder->window)
		goto beach;

	const char *mime = "video/avc";
	decoder->codec = AMediaCodec_createDecoderByType(mime);
	if(!decoder->codec)
	{
		CHIAKI_LOGE(decoder->log, "Video decoder: no AMediaCodec for %s", mime);
		goto error_window;
	}

	AMediaFormat *format = AMediaFormat_new();
	AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, mime);
	AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, decoder->target_width);
	AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, decoder->target_height);
	/* Android 11+: düşük gecikmeli çözme (desteklemeyen cihaz yok sayar). */
	AMediaFormat_setInt32(format, "low-latency", 1);
	media_status_t r = AMediaCodec_configure(decoder->codec, format, decoder->window, NULL, 0);
	AMediaFormat_delete(format);
	if(r != AMEDIA_OK)
	{
		CHIAKI_LOGE(decoder->log, "AMediaCodec_configure() failed: %d", (int)r);
		goto error_codec;
	}
	r = AMediaCodec_start(decoder->codec);
	if(r != AMEDIA_OK)
	{
		CHIAKI_LOGE(decoder->log, "AMediaCodec_start() failed: %d", (int)r);
		goto error_codec;
	}
	if(chiaki_thread_create(&decoder->output_thread, output_thread_func, decoder) != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(decoder->log, "Video decoder: output thread failed");
		AMediaCodec_stop(decoder->codec);
		goto error_codec;
	}
	ok = true;
	goto beach;

error_codec:
	AMediaCodec_delete(decoder->codec);
	decoder->codec = NULL;
error_window:
	ANativeWindow_release(decoder->window);
	decoder->window = NULL;
beach:
	chiaki_mutex_unlock(&decoder->codec_mutex);
	return ok;
}

bool couchsubs_video_decoder_video_sample(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	(void)frames_lost;
	(void)frame_recovered;
	bool result = true;
	CouchSubsVideoDecoder *decoder = user;
	chiaki_mutex_lock(&decoder->codec_mutex);
	if(!decoder->codec || decoder->shutdown_output)
		goto beach;

	while(buf_size > 0)
	{
		ssize_t index = AMediaCodec_dequeueInputBuffer(decoder->codec, INPUT_BUFFER_TIMEOUT_MS * 1000);
		if(index < 0)
		{
			/* libchiaki bozuk kare sayıp yeni anahtar kare ister. */
			result = false;
			goto beach;
		}
		size_t codec_buf_size;
		uint8_t *codec_buf = AMediaCodec_getInputBuffer(decoder->codec, (size_t)index, &codec_buf_size);
		size_t size = buf_size > codec_buf_size ? codec_buf_size : buf_size;
		memcpy(codec_buf, buf, size);
		/* Zaman damgası yalnız birer artar: en gerçek zamanlı davranış. */
		media_status_t r = AMediaCodec_queueInputBuffer(decoder->codec, (size_t)index, 0, size, decoder->timestamp_cur++, 0);
		if(r != AMEDIA_OK)
			CHIAKI_LOGE(decoder->log, "AMediaCodec_queueInputBuffer() failed: %d", (int)r);
		buf += size;
		buf_size -= size;
	}

beach:
	chiaki_mutex_unlock(&decoder->codec_mutex);
	return result;
}

static void *output_thread_func(void *user)
{
	CouchSubsVideoDecoder *decoder = user;
	while(1)
	{
		AMediaCodecBufferInfo info;
		ssize_t status = AMediaCodec_dequeueOutputBuffer(decoder->codec, &info, 100000);
		if(status >= 0)
		{
			/* render=true: kare ImageReader'a gider. */
			AMediaCodec_releaseOutputBuffer(decoder->codec, (size_t)status, info.size != 0);
			if(info.size != 0)
				decoder->frames_out++;
			if(info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM)
				break;
		}
		else
		{
			chiaki_mutex_lock(&decoder->codec_mutex);
			bool shutdown = decoder->shutdown_output;
			chiaki_mutex_unlock(&decoder->codec_mutex);
			if(shutdown)
				break;
		}
	}
	return NULL;
}
