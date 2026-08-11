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
	path := t.TempDir() + "/image.webp"
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
