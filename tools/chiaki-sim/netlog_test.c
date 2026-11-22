// SPDX-License-Identifier: AGPL-3.0-only
//
// chiaki-takion-stats.patch'in sınaması: yamalı congestioncontrol.c'nin GERÇEK iş parçacığı işlevi sahte saat, sahte
// paket sayaçları ve sahte gönderme tamponuyla sürülür. Beklenenler:
//   - temiz ağda (kayıp yok, yeniden gönderme yok) hiç satır yazılmaz;
//   - kayıp varsa 5 sn'de bir tek "Network in the last ..." satırı: PS5'ten gelmeyen paket oranı (PS5'e bildirilen
//     %5 tavanından önceki gerçek oran) ve PS5'e yeniden gönderilen / hiç onaylanmayan güvenilir paket sayısı;
//   - PS5'e bildirilen kayıp eskisi gibi packet_loss_max'ta kırpılır.
// Çalıştırma: tools/chiaki-sim/netlog.sh

#include <chiaki/congestioncontrol.h>
#include <chiaki/time.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t now_us;
uint64_t chiaki_time_now_monotonic_us(void) { return now_us; }

static char lines[64][512];
static int line_count;
void chiaki_log(ChiakiLog *log, ChiakiLogLevel level, const char *fmt, ...)
{
	(void)log;
	if(level != CHIAKI_LOG_INFO || line_count >= 64)
		return;
	va_list args;
	va_start(args, fmt);
	vsnprintf(lines[line_count++], sizeof(lines[0]), fmt, args);
	va_end(args);
}

// Her 200 ms'lik turda ne olacağı: PS5'ten gelen ve kaybolan paket, PS5'e yeniden gönderilen ve bırakılan paket.
typedef struct { uint64_t received, lost; uint32_t resent, given_up; } Tick;
static const Tick *ticks;
static int tick_count, tick_index;
static ChiakiTakion fake_takion;
static ChiakiTakionCongestionPacket sent[256];
static int sent_count;

void chiaki_thread_set_affinity(ChiakiThreadName name) { (void)name; }
ChiakiErrorCode chiaki_bool_pred_cond_init(ChiakiBoolPredCond *cond) { (void)cond; return CHIAKI_ERR_SUCCESS; }
ChiakiErrorCode chiaki_bool_pred_cond_fini(ChiakiBoolPredCond *cond) { (void)cond; return CHIAKI_ERR_SUCCESS; }
ChiakiErrorCode chiaki_bool_pred_cond_lock(ChiakiBoolPredCond *cond) { (void)cond; return CHIAKI_ERR_SUCCESS; }
ChiakiErrorCode chiaki_bool_pred_cond_unlock(ChiakiBoolPredCond *cond) { (void)cond; return CHIAKI_ERR_SUCCESS; }
ChiakiErrorCode chiaki_bool_pred_cond_signal(ChiakiBoolPredCond *cond) { (void)cond; return CHIAKI_ERR_SUCCESS; }
// Bekleme: saat 200 ms ilerler; senaryo bitince "durdur" sinyali.
ChiakiErrorCode chiaki_bool_pred_cond_timedwait(ChiakiBoolPredCond *cond, uint64_t timeout_ms)
{
	(void)cond;
	if(tick_index >= tick_count)
		return CHIAKI_ERR_SUCCESS;
	now_us += timeout_ms * 1000;
	// Gönderme tamponu kendi iş parçacığında sayar; bu turdaki yeniden gönderme ve bırakma burada eklenir.
	fake_takion.send_buffer.resent += ticks[tick_index].resent;
	fake_takion.send_buffer.given_up += ticks[tick_index].given_up;
	return CHIAKI_ERR_TIMEOUT;
}
void chiaki_packet_stats_get(ChiakiPacketStats *stats, bool reset, uint64_t *received, uint64_t *lost)
{
	(void)stats; (void)reset;
	*received = ticks[tick_index].received;
	*lost = ticks[tick_index].lost;
	tick_index++;
}
ChiakiErrorCode chiaki_takion_send_congestion(ChiakiTakion *takion, ChiakiTakionCongestionPacket *packet)
{
	(void)takion;
	if(sent_count < 256)
		sent[sent_count++] = *packet;
	return CHIAKI_ERR_SUCCESS;
}
static ChiakiThreadFunc thread_func;
static void *thread_arg;
ChiakiErrorCode chiaki_thread_create(ChiakiThread *thread, ChiakiThreadFunc func, void *arg)
{
	(void)thread;
	thread_func = func;
	thread_arg = arg;
	return CHIAKI_ERR_SUCCESS;
}
ChiakiErrorCode chiaki_thread_set_name(ChiakiThread *thread, const char *name) { (void)thread; (void)name; return CHIAKI_ERR_SUCCESS; }
ChiakiErrorCode chiaki_thread_join(ChiakiThread *thread, void **retval) { (void)thread; (void)retval; return CHIAKI_ERR_SUCCESS; }

static void run(const Tick *scenario, int count)
{
	ticks = scenario;
	tick_count = count;
	tick_index = 0;
	line_count = 0;
	sent_count = 0;
	now_us = 1000000;
	memset(&fake_takion, 0, sizeof(fake_takion));
	fake_takion.send_buffer.resent = 7; // önceki oturumdan kalan sayılar farka girmez
	fake_takion.send_buffer.given_up = 3;
	ChiakiCongestionControl control;
	chiaki_congestion_control_start(&control, &fake_takion, NULL, 0.05);
	thread_func(thread_arg); // senaryo bitene kadar döner
}

static int failures;
static void expect(int ok, const char *what)
{
	if(!ok)
	{
		printf("HATA: %s\n", what);
		for(int i = 0; i < line_count; i++)
			printf("  satir: %s\n", lines[i]);
		failures++;
	}
}

int main(void)
{
	// 1) Temiz ağ, 20 sn: hiç satır yok; PS5'e kayıpsız bildirim gider.
	static Tick clean[100];
	for(int i = 0; i < 100; i++)
		clean[i] = (Tick){ 300, 0, 0, 0 };
	run(clean, 100);
	expect(line_count == 0, "temiz agda satir yazilmamali");
	expect(sent_count == 100 && sent[0].received == 300 && sent[0].lost == 0, "temiz agda PS5'e kayipsiz bildirim gitmeli");

	// 2) GitHub #593'teki gibi: PS5'ten gelenlerin %87'si kayıp, PS5'e giden paketler hiç onaylanmıyor (10 sn).
	static Tick broken[50];
	for(int i = 0; i < 50; i++)
		broken[i] = (Tick){ 13, 87, 5, (i % 5 == 0) ? 1 : 0 };
	run(broken, 50);
	expect(line_count == 2, "10 sn kayipta 5 sn'de bir, toplam 2 satir olmali");
	expect(line_count > 0 && strstr(lines[0], "Network in the last 5000 ms: from the console 2175 of 2500 packets lost (87.0%)") != NULL,
		"ilk satir PS5'ten gelen kaybi gercek oranla (87%) yazmali");
	expect(line_count > 0 && strstr(lines[0], "to the console 125 packets sent again and 5 never acknowledged") != NULL,
		"ilk satir PS5'e giden yeniden gonderme ve onaysiz paketi (onceki oturumun sayilari haric) yazmali");
	// PS5'e bildirilen kayıp %5'te kırpılır (chiaki-ng ile aynı): 100 paketin 5'i.
	expect(sent_count == 50 && sent[0].lost == 5 && sent[0].received == 95, "PS5'e bildirilen kayip packet_loss_max'ta kirpilmali");

	// 3) Kısa kayıp patlaması, sonra temiz: yalnız patlamanın olduğu 5 sn için bir satır.
	static Tick burst[75];
	for(int i = 0; i < 75; i++)
		burst[i] = i == 3 ? (Tick){ 200, 100, 2, 0 } : (Tick){ 300, 0, 0, 0 };
	run(burst, 75);
	expect(line_count == 1, "tek patlamada tek satir olmali");
	expect(line_count > 0 && strstr(lines[0], "from the console 100 of 7500 packets lost (1.3%)") != NULL, "patlama satirinda oran");

	// 4) Yalnız yukarı yön bozuk (PS5'ten her şey geliyor, PS5'e giden onaylanmıyor): yine yazılır.
	static Tick uplink[25];
	for(int i = 0; i < 25; i++)
		uplink[i] = (Tick){ 300, 0, 5, i == 24 ? 1 : 0 };
	run(uplink, 25);
	expect(line_count == 1 && strstr(lines[0], "0 of 7500 packets lost (0.0%), to the console 125 packets sent again and 1 never acknowledged") != NULL,
		"yalniz yukari yon bozukken de satir yazilmali");

	if(failures)
		return 1;
	printf("netlog: 4 senaryo gecti\n");
	return 0;
}
