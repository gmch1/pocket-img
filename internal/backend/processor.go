package backend

import (
	"bufio"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	"image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/gen2brain/webp"
	"golang.org/x/image/draw"
)

var (
	errUnsupportedImage = errors.New("unsupported image format")
	errImageTooLarge    = errors.New("decoded image exceeds pixel limit")
)

type processor struct {
	dataDir      string
	maxPixels    int64
	thumbnailMax int
	webpQuality  int
	thumbQuality int
}

type webPInspection struct {
	animated       bool
	canPassThrough bool
}

func newProcessor(cfg Config) *processor {
	return &processor{
		dataDir:      cfg.DataDir,
		maxPixels:    cfg.MaxPixels,
		thumbnailMax: cfg.ThumbnailMax,
		webpQuality:  cfg.WebPQuality,
		thumbQuality: cfg.ThumbQuality,
	}
}

func (p *processor) process(tempPath, ownerID string) (imageRecord, error) {
	config, format, err := decodeConfig(tempPath)
	if err != nil {
		return imageRecord{}, fmt.Errorf("decode image header: %w", err)
	}
	if config.Width <= 0 || config.Height <= 0 {
		return imageRecord{}, errUnsupportedImage
	}
	if int64(config.Width)*int64(config.Height) > p.maxPixels {
		return imageRecord{}, errImageTooLarge
	}

	animated := format == "gif"
	passThroughWebP := false
	if format == "webp" {
		inspection, inspectErr := inspectWebP(tempPath)
		err = inspectErr
		if err != nil {
			return imageRecord{}, err
		}
		animated = inspection.animated
		passThroughWebP = inspection.canPassThrough
	}
	if format != "png" && format != "jpeg" && format != "gif" && format != "webp" {
		return imageRecord{}, errUnsupportedImage
	}

	id, err := randomID()
	if err != nil {
		return imageRecord{}, err
	}
	fullExtension := "webp"
	mediaType := "image/webp"
	if format == "gif" {
		fullExtension = "gif"
		mediaType = "image/gif"
	}

	imageValue, err := decodeFirstFrame(tempPath, format)
	if err != nil {
		return imageRecord{}, fmt.Errorf("decode image: %w", err)
	}

	fullCandidate := filepath.Join(p.dataDir, "tmp", id+".full."+fullExtension)
	thumbCandidate := filepath.Join(p.dataDir, "tmp", id+".thumb.webp")
	cleanupCandidates := true
	defer func() {
		if cleanupCandidates {
			_ = os.Remove(fullCandidate)
			_ = os.Remove(thumbCandidate)
		}
	}()

	if animated || passThroughWebP {
		if err := renameOrCopy(tempPath, fullCandidate); err != nil {
			return imageRecord{}, fmt.Errorf("preserve webp or animation: %w", err)
		}
	} else if err := writeWebP(fullCandidate, imageValue, p.webpQuality); err != nil {
		return imageRecord{}, fmt.Errorf("encode full webp: %w", err)
	}

	thumbnail := resizeDown(imageValue, p.thumbnailMax)
	if err := writeWebP(thumbCandidate, thumbnail, p.thumbQuality); err != nil {
		return imageRecord{}, fmt.Errorf("encode thumbnail: %w", err)
	}

	fullPath := p.fullPath(ownerID, id, fullExtension)
	thumbPath := p.thumbnailPath(ownerID, id)
	if err := os.MkdirAll(filepath.Dir(fullPath), 0o750); err != nil {
		return imageRecord{}, err
	}
	if err := os.MkdirAll(filepath.Dir(thumbPath), 0o750); err != nil {
		return imageRecord{}, err
	}
	if err := os.Rename(fullCandidate, fullPath); err != nil {
		return imageRecord{}, fmt.Errorf("commit full image: %w", err)
	}
	if err := os.Rename(thumbCandidate, thumbPath); err != nil {
		_ = os.Remove(fullPath)
		return imageRecord{}, fmt.Errorf("commit thumbnail: %w", err)
	}
	cleanupCandidates = false

	fullInfo, err := os.Stat(fullPath)
	if err != nil {
		p.removeFiles(ownerID, id, fullExtension)
		return imageRecord{}, err
	}
	thumbInfo, err := os.Stat(thumbPath)
	if err != nil {
		p.removeFiles(ownerID, id, fullExtension)
		return imageRecord{}, err
	}

	return imageRecord{
		OwnerID:        ownerID,
		ID:             id,
		Extension:      fullExtension,
		MediaType:      mediaType,
		Width:          config.Width,
		Height:         config.Height,
		ByteSize:       fullInfo.Size(),
		ThumbnailSize:  thumbInfo.Size(),
		Animated:       animated,
		CreatedAtMilli: time.Now().UTC().UnixMilli(),
	}, nil
}

func decodeConfig(path string) (image.Config, string, error) {
	file, err := os.Open(path)
	if err != nil {
		return image.Config{}, "", err
	}
	defer file.Close()
	return image.DecodeConfig(bufio.NewReader(file))
}

func decodeFirstFrame(path, format string) (image.Image, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	switch format {
	case "gif":
		return gif.Decode(file)
	case "webp":
		return webp.Decode(file)
	default:
		value, _, err := image.Decode(file)
		return value, err
	}
}

func inspectWebP(path string) (webPInspection, error) {
	file, err := os.Open(path)
	if err != nil {
		return webPInspection{}, err
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return webPInspection{}, err
	}
	var riffHeader [12]byte
	if _, err := io.ReadFull(file, riffHeader[:]); err != nil {
		return webPInspection{}, errUnsupportedImage
	}
	if string(riffHeader[:4]) != "RIFF" || string(riffHeader[8:]) != "WEBP" {
		return webPInspection{}, errUnsupportedImage
	}
	if declaredSize := int64(binary.LittleEndian.Uint32(riffHeader[4:8])) + 8; declaredSize != info.Size() {
		return webPInspection{}, errUnsupportedImage
	}

	result := webPInspection{canPassThrough: true}
	imageDataChunks := 0
	extendedHeaderChunks := 0
	alphaChunks := 0
	for offset := int64(len(riffHeader)); offset < info.Size(); {
		var chunkHeader [8]byte
		if _, err := io.ReadFull(file, chunkHeader[:]); err != nil {
			return webPInspection{}, errUnsupportedImage
		}
		chunkType := string(chunkHeader[:4])
		chunkSize := int64(binary.LittleEndian.Uint32(chunkHeader[4:]))
		paddedSize := chunkSize + chunkSize%2
		if offset+int64(len(chunkHeader))+paddedSize > info.Size() {
			return webPInspection{}, errUnsupportedImage
		}

		consumed := int64(0)
		switch chunkType {
		case "VP8 ", "VP8L":
			imageDataChunks++
			if imageDataChunks > 1 {
				result.canPassThrough = false
			}
		case "VP8X":
			if chunkSize != 10 {
				return webPInspection{}, errUnsupportedImage
			}
			var flags [1]byte
			if _, err := io.ReadFull(file, flags[:]); err != nil {
				return webPInspection{}, errUnsupportedImage
			}
			consumed = 1
			extendedHeaderChunks++
			if extendedHeaderChunks > 1 || offset != int64(len(riffHeader)) || imageDataChunks > 0 {
				result.canPassThrough = false
			}
			if flags[0]&0xc1 != 0 || flags[0]&(0x20|0x08|0x04) != 0 {
				// Reserved or metadata feature flags require sanitizing by re-encoding.
				result.canPassThrough = false
			}
			result.animated = result.animated || flags[0]&0x02 != 0
		case "ALPH":
			// Alpha data is part of the encoded image and is safe to retain.
			alphaChunks++
			if alphaChunks > 1 || imageDataChunks > 0 {
				result.canPassThrough = false
			}
		case "ANIM", "ANMF":
			result.animated = true
			result.canPassThrough = false
		case "ICCP", "EXIF", "XMP ":
			// Re-encode metadata-bearing images to retain the existing privacy behavior.
			result.canPassThrough = false
		default:
			// Unknown chunks are accepted by the decoder but are sanitized by re-encoding.
			result.canPassThrough = false
		}

		if _, err := file.Seek(chunkSize-consumed+chunkSize%2, io.SeekCurrent); err != nil {
			return webPInspection{}, errUnsupportedImage
		}
		offset += int64(len(chunkHeader)) + paddedSize
	}
	if alphaChunks > 0 && extendedHeaderChunks != 1 {
		result.canPassThrough = false
	}
	result.canPassThrough = result.canPassThrough && !result.animated && imageDataChunks == 1
	return result, nil
}

func writeWebP(path string, value image.Image, quality int) (returnErr error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o640)
	if err != nil {
		return err
	}
	defer func() {
		if err := file.Close(); returnErr == nil && err != nil {
			returnErr = err
		}
		if returnErr != nil {
			_ = os.Remove(path)
		}
	}()

	if err := webp.Encode(file, value, webp.Options{Quality: quality, Method: 4}); err != nil {
		return err
	}
	return file.Sync()
}

func resizeDown(source image.Image, maximum int) image.Image {
	bounds := source.Bounds()
	width, height := bounds.Dx(), bounds.Dy()
	if width <= maximum && height <= maximum {
		return source
	}

	newWidth, newHeight := maximum, maximum
	if width >= height {
		newHeight = max(1, height*maximum/width)
	} else {
		newWidth = max(1, width*maximum/height)
	}
	destination := image.NewNRGBA(image.Rect(0, 0, newWidth, newHeight))
	draw.CatmullRom.Scale(destination, destination.Bounds(), source, bounds, draw.Over, nil)
	return destination
}

func randomID() (string, error) {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}

func renameOrCopy(source, destination string) error {
	if err := os.Rename(source, destination); err == nil {
		return nil
	}

	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o640)
	if err != nil {
		return err
	}
	if _, err := io.Copy(output, input); err != nil {
		output.Close()
		_ = os.Remove(destination)
		return err
	}
	if err := output.Sync(); err != nil {
		output.Close()
		_ = os.Remove(destination)
		return err
	}
	if err := output.Close(); err != nil {
		_ = os.Remove(destination)
		return err
	}
	return os.Remove(source)
}

func (p *processor) fullPath(ownerID, id, extension string) string {
	return filepath.Join(p.dataDir, "objects", ownerID, id[:2], id[2:4], id+"."+extension)
}

func (p *processor) thumbnailPath(ownerID, id string) string {
	return filepath.Join(p.dataDir, "thumbnails", ownerID, id[:2], id[2:4], id+".webp")
}

func (p *processor) removeFiles(ownerID, id, extension string) error {
	var result error
	for _, path := range []string{p.fullPath(ownerID, id, extension), p.thumbnailPath(ownerID, id)} {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			result = errors.Join(result, err)
		}
	}
	return result
}

func (p *processor) migrateLegacyFiles(records []imageRecord) error {
	for _, record := range records {
		legacyFull := filepath.Join(p.dataDir, "objects", record.ID[:2], record.ID[2:4], record.ID+"."+record.Extension)
		legacyThumbnail := filepath.Join(p.dataDir, "thumbnails", record.ID[:2], record.ID[2:4], record.ID+".webp")
		if err := moveLegacyFile(legacyFull, p.fullPath(record.OwnerID, record.ID, record.Extension)); err != nil {
			return fmt.Errorf("migrate full image %s: %w", record.ID, err)
		}
		if err := moveLegacyFile(legacyThumbnail, p.thumbnailPath(record.OwnerID, record.ID)); err != nil {
			return fmt.Errorf("migrate thumbnail %s: %w", record.ID, err)
		}
	}
	return nil
}

func moveLegacyFile(source, destination string) error {
	if _, err := os.Stat(destination); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if _, err := os.Stat(source); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o750); err != nil {
		return err
	}
	return renameOrCopy(source, destination)
}
