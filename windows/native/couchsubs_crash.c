/* SPDX-License-Identifier: AGPL-3.0-only */
/* Çökme kaydı (yalnız Windows): süreç yerel bir hatayla (erişim ihlali gibi) kapanırken küçük bir döküm (.dmp) ve
 * yanına metin özeti (.txt) bırakır. Dosyalar yalnız kullanıcının bilgisayarında kalır; hiçbir yere gönderilmez.
 *
 * Neden yerel kodda: .NET, yönetilen kodda ya da P/Invoke altındaki yerel kodda olan erişim ihlalinde süreci
 * RaiseFailFastException ile kapatır; bu yol SetUnhandledExceptionFilter'ı hiç çağırmaz. Hatayı görebilen tek yer ilk
 * şans vektörlü işleyicidir, o da hatanın olduğu iş parçacığında çalışır: iş parçacığı yönetilen koddayken C#'a
 * (UnmanagedCallersOnly) girilemez, .NET süreci orada kendisi kapatır. Bu yüzden işleyici düz C'dir.
 *
 * İşleyici hatalı iş parçacığında yalnız bir olay kurar ve bekler; özet ve döküm önceden açılmış ayrı bir iş
 * parçacığında yazılır (yığın taşmasında hatalı iş parçacığında yer yoktur). Özet önce yazılır ve bellek ayırmaz;
 * döküm (dbghelp, bellek ayırır) yazılamasa da özet kalır. */

#include "couchsubs_native.h"

#ifdef _WIN32

#ifndef PSAPI_VERSION
#define PSAPI_VERSION 2 /* EnumProcessModules ve ötekiler kernel32'den (K32...), psapi.dll gerekmez */
#endif
#include <windows.h>
#include <psapi.h>

#ifndef LOAD_LIBRARY_SEARCH_SYSTEM32
#define LOAD_LIBRARY_SEARCH_SYSTEM32 0x00000800
#endif

#define CS_CRASH_MAX_PER_PROCESS 3
#define CS_CRASH_MAX_MODULES 512
#define CS_CRASH_STACK_WORDS 512
#define CS_CRASH_STACK_HITS 32
#define CS_CRASH_MAX_DUMP_BYTES (64LL * 1024 * 1024)
#define CS_CRASH_LOW_ADDRESS 0x10000
/* MiniDumpNormal | MiniDumpWithUnloadedModules | MiniDumpWithThreadInfo: yığınlar, modüller, boşaltılmış modüller. */
#define CS_CRASH_DUMP_TYPE (0x00000000 | 0x00000020 | 0x00001000)
#define CS_CLR_EXCEPTION 0xE0434352u

/* dbghelp.h'deki MINIDUMP_EXCEPTION_INFORMATION (4 bayta hizalı). */
#pragma pack(push, 4)
typedef struct {
	DWORD thread_id;
	EXCEPTION_POINTERS *pointers;
	BOOL client_pointers;
} cs_dump_exception;
#pragma pack(pop)

typedef BOOL (WINAPI *cs_write_dump_fn)(HANDLE process, DWORD pid, HANDLE file, int type,
		cs_dump_exception *exception, void *user_stream, void *callback);

static wchar_t cs_crash_dir[600];
static char cs_crash_header[2048];
static DWORD cs_crash_header_len;
static cs_write_dump_fn cs_crash_write_dump;
static HANDLE cs_crash_request, cs_crash_done;
static DWORD cs_crash_worker_id;
static SRWLOCK cs_crash_lock = SRWLOCK_INIT;
static LPTOP_LEVEL_EXCEPTION_FILTER cs_crash_previous;
static LONG cs_crash_installed;

/* İşleyiciden yazıcıya (cs_crash_lock altında). */
static EXCEPTION_POINTERS *cs_crash_pointers;
static DWORD cs_crash_thread;
static int cs_crash_unhandled;
static int cs_crash_append;

/* Son yazılan kayıt: aynı hata işlenmeden ikinci kez gelirse yeni kayıt açılmaz, özete satır eklenir. */
static int cs_crash_count;
static DWORD cs_crash_last_code, cs_crash_last_thread;
static void *cs_crash_last_address;
static wchar_t cs_crash_last_summary[700];

/* --- Bellek ayırmayan metin yazıcı --- */

typedef struct {
	char text[4096];
	DWORD length;
	HANDLE file;
} cs_out;

static void cs_out_flush(cs_out *out)
{
	DWORD written;
	if(out->length && out->file != INVALID_HANDLE_VALUE)
		WriteFile(out->file, out->text, out->length, &written, NULL);
	out->length = 0;
}

static void cs_out_bytes(cs_out *out, const char *text, DWORD length)
{
	for(DWORD i = 0; i < length; i++)
	{
		if(out->length == sizeof(out->text))
			cs_out_flush(out);
		out->text[out->length++] = text[i];
	}
}

static void cs_out_str(cs_out *out, const char *text)
{
	DWORD length = 0;
	while(text[length])
		length++;
	cs_out_bytes(out, text, length);
}

static void cs_out_hex(cs_out *out, unsigned long long value, int digits)
{
	char text[18];
	text[0] = '0';
	text[1] = 'x';
	for(int i = 0; i < digits; i++)
	{
		unsigned int nibble = (unsigned int)(value >> ((digits - 1 - i) * 4)) & 0xF;
		text[2 + i] = (char)(nibble < 10 ? '0' + nibble : 'A' + nibble - 10);
	}
	cs_out_bytes(out, text, (DWORD)(2 + digits));
}

static void cs_out_dec(cs_out *out, unsigned long long value, int min_digits)
{
	char text[24];
	int at = sizeof(text);
	do
	{
		text[--at] = (char)('0' + value % 10);
		value /= 10;
		min_digits--;
	} while(value || min_digits > 0);
	cs_out_bytes(out, text + at, (DWORD)(sizeof(text) - at));
}

static void cs_out_wide(cs_out *out, const wchar_t *text)
{
	char utf8[1600];
	int length = WideCharToMultiByte(CP_UTF8, 0, text, -1, utf8, sizeof(utf8), NULL, NULL);
	if(length > 1)
		cs_out_bytes(out, utf8, (DWORD)(length - 1));
}

static void cs_wide_append(wchar_t *target, size_t capacity, const wchar_t *text)
{
	size_t at = 0;
	while(at < capacity - 1 && target[at])
		at++;
	while(at < capacity - 1 && *text)
		target[at++] = *text++;
	target[at] = 0;
}

static void cs_wide_append_dec(wchar_t *target, size_t capacity, unsigned int value, int digits)
{
	wchar_t text[12];
	int at = 11;
	text[at] = 0;
	do
	{
		text[--at] = (wchar_t)(L'0' + value % 10);
		value /= 10;
		digits--;
	} while((value || digits > 0) && at > 0);
	cs_wide_append(target, capacity, text + at);
}

/* --- Modüller --- */

typedef struct {
	HMODULE handles[CS_CRASH_MAX_MODULES];
	DWORD count;
} cs_modules;

static void cs_modules_read(cs_modules *modules)
{
	DWORD needed = 0;
	modules->count = 0;
	if(EnumProcessModules(GetCurrentProcess(), modules->handles, sizeof(modules->handles), &needed))
	{
		modules->count = needed / sizeof(HMODULE);
		if(modules->count > CS_CRASH_MAX_MODULES)
			modules->count = CS_CRASH_MAX_MODULES;
	}
}

/* Adresin düştüğü modül; yoksa -1. */
static int cs_modules_find(const cs_modules *modules, unsigned long long address, unsigned long long *offset)
{
	for(DWORD i = 0; i < modules->count; i++)
	{
		MODULEINFO info;
		if(!GetModuleInformation(GetCurrentProcess(), modules->handles[i], &info, sizeof(info)))
			continue;
		unsigned long long base = (unsigned long long)(ULONG_PTR)info.lpBaseOfDll;
		if(address >= base && address < base + info.SizeOfImage)
		{
			if(offset)
				*offset = address - base;
			return (int)i;
		}
	}
	return -1;
}

static const wchar_t *cs_base_name(const wchar_t *path)
{
	const wchar_t *name = path;
	for(const wchar_t *at = path; *at; at++)
		if(*at == L'\\' || *at == L'/')
			name = at + 1;
	return name;
}

static void cs_out_module_at(cs_out *out, const cs_modules *modules, unsigned long long address)
{
	unsigned long long offset = 0;
	int index = cs_modules_find(modules, address, &offset);
	wchar_t path[MAX_PATH * 2];
	if(index < 0 || !GetModuleFileNameExW(GetCurrentProcess(), modules->handles[index], path, sizeof(path) / sizeof(path[0])))
	{
		cs_out_str(out, "modül yok (adres yüklü hiçbir modüle düşmüyor)");
		return;
	}
	cs_out_wide(out, cs_base_name(path));
	cs_out_str(out, "+");
	cs_out_hex(out, offset, 8);
}

static int cs_same_name(const wchar_t *a, const wchar_t *b)
{
	for(;; a++, b++)
	{
		wchar_t x = *a >= L'A' && *a <= L'Z' ? (wchar_t)(*a + 32) : *a;
		wchar_t y = *b >= L'A' && *b <= L'Z' ? (wchar_t)(*b + 32) : *b;
		if(x != y)
			return 0;
		if(!x)
			return 1;
	}
}

/* Adres .NET'in kendi kodunda değil, düz yerel bir modülde mi. Yönetilen kodda (JIT kodu hiçbir modülde değildir;
 * önceden derlenmiş derlemelerin CLR başlığı vardır) ve coreclr'ın yardımcılarında boş göstericiye erişim sıradan
 * NullReferenceException'dır, çökme değil. */
static int cs_address_is_plain_native(unsigned long long address)
{
	cs_modules modules; /* hatalı iş parçacığında, kilitsiz çağrılır: paylaşılan bellek kullanılmaz */
	cs_modules_read(&modules);
	int index = cs_modules_find(&modules, address, NULL);
	if(index < 0)
		return 0;
	wchar_t path[MAX_PATH * 2];
	if(GetModuleFileNameExW(GetCurrentProcess(), modules.handles[index], path, sizeof(path) / sizeof(path[0])))
	{
		const wchar_t *name = cs_base_name(path);
		if(cs_same_name(name, L"coreclr.dll") || cs_same_name(name, L"clrjit.dll"))
			return 0;
	}
	const unsigned char *base = (const unsigned char *)modules.handles[index];
	IMAGE_DOS_HEADER dos;
	IMAGE_NT_HEADERS nt;
	SIZE_T read = 0;
	if(!ReadProcessMemory(GetCurrentProcess(), base, &dos, sizeof(dos), &read) || read != sizeof(dos) || dos.e_magic != IMAGE_DOS_SIGNATURE)
		return 1;
	if(!ReadProcessMemory(GetCurrentProcess(), base + dos.e_lfanew, &nt, sizeof(nt), &read) || read != sizeof(nt) || nt.Signature != IMAGE_NT_SIGNATURE)
		return 1;
	if(nt.OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR)
		return 1;
	return nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR].VirtualAddress == 0;
}

/* --- Özet ve döküm (yazıcı iş parçacığında) --- */

static const char *cs_crash_code_name(DWORD code)
{
	switch(code)
	{
		case EXCEPTION_ACCESS_VIOLATION: return "erişim ihlali";
		case EXCEPTION_IN_PAGE_ERROR: return "bellek sayfası okunamadı";
		case EXCEPTION_ILLEGAL_INSTRUCTION: return "geçersiz komut";
		case EXCEPTION_PRIV_INSTRUCTION: return "ayrıcalıklı komut";
		case EXCEPTION_STACK_OVERFLOW: return "yığın taşması";
		case EXCEPTION_INT_DIVIDE_BY_ZERO: return "sıfıra bölme";
		case 0xE06D7363: return "C++ istisnası";
		default: return "yerel istisna";
	}
}

static void cs_crash_write_summary(cs_out *out, const wchar_t *dump_name, const SYSTEMTIME *now)
{
	static cs_modules modules;
	const EXCEPTION_RECORD *record = cs_crash_pointers->ExceptionRecord;
	const CONTEXT *context = cs_crash_pointers->ContextRecord;
	cs_modules_read(&modules);

	cs_out_str(out, "CouchSubs çökme kaydı\r\n");
	cs_out_str(out, "Bu dosya ve yanındaki .dmp yalnız bu bilgisayarda durur; CouchSubs bunları hiçbir yere göndermez.\r\n");
	cs_out_bytes(out, cs_crash_header, cs_crash_header_len);
	cs_out_str(out, "Zaman: ");
	cs_out_dec(out, now->wYear, 4); cs_out_str(out, "-"); cs_out_dec(out, now->wMonth, 2); cs_out_str(out, "-"); cs_out_dec(out, now->wDay, 2);
	cs_out_str(out, " "); cs_out_dec(out, now->wHour, 2); cs_out_str(out, ":"); cs_out_dec(out, now->wMinute, 2); cs_out_str(out, ":"); cs_out_dec(out, now->wSecond, 2);
	cs_out_str(out, "\r\nSüreç: ");
	cs_out_dec(out, GetCurrentProcessId(), 1);
	cs_out_str(out, "\r\nİş parçacığı: ");
	cs_out_dec(out, cs_crash_thread, 1);
	cs_out_str(out, "\r\nİstisna kodu: ");
	cs_out_hex(out, record->ExceptionCode, 8);
	cs_out_str(out, " (");
	cs_out_str(out, cs_crash_code_name(record->ExceptionCode));
	cs_out_str(out, ")\r\nİstisna adresi: ");
	cs_out_hex(out, (unsigned long long)(ULONG_PTR)record->ExceptionAddress, 16);
	cs_out_str(out, "\r\nModül: ");
	cs_out_module_at(out, &modules, (unsigned long long)(ULONG_PTR)record->ExceptionAddress);
	cs_out_str(out, "\r\n");
	if((record->ExceptionCode == EXCEPTION_ACCESS_VIOLATION || record->ExceptionCode == EXCEPTION_IN_PAGE_ERROR) && record->NumberParameters >= 2)
	{
		ULONG_PTR kind = record->ExceptionInformation[0];
		cs_out_str(out, "Erişim: ");
		cs_out_str(out, kind == 0 ? "okuma " : kind == 1 ? "yazma " : kind == 8 ? "yürütme " : "bilinmiyor ");
		cs_out_hex(out, (unsigned long long)record->ExceptionInformation[1], 16);
		cs_out_str(out, "\r\n");
	}
	cs_out_str(out, cs_crash_unhandled ? "İşlenmedi: evet\r\n" : "Aşama: ilk şans\r\n");

#if defined(__x86_64__) || defined(_M_X64)
	if(context)
	{
		static const char *names[] = { "RIP", "RSP", "RBP", "RAX", "RBX", "RCX", "RDX", "RSI", "RDI", "R8", "R9", "R10", "R11", "R12", "R13", "R14", "R15" };
		unsigned long long values[] = { context->Rip, context->Rsp, context->Rbp, context->Rax, context->Rbx, context->Rcx, context->Rdx,
			context->Rsi, context->Rdi, context->R8, context->R9, context->R10, context->R11, context->R12, context->R13, context->R14, context->R15 };
		cs_out_str(out, "Yazmaçlar:");
		for(int i = 0; i < (int)(sizeof(values) / sizeof(values[0])); i++)
		{
			cs_out_str(out, i % 4 == 0 ? "\r\n  " : " ");
			cs_out_str(out, names[i]);
			cs_out_str(out, "=");
			cs_out_hex(out, values[i], 16);
		}
		/* Hatalı komutun baytları: JIT kodu hiçbir modülde değildir, döküm de onu içermez; komut buradan çözülür
		 * (hangi yazmaç adres, hangisi sıra; GitHub #903). "|" RIP'in yeridir. */
		cs_out_str(out, "\r\nKomut baytları (RIP-16 | RIP+32):\r\n  ");
		static unsigned char code[48];
		SIZE_T code_read = 0;
		int code_start = 16;
		if(!ReadProcessMemory(GetCurrentProcess(), (const void *)(ULONG_PTR)(context->Rip - 16), code, sizeof(code), &code_read)
				|| code_read != sizeof(code))
		{
			/* RIP'in önü okunamayan sayfada: yalnız RIP'ten sonrası. */
			code_start = 0;
			if(!ReadProcessMemory(GetCurrentProcess(), (const void *)(ULONG_PTR)context->Rip, code, 32, &code_read))
				code_read = 0;
		}
		if(!code_read)
			cs_out_str(out, "(okunamadı)");
		for(SIZE_T i = 0; i < code_read; i++)
		{
			static const char digits[] = "0123456789ABCDEF";
			char text[3] = { digits[code[i] >> 4], digits[code[i] & 0xF], ' ' };
			if((int)i == code_start)
				cs_out_str(out, "| ");
			cs_out_bytes(out, text, 3);
		}
		/* Yığındaki, yüklü bir modülün içine düşen değerler: dönüş adresleri büyük olasılıkla bunlardır. Döküm
		 * paylaşılamasa da hatanın hangi bileşenlerden geçtiği buradan görülür. */
		cs_out_str(out, "\r\nYığındaki modül adresleri:\r\n");
		static unsigned long long words[CS_CRASH_STACK_WORDS];
		SIZE_T read = 0;
		int hits = 0;
		ReadProcessMemory(GetCurrentProcess(), (const void *)(ULONG_PTR)context->Rsp, words, sizeof(words), &read);
		for(SIZE_T i = 0; i < read / sizeof(words[0]) && hits < CS_CRASH_STACK_HITS; i++)
		{
			if(cs_modules_find(&modules, words[i], NULL) < 0)
				continue;
			cs_out_str(out, "  ");
			cs_out_module_at(out, &modules, words[i]);
			cs_out_str(out, "\r\n");
			hits++;
		}
		if(!hits)
			cs_out_str(out, "  (yok)\r\n");
	}
#else
	(void)context;
#endif

	cs_out_str(out, "Yüklü modüller:\r\n");
	for(DWORD i = 0; i < modules.count; i++)
	{
		MODULEINFO info;
		wchar_t path[MAX_PATH * 2];
		if(!GetModuleInformation(GetCurrentProcess(), modules.handles[i], &info, sizeof(info))
				|| !GetModuleFileNameExW(GetCurrentProcess(), modules.handles[i], path, sizeof(path) / sizeof(path[0])))
			continue;
		cs_out_str(out, "  ");
		cs_out_hex(out, (unsigned long long)(ULONG_PTR)info.lpBaseOfDll, 16);
		cs_out_str(out, " ");
		cs_out_hex(out, info.SizeOfImage, 8);
		cs_out_str(out, " ");
		cs_out_wide(out, path);
		cs_out_str(out, "\r\n");
	}
	cs_out_str(out, "Döküm: ");
	cs_out_wide(out, dump_name);
	cs_out_str(out, "\r\n");
	cs_out_flush(out);
}

static void cs_crash_write_record(void)
{
	static cs_out out;
	SYSTEMTIME now;
	wchar_t name[80], dump_path[700];
	const EXCEPTION_RECORD *record = cs_crash_pointers->ExceptionRecord;

	if(cs_crash_append)
	{
		/* Az önce kaydedilen hata işlenmedi: süreç kapanıyor. */
		out.length = 0;
		out.file = CreateFileW(cs_crash_last_summary, FILE_APPEND_DATA, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
		cs_out_str(&out, "İşlenmedi: evet\r\n");
		cs_out_flush(&out);
		if(out.file != INVALID_HANDLE_VALUE)
			CloseHandle(out.file);
		return;
	}

	GetLocalTime(&now);
	name[0] = 0;
	cs_wide_append(name, 80, L"cokme-");
	cs_wide_append_dec(name, 80, now.wYear, 4);
	cs_wide_append_dec(name, 80, now.wMonth, 2);
	cs_wide_append_dec(name, 80, now.wDay, 2);
	cs_wide_append(name, 80, L"-");
	cs_wide_append_dec(name, 80, now.wHour, 2);
	cs_wide_append_dec(name, 80, now.wMinute, 2);
	cs_wide_append_dec(name, 80, now.wSecond, 2);
	cs_wide_append(name, 80, L"-");
	cs_wide_append_dec(name, 80, GetCurrentProcessId(), 1);
	cs_wide_append(name, 80, L"-");
	cs_wide_append_dec(name, 80, (unsigned int)cs_crash_count, 1);

	cs_crash_last_summary[0] = 0;
	cs_wide_append(cs_crash_last_summary, 700, cs_crash_dir);
	cs_wide_append(cs_crash_last_summary, 700, L"\\");
	cs_wide_append(cs_crash_last_summary, 700, name);
	cs_wide_append(cs_crash_last_summary, 700, L".txt");
	dump_path[0] = 0;
	cs_wide_append(dump_path, 700, cs_crash_dir);
	cs_wide_append(dump_path, 700, L"\\");
	cs_wide_append(dump_path, 700, name);
	cs_wide_append(dump_path, 700, L".dmp");
	cs_wide_append(name, 80, L".dmp");

	cs_crash_last_code = record->ExceptionCode;
	cs_crash_last_address = record->ExceptionAddress;
	cs_crash_last_thread = cs_crash_thread;
	cs_crash_count++;

	CreateDirectoryW(cs_crash_dir, NULL);
	out.length = 0;
	out.file = CreateFileW(cs_crash_last_summary, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
	if(out.file == INVALID_HANDLE_VALUE)
		return;
	cs_crash_write_summary(&out, name, &now);
	FlushFileBuffers(out.file);

	/* Döküm: özet diskte; buradan sonrası takılsa da (ör. bellek yığını kilitliyken) kayıt kalır. */
	const char *result = "Döküm durumu: yazılamadı (dbghelp yok)\r\n";
	if(cs_crash_write_dump)
	{
		HANDLE dump = CreateFileW(dump_path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
		result = "Döküm durumu: yazılamadı (dosya açılamadı)\r\n";
		if(dump != INVALID_HANDLE_VALUE)
		{
			cs_dump_exception exception = { cs_crash_thread, cs_crash_pointers, FALSE };
			BOOL ok = cs_crash_write_dump(GetCurrentProcess(), GetCurrentProcessId(), dump, CS_CRASH_DUMP_TYPE, &exception, NULL, NULL);
			LARGE_INTEGER size;
			size.QuadPart = 0;
			GetFileSizeEx(dump, &size);
			CloseHandle(dump);
			if(!ok || size.QuadPart == 0)
			{
				DeleteFileW(dump_path);
				result = "Döküm durumu: yazılamadı\r\n";
			}
			else if(size.QuadPart > CS_CRASH_MAX_DUMP_BYTES)
			{
				DeleteFileW(dump_path);
				result = "Döküm durumu: çok büyük olduğu için silindi\r\n";
			}
			else
				result = "Döküm durumu: yazıldı\r\n";
		}
	}
	cs_out_str(&out, result);
	cs_out_flush(&out);
	CloseHandle(out.file);
}

static DWORD WINAPI cs_crash_worker(LPVOID parameter)
{
	(void)parameter;
	for(;;)
	{
		WaitForSingleObject(cs_crash_request, INFINITE);
		cs_crash_write_record();
		SetEvent(cs_crash_done);
	}
	return 0;
}

/* Hatalı iş parçacığında: kaydı yazıcıya bırakır ve bitmesini bekler. */
static void cs_crash_capture(EXCEPTION_POINTERS *info, int unhandled)
{
	if(GetCurrentThreadId() == cs_crash_worker_id)
		return; /* yazıcının kendi hatası: yeniden kayıt denenmez */
	AcquireSRWLockExclusive(&cs_crash_lock);
	const EXCEPTION_RECORD *record = info->ExceptionRecord;
	int same = cs_crash_count > 0 && cs_crash_last_code == record->ExceptionCode
		&& cs_crash_last_address == record->ExceptionAddress && cs_crash_last_thread == GetCurrentThreadId();
	if((same && unhandled) || (!same && cs_crash_count < CS_CRASH_MAX_PER_PROCESS))
	{
		cs_crash_pointers = info;
		cs_crash_thread = GetCurrentThreadId();
		cs_crash_unhandled = unhandled;
		cs_crash_append = same;
		ResetEvent(cs_crash_done);
		SetEvent(cs_crash_request);
		WaitForSingleObject(cs_crash_done, 30000);
	}
	ReleaseSRWLockExclusive(&cs_crash_lock);
}

/* İlk şans: .NET'in süreci RaiseFailFastException ile kapattığı hatalar başka hiçbir yerde görülemez. */
static LONG CALLBACK cs_crash_vectored(EXCEPTION_POINTERS *info)
{
	if(!info || !info->ExceptionRecord)
		return EXCEPTION_CONTINUE_SEARCH;
	const EXCEPTION_RECORD *record = info->ExceptionRecord;
	switch(record->ExceptionCode)
	{
		case EXCEPTION_ACCESS_VIOLATION:
		{
			unsigned long long ip = (unsigned long long)(ULONG_PTR)record->ExceptionAddress;
			/* Boş göstericiye erişim yönetilen kodda NullReferenceException'dır (yakalanır, süreç sürer). Yalnız düz yerel
			 * modüldeki ya da boş adrese atlamış olan sayılır. */
			if(record->NumberParameters >= 2 && record->ExceptionInformation[1] < CS_CRASH_LOW_ADDRESS
					&& ip >= CS_CRASH_LOW_ADDRESS && !cs_address_is_plain_native(ip))
				return EXCEPTION_CONTINUE_SEARCH;
			break;
		}
		case EXCEPTION_IN_PAGE_ERROR:
		case EXCEPTION_ILLEGAL_INSTRUCTION:
		case EXCEPTION_PRIV_INSTRUCTION:
		case EXCEPTION_STACK_OVERFLOW:
			break;
		default:
			return EXCEPTION_CONTINUE_SEARCH;
	}
	cs_crash_capture(info, 0);
	return EXCEPTION_CONTINUE_SEARCH;
}

/* İkinci şans: hata hiçbir yerde işlenmedi (yerel iş parçacıkları). Yönetilen istisnalar hata.log'a zaten yazılır. */
static LONG WINAPI cs_crash_unhandled_filter(EXCEPTION_POINTERS *info)
{
	if(info && info->ExceptionRecord && info->ExceptionRecord->ExceptionCode != CS_CLR_EXCEPTION)
		cs_crash_capture(info, 1);
	return cs_crash_previous ? cs_crash_previous(info) : EXCEPTION_CONTINUE_SEARCH;
}

CS_API int cs_crash_install(const uint16_t *directory, const char *header)
{
	if(!directory || !directory[0])
		return 1;
	if(InterlockedCompareExchange(&cs_crash_installed, 1, 0) != 0)
		return 0;
	cs_crash_dir[0] = 0;
	cs_wide_append(cs_crash_dir, sizeof(cs_crash_dir) / sizeof(cs_crash_dir[0]), (const wchar_t *)directory);
	cs_crash_header_len = 0;
	if(header)
		while(header[cs_crash_header_len] && cs_crash_header_len < sizeof(cs_crash_header))
		{
			cs_crash_header[cs_crash_header_len] = header[cs_crash_header_len];
			cs_crash_header_len++;
		}
	/* dbghelp yalnız Windows'un kendi klasöründen ve şimdi yüklenir: çökme anında DLL yüklenmez. */
	HMODULE dbghelp = LoadLibraryExW(L"dbghelp.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
	if(dbghelp)
		cs_crash_write_dump = (cs_write_dump_fn)(void *)GetProcAddress(dbghelp, "MiniDumpWriteDump");
	cs_crash_request = CreateEventW(NULL, FALSE, FALSE, NULL);
	cs_crash_done = CreateEventW(NULL, TRUE, FALSE, NULL);
	HANDLE worker = cs_crash_request && cs_crash_done ? CreateThread(NULL, 0, cs_crash_worker, NULL, 0, &cs_crash_worker_id) : NULL;
	if(!worker)
	{
		InterlockedExchange(&cs_crash_installed, 0);
		return -1;
	}
	CloseHandle(worker);
	AddVectoredExceptionHandler(1, cs_crash_vectored);
	cs_crash_previous = SetUnhandledExceptionFilter(cs_crash_unhandled_filter);
	return 0;
}

/* --- Deneme (yalnız test argümanıyla çağrılır) --- */

static volatile unsigned long long cs_crash_test_address = 0x0000000012345678ULL;

static DWORD WINAPI cs_crash_test_thread(LPVOID parameter)
{
	int kind = (int)(INT_PTR)parameter;
	if(kind == 2)
	{
		/* Boşaltılmış geri çağrıya atlama: bırakılmış belleğe çağrı; adres hiçbir modüle düşmez. */
		void *memory = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
		void (*volatile freed)(void) = (void (*)(void))memory;
		VirtualFree(memory, 0, MEM_RELEASE);
		freed();
	}
	else
	{
		volatile int *target = (volatile int *)(ULONG_PTR)cs_crash_test_address;
		*target = 1;
	}
	return 0;
}

CS_API void cs_crash_test(int kind)
{
	if(kind == 0)
	{
		cs_crash_test_thread((LPVOID)(INT_PTR)0);
		return;
	}
	HANDLE thread = CreateThread(NULL, 0, cs_crash_test_thread, (LPVOID)(INT_PTR)kind, 0, NULL);
	if(thread)
		WaitForSingleObject(thread, INFINITE);
}

#else

CS_API int cs_crash_install(const uint16_t *directory, const char *header)
{
	(void)directory;
	(void)header;
	return -1;
}

CS_API void cs_crash_test(int kind)
{
	(void)kind;
}

#endif
