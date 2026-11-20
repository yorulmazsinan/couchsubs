// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// chiaki-ng android/app/src/main/cpp/video-decoder.h'den uyarlandı (Florian Märkl ve chiaki-ng katkıcıları).
// Değişiklik: çözücü yüzeysiz (ByteBuffer çıkış) çalışır; karenin parlaklık (Y) düzlemi yerel tarafta okunur ve
// Java'nın sahip olduğu bir doğrudan arabelleğe kopyalanıp dinleyiciye verilir (ImageReader ve Image.getPlanes yok).

#ifndef COUCHSUBS_VIDEO_DECODER_H
#define COUCHSUBS_VIDEO_DECODER_H

#include <jni.h>

#include <chiaki/thread.h>
#include <chiaki/log.h>

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct AMediaCodec AMediaCodec;

/* Çözücünün çıkış biçimi (yalnız çıkış iş parçacığı okur/yazar). */
typedef struct couchsubs_output_format_t
{
	bool known;
	/* Y düzlemi doğrusal ve ilk düzlem olan bir YUV 4:2:0 biçimi. */
	bool supported;
	int32_t color_format;
	int32_t width;
	int32_t height;
	int32_t stride;
	int32_t slice_height;
	/* Görünür alan (dahil değil: right/bottom bir fazlası). */
	int32_t crop_left;
	int32_t crop_top;
	int32_t crop_right;
	int32_t crop_bottom;
} CouchSubsOutputFormat;

typedef struct couchsubs_video_decoder_t
{
	ChiakiLog *log;
	ChiakiMutex codec_mutex;
	/* Çıkış arabelleğine erişim ile çözücünün durdurulmasını sıralar: AMediaCodec_stop() arabellek okunurken
	 * çağrılmaz (okunan bellek elden gitmesin). Kilit sırası: codec_mutex, sonra output_mutex. */
	ChiakiMutex output_mutex;
	AMediaCodec *codec;
	uint64_t timestamp_cur;
	ChiakiThread output_thread;
	/* Çıkış iş parçacığı dursun (kilitsiz de okunur). */
	atomic_bool shutdown_output;
	int32_t target_width;
	int32_t target_height;
	/* Dinleyiciye verilen kare sayısı (tanı için; başka iş parçacığı okur). */
	_Atomic uint64_t frames_out;
	/* Art arda çözücü hatası; eşiği geçerse yazılım çözücüye geçilir. */
	uint32_t codec_errors;
	/* Çıkış iş parçacığı okunamayan bir kare biçimi gördü: donanım çözücü bırakılır. */
	atomic_bool unsupported_output;
	/* Yazılım çözücü (c2.android / OMX.google) kullanılıyor. */
	bool software;
	/* PS5'in akış başlığı (SPS/PPS). libchiaki onu yalnız bir kez verir ve dönüş değerine bakmaz; çözücü yeniden
	 * kurulunca (yazılım çözücüye geçiş) yeni çözücüye önce bu verilir, yoksa hiç kare çıkmaz. */
	uint8_t *header;
	size_t header_size;
	/* Açık çözücüye başlık henüz verilmedi. */
	bool header_pending;

	/* Kare dinleyicisi: onFrame(ByteBuffer, int width, int height, int rowStride, int colorFormat, boolean chroma).
	 * chroma: arabellekte Y düzleminin ardından yarım çözünürlüklü U ve V düzlemleri de var (stil örneklemesi için). */
	JavaVM *vm;
	jobject frame_listener;
	jmethodID on_frame;
	/* Yalnız çıkış iş parçacığı kullanır. */
	CouchSubsOutputFormat format;
	/* Java'nın sahip olduğu doğrudan arabellek (genel başvuru): Java tarafı başvuruyu tutsa bile bellek GC'nindir,
	 * oturum bitince elden gitmez. */
	jobject frame_buffer;
	uint8_t *frame_ptr;
	size_t frame_capacity;
	/* Son kopyalanan karede renk düzlemleri de var. */
	bool frame_chroma;
} CouchSubsVideoDecoder;

ChiakiErrorCode couchsubs_video_decoder_init(CouchSubsVideoDecoder *decoder, ChiakiLog *log, int32_t width, int32_t height);
/* H.264 çözücüyü başlatır; kareler frame_listener'a verilir. Başarısızsa false. swap: üreticiye göre seçilen çözücü
 * türünün tersiyle başla (önceki oturumda hiç görüntü gelmediyse). */
bool couchsubs_video_decoder_start(CouchSubsVideoDecoder *decoder, JNIEnv *env, jobject frame_listener, bool swap);
void couchsubs_video_decoder_fini(CouchSubsVideoDecoder *decoder, JNIEnv *env);
bool couchsubs_video_decoder_video_sample(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user);

#endif
