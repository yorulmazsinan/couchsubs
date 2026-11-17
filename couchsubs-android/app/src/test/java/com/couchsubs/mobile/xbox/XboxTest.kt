// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.xbox

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.webrtc.EncodedImage
import org.webrtc.VideoCodecStatus
import org.webrtc.VideoDecoder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.Instant

/** Sahte HTTP: istekleri kaydeder, sırayla ya da adrese göre yanıt verir. */
private class FakeHttp(private val answer: (method: String, url: String, body: String?) -> XboxHttpResponse) : XboxHttp {
    val calls = ArrayList<Triple<String, String, Map<String, String>>>()
    val bodies = ArrayList<String?>()
    override fun request(method: String, url: String, headers: Map<String, String>, body: String?): XboxHttpResponse {
        calls += Triple(method, url, headers)
        bodies += body
        return answer(method, url, body)
    }
}

private fun ok(json: String) = XboxHttpResponse(200, json)

class XboxTokensTest {
    private val now = Instant.parse("2026-11-16T10:00:00Z").toEpochMilli()

    @Test fun userTokenGetsExpiresOnLikeXalNode() {
        val token = XboxUserToken.fromResponse(JSONObject("""{"access_token":"A","refresh_token":"R","expires_in":3600,"token_type":"bearer"}"""), now)
        assertEquals("A", token.accessToken)
        assertEquals("R", token.refreshToken)
        assertEquals("2026-11-16T11:00:00Z", token.json.getString("expires_on"))
        assertEquals(3600, token.secondsValid(now))
        // Saklanan metin geri okunur (Windows'taki userToken JSON'u).
        val restored = XboxUserToken.parse(token.serialize())!!
        assertEquals(now + 3_600_000, restored.expiresOnMs)
    }

    @Test fun refreshKeepsPreviousRefreshTokenWhenMissing() {
        val first = XboxUserToken.fromResponse(JSONObject("""{"access_token":"A","refresh_token":"R","expires_in":10}"""), now)
        val second = XboxUserToken.fromResponse(JSONObject("""{"access_token":"B","expires_in":10}"""), now, first)
        assertEquals("R", second.refreshToken)
    }

    @Test fun windowsStoredTokenParses() {
        val stored = """{"token_type":"Bearer","scope":"xboxlive.signin openid profile offline_access","expires_in":3600,"ext_expires_in":3600,"access_token":"EwA","refresh_token":"M.C5","id_token":"x","expires_on":"2026-11-16T10:30:00.123Z"}"""
        val token = XboxUserToken.parse(stored)!!
        assertEquals(1800, token.secondsValid(now))
        assertNull(XboxUserToken.parse("""{"access_token":"A"}"""))
        assertNull(XboxUserToken.parse("bozuk"))
        assertNull(XboxUserToken.parse(null))
    }

    @Test fun xstsTokenWithSevenFractionDigits() {
        val token = XboxXstsToken.parse(JSONObject("""{"IssueInstant":"2026-11-16T09:00:00.1234567Z","NotAfter":"2026-11-16T10:16:00.1234567Z","Token":"T","DisplayClaims":{"xui":[{"uhs":"123"}]}}"""))
        assertEquals("T", token.token)
        assertEquals("123", token.userHash)
        assertEquals(960, token.secondsValid(now))
    }

    @Test fun homeEndpointPicksDefaultRegion() {
        val body = JSONObject("""{"gsToken":"G","durationInSeconds":14400,"offeringSettings":{"regions":[
            {"name":"WestEurope","baseUri":"https://weu.core.gssv-play-prodxhome.xboxlive.com/","isDefault":false},
            {"name":"UKSouth","baseUri":"https://uks.core.gssv-play-prodxhome.xboxlive.com","isDefault":true}]}}""")
        val endpoint = XboxHomeEndpoint.parse(body, now)
        assertEquals("https://uks.core.gssv-play-prodxhome.xboxlive.com", endpoint.baseUrl)
        assertEquals("G", endpoint.token)
        assertEquals(now + 14_400_000, endpoint.expiresAtMs)
        val first = XboxHomeEndpoint.parse(JSONObject("""{"gsToken":"G","offeringSettings":{"regions":[{"baseUri":"https://a/","isDefault":false}]}}"""), now)
        assertEquals("https://a", first.baseUrl)
        assertEquals(now + 30 * 60_000, first.expiresAtMs)
        try {
            XboxHomeEndpoint.parse(JSONObject("""{"gsToken":"G","offeringSettings":{"regions":[]}}"""), now)
            fail()
        } catch (error: XboxException) {
            assertEquals(XboxError.SERVICE, error.kind)
        }
    }

    @Test fun deviceCodeAndPollErrors() {
        val code = XboxDeviceCode.parse(JSONObject("""{"user_code":"ABCD1234","device_code":"DC","verification_uri":"https://www.microsoft.com/link","expires_in":900,"interval":0}"""))
        assertEquals("ABCD1234", code.userCode)
        assertEquals(1, code.intervalSeconds)
        assertEquals(DeviceCodePoll.PENDING, DeviceCodePoll.classify(XboxHttpResponse(400, """{"error":"authorization_pending"}""")))
        assertEquals(DeviceCodePoll.SLOW_DOWN, DeviceCodePoll.classify(XboxHttpResponse(400, """{"error":"slow_down"}""")))
        assertEquals(DeviceCodePoll.EXPIRED, DeviceCodePoll.classify(XboxHttpResponse(400, """{"error":"expired_token"}""")))
        assertEquals(DeviceCodePoll.DECLINED, DeviceCodePoll.classify(XboxHttpResponse(400, """{"error":"authorization_declined"}""")))
        assertEquals(DeviceCodePoll.FAILED, DeviceCodePoll.classify(XboxHttpResponse(400, """{"error":"invalid_grant"}""")))
        assertEquals(DeviceCodePoll.PENDING, DeviceCodePoll.classify(XboxHttpResponse(503, "")))
    }

    @Test fun consoleListRequiresStreamingAndRemoteManagement() {
        val list = XboxConsole.parseList(JSONObject("""{"status":{"errorCode":"OK"},"result":[
            {"id":"F4001","name":"Salon","consoleType":"XboxSeriesX","powerState":"ConnectedStandby","consoleStreamingEnabled":true,"remoteManagementEnabled":true},
            {"id":"F4002","name":"Oda","consoleType":"XboxOne","consoleStreamingEnabled":true,"remoteManagementEnabled":false},
            {"name":"kimliksiz"}]}"""))
        assertEquals(2, list.size)
        assertTrue(list[0].streamingEnabled)
        assertEquals("XboxSeriesX", list[0].model)
        assertFalse(list[1].streamingEnabled)
        assertEquals(list[0], XboxConsole.fromJson(list[0].toJson()))
    }
}

class XboxAuthTest {
    private var clock = Instant.parse("2026-11-16T10:00:00Z").toEpochMilli()

    @Test fun deviceCodeFlowWaitsThenSaves() {
        var polls = 0
        val http = FakeHttp { _, url, _ ->
            when {
                url.endsWith("/devicecode") -> ok("""{"user_code":"U","device_code":"D","verification_uri":"https://www.microsoft.com/link","expires_in":900,"interval":5}""")
                url.endsWith("/token") -> if (++polls < 3) XboxHttpResponse(400, """{"error":"authorization_pending"}""")
                    else ok("""{"access_token":"A","refresh_token":"R","expires_in":3600}""")
                else -> error(url)
            }
        }
        var saved: XboxUserToken? = null
        val auth = XboxAuth(http, { clock }, { clock += it }, onUserToken = { saved = it })
        val code = auth.startDeviceCode()
        assertTrue(http.bodies[0]!!.contains("client_id=${XboxAuth.CLIENT_ID}"))
        assertTrue(http.bodies[0]!!.contains("scope=xboxlive.signin+openid+profile+offline_access"))
        val token = auth.pollDeviceCode(code)
        assertEquals("A", token.accessToken)
        assertEquals("A", saved?.accessToken)
        assertTrue(auth.signedIn)
        assertEquals(3, polls)
        assertTrue(http.bodies[1]!!.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
    }

    @Test fun deviceCodePollSurvivesNetworkDrops() {
        // Kullanıcı tarayıcıdayken arka plandaki istek kesilir; giriş bitmemeli, onay gelince tamamlanmalı.
        var polls = 0
        val http = FakeHttp { _, _, _ ->
            when (++polls) {
                1 -> XboxHttpResponse(400, """{"error":"authorization_pending"}""")
                2, 3 -> throw XboxException(XboxError.NETWORK, "Software caused connection abort")
                else -> ok("""{"access_token":"A","refresh_token":"R","expires_in":3600}""")
            }
        }
        val auth = XboxAuth(http, { clock }, { clock += it })
        assertEquals("A", auth.pollDeviceCode(XboxDeviceCode("U", "D", "u", 900, 5)).accessToken)
        assertEquals(4, polls)
    }

    @Test fun deviceCodePollGivesUpOnNetworkAfterExpiry() {
        val http = FakeHttp { _, _, _ -> throw XboxException(XboxError.NETWORK, "offline") }
        val auth = XboxAuth(http, { clock }, { clock += it })
        try {
            auth.pollDeviceCode(XboxDeviceCode("U", "D", "u", 60, 5))
            fail()
        } catch (error: XboxException) {
            assertEquals(XboxError.NETWORK, error.kind)
        }
    }

    @Test fun deviceCodeExpires() {
        val http = FakeHttp { _, _, _ -> XboxHttpResponse(400, """{"error":"expired_token"}""") }
        val auth = XboxAuth(http, { clock }, { clock += it })
        try {
            auth.pollDeviceCode(XboxDeviceCode("U", "D", "u", 900, 5))
            fail()
        } catch (error: XboxException) {
            assertEquals(XboxError.CODE_EXPIRED, error.kind)
        }
    }

    @Test fun chainRefreshesExpiredUserTokenAndCachesXsts() {
        val expired = XboxUserToken.fromResponse(JSONObject("""{"access_token":"OLD","refresh_token":"R","expires_in":30}"""), clock)
        val http = FakeHttp { _, url, body ->
            when {
                url.endsWith("/token") -> ok("""{"access_token":"NEW","refresh_token":"R2","expires_in":3600}""")
                url.contains("user.auth.xboxlive.com") -> {
                    assertTrue(body!!.contains("\"RpsTicket\":\"d=NEW\""))
                    ok("""{"Token":"XBL","NotAfter":"2026-11-30T00:00:00Z","DisplayClaims":{"xui":[{"uhs":"H"}]}}""")
                }
                url.contains("xsts.auth.xboxlive.com") -> ok("""{"Token":"XSTS","NotAfter":"2026-11-17T00:00:00Z","DisplayClaims":{"xui":[{"uhs":"H"}]}}""")
                url.contains("xhome.gssv-play-prod.xboxlive.com/v2/login/user") -> {
                    assertTrue(body!!.contains("\"offeringId\":\"xhome\""))
                    ok("""{"gsToken":"GS","durationInSeconds":14400,"offeringSettings":{"regions":[{"baseUri":"https://uks.example/","isDefault":true}]}}""")
                }
                else -> error(url)
            }
        }
        var saved: XboxUserToken? = null
        val auth = XboxAuth(http, { clock }, { clock += it }, expired, { saved = it })
        val home = auth.homeEndpoint()
        assertEquals("https://uks.example", home.baseUrl)
        assertEquals("R2", saved?.refreshToken)
        val calls = http.calls.size
        auth.homeEndpoint()
        auth.xsts(XboxAuth.RP_GSSV)
        assertEquals(calls, http.calls.size)
        // Konsol listesi için ayrı XSTS (http://xboxlive.com).
        auth.xsts(XboxAuth.RP_XBOXLIVE)
        assertEquals(calls + 1, http.calls.size)
        assertTrue(http.bodies.last()!!.contains("\"RelyingParty\":\"http://xboxlive.com\""))
    }

    @Test fun invalidRefreshTokenAsksForSignIn() {
        val expired = XboxUserToken.fromResponse(JSONObject("""{"access_token":"OLD","refresh_token":"R","expires_in":0}"""), clock)
        val auth = XboxAuth(FakeHttp { _, _, _ -> XboxHttpResponse(400, """{"error":"invalid_grant"}""") }, { clock }, {}, expired)
        try {
            auth.userAccessToken()
            fail()
        } catch (error: XboxException) {
            assertEquals(XboxError.SIGN_IN_REQUIRED, error.kind)
        }
    }

    @Test fun xstsNoXboxProfile() {
        val token = XboxUserToken.fromResponse(JSONObject("""{"access_token":"A","refresh_token":"R","expires_in":3600}"""), clock)
        val auth = XboxAuth(FakeHttp { _, url, _ ->
            if (url.contains("user.auth")) ok("""{"Token":"XBL","NotAfter":"2026-11-30T00:00:00Z","DisplayClaims":{"xui":[{"uhs":"H"}]}}""")
            else XboxHttpResponse(401, """{"Identity":"0","XErr":2148916233,"Message":""}""")
        }, { clock }, {}, token)
        try {
            auth.xsts(XboxAuth.RP_XBOXLIVE)
            fail()
        } catch (error: XboxException) {
            assertEquals(XboxError.NO_XBOX_ACCOUNT, error.kind)
        }
    }
}

class XboxHomeTest {
    private val clock = Instant.parse("2026-11-16T10:00:00Z").toEpochMilli()

    private fun auth(http: XboxHttp) = XboxAuth(http, { clock }, {},
        XboxUserToken.fromResponse(JSONObject("""{"access_token":"A","refresh_token":"R","expires_in":3600}"""), clock))

    private fun tokens(url: String): XboxHttpResponse? = when {
        url.contains("user.auth") || url.contains("xsts.auth") -> ok("""{"Token":"X","NotAfter":"2026-11-30T00:00:00Z","DisplayClaims":{"xui":[{"uhs":"H"}]}}""")
        url.contains("/v2/login/user") -> ok("""{"gsToken":"GS","durationInSeconds":14400,"offeringSettings":{"regions":[{"baseUri":"https://uks.example/","isDefault":true}]}}""")
        url.contains("login.live.com") -> ok("""{"access_token":"LPT","refresh_token":"R3"}""")
        else -> null
    }

    @Test fun playStateConnectWithBridgeHeaders() {
        val http = FakeHttp { method, url, _ ->
            tokens(url) ?: when {
                url == "https://uks.example/v5/sessions/home/play" -> ok("""{"sessionPath":"v5/sessions/home/ABC-123"}""")
                url.endsWith("/state") -> ok("""{"state":"ReadyToConnect"}""")
                url.endsWith("/connect") && method == "POST" -> XboxHttpResponse(202, "")
                else -> error(url)
            }
        }
        val home = XboxHome(auth(http), http, {})
        assertEquals("ABC-123", home.play("F4001"))
        val (_, _, headers) = http.calls.first { it.second.endsWith("/play") }
        assertEquals("Bearer GS", headers["Authorization"])
        assertEquals("XboxComBrowser", headers["X-Gssv-Client"])
        assertEquals(XboxHome.DEVICE_INFO, headers["X-MS-Device-Info"])
        val play = JSONObject(http.bodies[http.calls.indexOfFirst { it.second.endsWith("/play") }]!!)
        assertEquals("F4001", play.getString("serverId"))
        assertEquals("V3;WebrtcTransport.dll", play.getJSONObject("settings").getString("nanoVersion"))
        assertEquals("ReadyToConnect", home.state("ABC-123").state)
        home.connect("ABC-123")
        assertTrue(http.bodies.last()!!.contains("\"userToken\":\"LPT\""))
        // Cihaz bilgisi geçerli JSON (Windows köprüsündeki nesneyle aynı).
        assertEquals("Surface Pro", JSONObject(XboxHome.DEVICE_INFO).getJSONObject("dev").getJSONObject("hw").getString("model"))
    }

    @Test fun sdpExchangeWaitsForResponse() {
        var gets = 0
        val http = FakeHttp { method, url, _ ->
            tokens(url) ?: when {
                url.endsWith("/sdp") && method == "POST" -> XboxHttpResponse(202, "")
                url.endsWith("/sdp") && method == "GET" -> if (++gets < 3) XboxHttpResponse(204, "")
                    else ok(JSONObject().put("exchangeResponse", """{"messageType":"answer","sdp":"v=0 answer","status":"success"}""").toString())
                else -> error(url)
            }
        }
        val home = XboxHome(auth(http), http, {})
        assertEquals("v=0 answer", home.sdp("S", "v=0 offer"))
        val offer = JSONObject(http.bodies[http.calls.indexOfFirst { it.first == "POST" && it.second.endsWith("/sdp") }]!!)
        assertEquals(8, offer.getJSONObject("configuration").getJSONObject("input").getInt("maxVersion"))
        assertEquals(3, gets)
    }

    @Test fun exchangeTimesOut() {
        val http = FakeHttp { method, url, _ -> tokens(url) ?: if (method == "POST") XboxHttpResponse(202, "") else XboxHttpResponse(204, "") }
        try {
            XboxHome(auth(http), http, {}).sdp("S", "offer")
            fail()
        } catch (error: XboxException) {
            assertEquals(XboxError.TIMEOUT, error.kind)
        }
        assertEquals(XboxHome.EXCHANGE_ATTEMPTS, http.calls.count { it.first == "GET" && it.second.endsWith("/sdp") })
    }

    @Test fun iceAddsTeredoCandidates() {
        val remote = """[{"candidate":"a=candidate:1 1 UDP 100 2001:0000:4136:e378:8000:63bf:3fff:fdd2 1234 typ host ","sdpMLineIndex":0,"sdpMid":"0"},
            {"candidate":"a=candidate:2 1 UDP 1 192.168.1.20 9002 typ host ","sdpMLineIndex":0,"sdpMid":"0"},
            {"candidate":"a=end-of-candidates","sdpMLineIndex":0,"sdpMid":"0"}]"""
        val http = FakeHttp { method, url, _ ->
            tokens(url) ?: if (method == "POST") XboxHttpResponse(202, "") else ok(JSONObject().put("exchangeResponse", remote).toString())
        }
        val list = XboxHome(auth(http), http, {}).ice("S", listOf(XboxIceCandidate("candidate:1 1 udp 2122260223 192.168.1.5 50000 typ host", "0", 0)))
        assertEquals(5, list.size)
        assertEquals("a=candidate:10 1 UDP 1 192.0.2.45 9002 typ host ", list[0].candidate)
        assertEquals("a=candidate:10 1 UDP 1 192.0.2.45 40000 typ host ", list[1].candidate)
        assertEquals("candidate:10 1 UDP 1 192.0.2.45 9002 typ host", list[0].sdpLine)
        assertNull(list[4].sdpLine)
        val sent = JSONObject(http.bodies[http.calls.indexOfFirst { it.first == "POST" && it.second.endsWith("/ice") }]!!)
        assertEquals("iceCandidate", sent.getString("messageType"))
        assertEquals(1, sent.getJSONArray("candidate").length())
    }

    @Test fun serviceErrorsAreClassified() {
        val http = FakeHttp { _, url, _ -> tokens(url) ?: XboxHttpResponse(400, """{"code":"ServerInUse","message":"busy"}""") }
        try {
            XboxHome(auth(http), http, {}).play("F")
            fail()
        } catch (error: XboxException) {
            assertEquals(XboxError.BUSY, error.kind)
        }
    }
}

class TeredoTest {
    @Test fun decodesClientAddressAndPort() {
        // RFC 4380 örneği (Wikipedia): istemci 192.0.2.45, bağlantı noktası 40000.
        val info = Teredo.inspect("2001:0000:4136:e378:8000:63bf:3fff:fdd2")!!
        assertEquals("192.0.2.45", info.client4)
        assertEquals(40000, info.udpPort)
        assertEquals("192.0.2.45", Teredo.inspect("2001:0:4136:e378:8000:63bf:3fff:fdd2")!!.client4)
    }

    @Test fun parsesCompressedAndRejectsInvalid() {
        assertArrayEquals(intArrayOf(0x2001, 0, 0, 0, 0, 0, 0, 1), Teredo.parseIpv6("2001::1"))
        assertNull(Teredo.parseIpv6("192.168.1.1"))
        assertNull(Teredo.parseIpv6("2001:::1"))
        assertNull(Teredo.parseIpv6("2001:0:1"))
        assertNull(Teredo.parseIpv6("2001:zzzz::1"))
    }
}

class XboxChannelsTest {
    @Test fun clientMetadataPacketIsFifteenBytes() {
        val packet = XboxChannels.clientMetadataPacket(0, 1234.5)
        assertEquals(15, packet.size)
        val buffer = ByteBuffer.wrap(packet).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(8, buffer.getShort(0).toInt())
        assertEquals(0, buffer.getInt(2))
        assertEquals(1234.5, buffer.getDouble(6), 0.0)
        assertEquals(2, packet[14].toInt())
    }

    @Test fun frameAckPacketMatchesPlayer() {
        // Input/Packet.ts: 14 bayt başlık + 1 bayt sayı + kare başına 28 bayt; tür 1 = Metadata.
        val frames = listOf(XboxFrameAck(0x1_0000_0005L, 100, 104), XboxFrameAck(3000, 116, 120))
        val packet = XboxChannels.frameAckPacket(7, 130.0, frames)
        assertEquals(14 + 1 + 28 * 2, packet.size)
        val buffer = ByteBuffer.wrap(packet).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(1, buffer.getShort(0).toInt())
        assertEquals(7, buffer.getInt(2))
        assertEquals(130.0, buffer.getDouble(6), 0.0)
        assertEquals(2, packet[14].toInt())
        // serverDataKey alt 32 bit; varış/gönderim, çözülme/gösterim, paket anı ikişer kez.
        assertEquals(listOf(5, 100, 100, 104, 104, 130, 130), (0 until 7).map { buffer.getInt(15 + it * 4) })
        assertEquals(3000, buffer.getInt(15 + 28))
    }

    @Test fun frameAckQueueDrainsInPlayerSizedBatches() {
        val queue = XboxFrameAckQueue(capacity = 40)
        repeat(45) { queue.offer(XboxFrameAck(it.toLong(), 0, 0)) }
        val first = queue.drain()
        assertEquals(XboxChannels.MAX_FRAME_ACKS, first.size)
        // Sığa ulaşınca en eskiler düşer: 0-4 atıldı.
        assertEquals(5L, first.first().serverDataKey)
        assertEquals(11, queue.drain().size)
        assertTrue(queue.drain().isEmpty())
        // libwebrtc damgayı ms'ye yuvarlar (RtpTimestamp / 90); 90 kHz'e geri çevrilir.
        assertEquals(90_000L, XboxFrameAckQueue.serverDataKey(1000))
        assertEquals((47_721_858L * 90) and 0xFFFFFFFFL, XboxFrameAckQueue.serverDataKey(47_721_858))
    }

    @Test fun configurationMessagesMatchPlayer() {
        val messages = XboxChannels.configurationMessages().map(::JSONObject)
        assertEquals(6, messages.size)
        assertEquals("/streaming/systemUi/configuration", messages[0].getString("target"))
        assertEquals(0, JSONObject(messages[0].getString("content")).getJSONArray("systemUis").length())
        assertEquals(1920, JSONObject(messages[5].getString("content")).getInt("preferredWidth"))
        assertTrue(messages.all { it.getString("type") == "Message" })
        assertTrue(XboxChannels.isHandshakeAck("""{"type":"HandshakeAck","version":"messageV1"}"""))
        assertFalse(XboxChannels.isHandshakeAck("{bozuk"))
        assertEquals("Handshake", JSONObject(XboxChannels.HANDSHAKE).getString("type"))
    }

    @Test fun offerGetsStereo() {
        val sdp = "a=fmtp:111 minptime=10;useinbandfec=1\r\na=fmtp:112 useinbandfec=1\r\n"
        assertEquals("a=fmtp:111 minptime=10;useinbandfec=1; stereo=1\r\na=fmtp:112 useinbandfec=1\r\n", XboxChannels.mungeOffer(sdp))
    }

    @Test fun sessionIdFromPath() {
        assertEquals("ABC", XboxHome.sessionId(JSONObject("""{"sessionPath":"v5/sessions/home/ABC"}""")))
        assertNull(XboxHome.sessionId(JSONObject("{}")))
        assertNotNull(XboxHome.playBody("F", 180).getJSONObject("settings"))
        assertEquals(180, XboxHome.playBody("F", 180).getJSONObject("settings").getInt("timezoneOffsetMinutes"))
    }
}

class XboxSessionMachineTest {
    @Test fun staleFramesFromPreviousConnectionDoNotAffectReconnect() {
        val frames = XboxFrameCounter()
        val previous = frames.beginSession()
        assertEquals(1L, frames.recordFrame(previous))
        assertEquals(1L, frames.totalFrames)

        val current = frames.beginSession()
        assertEquals(0L, frames.framesInSession(current))
        assertNull(frames.recordFrame(previous))
        assertEquals(0L, frames.framesInSession(current))
        assertEquals(1L, frames.recordFrame(current))
        assertEquals(2L, frames.totalFrames)
        assertEquals(1L, frames.framesInSession(current))
    }

    @Test fun happyPath() {
        val m = XboxSessionMachine()
        assertEquals(XboxSessionMachine.Action.Play, m.start())
        assertEquals(XboxSessionMachine.Action.PollState(0), m.played())
        assertEquals(XboxSessionMachine.Action.PollState(1000), m.status("Provisioning", null))
        assertEquals(XboxSessionMachine.Action.Connect, m.status("ReadyToConnect", null))
        assertEquals(XboxSessionMachine.Action.PollState(1000), m.connected())
        // connect bir kez gönderilir.
        assertEquals(XboxSessionMachine.Action.PollState(1000), m.status("ReadyToConnect", null))
        assertEquals(XboxSessionMachine.Action.Negotiate, m.status("Provisioned", null))
        assertTrue(m.streaming())
        assertEquals(XboxSessionMachine.Phase.Streaming, m.phase)
        assertFalse(m.streaming())
    }

    @Test fun timesOutAfterMaxPolls() {
        val m = XboxSessionMachine(maxPolls = 3)
        m.start(); m.played()
        assertEquals(XboxSessionMachine.Action.PollState(1000), m.status("Provisioning", null))
        assertEquals(XboxSessionMachine.Action.PollState(1000), m.status("Provisioning", null))
        assertEquals(XboxSessionMachine.Action.Retry(5000), m.status("Provisioning", null))
        assertEquals(XboxError.TIMEOUT, (m.phase as XboxSessionMachine.Phase.Failed).kind)
    }

    @Test fun failedStateDoesNotRetryAndClassifies() {
        val m = XboxSessionMachine()
        m.start(); m.played()
        // Konsol yayını reddetti: yeniden denemek konsolu yeniden tetikler.
        assertEquals(XboxSessionMachine.Action.Retry(null), m.status("Failed", """{"code":"ServerInUse"}"""))
        assertEquals(XboxError.BUSY, (m.phase as XboxSessionMachine.Phase.Failed).kind)
        assertFalse((m.phase as XboxSessionMachine.Phase.Failed).willRetry)
        assertEquals(XboxError.CONSOLE_UNAVAILABLE, XboxSessionMachine.classifyFailure("""{"code":"ConsoleOffline"}"""))
    }

    @Test fun errorDetailsStopsRetrying() {
        val m = XboxSessionMachine()
        m.start(); m.played()
        // Boş ayrıntı hata sayılmaz.
        assertEquals(XboxSessionMachine.Action.PollState(1000), m.status("Provisioning", """{"code":null,"message":null}"""))
        assertEquals(XboxSessionMachine.Action.Retry(null), m.status("Provisioning", """{"code":"Conflict","message":"x"}"""))
    }

    @Test fun retriesBackOffThenStop() {
        val m = XboxSessionMachine()
        assertEquals(XboxSessionMachine.Action.Retry(5000), m.fail(XboxError.NETWORK, "kopma"))
        assertEquals(XboxSessionMachine.Action.Retry(15000), m.fail(XboxError.NETWORK, "kopma"))
        assertEquals(XboxSessionMachine.Action.Retry(45000), m.fail(XboxError.NETWORK, "kopma"))
        assertEquals(3, (m.phase as XboxSessionMachine.Phase.Failed).attempt)
        assertEquals(XboxSessionMachine.Action.Retry(null), m.fail(XboxError.NETWORK, "kopma"))
    }

    @Test fun healthyStreamResetsRetries() {
        var now = 1_000L
        val m = XboxSessionMachine(clock = { now })
        m.fail(XboxError.NETWORK, "kopma"); m.fail(XboxError.NETWORK, "kopma")
        m.start(); m.played(); m.status("Provisioned", null); m.streaming()
        now += 60_000
        assertEquals(XboxSessionMachine.Action.Retry(5000), m.fail(XboxError.NETWORK, "kopma"))
        // Kısa süren yayın sayacı sıfırlamaz.
        m.start(); m.played(); m.status("Provisioned", null); m.streaming()
        now += 1_000
        assertEquals(XboxSessionMachine.Action.Retry(15000), m.fail(XboxError.NETWORK, "kopma"))
    }

    @Test fun signInErrorsDoNotRetry() {
        val m = XboxSessionMachine()
        m.start()
        assertEquals(XboxSessionMachine.Action.Retry(null), m.fail(XboxError.SIGN_IN_REQUIRED, "giriş"))
        assertFalse((m.phase as XboxSessionMachine.Phase.Failed).willRetry)
    }

    @Test fun stopIsFinal() {
        val m = XboxSessionMachine()
        m.start(); m.played()
        m.stop()
        assertEquals(XboxSessionMachine.Action.Nothing, m.status("Provisioned", null))
        assertEquals(XboxSessionMachine.Action.Nothing, m.start())
        assertEquals(XboxSessionMachine.Action.Nothing, m.fail(XboxError.NETWORK, "x"))
    }

    @Test fun eventsOutOfOrderAreIgnored() {
        val m = XboxSessionMachine()
        assertEquals(XboxSessionMachine.Action.Nothing, m.played())
        assertEquals(XboxSessionMachine.Action.Nothing, m.status("Provisioned", null))
        assertFalse(m.streaming())
    }
}

class ReportingDecoderTest {
    /** Sahte çözücü: kaç kare istendiğini sayar. */
    private class CountingDecoder : VideoDecoder {
        var decoded = 0
        override fun initDecode(settings: VideoDecoder.Settings, callback: VideoDecoder.Callback) = VideoCodecStatus.OK
        override fun release() = VideoCodecStatus.OK
        override fun decode(frame: EncodedImage, info: VideoDecoder.DecodeInfo?): VideoCodecStatus {
            decoded++
            return VideoCodecStatus.OK
        }
        override fun getImplementationName() = "counting"
    }

    @Test fun decodeAcceptsNullInfoLikeLibwebrtc() {
        // libwebrtc'nin yerel sarmalayıcısı (sdk/android/src/jni/video_decoder_wrapper.cc) Java decode'u info = null ile
        // çağırır; null kabul etmeyen bir Kotlin imzası istisna atar ve süreç jvm.cc'deki denetimle kapanır.
        val inner = CountingDecoder()
        val decoder: VideoDecoder = ReportingDecoder(inner) { _, _, _ -> }
        val frame = EncodedImage.builder().setBuffer(ByteBuffer.allocateDirect(1), null).setCaptureTimeNs(1_000_000).createEncodedImage()
        assertEquals(VideoCodecStatus.OK, decoder.decode(frame, null))
        assertEquals(1, inner.decoded)
    }
}
