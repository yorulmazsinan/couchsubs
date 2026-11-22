// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** webOS 3.x (2017) LG ikinci ekran hedefine cevap vermiyor; "ssdp:all" yanıtı LG olarak tanınır (#498). */
class TvDiscoveryTest {
    @Test
    fun oldWebOsAnswerToSsdpAllIsAnLgTv() {
        val root = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.40:1259/\r\nST: upnp:rootdevice\r\n" +
            "USN: uuid:LGTV2017-1234::upnp:rootdevice\r\nSERVER: Linux/3.10.19-32.afro.4 UPnP/1.0 LGE WebOS TV LGE_DLNA_SDK/1.6.0\r\n\r\n"
        assertEquals("192.168.1.40" to TvBrand.LG, TvDiscovery.parse(root))
        val netflix = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.40:9080\r\nST: urn:mdx-netflix-com:service:target:1\r\n" +
            "USN: uuid:LGTV2017-1234::urn:mdx-netflix-com:service:target:1\r\n\r\n"
        assertEquals("192.168.1.40" to TvBrand.LG, TvDiscovery.parse(netflix))
    }

    @Test
    fun otherDevicesAnsweringSsdpAllAreIgnored() {
        val router = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.1:49152/desc.xml\r\nST: upnp:rootdevice\r\n" +
            "USN: uuid:abcd::upnp:rootdevice\r\nSERVER: Linux UPnP/1.0 MiniUPnPd\r\n\r\n"
        assertNull(TvDiscovery.parse(router))
    }

    @Test
    fun knownTargetsKeepTheirBrand() {
        val lg = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.153:1990/x.xml\r\nST: urn:lge-com:service:webos-second-screen:1\r\n\r\n"
        assertEquals("192.168.1.153" to TvBrand.LG, TvDiscovery.parse(lg))
        val dial = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.60:8008/ssdp/device-desc.xml\r\nST: urn:dial-multiscreen-org:service:dial:1\r\n\r\n"
        assertEquals("192.168.1.60" to TvBrand.ANDROID_TV, TvDiscovery.parse(dial))
        val samsung = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.70:7676/smp_15_\r\nST: urn:samsung.com:device:RemoteControlReceiver:1\r\n" +
            "SERVER: SHP, UPnP/1.0, Samsung UPnP SDK/1.0\r\n\r\n"
        assertEquals("192.168.1.70" to TvBrand.SAMSUNG, TvDiscovery.parse(samsung))
    }

    /** Sorulan hedefi aynen geri söyleyen cihaz (Android TV) LG ya da Samsung sayılmaz; DIAL yanıtıyla Android TV kalır. */
    @Test
    fun echoedTargetsAreNotABrand() {
        val server = "SERVER: Linux/4.9.125 UPnP/1.0 Portable SDK for UPnP devices/1.6.18\r\n"
        val lgEcho = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.133:49152/description.xml\r\nST: urn:lge-com:service:webos-second-screen:1\r\n" +
            "USN: uuid:5f9e::urn:lge-com:service:webos-second-screen:1\r\n$server\r\n"
        assertNull(TvDiscovery.parse(lgEcho))
        val samsungEcho = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.133:49152/description.xml\r\n" +
            "ST: urn:samsung.com:device:RemoteControlReceiver:1\r\nUSN: uuid:5f9e::urn:samsung.com:device:RemoteControlReceiver:1\r\n$server\r\n"
        assertNull(TvDiscovery.parse(samsungEcho))
        val dial = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.133:8008/ssdp/device-desc.xml\r\nST: urn:dial-multiscreen-org:service:dial:1\r\n$server\r\n"
        assertEquals("192.168.1.133" to TvBrand.ANDROID_TV, TvDiscovery.parse(dial))
    }
}
