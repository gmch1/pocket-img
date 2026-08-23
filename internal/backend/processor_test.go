package backend

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"os"
	"testing"

	"github.com/gen2brain/webp"
)

func TestInspectWebPPassThroughPolicy(t *testing.T) {
	source := makeWebP(t, 320, 180)
	plainPath := writeTestImage(t, source)
	plain, err := inspectWebP(plainPath)
	if err != nil {
		t.Fatal(err)
	}
	if plain.animated || !plain.canPassThrough {
		t.Fatalf("unexpected plain webp inspection: %#v", plain)
	}

	withMetadata := appendWebPChunk(t, source, "EXIF", []byte("private metadata"))
	metadataPath := writeTestImage(t, withMetadata)
	metadata, err := inspectWebP(metadataPath)
	if err != nil {
		t.Fatal(err)
	}
	if metadata.animated || metadata.canPassThrough {
		t.Fatalf("metadata-bearing webp should be sanitized: %#v", metadata)
	}

	withDuplicateImageData := appendWebPChunk(t, source, "VP8 ", []byte{0})
	duplicatePath := writeTestImage(t, withDuplicateImageData)
	duplicate, err := inspectWebP(duplicatePath)
	if err != nil {
		t.Fatal(err)
	}
	if duplicate.canPassThrough {
		t.Fatalf("webp with duplicate image data should be sanitized: %#v", duplicate)
	}
}

func TestInspectMP4ValidatesH264VideoStructure(t *testing.T) {
	content := makeH264MP4(t, 1280, 720)
	path := writeTestMedia(t, "recording.mp4", content)
	inspection, recognized, err := inspectMP4(path)
	if err != nil {
		t.Fatal(err)
	}
	if !recognized || inspection.width != 1280 || inspection.height != 720 {
		t.Fatalf("unexpected MP4 inspection: recognized=%v inspection=%#v", recognized, inspection)
	}

	imagePath := writeTestMedia(t, "renamed.mp4", makeWebP(t, 32, 24))
	if _, recognized, err := inspectMP4(imagePath); err != nil || recognized {
		t.Fatalf("file name was trusted as MP4: recognized=%v err=%v", recognized, err)
	}
}

func TestInspectMP4RejectsMalformedOrUnsupportedTracks(t *testing.T) {
	valid := makeH264MP4(t, 640, 360)
	tests := map[string][]byte{
		"truncated container": valid[:len(valid)-1],
		"non-H264 video":      bytes.ReplaceAll(valid, []byte("avc1"), []byte("hvc1")),
		"audio track":         makeH264MP4WithAudio(t, 640, 360),
	}
	for name, content := range tests {
		t.Run(name, func(t *testing.T) {
			path := writeTestMedia(t, "invalid.mp4", content)
			if _, recognized, err := inspectMP4(path); !recognized || err == nil {
				t.Fatalf("invalid MP4 accepted: recognized=%v err=%v", recognized, err)
			}
		})
	}
}

func makeWebP(t *testing.T, width, height int) []byte {
	t.Helper()
	value := image.NewNRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			value.SetNRGBA(x, y, color.NRGBA{R: uint8(x), G: uint8(y), B: uint8(x + y), A: 0xff})
		}
	}
	var encoded bytes.Buffer
	if err := webp.Encode(&encoded, value, webp.Options{Quality: 82, Method: 4}); err != nil {
		t.Fatal(err)
	}
	return encoded.Bytes()
}

func appendWebPChunk(t *testing.T, source []byte, chunkType string, payload []byte) []byte {
	t.Helper()
	if len(chunkType) != 4 {
		t.Fatalf("chunk type must be four bytes: %q", chunkType)
	}
	result := append([]byte(nil), source...)
	result = append(result, chunkType...)
	var size [4]byte
	binary.LittleEndian.PutUint32(size[:], uint32(len(payload)))
	result = append(result, size[:]...)
	result = append(result, payload...)
	if len(payload)%2 != 0 {
		result = append(result, 0)
	}
	binary.LittleEndian.PutUint32(result[4:8], uint32(len(result)-8))
	return result
}

func writeTestImage(t *testing.T, content []byte) string {
	t.Helper()
	return writeTestMedia(t, "image.webp", content)
}

func writeTestMedia(t *testing.T, name string, content []byte) string {
	t.Helper()
	path := t.TempDir() + "/" + name
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func makeH264MP4(t *testing.T, width, height int) []byte {
	t.Helper()
	return makeTestH264MP4(t, width, height, false)
}

func makeH264MP4WithAudio(t *testing.T, width, height int) []byte {
	t.Helper()
	return makeTestH264MP4(t, width, height, true)
}

func makeTestH264MP4(t *testing.T, width, height int, includeAudio bool) []byte {
	t.Helper()
	if width < 1 || width > 0xffff || height < 1 || height > 0xffff {
		t.Fatalf("invalid test video dimensions %dx%d", width, height)
	}

	fileTypePayload := make([]byte, 16)
	copy(fileTypePayload[0:4], "mp42")
	copy(fileTypePayload[8:12], "isom")
	copy(fileTypePayload[12:16], "avc1")
	fileType := makeMP4Box(t, "ftyp", fileTypePayload)

	sample := []byte{0, 0, 0, 2, 0x65, 0x88}
	mediaData := makeMP4Box(t, "mdat", sample)
	chunkOffset := uint32(len(fileType) + 8)

	avcConfiguration := []byte{
		1, 100, 0, 31, 0xff, 0xe1,
		0, 2, 0x67, 0x64,
		1, 0, 2, 0x68, 0xee,
	}
	visualSample := make([]byte, 78)
	binary.BigEndian.PutUint16(visualSample[6:8], 1)
	binary.BigEndian.PutUint16(visualSample[24:26], uint16(width))
	binary.BigEndian.PutUint16(visualSample[26:28], uint16(height))
	binary.BigEndian.PutUint32(visualSample[28:32], 72<<16)
	binary.BigEndian.PutUint32(visualSample[32:36], 72<<16)
	binary.BigEndian.PutUint16(visualSample[40:42], 1)
	binary.BigEndian.PutUint16(visualSample[74:76], 24)
	visualSample = append(visualSample, makeMP4Box(t, "avcC", avcConfiguration)...)
	avcSampleEntry := makeMP4Box(t, "avc1", visualSample)

	sampleDescriptionPayload := make([]byte, 8)
	binary.BigEndian.PutUint32(sampleDescriptionPayload[4:8], 1)
	sampleDescriptionPayload = append(sampleDescriptionPayload, avcSampleEntry...)
	sampleDescription := makeMP4Box(t, "stsd", sampleDescriptionPayload)

	timeToSamplePayload := make([]byte, 16)
	binary.BigEndian.PutUint32(timeToSamplePayload[4:8], 1)
	binary.BigEndian.PutUint32(timeToSamplePayload[8:12], 1)
	binary.BigEndian.PutUint32(timeToSamplePayload[12:16], 1000)
	timeToSample := makeMP4Box(t, "stts", timeToSamplePayload)

	sampleToChunkPayload := make([]byte, 20)
	binary.BigEndian.PutUint32(sampleToChunkPayload[4:8], 1)
	binary.BigEndian.PutUint32(sampleToChunkPayload[8:12], 1)
	binary.BigEndian.PutUint32(sampleToChunkPayload[12:16], 1)
	binary.BigEndian.PutUint32(sampleToChunkPayload[16:20], 1)
	sampleToChunk := makeMP4Box(t, "stsc", sampleToChunkPayload)

	sampleSizePayload := make([]byte, 12)
	binary.BigEndian.PutUint32(sampleSizePayload[4:8], uint32(len(sample)))
	binary.BigEndian.PutUint32(sampleSizePayload[8:12], 1)
	sampleSize := makeMP4Box(t, "stsz", sampleSizePayload)

	chunkOffsetPayload := make([]byte, 12)
	binary.BigEndian.PutUint32(chunkOffsetPayload[4:8], 1)
	binary.BigEndian.PutUint32(chunkOffsetPayload[8:12], chunkOffset)
	chunkOffsets := makeMP4Box(t, "stco", chunkOffsetPayload)

	sampleTable := makeMP4Box(t, "stbl", joinBytes(
		sampleDescription, timeToSample, sampleToChunk, sampleSize, chunkOffsets,
	))
	mediaInfo := makeMP4Box(t, "minf", sampleTable)

	mediaHeaderPayload := make([]byte, 24)
	binary.BigEndian.PutUint32(mediaHeaderPayload[12:16], 1000)
	binary.BigEndian.PutUint32(mediaHeaderPayload[16:20], 1000)
	mediaHeader := makeMP4Box(t, "mdhd", mediaHeaderPayload)

	handlerPayload := make([]byte, 24)
	copy(handlerPayload[8:12], "vide")
	handler := makeMP4Box(t, "hdlr", handlerPayload)
	media := makeMP4Box(t, "mdia", joinBytes(mediaHeader, handler, mediaInfo))

	trackHeaderPayload := make([]byte, 84)
	trackHeaderPayload[3] = 7
	binary.BigEndian.PutUint32(trackHeaderPayload[12:16], 1)
	binary.BigEndian.PutUint32(trackHeaderPayload[76:80], uint32(width)<<16)
	binary.BigEndian.PutUint32(trackHeaderPayload[80:84], uint32(height)<<16)
	trackHeader := makeMP4Box(t, "tkhd", trackHeaderPayload)
	track := makeMP4Box(t, "trak", joinBytes(trackHeader, media))

	movieHeaderPayload := make([]byte, 100)
	binary.BigEndian.PutUint32(movieHeaderPayload[12:16], 1000)
	binary.BigEndian.PutUint32(movieHeaderPayload[16:20], 1000)
	binary.BigEndian.PutUint32(movieHeaderPayload[96:100], 2)
	movieHeader := makeMP4Box(t, "mvhd", movieHeaderPayload)
	moviePayload := joinBytes(movieHeader, track)
	if includeAudio {
		audioTrack := bytes.Replace(track, []byte("vide"), []byte("soun"), 1)
		moviePayload = append(moviePayload, audioTrack...)
	}
	movie := makeMP4Box(t, "moov", moviePayload)
	return joinBytes(fileType, mediaData, movie)
}

func makeMP4Box(t *testing.T, boxType string, payload []byte) []byte {
	t.Helper()
	if len(boxType) != 4 || uint64(len(payload))+8 > uint64(^uint32(0)) {
		t.Fatalf("invalid test MP4 box %q with %d payload bytes", boxType, len(payload))
	}
	result := make([]byte, 8+len(payload))
	binary.BigEndian.PutUint32(result[0:4], uint32(len(result)))
	copy(result[4:8], boxType)
	copy(result[8:], payload)
	return result
}

func joinBytes(values ...[]byte) []byte {
	var result []byte
	for _, value := range values {
		result = append(result, value...)
	}
	return result
}
