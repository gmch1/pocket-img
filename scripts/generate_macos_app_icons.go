// Command generate_macos_app_icons creates the raster sizes required by a
// macOS AppIcon asset set from one square PNG master.
package main

import (
	"fmt"
	"image"
	"image/png"
	"os"
	"path/filepath"

	xdraw "golang.org/x/image/draw"
)

var outputs = []struct {
	name string
	size int
}{
	{"AppIcon-16.png", 16},
	{"AppIcon-16@2x.png", 32},
	{"AppIcon-32.png", 32},
	{"AppIcon-32@2x.png", 64},
	{"AppIcon-128.png", 128},
	{"AppIcon-128@2x.png", 256},
	{"AppIcon-256.png", 256},
	{"AppIcon-256@2x.png", 512},
	{"AppIcon-512.png", 512},
	{"AppIcon-512@2x.png", 1024},
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: go run ./scripts/generate_macos_app_icons.go <source.png> <output-directory>")
		os.Exit(2)
	}

	source, err := readPNG(os.Args[1])
	if err != nil {
		fatal(err)
	}
	if source.Bounds().Dx() != source.Bounds().Dy() {
		fatal(fmt.Errorf("source must be square, got %dx%d", source.Bounds().Dx(), source.Bounds().Dy()))
	}
	if err := os.MkdirAll(os.Args[2], 0o755); err != nil {
		fatal(err)
	}

	for _, output := range outputs {
		destination := image.NewNRGBA(image.Rect(0, 0, output.size, output.size))
		xdraw.CatmullRom.Scale(
			destination,
			destination.Bounds(),
			source,
			source.Bounds(),
			xdraw.Over,
			nil,
		)
		if err := writePNG(filepath.Join(os.Args[2], output.name), destination); err != nil {
			fatal(err)
		}
	}
}

func readPNG(path string) (image.Image, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return png.Decode(file)
}

func writePNG(path string, source image.Image) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	encoder := png.Encoder{CompressionLevel: png.BestCompression}
	if err := encoder.Encode(file, source); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
