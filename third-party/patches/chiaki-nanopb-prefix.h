/* SPDX-License-Identifier: AGPL-3.0-only */
/*
 * chiaki-ng'nin derlediği nanopb (0.4) ile uygulamadaki başka nanopb kopyaları aynı adları dışa verir. iOS uygulaması
 * Firebase üzerinden nanopb 0.3'ü getiriyor; bağlayıcı tek bir _pb_encode seçince chiaki'nin 0.4 biçimindeki mesajları
 * 0.3 kodlayıcısıyla kodlanıyor ve Remote Play oturumu "Senkusha set version protobuf encoding failed" ile düşüyordu.
 *
 * Bu başlık build-chiaki-{ios,macos}.sh tarafından chiaki-ng derlemesindeki her C dosyasına -include ile eklenir;
 * nanopb'nin dışa açık bütün sembolleri chiaki_nanopb_ önekini alır. Liste libprotobuf-nanopb.a'nın dış sembolleridir
 * (nm -gU); yalnız gerçek işlevler burada, pb_encode_delimited gibi makrolar bunlara açıldığı için ayrıca gerekmez.
 * nanopb sürümü değişirse listeyi yeniden çıkarın: betikler önek almamış _pb_ sembolü kalırsa derlemeyi durdurur.
 */
#ifndef CHIAKI_NANOPB_PREFIX_H
#define CHIAKI_NANOPB_PREFIX_H

#define pb_close_string_substream chiaki_nanopb_close_string_substream
#define pb_decode chiaki_nanopb_decode
#define pb_decode_bool chiaki_nanopb_decode_bool
#define pb_decode_ex chiaki_nanopb_decode_ex
#define pb_decode_fixed32 chiaki_nanopb_decode_fixed32
#define pb_decode_fixed64 chiaki_nanopb_decode_fixed64
#define pb_decode_svarint chiaki_nanopb_decode_svarint
#define pb_decode_tag chiaki_nanopb_decode_tag
#define pb_decode_varint chiaki_nanopb_decode_varint
#define pb_decode_varint32 chiaki_nanopb_decode_varint32
#define pb_default_field_callback chiaki_nanopb_default_field_callback
#define pb_encode chiaki_nanopb_encode
#define pb_encode_ex chiaki_nanopb_encode_ex
#define pb_encode_fixed32 chiaki_nanopb_encode_fixed32
#define pb_encode_fixed64 chiaki_nanopb_encode_fixed64
#define pb_encode_string chiaki_nanopb_encode_string
#define pb_encode_submessage chiaki_nanopb_encode_submessage
#define pb_encode_svarint chiaki_nanopb_encode_svarint
#define pb_encode_tag chiaki_nanopb_encode_tag
#define pb_encode_tag_for_field chiaki_nanopb_encode_tag_for_field
#define pb_encode_varint chiaki_nanopb_encode_varint
#define pb_field_iter_begin chiaki_nanopb_field_iter_begin
#define pb_field_iter_begin_const chiaki_nanopb_field_iter_begin_const
#define pb_field_iter_begin_extension chiaki_nanopb_field_iter_begin_extension
#define pb_field_iter_begin_extension_const chiaki_nanopb_field_iter_begin_extension_const
#define pb_field_iter_find chiaki_nanopb_field_iter_find
#define pb_field_iter_find_extension chiaki_nanopb_field_iter_find_extension
#define pb_field_iter_next chiaki_nanopb_field_iter_next
#define pb_get_encoded_size chiaki_nanopb_get_encoded_size
#define pb_istream_from_buffer chiaki_nanopb_istream_from_buffer
#define pb_make_string_substream chiaki_nanopb_make_string_substream
#define pb_ostream_from_buffer chiaki_nanopb_ostream_from_buffer
#define pb_read chiaki_nanopb_read
#define pb_release chiaki_nanopb_release
#define pb_skip_field chiaki_nanopb_skip_field
#define pb_write chiaki_nanopb_write
/* PB_ENABLE_MALLOC ya da PB_CONVERT_DOUBLE_FLOAT açılırsa dışa açılanlar. */
#define pb_decode_double_as_float chiaki_nanopb_decode_double_as_float
#define pb_encode_float_as_double chiaki_nanopb_encode_float_as_double

#endif
