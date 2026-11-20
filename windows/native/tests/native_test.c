/* SPDX-License-Identifier: AGPL-3.0-only */
/* couchsubs_native için testler. Kullanım: couchsubs_native_test <sample-1080p.h264>
 * (remoteplay/Tests/RemotePlayTests/Fixtures altındaki ffmpeg testsrc2, 6 kare, Annex-B). */

#include "../couchsubs_native.c"

static int failures = 0;

#define CHECK(cond) do { \
	if(!(cond)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } \
} while(0)

/* --- Annex-B'yi PS5'in gönderdiği gibi erişim birimlerine (kare) böler --- */

typedef struct {
	size_t start, end; /* başlangıç kodundan sonraki NAL baytları */
} nal_range;

static size_t find_nals(const uint8_t *data, size_t size, nal_range *out, size_t max)
{
	size_t count = 0;
	size_t i = 0;
	size_t starts[4096];
	while(i + 3 <= size && count < max)
	{
		if(data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
		{
			starts[count++] = i + 3;
			i += 3;
		}
		else
			i++;
	}
	for(size_t n = 0; n < count; n++)
	{
		size_t end = n + 1 < count ? starts[n + 1] - 3 : size;
		if(n + 1 < count && end > starts[n] && data[end - 1] == 0)
			end--;
		out[n].start = starts[n];
		out[n].end = end;
	}
	return count;
}

typedef struct {
	uint8_t *data;
	size_t size;
} unit;

static size_t access_units(const uint8_t *data, size_t size, unit *units, size_t max)
{
	static nal_range nals[4096];
	size_t nal_count = find_nals(data, size, nals, 4096);
	size_t count = 0;
	uint8_t *current = malloc(size + 4 * nal_count + 64);
	size_t current_size = 0;
	bool has_slice = false;
	for(size_t n = 0; n < nal_count; n++)
	{
		int type = data[nals[n].start] & 0x1f;
		bool is_slice = type == 1 || type == 5;
		if((type == 7 || type == 9 || is_slice) && has_slice && count < max)
		{
			units[count].data = current;
			units[count].size = current_size;
			count++;
			current = malloc(size + 4 * nal_count + 64);
			current_size = 0;
			has_slice = false;
		}
		static const uint8_t code[4] = { 0, 0, 0, 1 };
		memcpy(current + current_size, code, 4);
		current_size += 4;
		memcpy(current + current_size, data + nals[n].start, nals[n].end - nals[n].start);
		current_size += nals[n].end - nals[n].start;
		has_slice = has_slice || is_slice;
	}
	if(current_size && count < max)
	{
		units[count].data = current;
		units[count].size = current_size;
		count++;
	}
	else
		free(current);
	return count;
}

static uint8_t *read_file(const char *path, size_t *size)
{
	FILE *f = fopen(path, "rb");
	if(!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long length = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *data = malloc((size_t)length + AV_INPUT_BUFFER_PADDING_SIZE);
	if(data && fread(data, 1, (size_t)length, f) != (size_t)length)
	{
		free(data);
		data = NULL;
	}
	fclose(f);
	*size = (size_t)length;
	return data;
}

/* --- Testler --- */

static void check_frame(cs_decoder *decoder)
{
	CHECK(cs_decoder_convert(decoder, decoder->frame));
	CHECK(decoder->width == 1920);
	CHECK(decoder->height == 1080);
	CHECK(decoder->stride >= 1920 * 4);
	/* testsrc2 karesi tek renk değildir; dönüşüm gerçekten piksel yazmış olmalı. */
	const uint8_t *row = decoder->bgra + (size_t)decoder->stride * 540;
	bool varied = false;
	for(int x = 4; x < 1920 * 4; x += 4)
		if(row[x] != row[0] || row[x + 1] != row[1] || row[x + 2] != row[2])
			varied = true;
	CHECK(varied);
	CHECK(row[3] == 255);
	av_frame_unref(decoder->frame);
}

/* Çözücüde bekleyen kareleri boşaltır; çıkan kare sayısı. */
static int flush(cs_decoder *decoder)
{
	int frames = 0;
	avcodec_send_packet(decoder->codec, NULL);
	while(avcodec_receive_frame(decoder->codec, decoder->frame) == 0)
	{
		frames++;
		check_frame(decoder);
	}
	return frames;
}

static void test_reason_is_read_from_log(void)
{
	uint32_t reason = 0;
	CHECK(cs_reason_from_log("Reported Application Reason: 0x80108b02 (Invalid PSN ID)", &reason));
	CHECK(reason == 0x80108b02);
	CHECK(!cs_reason_from_log("Regist waiting for response", &reason));
	CHECK(!cs_reason_from_log(NULL, &reason));
}

static void test_throttle_thirty_fps_at_four(void)
{
	cs_throttle throttle;
	cs_throttle_init(&throttle, 4);
	int passed = 0;
	uint64_t clock = 0;
	for(int i = 0; i < 30; i++)
	{
		if(cs_throttle_should_pass(&throttle, clock))
			passed++;
		clock += 1000000 / 30;
	}
	CHECK(passed >= 4 && passed <= 5);

	cs_throttle_init(&throttle, 0);
	CHECK(cs_throttle_should_pass(&throttle, 5));
	CHECK(cs_throttle_should_pass(&throttle, 5));
}

static void test_quit_reasons(void)
{
	CHECK(cs_quit_reason(CHIAKI_QUIT_REASON_STOPPED) == CS_QUIT_STOPPED);
	CHECK(cs_quit_reason(CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_IN_USE) == CS_QUIT_IN_USE);
	CHECK(cs_quit_reason(CHIAKI_QUIT_REASON_SESSION_REQUEST_CONNECTION_REFUSED) == CS_QUIT_REFUSED);
	CHECK(cs_quit_reason(CHIAKI_QUIT_REASON_CTRL_CONNECTION_REFUSED) == CS_QUIT_REFUSED);
	CHECK(cs_quit_reason(CHIAKI_QUIT_REASON_PSN_REGIST_FAILED) == CS_QUIT_PSN_REGIST_FAILED);
	CHECK(cs_quit_reason(CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_DISCONNECTED) == CS_QUIT_NETWORK);
	CHECK(cs_quit_reason(CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_SHUTDOWN) == CS_QUIT_NETWORK);
	CHECK(cs_quit_reason(CHIAKI_QUIT_REASON_CTRL_CONNECT_FAILED) == CS_QUIT_NETWORK);
	CHECK(cs_quit_reason(CHIAKI_QUIT_REASON_STREAM_CONNECTION_UNKNOWN) == CS_QUIT_NETWORK);
	CHECK(cs_quit_reason(CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_CRASH) == CS_QUIT_RP_CRASHED);
	CHECK(cs_quit_reason(CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_VERSION_MISMATCH) == CS_QUIT_OTHER);
}

static void test_fixture_decodes(const char *path)
{
	size_t size = 0;
	uint8_t *data = read_file(path, &size);
	CHECK(data != NULL);
	if(!data)
		return;
	unit units[64];
	size_t count = access_units(data, size, units, 64);
	CHECK(count == 6);

	cs_decoder decoder;
	CHECK(cs_decoder_init(&decoder) == 0);
	int frames = 0;
	for(size_t i = 0; i < count; i++)
	{
		int got = cs_decoder_decode(&decoder, units[i].data, units[i].size);
		CHECK(got >= 0);
		if(got == 1)
		{
			frames++;
			check_frame(&decoder);
		}
	}
	/* Kare sırası SPS'teki yeniden sıralama derinliği kadar gecikebilir (örnekte 2; PS5'te 0). */
	CHECK(frames >= 4);
	frames += flush(&decoder);
	CHECK(frames == 6);
	cs_decoder_fini(&decoder);

	/* Yeni bir çözücü yalnız ilk anahtar kareyle de 1080p görüntü üretmeli. */
	CHECK(cs_decoder_init(&decoder) == 0);
	CHECK(cs_decoder_decode(&decoder, units[0].data, units[0].size) >= 0);
	CHECK(flush(&decoder) == 1);
	cs_decoder_fini(&decoder);

	for(size_t i = 0; i < count; i++)
		free(units[i].data);
	free(data);
}

static void test_garbage_does_not_crash(void)
{
	cs_decoder decoder;
	CHECK(cs_decoder_init(&decoder) == 0);
	uint8_t garbage[8 + AV_INPUT_BUFFER_PADDING_SIZE] = { 0, 0, 0, 1, 0x65, 0xff, 0x00, 0x12 };
	CHECK(cs_decoder_decode(&decoder, garbage, 8) <= 0);
	CHECK(cs_decoder_decode(&decoder, NULL, 0) == 0);
	cs_decoder_fini(&decoder);
}

/* --- Oturum yaşam döngüsü --- */

typedef struct {
	ChiakiMutex mutex;
	ChiakiCond cond;
	bool quit;
	int reason;
} quit_wait;

static void on_event(int event, int quit_reason, const char *reason_text, void *user)
{
	(void)reason_text;
	quit_wait *wait = user;
	if(event != CS_EVENT_QUIT)
		return;
	chiaki_mutex_lock(&wait->mutex);
	wait->quit = true;
	wait->reason = quit_reason;
	chiaki_mutex_unlock(&wait->mutex);
	chiaki_cond_signal(&wait->cond);
}

static bool quit_pred(void *user)
{
	return ((quit_wait *)user)->quit;
}

/* Bağlanamayan bir adreste oturum kapanmayı bildirmeli; durdurmak hızlı ve güvenli olmalı. */
static void test_session_to_closed_port_quits_and_stops(void)
{
	quit_wait wait = { 0 };
	chiaki_mutex_init(&wait.mutex, false);
	chiaki_cond_init(&wait.cond);
	uint8_t key[16], morning[16], account[8];
	memset(key, 0x31, sizeof(key));
	memset(morning, 1, sizeof(morning));
	memset(account, 1, sizeof(account));
	cs_session *session = cs_session_start("127.0.0.1", key, morning, account, 15, NULL, on_event, NULL, &wait);
	CHECK(session != NULL);
	if(!session)
		return;
	chiaki_mutex_lock(&wait.mutex);
	chiaki_cond_timedwait_pred(&wait.cond, &wait.mutex, 15000, quit_pred, &wait);
	bool quit = wait.quit;
	chiaki_mutex_unlock(&wait.mutex);
	CHECK(quit);
	CHECK(wait.reason != CS_QUIT_STOPPED);

	uint64_t begin = chiaki_time_now_monotonic_ms();
	cs_session_stop(session);
	CHECK(chiaki_time_now_monotonic_ms() - begin < 2000);
	chiaki_cond_fini(&wait.cond);
	chiaki_mutex_fini(&wait.mutex);
}

/* Bağlanmaya çalışırken durdurmak da güvenli olmalı. */
static void test_stop_right_after_start(void)
{
	uint8_t key[16] = { 0 }, morning[16] = { 0 }, account[8] = { 0 };
	cs_session *session = cs_session_start("127.0.0.1", key, morning, account, 15, NULL, NULL, NULL, NULL);
	CHECK(session != NULL);
	cs_session_stop(session);
}

/* 720p istenen oturum da açılır ve hemen durdurulabilir (bağlantı sık koparsa uygulama 720p ister). */
static void test_stop_right_after_start_720p(void)
{
	uint8_t key[16] = { 0 }, morning[16] = { 0 }, account[8] = { 0 };
	cs_session *session = cs_session_start_ex("127.0.0.1", key, morning, account, 15, 720, NULL, NULL, NULL, NULL);
	CHECK(session != NULL);
	cs_session_stop(session);
}

static void count_console(const char *host, const char *name, int awake, void *user)
{
	(void)host;
	(void)name;
	(void)awake;
	(*(int *)user)++;
}

static void test_discover_returns_after_timeout(void)
{
	const char *targets[] = { "127.0.0.1", "not-an-address" };
	int found = 0;
	uint64_t begin = chiaki_time_now_monotonic_ms();
	CHECK(cs_discover(targets, 2, 600, count_console, &found) == 0);
	uint64_t elapsed = chiaki_time_now_monotonic_ms() - begin;
	CHECK(elapsed >= 500 && elapsed < 3000);
	CHECK(found == 0);
	CHECK(cs_discover(NULL, 0, 100, count_console, &found) != 0);
}

static void count_console_ex(const char *host, const char *name, int awake, const char *titleid, const char *app, void *user)
{
	(void)host;
	(void)name;
	(void)awake;
	(void)titleid;
	(void)app;
	(*(int *)user)++;
}

static void test_discover_ex_returns_after_timeout(void)
{
	const char *targets[] = { "127.0.0.1" };
	int found = 0;
	CHECK(cs_discover_ex(targets, 1, 600, count_console_ex, &found) == 0);
	CHECK(found == 0);
	CHECK(cs_discover_ex(targets, 1, 100, NULL, &found) != 0);
}

int main(int argc, char **argv)
{
	if(argc < 2)
	{
		fprintf(stderr, "usage: %s <sample-1080p.h264>\n", argv[0]);
		return 2;
	}
	CHECK(cs_init() == 0);
	CHECK(cs_init() == 0);
	test_reason_is_read_from_log();
	test_throttle_thirty_fps_at_four();
	test_quit_reasons();
	test_fixture_decodes(argv[1]);
	test_garbage_does_not_crash();
	test_discover_returns_after_timeout();
	test_discover_ex_returns_after_timeout();
	test_session_to_closed_port_quits_and_stops();
	test_stop_right_after_start();
	test_stop_right_after_start_720p();
	if(failures)
	{
		fprintf(stderr, "%d check(s) failed\n", failures);
		return 1;
	}
	printf("all native tests passed\n");
	return 0;
}
