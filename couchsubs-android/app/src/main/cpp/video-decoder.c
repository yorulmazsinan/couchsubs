// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// chiaki-ng android/app/src/main/cpp/video-decoder.c'den uyarlandı (Florian Märkl ve chiaki-ng katkıcıları).
// Değişiklikler: yüzey yok (ByteBuffer çıkış, parlaklık düzlemi burada okunur), yeni geri çağrı imzası (frames_lost,
// frame_recovered), düşük gecikme isteği, yazılım çözücüye geçiş.
//
// Neden yüzey yok: kareler eskiden bir ImageReader'a çözülüp Java'da Image.getPlanes() ile okunuyordu. Bazı
// cihazlarda (Samsung, Xiaomi, Honor; Android 15-17) çözücünün verdiği kare işlemciden okunamıyor ve getPlanes()
// libmedia_jni içinde "non-zero capacity for nullptr pointer" ile JNI'yi durduruyordu (SIGABRT, Java'da
// yakalanamaz). Şimdi çıkış arabelleği AMediaCodec_getOutputBuffer() ile alınır; boş ya da sınır dışı arabellek,
// tanınmayan biçim yalnız kareyi atlatır.

#include "video-decoder.h"

#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <sys/system_properties.h>

#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#define INPUT_BUFFER_TIMEOUT_MS 10
/* Başlık (SPS/PPS) bir kez gelir; yitirilmesin diye giriş arabelleği daha uzun beklenir. */
#define HEADER_INPUT_TIMEOUT_MS 500
/* Bu kadar art arda hatadan sonra donanım çözücü bırakılır, yazılım çözücüyle yeniden kurulur. */
#define CODEC_ERROR_LIMIT 30
/* MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible */
#define COLOR_FORMAT_YUV420_FLEXIBLE 0x7F420888
/* Altyazı okumaya yetmeyecek kadar küçük kare okunmaz. */
#define MIN_FRAME_SIDE 16
/* Bir H.264 karesinin en büyük kabul edilen boyu; 1080p anahtar kare birkaç MB'ı geçmez (Mac/iPhone'da
 * StreamSession.maxSampleBytes, Windows'ta couchsubs_native.c ile aynı; GitHub #855). */
#define MAX_SAMPLE_BYTES ((size_t)64 << 20)

static const char *const SOFTWARE_DECODERS[] = { "c2.android.avc.decoder", "OMX.google.h264.decoder", NULL };

static void *output_thread_func(void *user);

ChiakiErrorCode couchsubs_video_decoder_init(CouchSubsVideoDecoder *decoder, ChiakiLog *log, int32_t width, int32_t height)
{
	memset(decoder, 0, sizeof(*decoder));
	decoder->log = log;
	decoder->target_width = width;
	decoder->target_height = height;
	atomic_init(&decoder->shutdown_output, false);
	atomic_init(&decoder->unsupported_output, false);
	atomic_init(&decoder->frames_out, 0);
	ChiakiErrorCode err = chiaki_mutex_init(&decoder->codec_mutex, false);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;
	err = chiaki_mutex_init(&decoder->output_mutex, false);
	if(err != CHIAKI_ERR_SUCCESS)
		chiaki_mutex_fini(&decoder->codec_mutex);
	return err;
}

/* Çözücüyü durdurur, çıkış iş parçacığını bekler ve siler (codec_mutex tutulurken çağrılır, dönüşte de tutulur).
 * Sıra önemli: önce çıkış iş parçacığına dur denir, sonra output_mutex alınır; böylece AMediaCodec_stop() çıkış
 * arabelleği okunurken çağrılmaz (eskiden çağrılabiliyordu: okunan bellek elden gidince SIGSEGV). */
static void stop_codec(CouchSubsVideoDecoder *decoder)
{
	if(!decoder->codec)
		return;
	atomic_store(&decoder->shutdown_output, true);
	chiaki_mutex_lock(&decoder->output_mutex);
	AMediaCodec_stop(decoder->codec);
	chiaki_mutex_unlock(&decoder->output_mutex);
	/* Çıkış iş parçacığı codec_mutex'i kısa süre alabilir: beklerken bırakılır. */
	chiaki_mutex_unlock(&decoder->codec_mutex);
	chiaki_thread_join(&decoder->output_thread, NULL);
	chiaki_mutex_lock(&decoder->codec_mutex);
	AMediaCodec_delete(decoder->codec);
	decoder->codec = NULL;
}

void couchsubs_video_decoder_fini(CouchSubsVideoDecoder *decoder, JNIEnv *env)
{
	chiaki_mutex_lock(&decoder->codec_mutex);
	stop_codec(decoder);
	chiaki_mutex_unlock(&decoder->codec_mutex);
	if(decoder->frame_listener && env)
		(*env)->DeleteGlobalRef(env, decoder->frame_listener);
	decoder->frame_listener = NULL;
	chiaki_mutex_fini(&decoder->output_mutex);
	chiaki_mutex_fini(&decoder->codec_mutex);
	free(decoder->header);
	decoder->header = NULL;
	decoder->header_size = 0;
}

/* Çözücüyü kurar ve çıkış iş parçacığını başlatır (kilit tutulurken). software: yazılım çözücü. Bazı üreticilerin
 * (ör. Honor/MagicOS) donanım çözücüsü kurulumda ya da çözerken hata verebilir; o zaman yazılım çözücü denenir.
 * Başarısızsa codec NULL kalır. */
static bool open_codec(CouchSubsVideoDecoder *decoder, bool software)
{
	const char *mime = "video/avc";
	for(int i = 0; software ? SOFTWARE_DECODERS[i] != NULL : i == 0; i++)
	{
		const char *name = software ? SOFTWARE_DECODERS[i] : "(default)";
		decoder->codec = software ? AMediaCodec_createCodecByName(name) : AMediaCodec_createDecoderByType(mime);
		if(!decoder->codec)
		{
			CHIAKI_LOGE(decoder->log, "Video decoder: no AMediaCodec %s for %s", name, mime);
			continue;
		}
		AMediaFormat *format = AMediaFormat_new();
		AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, mime);
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, decoder->target_width);
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, decoder->target_height);
		/* Yüzeysiz çözmede esnek YUV 4:2:0 istenir (Android 5+ çözücüleri desteklemek zorunda): Y düzlemi ilk ve
		 * doğrusaldır; satır aralığı ve görünür alan çıkış biçiminden okunur. */
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_COLOR_FORMAT, COLOR_FORMAT_YUV420_FLEXIBLE);
		/* Android 11+: düşük gecikmeli çözme (desteklemeyen cihaz yok sayar). */
		AMediaFormat_setInt32(format, "low-latency", 1);
		media_status_t r = AMediaCodec_configure(decoder->codec, format, NULL, NULL, 0);
		AMediaFormat_delete(format);
		if(r != AMEDIA_OK)
		{
			CHIAKI_LOGE(decoder->log, "AMediaCodec_configure() failed (%s): %d", name, (int)r);
			goto next;
		}
		r = AMediaCodec_start(decoder->codec);
		if(r != AMEDIA_OK)
		{
			CHIAKI_LOGE(decoder->log, "AMediaCodec_start() failed (%s): %d", name, (int)r);
			goto next;
		}
		atomic_store(&decoder->shutdown_output, false);
		atomic_store(&decoder->unsupported_output, false);
		memset(&decoder->format, 0, sizeof(decoder->format));
		decoder->codec_errors = 0;
		/* Yeni çözücü başlığı (SPS/PPS) görmedi; elde varsa ilk örnekten önce verilir. */
		decoder->header_pending = decoder->header != NULL;
		if(chiaki_thread_create(&decoder->output_thread, output_thread_func, decoder) != CHIAKI_ERR_SUCCESS)
		{
			CHIAKI_LOGE(decoder->log, "Video decoder: output thread failed");
			AMediaCodec_stop(decoder->codec);
			goto next;
		}
		chiaki_thread_set_name(&decoder->output_thread, "CouchSubs video");
		decoder->software = software;
		CHIAKI_LOGI(decoder->log, "Video decoder: %s started (buffer output)", software ? name : "hardware decoder");
		return true;
next:
		AMediaCodec_delete(decoder->codec);
		decoder->codec = NULL;
	}
	return false;
}

static bool prefers_software_decoder(void)
{
	char manufacturer[PROP_VALUE_MAX] = { 0 };
	__system_property_get("ro.product.manufacturer", manufacturer);
	return strcasecmp(manufacturer, "samsung") == 0;
}

bool couchsubs_video_decoder_start(CouchSubsVideoDecoder *decoder, JNIEnv *env, jobject frame_listener, bool swap)
{
	if(!frame_listener)
		return false;
	if((*env)->GetJavaVM(env, &decoder->vm) != JNI_OK)
		return false;
	jclass cls = (*env)->GetObjectClass(env, frame_listener);
	decoder->on_frame = cls ? (*env)->GetMethodID(env, cls, "onFrame", "(Ljava/nio/ByteBuffer;IIIIZ)V") : NULL;
	if(cls)
		(*env)->DeleteLocalRef(env, cls);
	if(!decoder->on_frame)
	{
		if((*env)->ExceptionCheck(env))
			(*env)->ExceptionClear(env);
		CHIAKI_LOGE(decoder->log, "Video decoder: frame listener has no onFrame");
		return false;
	}
	decoder->frame_listener = (*env)->NewGlobalRef(env, frame_listener);
	if(!decoder->frame_listener)
		return false;

	chiaki_mutex_lock(&decoder->codec_mutex);
	/* Samsung'da yazılım çözücüyle başlanır (#96'dan beri sahada görüntü veren seçim); yazılım çözücü kareyi
	 * işlemciyle yazar, çıkışı hep düz YUV 4:2:0'dır. Açılamazsa donanım çözücü denenir. swap: önceki oturumda bu
	 * seçimle hiç görüntü gelmedi; öbür türle denenir (StreamSession). */
	bool software_first = prefers_software_decoder() != swap;
	CHIAKI_LOGI(decoder->log, "Video decoder: trying %s decoder first%s", software_first ? "software" : "hardware",
			swap ? " (swapped after no picture)" : "");
	bool ok = open_codec(decoder, software_first);
	if(!ok)
	{
		CHIAKI_LOGE(decoder->log, "Video decoder: %s decoder failed, trying %s decoder",
				software_first ? "software" : "hardware", software_first ? "hardware" : "software");
		ok = open_codec(decoder, !software_first);
	}
	chiaki_mutex_unlock(&decoder->codec_mutex);
	return ok;
}

/* Donanım çözücü art arda hata verdiyse ya da okunamayan biçimde kare verdiyse yazılım çözücüyle yeniden kurar.
 * Kilit tutulurken çağrılır, dönüşte de tutulur. */
static void fall_back_to_software(CouchSubsVideoDecoder *decoder)
{
	if(atomic_load(&decoder->unsupported_output))
		CHIAKI_LOGE(decoder->log, "Video decoder: unreadable output format, switching to software decoder");
	else
		CHIAKI_LOGE(decoder->log, "Video decoder: %u errors in a row, switching to software decoder", (unsigned)decoder->codec_errors);
	stop_codec(decoder);
	if(!open_codec(decoder, true))
	{
		/* Görüntü gelmez; PictureWatchdog oturumu yeniden kurar. Süreç çökmez. */
		CHIAKI_LOGE(decoder->log, "Video decoder: software decoder could not be opened");
		decoder->software = true;
	}
}

/* Örnek H.264 akış başlığı mı (SPS ile başlıyor: libchiaki'nin profil başlığı SPS+PPS'tir). */
static bool is_stream_header(const uint8_t *buf, size_t size)
{
	size_t at;
	if(size >= 5 && buf[0] == 0 && buf[1] == 0 && buf[2] == 0 && buf[3] == 1)
		at = 4;
	else if(size >= 4 && buf[0] == 0 && buf[1] == 0 && buf[2] == 1)
		at = 3;
	else
		return false;
	return (buf[at] & 0x1f) == 7;
}

/* Örneği çözücüye verir (kilit tutulurken). Giriş arabelleği timeout_ms içinde gelmezse ya da hata olursa false. */
static bool queue_input(CouchSubsVideoDecoder *decoder, const uint8_t *buf, size_t buf_size, int timeout_ms)
{
	while(buf_size > 0)
	{
		ssize_t index = AMediaCodec_dequeueInputBuffer(decoder->codec, (int64_t)timeout_ms * 1000);
		if(index < 0)
		{
			/* TRY_AGAIN_LATER olağan; başka bir değer çözücü hatasıdır. */
			if(index != AMEDIACODEC_INFO_TRY_AGAIN_LATER)
				decoder->codec_errors++;
			/* libchiaki bozuk kare sayıp yeni anahtar kare ister. */
			return false;
		}
		size_t codec_buf_size;
		uint8_t *codec_buf = AMediaCodec_getInputBuffer(decoder->codec, (size_t)index, &codec_buf_size);
		if(!codec_buf || codec_buf_size == 0)
		{
			/* NDK belgesi: arabellek alınamazsa NULL döner; memcpy süreci çökertirdi. Kare atlanır. */
			CHIAKI_LOGE(decoder->log, "AMediaCodec_getInputBuffer() returned no buffer");
			AMediaCodec_queueInputBuffer(decoder->codec, (size_t)index, 0, 0, decoder->timestamp_cur++, 0);
			return false;
		}
		size_t size = buf_size > codec_buf_size ? codec_buf_size : buf_size;
		memcpy(codec_buf, buf, size);
		/* Zaman damgası yalnız birer artar: en gerçek zamanlı davranış. */
		media_status_t r = AMediaCodec_queueInputBuffer(decoder->codec, (size_t)index, 0, size, decoder->timestamp_cur++, 0);
		if(r != AMEDIA_OK)
		{
			CHIAKI_LOGE(decoder->log, "AMediaCodec_queueInputBuffer() failed: %d", (int)r);
			decoder->codec_errors++;
			return false;
		}
		buf += size;
		buf_size -= size;
	}
	return true;
}

bool couchsubs_video_decoder_video_sample(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	(void)frames_lost;
	(void)frame_recovered;
	bool result = true;
	CouchSubsVideoDecoder *decoder = user;
	if(!buf || buf_size == 0 || buf_size > MAX_SAMPLE_BYTES)
	{
		/* false: libchiaki karenin işlenmediğini bilir, yeni anahtar kare ister. */
		CHIAKI_LOGW(decoder->log, "Video decoder: implausible sample size (%zu), dropped", buf_size);
		return false;
	}
	chiaki_mutex_lock(&decoder->codec_mutex);
	/* libchiaki başlığı (SPS/PPS) profil başında bir kez verir ve dönüş değerine bakmaz: başlık yitirilirse ya da
	 * çözücü sonradan yeniden kurulursa (yazılım çözücüye geçiş) çözücü hiç kare çıkaramaz, bağlantı açıkken görüntü
	 * gelmez. Başlık saklanır, her yeni çözücüye ilk iş verilir. */
	bool header = is_stream_header(buf, buf_size);
	if(header)
	{
		uint8_t *copy = malloc(buf_size);
		if(copy)
		{
			memcpy(copy, buf, buf_size);
			free(decoder->header);
			decoder->header = copy;
			decoder->header_size = buf_size;
		}
		decoder->header_pending = true;
	}
	if(!decoder->software && decoder->codec
			&& (decoder->codec_errors >= CODEC_ERROR_LIMIT || atomic_load(&decoder->unsupported_output)))
		fall_back_to_software(decoder);
	if(!decoder->codec || atomic_load(&decoder->shutdown_output))
		goto beach;

	if(decoder->header_pending && decoder->header)
	{
		if(!queue_input(decoder, decoder->header, decoder->header_size, HEADER_INPUT_TIMEOUT_MS))
		{
			CHIAKI_LOGE(decoder->log, "Video decoder: stream header could not be queued");
			result = false;
			goto beach;
		}
		decoder->header_pending = false;
		if(header)
			goto beach;
	}
	if(!queue_input(decoder, buf, buf_size, INPUT_BUFFER_TIMEOUT_MS))
		result = false;

beach:
	chiaki_mutex_unlock(&decoder->codec_mutex);
	return result;
}

/* --- Çıkış --- */

/* Y düzlemi ilk ve doğrusal olan YUV 4:2:0 biçimleri. Döşemeli (tiled) ve sıkıştırılmış satıcı biçimleri (ör. Qualcomm
 * 0x7FA30C03/UBWC, Samsung 0x7FC00002) işlemciden düz okunamaz; onlarda kare atlanır, yazılım çözücüye geçilir. */
static bool is_linear_yuv420(int32_t color_format)
{
	switch(color_format)
	{
		case 19: /* COLOR_FormatYUV420Planar (I420) */
		case 20: /* COLOR_FormatYUV420PackedPlanar */
		case 21: /* COLOR_FormatYUV420SemiPlanar (NV12) */
		case 39: /* COLOR_FormatYUV420PackedSemiPlanar */
		case COLOR_FORMAT_YUV420_FLEXIBLE:
		case 0x7FA30C04: /* QOMX_COLOR_FORMATYUV420PackedSemiPlanar32m (NV12, hizalı satırlar) */
		case 0x32315659: /* HAL_PIXEL_FORMAT_YV12 */
		case 0x11: /* HAL_PIXEL_FORMAT_YCrCb_420_SP (NV21) */
		case 0x23: /* HAL_PIXEL_FORMAT_YCbCr_420_888 */
			return true;
		default:
			return false;
	}
}

static int32_t format_int(AMediaFormat *format, const char *key, int32_t fallback)
{
	int32_t value;
	return AMediaFormat_getInt32(format, key, &value) ? value : fallback;
}

/* Çözücünün çıkış biçimini okur (output_mutex tutulurken, çözücü durdurulmamışken). */
static void read_output_format(CouchSubsVideoDecoder *decoder)
{
	CouchSubsOutputFormat *f = &decoder->format;
	memset(f, 0, sizeof(*f));
	AMediaFormat *format = AMediaCodec_getOutputFormat(decoder->codec);
	if(!format)
		return;
	f->known = true;
	f->color_format = format_int(format, AMEDIAFORMAT_KEY_COLOR_FORMAT, -1);
	f->width = format_int(format, AMEDIAFORMAT_KEY_WIDTH, 0);
	f->height = format_int(format, AMEDIAFORMAT_KEY_HEIGHT, 0);
	f->stride = format_int(format, "stride", f->width);
	f->slice_height = format_int(format, "slice-height", f->height);
	f->color_range = format_int(format, "color-range", 0);
	f->full_range = f->color_range == 1;
	f->color_standard = format_int(format, "color-standard", 0);
	int32_t left, top, right, bottom;
	if(AMediaFormat_getInt32(format, "crop-left", &left) && AMediaFormat_getInt32(format, "crop-top", &top)
			&& AMediaFormat_getInt32(format, "crop-right", &right) && AMediaFormat_getInt32(format, "crop-bottom", &bottom))
	{
		f->crop_left = left;
		f->crop_top = top;
		f->crop_right = right + 1;
		f->crop_bottom = bottom + 1;
	}
	else
	{
		f->crop_right = f->width;
		f->crop_bottom = f->height;
	}
	AMediaFormat_delete(format);

	if(f->stride < f->width)
		f->stride = f->width;
	if(f->crop_left < 0) f->crop_left = 0;
	if(f->crop_top < 0) f->crop_top = 0;
	if(f->crop_right > f->width) f->crop_right = f->width;
	if(f->crop_bottom > f->height) f->crop_bottom = f->height;
	bool sized = f->width > 0 && f->height > 0 && f->stride <= 16384
		&& f->crop_right - f->crop_left >= MIN_FRAME_SIDE && f->crop_bottom - f->crop_top >= MIN_FRAME_SIDE;
	f->supported = sized && is_linear_yuv420(f->color_format);
	if(f->supported)
		CHIAKI_LOGI(decoder->log, "Video decoder: output 0x%x %dx%d stride %d slice %d crop %d,%d-%d,%d range %d (%s) standard %d",
				(unsigned)f->color_format, f->width, f->height, f->stride, f->slice_height,
				f->crop_left, f->crop_top, f->crop_right, f->crop_bottom, f->color_range,
				f->full_range ? "full, mapped to limited" : "limited", f->color_standard);
	else
		CHIAKI_LOGE(decoder->log, "Video decoder: unreadable output 0x%x %dx%d stride %d crop %d,%d-%d,%d; frames skipped",
				(unsigned)f->color_format, f->width, f->height, f->stride,
				f->crop_left, f->crop_top, f->crop_right, f->crop_bottom);
}

/* Kare arabelleğini (Java'nın doğrudan ByteBuffer'ı) en az size bayta büyütür. */
static bool ensure_frame_buffer(CouchSubsVideoDecoder *decoder, JNIEnv *env, size_t size)
{
	if(decoder->frame_buffer && decoder->frame_capacity >= size)
		return true;
	if(size > 0x7fffffff)
		return false;
	jclass cls = (*env)->FindClass(env, "java/nio/ByteBuffer");
	jmethodID allocate = cls ? (*env)->GetStaticMethodID(env, cls, "allocateDirect", "(I)Ljava/nio/ByteBuffer;") : NULL;
	jobject buffer = allocate ? (*env)->CallStaticObjectMethod(env, cls, allocate, (jint)size) : NULL;
	if((*env)->ExceptionCheck(env))
	{
		/* Bellek yetmedi: kare atlanır. */
		(*env)->ExceptionClear(env);
		buffer = NULL;
	}
	if(cls)
		(*env)->DeleteLocalRef(env, cls);
	uint8_t *ptr = buffer ? (*env)->GetDirectBufferAddress(env, buffer) : NULL;
	jlong capacity = buffer ? (*env)->GetDirectBufferCapacity(env, buffer) : -1;
	jobject global = ptr && capacity >= (jlong)size ? (*env)->NewGlobalRef(env, buffer) : NULL;
	if(buffer)
		(*env)->DeleteLocalRef(env, buffer);
	if(!global)
		return false;
	if(decoder->frame_buffer)
		(*env)->DeleteGlobalRef(env, decoder->frame_buffer);
	decoder->frame_buffer = global;
	decoder->frame_ptr = ptr;
	decoder->frame_capacity = (size_t)capacity;
	return true;
}

/* Renk düzlemlerini (U, V; yarım çözünürlük, sıkışık) kare arabelleğinde Y'nin ardına kopyalar. Yalnız düzeni kesin
 * bilinen biçimlerde (I420, NV12, NV21); diğerlerinde false döner, Java tarafı gri tonla sürer. Ekran yazısının
 * özgün renklerini (zemin, yazı) bulmak içindir; yazı tanıma yine yalnız parlaklıkla okur. */
static bool copy_chroma(CouchSubsVideoDecoder *decoder, const uint8_t *base, size_t start, size_t end, size_t width, size_t height)
{
	CouchSubsOutputFormat *f = &decoder->format;
	size_t stride = (size_t)f->stride;
	size_t slice = (size_t)(f->slice_height >= f->height ? f->slice_height : f->height);
	size_t cw = width / 2;
	size_t ch = height / 2;
	size_t cl = (size_t)f->crop_left / 2;
	size_t ct = (size_t)f->crop_top / 2;
	if(cw == 0 || ch == 0)
		return false;
	uint8_t *dst_u = decoder->frame_ptr + width * height;
	uint8_t *dst_v = dst_u + cw * ch;
	size_t plane = start + stride * slice;
	switch(f->color_format)
	{
		case 19: /* I420 */
		case 20:
		{
			size_t cstride = stride / 2;
			size_t u0 = plane;
			size_t v0 = plane + cstride * (slice / 2);
			if(v0 + (ct + ch - 1) * cstride + cl + cw > end)
				return false;
			for(size_t y = 0; y < ch; y++)
			{
				memcpy(dst_u + y * cw, base + u0 + (ct + y) * cstride + cl, cw);
				memcpy(dst_v + y * cw, base + v0 + (ct + y) * cstride + cl, cw);
			}
			return true;
		}
		case 21: /* NV12: UV iç içe */
		case 39:
		case 0x11: /* NV21: VU iç içe */
		{
			bool vu = f->color_format == 0x11;
			if(plane + (ct + ch - 1) * stride + 2 * (cl + cw) > end)
				return false;
			for(size_t y = 0; y < ch; y++)
			{
				const uint8_t *row = base + plane + (ct + y) * stride + 2 * cl;
				for(size_t x = 0; x < cw; x++)
				{
					dst_u[y * cw + x] = row[2 * x + (vu ? 1 : 0)];
					dst_v[y * cw + x] = row[2 * x + (vu ? 0 : 1)];
				}
			}
			return true;
		}
		default:
			return false;
	}
}

/* Tam aralıklı (0–255) kare sınırlı aralığa (Y 16–235, U/V 16–240) çevrilir: Kotlin tarafı (PhoneFrames.phoneTone,
 * RegionPixels.color, yazı tanıma) karenin sınırlı aralıklı olduğunu varsayar; tam aralıklı akışta (MediaCodec
 * "color-range" 1) karanlık ve açık tonlar kırpılıyor, telefon araması dosyadaki kareden farklı parlaklık görüyordu
 * (Mac/iPhone FrameColor, Windows sws_setColorspaceDetails ile aynı amaç: tek bilinen biçim). */
static void limit_range(uint8_t *frame, size_t luma, size_t chroma)
{
	static uint8_t y_table[256], c_table[256];
	static atomic_bool ready = false;
	if(!atomic_load(&ready))
	{
		for(int v = 0; v < 256; v++)
		{
			y_table[v] = (uint8_t)(16 + (v * 219 + 127) / 255);
			c_table[v] = (uint8_t)(16 + (v * 224 + 127) / 255);
		}
		atomic_store(&ready, true);
	}
	for(size_t i = 0; i < luma; i++)
		frame[i] = y_table[frame[i]];
	for(size_t i = luma; i < luma + chroma; i++)
		frame[i] = c_table[frame[i]];
}

/* Çıkış arabelleğinin görünür Y bölgesini sıkışık (satır aralığı = en) biçimde kare arabelleğine kopyalar
 * (output_mutex tutulurken, çözücü durdurulmamışken). Okunamıyorsa false; kare atlanır. */
static bool copy_luma(CouchSubsVideoDecoder *decoder, JNIEnv *env, size_t index, const AMediaCodecBufferInfo *info)
{
	CouchSubsOutputFormat *f = &decoder->format;
	/* Bazı çözücüler ilk kareden önce biçim değişimi bildirmez. */
	if(!f->known)
		read_output_format(decoder);
	if(!f->supported)
		return false;
	size_t out_size = 0;
	uint8_t *base = AMediaCodec_getOutputBuffer(decoder->codec, index, &out_size);
	if(!base || out_size == 0 || info->offset < 0 || info->size <= 0)
		return false;
	size_t start = (size_t)info->offset;
	size_t end = start + (size_t)info->size;
	if(end > out_size)
		end = out_size;
	if(start >= end)
		return false;
	size_t width = (size_t)(f->crop_right - f->crop_left);
	size_t height = (size_t)(f->crop_bottom - f->crop_top);
	size_t stride = (size_t)f->stride;
	size_t first = start + (size_t)f->crop_top * stride + (size_t)f->crop_left;
	size_t last = first + (height - 1) * stride + width;
	if(last > end)
	{
		/* Arabellek biçimin söylediğinden küçük: okumak sınır dışına taşardı. */
		static atomic_bool logged = false;
		if(!atomic_exchange(&logged, true))
			CHIAKI_LOGE(decoder->log, "Video decoder: output buffer too small (%zu < %zu); frames skipped", end, last);
		return false;
	}
	size_t chroma_width = width / 2;
	size_t chroma_height = height / 2;
	if(!ensure_frame_buffer(decoder, env, width * height + 2 * chroma_width * chroma_height))
		return false;
	const uint8_t *src = base + first;
	uint8_t *dst = decoder->frame_ptr;
	for(size_t y = 0; y < height; y++)
		memcpy(dst + y * width, src + y * stride, width);
	decoder->frame_chroma = copy_chroma(decoder, base, start, end, width, height);
	if(f->full_range)
		limit_range(dst, width * height, decoder->frame_chroma ? 2 * chroma_width * chroma_height : 0);
	return true;
}

static void deliver_frame(CouchSubsVideoDecoder *decoder, JNIEnv *env)
{
	CouchSubsOutputFormat *f = &decoder->format;
	jint width = f->crop_right - f->crop_left;
	jint height = f->crop_bottom - f->crop_top;
	(*env)->CallVoidMethod(env, decoder->frame_listener, decoder->on_frame, decoder->frame_buffer, width, height, width,
			(jint)f->color_format, (jboolean)decoder->frame_chroma);
	if((*env)->ExceptionCheck(env))
		(*env)->ExceptionClear(env);
	atomic_fetch_add(&decoder->frames_out, 1);
}

static void *output_thread_func(void *user)
{
	CouchSubsVideoDecoder *decoder = user;
	JNIEnv *env = NULL;
	bool attached = false;
	if(decoder->vm)
	{
		JavaVMAttachArgs args = { JNI_VERSION_1_6, "CouchSubs video", NULL };
		if((*decoder->vm)->AttachCurrentThread(decoder->vm, &env, &args) == JNI_OK)
			attached = true;
		else
		{
			env = NULL;
			CHIAKI_LOGE(decoder->log, "Video decoder: output thread could not attach to the VM");
		}
	}
	while(!atomic_load(&decoder->shutdown_output))
	{
		AMediaCodecBufferInfo info;
		ssize_t status = AMediaCodec_dequeueOutputBuffer(decoder->codec, &info, 100000);
		if(status >= 0)
		{
			bool copied = false;
			chiaki_mutex_lock(&decoder->output_mutex);
			if(!atomic_load(&decoder->shutdown_output))
			{
				if(env && info.size > 0)
					copied = copy_luma(decoder, env, (size_t)status, &info);
				/* Yüzey yok: render=false, arabellek yalnız geri verilir. */
				AMediaCodec_releaseOutputBuffer(decoder->codec, (size_t)status, false);
			}
			chiaki_mutex_unlock(&decoder->output_mutex);
			/* Kopya Java'nın arabelleğinde: dinleyici çözücünün belleğine dokunmaz. */
			if(copied)
				deliver_frame(decoder, env);
			if(info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM)
				break;
			/* Kilit yalnız sayaç sıfırlanacaksa alınır: giriş tarafı kilidi başlık için 500 ms'ye kadar tutabilir. */
			if(info.size > 0 && decoder->codec_errors)
			{
				chiaki_mutex_lock(&decoder->codec_mutex);
				decoder->codec_errors = 0;
				chiaki_mutex_unlock(&decoder->codec_mutex);
			}
			if(decoder->format.known && !decoder->format.supported && !decoder->software)
				atomic_store(&decoder->unsupported_output, true);
		}
		else if(status == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED)
		{
			chiaki_mutex_lock(&decoder->output_mutex);
			if(!atomic_load(&decoder->shutdown_output))
				read_output_format(decoder);
			chiaki_mutex_unlock(&decoder->output_mutex);
			if(decoder->format.known && !decoder->format.supported && !decoder->software)
				atomic_store(&decoder->unsupported_output, true);
		}
		else
		{
			/* TRY_AGAIN_LATER (-1) ve arabellek (-3) değişimi olağan; daha küçükse çözücü hatası.
			 * Hata durumundaki çözücü hemen döner: dönerek işlemciyi yakmasın diye kısa beklenir. */
			bool failed = status < AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED;
			if(!failed)
				continue;
			chiaki_mutex_lock(&decoder->codec_mutex);
			if(!atomic_load(&decoder->shutdown_output))
				decoder->codec_errors++;
			chiaki_mutex_unlock(&decoder->codec_mutex);
			usleep(10000);
		}
	}
	if(env)
	{
		if(decoder->frame_buffer)
			(*env)->DeleteGlobalRef(env, decoder->frame_buffer);
		decoder->frame_buffer = NULL;
		decoder->frame_ptr = NULL;
		decoder->frame_capacity = 0;
	}
	if(attached)
		(*decoder->vm)->DetachCurrentThread(decoder->vm);
	return NULL;
}
