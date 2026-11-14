/* SPDX-License-Identifier: AGPL-3.0-only */
/* Kotlin'deki com.couchsubs.mobile.remoteplay.NativeBridge'in yerel tarafı: libchiaki ile PS5 arama, uyandırma,
 * kayıt ve görüntü akışı. Davranış Windows'taki windows/native/couchsubs_native.c ile aynıdır (1080p30 H.264,
 * ses kapalı, kol girdisi yok); çözme FFmpeg yerine Android MediaCodec'le, ImageReader'ın yüzeyine yapılır.
 * JNI kalıpları chiaki-ng'nin android/app/src/main/cpp/chiaki-jni.c dosyasından uyarlandı. */

#include <jni.h>
#include <android/log.h>

#include <chiaki/common.h>
#include <chiaki/discovery.h>
#include <chiaki/log.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>
#include <chiaki/thread.h>
#include <chiaki/time.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "video-decoder.h"

#define TAG "CouchSubsChiaki"
#define JNI_FCN(name) Java_com_couchsubs_mobile_remoteplay_NativeBridge_##name
#define LOG_MASK (CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING | CHIAKI_LOG_INFO)
#define MAX_ERRORS 8
#define MAX_CONSOLES 32

static JavaVM *global_vm;

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved)
{
	(void)reserved;
	global_vm = vm;
	return JNI_VERSION_1_6;
}

/* --- Günlük --- */

static int android_level(ChiakiLogLevel level)
{
	if(level & CHIAKI_LOG_ERROR) return ANDROID_LOG_ERROR;
	if(level & CHIAKI_LOG_WARNING) return ANDROID_LOG_WARN;
	if(level & CHIAKI_LOG_INFO) return ANDROID_LOG_INFO;
	return ANDROID_LOG_DEBUG;
}

/* Hata satırlarını biriktiren günlük: Kotlin tarafı kullanıcıya anlatılacak nedeni bunlardan çıkarır (Windows'taki
 * Registration.FailureFrom). */
typedef struct {
	ChiakiMutex mutex;
	char *errors[MAX_ERRORS];
	int count;
	uint32_t reason;
} cs_log_sink;

static const char cs_reason_prefix[] = "Reported Application Reason: 0x";

static void cs_sink_cb(ChiakiLogLevel level, const char *message, void *user)
{
	if(!message)
		return;
	__android_log_write(android_level(level), TAG, message);
	cs_log_sink *sink = user;
	if(!sink)
		return;
	chiaki_mutex_lock(&sink->mutex);
	/* PS5'in red nedeni olaya değil yalnız günlüğe yazılır. */
	const char *found = strstr(message, cs_reason_prefix);
	if(found)
	{
		char *end = NULL;
		unsigned long value = strtoul(found + sizeof(cs_reason_prefix) - 1, &end, 16);
		if(end != found + sizeof(cs_reason_prefix) - 1)
			sink->reason = (uint32_t)value;
	}
	if((level & CHIAKI_LOG_ERROR) && sink->count < MAX_ERRORS)
		sink->errors[sink->count++] = strdup(message);
	chiaki_mutex_unlock(&sink->mutex);
}

static void cs_sink_init(cs_log_sink *sink)
{
	memset(sink, 0, sizeof(*sink));
	chiaki_mutex_init(&sink->mutex, false);
}

static void cs_sink_fini(cs_log_sink *sink)
{
	for(int i = 0; i < sink->count; i++)
		free(sink->errors[i]);
	sink->count = 0;
	chiaki_mutex_fini(&sink->mutex);
}

/* Hata satırları alt alta, Java dizesi olarak (yoksa NULL). */
static jstring cs_sink_errors(JNIEnv *env, cs_log_sink *sink)
{
	chiaki_mutex_lock(&sink->mutex);
	size_t total = 0;
	for(int i = 0; i < sink->count; i++)
		total += strlen(sink->errors[i]) + 1;
	jstring result = NULL;
	if(total > 0)
	{
		char *joined = calloc(1, total + 1);
		if(joined)
		{
			for(int i = 0; i < sink->count; i++)
			{
				strcat(joined, sink->errors[i]);
				strcat(joined, "\n");
			}
			/* NewStringUTF yalnız geçerli (değiştirilmiş) UTF-8 kabul eder; ASCII dışı baytlar '?' olur. */
			for(char *c = joined; *c; c++)
				if(*c & 0x80) *c = '?';
			result = (*env)->NewStringUTF(env, joined);
			free(joined);
		}
	}
	chiaki_mutex_unlock(&sink->mutex);
	return result;
}

/* --- Başlatma --- */

static pthread_once_t cs_once = PTHREAD_ONCE_INIT;
static int cs_init_result = -1;

static void cs_init_once(void)
{
	cs_init_result = (int)chiaki_lib_init();
}

JNIEXPORT jint JNICALL JNI_FCN(init)(JNIEnv *env, jclass cls)
{
	(void)env; (void)cls;
	pthread_once(&cs_once, cs_init_once);
	return cs_init_result;
}

/* --- PS5 arama ve uyandırma --- */

typedef struct {
	ChiakiMutex mutex;
	char *found[MAX_CONSOLES];
	int count;
} cs_discover_ctx;

static void cs_discovery_cb(ChiakiDiscoveryHost *host, void *user)
{
	cs_discover_ctx *ctx = user;
	if(!host || !host->host_addr || !chiaki_discovery_host_is_ps5(host))
		return;
	char line[256];
	snprintf(line, sizeof(line), "%s\t%s\t%d", host->host_addr, host->host_name ? host->host_name : "PS5",
			host->state == CHIAKI_DISCOVERY_HOST_STATE_READY ? 1 : 0);
	for(char *c = line; *c; c++)
		if(*c & 0x80) *c = '?';
	chiaki_mutex_lock(&ctx->mutex);
	bool seen = false;
	for(int i = 0; i < ctx->count; i++)
		if(strncmp(ctx->found[i], line, strcspn(line, "\t")) == 0 && ctx->found[i][strcspn(line, "\t")] == '\t')
		{
			/* Aynı PS5'in son yanıtı geçerlidir (uyanınca durum değişir). */
			free(ctx->found[i]);
			ctx->found[i] = strdup(line);
			seen = true;
		}
	if(!seen && ctx->count < MAX_CONSOLES)
		ctx->found[ctx->count++] = strdup(line);
	chiaki_mutex_unlock(&ctx->mutex);
}

static void cs_sleep_ms(unsigned int ms)
{
	struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
	nanosleep(&ts, NULL);
}

/* Verilen adreslere PS5 araması gönderir; yanıtlar "adres\tad\tuyanık(0/1)" dizeleri. Süre dolana kadar bloklar. */
JNIEXPORT jobjectArray JNICALL JNI_FCN(discover)(JNIEnv *env, jclass cls, jobjectArray targets, jint timeout_ms)
{
	(void)cls;
	jclass string_class = (*env)->FindClass(env, "java/lang/String");
	jsize target_count = targets ? (*env)->GetArrayLength(env, targets) : 0;
	if(target_count <= 0)
		return (*env)->NewObjectArray(env, 0, string_class, NULL);

	ChiakiLog log;
	chiaki_log_init(&log, CHIAKI_LOG_ERROR, cs_sink_cb, NULL);
	ChiakiDiscovery discovery;
	if(chiaki_discovery_init(&discovery, &log, AF_INET) != CHIAKI_ERR_SUCCESS)
		return NULL;

	cs_discover_ctx ctx;
	memset(&ctx, 0, sizeof(ctx));
	chiaki_mutex_init(&ctx.mutex, false);
	ChiakiDiscoveryThread thread;
	if(chiaki_discovery_thread_start(&thread, &discovery, cs_discovery_cb, &ctx) != CHIAKI_ERR_SUCCESS)
	{
		chiaki_discovery_fini(&discovery);
		chiaki_mutex_fini(&ctx.mutex);
		return NULL;
	}

	struct sockaddr_in *addresses = calloc((size_t)target_count, sizeof(struct sockaddr_in));
	int address_count = 0;
	for(jsize i = 0; addresses && i < target_count; i++)
	{
		jstring target = (*env)->GetObjectArrayElement(env, targets, i);
		if(!target)
			continue;
		const char *text = (*env)->GetStringUTFChars(env, target, NULL);
		struct sockaddr_in *address = &addresses[address_count];
		address->sin_family = AF_INET;
		address->sin_port = htons(CHIAKI_DISCOVERY_PORT_PS5);
		if(inet_pton(AF_INET, text, &address->sin_addr) == 1)
			address_count++;
		(*env)->ReleaseStringUTFChars(env, target, text);
		(*env)->DeleteLocalRef(env, target);
	}

	char version[] = CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5;
	ChiakiDiscoveryPacket packet;
	memset(&packet, 0, sizeof(packet));
	packet.cmd = CHIAKI_DISCOVERY_CMD_SRCH;
	packet.protocol_version = version;
	/* Yanıt kaçmasın diye arama süre dolana kadar yinelenir. */
	uint64_t end = chiaki_time_now_monotonic_ms() + (uint64_t)(timeout_ms > 0 ? timeout_ms : 0);
	do
	{
		for(int i = 0; i < address_count; i++)
			chiaki_discovery_send(&discovery, &packet, (struct sockaddr *)&addresses[i], sizeof(struct sockaddr_in));
		cs_sleep_ms(500);
	} while(chiaki_time_now_monotonic_ms() < end);

	chiaki_discovery_thread_stop(&thread);
	chiaki_discovery_fini(&discovery);
	free(addresses);

	jobjectArray result = (*env)->NewObjectArray(env, ctx.count, string_class, NULL);
	for(int i = 0; i < ctx.count; i++)
	{
		jstring line = (*env)->NewStringUTF(env, ctx.found[i]);
		(*env)->SetObjectArrayElement(env, result, i, line);
		(*env)->DeleteLocalRef(env, line);
		free(ctx.found[i]);
	}
	chiaki_mutex_fini(&ctx.mutex);
	return result;
}

JNIEXPORT jint JNICALL JNI_FCN(wake)(JNIEnv *env, jclass cls, jstring host_string, jlong credential)
{
	(void)cls;
	ChiakiLog log;
	chiaki_log_init(&log, CHIAKI_LOG_ERROR, cs_sink_cb, NULL);
	const char *host = (*env)->GetStringUTFChars(env, host_string, NULL);
	ChiakiErrorCode err = chiaki_discovery_wakeup(&log, NULL, host, (uint64_t)credential, true);
	(*env)->ReleaseStringUTFChars(env, host_string, host);
	return err == CHIAKI_ERR_SUCCESS ? 0 : (int)err;
}

/* --- Kayıt --- */

typedef struct {
	ChiakiMutex mutex;
	ChiakiCond cond;
	bool done;
	ChiakiRegistEventType type;
	bool has_host;
	ChiakiRegisteredHost host;
} cs_regist_ctx;

static void cs_regist_event(ChiakiRegistEvent *event, void *user)
{
	cs_regist_ctx *ctx = user;
	chiaki_mutex_lock(&ctx->mutex);
	if(!ctx->done)
	{
		ctx->type = event ? event->type : CHIAKI_REGIST_EVENT_TYPE_FINISHED_FAILED;
		if(event && event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS && event->registered_host)
		{
			ctx->host = *event->registered_host;
			ctx->has_host = true;
		}
		ctx->done = true;
	}
	chiaki_mutex_unlock(&ctx->mutex);
	chiaki_cond_signal(&ctx->cond);
}

static bool cs_regist_done(void *user)
{
	return ((cs_regist_ctx *)user)->done;
}

static void set_int(JNIEnv *env, jobject obj, const char *name, jint value)
{
	jclass cls = (*env)->GetObjectClass(env, obj);
	(*env)->SetIntField(env, obj, (*env)->GetFieldID(env, cls, name, "I"), value);
}

static void set_object(JNIEnv *env, jobject obj, const char *name, const char *sig, jobject value)
{
	jclass cls = (*env)->GetObjectClass(env, obj);
	(*env)->SetObjectField(env, obj, (*env)->GetFieldID(env, cls, name, sig), value);
}

static jbyteArray byte_array(JNIEnv *env, const void *data, size_t size)
{
	jbyteArray array = (*env)->NewByteArray(env, (jsize)size);
	(*env)->SetByteArrayRegion(env, array, 0, (jsize)size, (const jbyte *)data);
	return array;
}

/* PS5'in "Cihazı Bağla" kodu ile kayıt (bloklar, en çok ~30 sn). Sonuç outcome'a yazılır:
 * code 0 başarı, 1 PS5 reddetti ya da hata (reason, errors), 2 yanıt yok (zaman aşımı), -1 başlatılamadı. */
JNIEXPORT void JNICALL JNI_FCN(register)(JNIEnv *env, jclass cls, jstring host_string, jbyteArray account_array,
		jint pin, jobject outcome)
{
	(void)cls;
	int result = -1;
	if(!host_string || !account_array || (*env)->GetArrayLength(env, account_array) != CHIAKI_PSN_ACCOUNT_ID_SIZE)
	{
		set_int(env, outcome, "code", result);
		return;
	}
	cs_log_sink sink;
	cs_sink_init(&sink);
	ChiakiLog log;
	chiaki_log_init(&log, LOG_MASK, cs_sink_cb, &sink);

	cs_regist_ctx ctx;
	memset(&ctx, 0, sizeof(ctx));
	chiaki_mutex_init(&ctx.mutex, false);
	chiaki_cond_init(&ctx.cond);

	const char *host = (*env)->GetStringUTFChars(env, host_string, NULL);
	ChiakiRegistInfo info;
	memset(&info, 0, sizeof(info));
	info.target = CHIAKI_TARGET_PS5_1;
	info.host = host;
	info.broadcast = false;
	info.psn_online_id = NULL;
	(*env)->GetByteArrayRegion(env, account_array, 0, CHIAKI_PSN_ACCOUNT_ID_SIZE, (jbyte *)info.psn_account_id);
	info.pin = (uint32_t)pin;
	info.console_pin = 0;
	info.holepunch_info = NULL;
	info.rudp = NULL;

	ChiakiRegist regist;
	ChiakiErrorCode err = chiaki_regist_start(&regist, &log, &info, cs_regist_event, &ctx);
	if(err == CHIAKI_ERR_SUCCESS)
	{
		chiaki_mutex_lock(&ctx.mutex);
		err = chiaki_cond_timedwait_pred(&ctx.cond, &ctx.mutex, 30000, cs_regist_done, &ctx);
		if(err == CHIAKI_ERR_TIMEOUT)
		{
			chiaki_mutex_unlock(&ctx.mutex);
			chiaki_regist_stop(&regist);
			chiaki_mutex_lock(&ctx.mutex);
			chiaki_cond_wait_pred(&ctx.cond, &ctx.mutex, cs_regist_done, &ctx);
		}
		chiaki_mutex_unlock(&ctx.mutex);
		chiaki_regist_fini(&regist);

		if(ctx.type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS && ctx.has_host)
		{
			char nickname[sizeof(ctx.host.server_nickname) + 1];
			memcpy(nickname, ctx.host.server_nickname, sizeof(ctx.host.server_nickname));
			nickname[sizeof(ctx.host.server_nickname)] = '\0';
			for(char *c = nickname; *c; c++)
				if(*c & 0x80) *c = '?';
			set_object(env, outcome, "nickname", "Ljava/lang/String;", (*env)->NewStringUTF(env, nickname));
			set_object(env, outcome, "registKey", "[B", byte_array(env, ctx.host.rp_regist_key, sizeof(ctx.host.rp_regist_key)));
			set_object(env, outcome, "morning", "[B", byte_array(env, ctx.host.rp_key, sizeof(ctx.host.rp_key)));
			result = 0;
		}
		else if(ctx.type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED)
			result = 2;
		else
			result = 1;
	}
	(*env)->ReleaseStringUTFChars(env, host_string, host);

	chiaki_mutex_lock(&sink.mutex);
	uint32_t reason = sink.reason;
	chiaki_mutex_unlock(&sink.mutex);
	set_int(env, outcome, "code", result);
	set_int(env, outcome, "reason", (jint)reason);
	set_object(env, outcome, "errors", "Ljava/lang/String;", cs_sink_errors(env, &sink));
	chiaki_cond_fini(&ctx.cond);
	chiaki_mutex_fini(&ctx.mutex);
	cs_sink_fini(&sink);
}

/* --- Görüntü akışı --- */

/* Kotlin'deki StreamSession.Native ile aynı değerler. */
enum { CS_EVENT_CONNECTED = 1, CS_EVENT_LOGIN_PIN = 2, CS_EVENT_QUIT = 3 };
enum { CS_QUIT_STOPPED = 1, CS_QUIT_IN_USE = 2, CS_QUIT_REFUSED = 3, CS_QUIT_NETWORK = 4, CS_QUIT_OTHER = 5 };

typedef struct {
	ChiakiSession session;
	ChiakiLog log;
	cs_log_sink sink;
	CouchSubsVideoDecoder decoder;
	jobject listener;
	jmethodID on_event;
} cs_session;

static int cs_quit_reason(ChiakiQuitReason reason)
{
	switch(reason)
	{
		case CHIAKI_QUIT_REASON_STOPPED:
			return CS_QUIT_STOPPED;
		case CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_IN_USE:
			return CS_QUIT_IN_USE;
		case CHIAKI_QUIT_REASON_SESSION_REQUEST_CONNECTION_REFUSED:
		case CHIAKI_QUIT_REASON_CTRL_CONNECTION_REFUSED:
		case CHIAKI_QUIT_REASON_PSN_REGIST_FAILED:
			return CS_QUIT_REFUSED;
		case CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_DISCONNECTED:
		case CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_SHUTDOWN:
		case CHIAKI_QUIT_REASON_CTRL_CONNECT_FAILED:
		case CHIAKI_QUIT_REASON_STREAM_CONNECTION_UNKNOWN:
			return CS_QUIT_NETWORK;
		default:
			return CS_QUIT_OTHER;
	}
}

/* libchiaki'nin oturum iş parçacığında çağrılır; o iş parçacığı JVM'e bağlanıp ayrılır. */
static void cs_session_event(ChiakiEvent *event, void *user)
{
	cs_session *session = user;
	if(!event)
		return;
	int type = 0, reason = 0;
	const char *text = NULL;
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			type = CS_EVENT_CONNECTED;
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			type = CS_EVENT_LOGIN_PIN;
			break;
		case CHIAKI_EVENT_QUIT:
			type = CS_EVENT_QUIT;
			reason = cs_quit_reason(event->quit.reason);
			text = reason == CS_QUIT_OTHER ? chiaki_quit_reason_string(event->quit.reason) : event->quit.reason_str;
			break;
		default:
			return;
	}
	JNIEnv *env = NULL;
	bool attached = false;
	if((*global_vm)->GetEnv(global_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK)
	{
		if((*global_vm)->AttachCurrentThread(global_vm, &env, NULL) != JNI_OK)
			return;
		attached = true;
	}
	char *clean = text ? strdup(text) : NULL;
	if(clean)
		for(char *c = clean; *c; c++)
			if(*c & 0x80) *c = '?';
	jstring text_java = clean ? (*env)->NewStringUTF(env, clean) : NULL;
	(*env)->CallVoidMethod(env, session->listener, session->on_event, (jint)type, (jint)reason, text_java);
	if((*env)->ExceptionCheck(env))
		(*env)->ExceptionClear(env);
	if(text_java)
		(*env)->DeleteLocalRef(env, text_java);
	free(clean);
	if(attached)
		(*global_vm)->DetachCurrentThread(global_vm);
}

static void cs_session_free(JNIEnv *env, cs_session *session)
{
	couchsubs_video_decoder_fini(&session->decoder);
	if(session->listener)
		(*env)->DeleteGlobalRef(env, session->listener);
	cs_sink_fini(&session->sink);
	free(session);
}

/* Oturumu başlatır; 0 dönerse lastError'a nedeni yazar. listener.onEvent(type, reason, text) libchiaki'nin iş
 * parçacığından çağrılır. Görüntü surface'e (ImageReader) çözülür. */
JNIEXPORT jlong JNICALL JNI_FCN(sessionStart)(JNIEnv *env, jclass cls, jstring host_string, jbyteArray regist_key_array,
		jbyteArray morning_array, jbyteArray account_array, jint width, jint height, jobject surface, jobject listener,
		jobject outcome)
{
	(void)cls;
	cs_session *session = calloc(1, sizeof(cs_session));
	if(!session)
		return 0;
	cs_sink_init(&session->sink);
	chiaki_log_init(&session->log, LOG_MASK, cs_sink_cb, &session->sink);
	session->listener = (*env)->NewGlobalRef(env, listener);
	session->on_event = (*env)->GetMethodID(env, (*env)->GetObjectClass(env, listener), "onEvent", "(IILjava/lang/String;)V");

	if(couchsubs_video_decoder_init(&session->decoder, &session->log, width, height) != CHIAKI_ERR_SUCCESS
			|| !couchsubs_video_decoder_start(&session->decoder, env, surface))
	{
		set_object(env, outcome, "errors", "Ljava/lang/String;", (*env)->NewStringUTF(env, "H.264 decoder could not be opened"));
		cs_session_free(env, session);
		return 0;
	}

	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = true;
	const char *host = (*env)->GetStringUTFChars(env, host_string, NULL);
	info.host = host; /* libchiaki adresi oturum açılırken kopyalar */
	jsize key_size = (*env)->GetArrayLength(env, regist_key_array);
	(*env)->GetByteArrayRegion(env, regist_key_array, 0, key_size < (jsize)sizeof(info.regist_key) ? key_size : (jsize)sizeof(info.regist_key),
			(jbyte *)info.regist_key);
	jsize morning_size = (*env)->GetArrayLength(env, morning_array);
	(*env)->GetByteArrayRegion(env, morning_array, 0, morning_size < (jsize)sizeof(info.morning) ? morning_size : (jsize)sizeof(info.morning),
			(jbyte *)info.morning);
	(*env)->GetByteArrayRegion(env, account_array, 0, CHIAKI_PSN_ACCOUNT_ID_SIZE, (jbyte *)info.psn_account_id);
	chiaki_connect_video_profile_preset(&info.video_profile,
			height >= 1080 ? CHIAKI_VIDEO_RESOLUTION_PRESET_1080p : CHIAKI_VIDEO_RESOLUTION_PRESET_720p, CHIAKI_VIDEO_FPS_PRESET_30);
	info.video_profile.codec = CHIAKI_CODEC_H264;
	info.video_profile_auto_downgrade = true;
	info.enable_keyboard = false;
	info.enable_dualsense = false;
	info.audio_video_disabled = CHIAKI_AUDIO_DISABLED;
	info.auto_regist = false;
	info.holepunch_session = NULL;
	info.rudp_sock = NULL;
	info.packet_loss_max = 0.05;
	info.enable_idr_on_fec_failure = true;

	ChiakiErrorCode err = chiaki_session_init(&session->session, &info, &session->log);
	(*env)->ReleaseStringUTFChars(env, host_string, host);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		char line[128];
		snprintf(line, sizeof(line), "Session init failed: %s", chiaki_error_string(err));
		set_object(env, outcome, "errors", "Ljava/lang/String;", (*env)->NewStringUTF(env, line));
		cs_session_free(env, session);
		return 0;
	}
	chiaki_session_set_event_cb(&session->session, cs_session_event, session);
	chiaki_session_set_video_sample_cb(&session->session, couchsubs_video_decoder_video_sample, &session->decoder);
	err = chiaki_session_start(&session->session);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		char line[128];
		snprintf(line, sizeof(line), "Session start failed: %s", chiaki_error_string(err));
		set_object(env, outcome, "errors", "Ljava/lang/String;", (*env)->NewStringUTF(env, line));
		chiaki_session_fini(&session->session);
		cs_session_free(env, session);
		return 0;
	}
	return (jlong)(intptr_t)session;
}

/* Oturumu durdurur ve iş parçacıklarını bekler; sonrasında geri çağrı gelmez. Aynı oturum için bir kez çağrılmalı,
 * oturumun kendi geri çağrısından çağrılmamalı. */
JNIEXPORT void JNICALL JNI_FCN(sessionStop)(JNIEnv *env, jclass cls, jlong ptr)
{
	(void)cls;
	cs_session *session = (cs_session *)(intptr_t)ptr;
	if(!session)
		return;
	chiaki_session_stop(&session->session);
	chiaki_session_join(&session->session);
	chiaki_session_fini(&session->session);
	cs_session_free(env, session);
}

/* Oturumun biriktirdiği hata satırları (yoksa null). */
JNIEXPORT jstring JNICALL JNI_FCN(sessionErrors)(JNIEnv *env, jclass cls, jlong ptr)
{
	(void)cls;
	cs_session *session = (cs_session *)(intptr_t)ptr;
	return session ? cs_sink_errors(env, &session->sink) : NULL;
}

/* Çözücünün yüzeye verdiği kare sayısı (tanı: görüntü geliyor mu). */
JNIEXPORT jlong JNICALL JNI_FCN(sessionFrames)(JNIEnv *env, jclass cls, jlong ptr)
{
	(void)env; (void)cls;
	cs_session *session = (cs_session *)(intptr_t)ptr;
	return session ? (jlong)session->decoder.frames_out : 0;
}
