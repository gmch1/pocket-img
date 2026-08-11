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
	if format == "webp" {
		animated, err = animatedWebP(tempPath)
		if err != nil {
			return imageRecord{}, err
		}
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

	if animated {
		if err := renameOrCopy(tempPath, fullCandidate); err != nil {
			return imageRecord{}, fmt.Errorf("preserve animation: %w", err)
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

func animatedWebP(path string) (bool, error) {
	file, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer file.Close()

	data, err := io.ReadAll(io.LimitReader(file, 1<<20))
	if err != nil {
		return false, err
	}
	if len(data) < 12 || string(data[:4]) != "RIFF" || string(data[8:12]) != "WEBP" {
		return false, errUnsupportedImage
	}
	for offset := 12; offset+8 <= len(data); {
		chunkType := string(data[offset : offset+4])
		chunkSize := int(binary.LittleEndian.Uint32(data[offset+4 : offset+8]))
		dataOffset := offset + 8
		if chunkSize < 0 || dataOffset+chunkSize > len(data) {
			break
		}
		if chunkType == "VP8X" && chunkSize >= 1 && data[dataOffset]&0x02 != 0 {
			return true, nil
		}
		if chunkType == "ANIM" || chunkType == "ANMF" {
			return true, nil
		}
		offset = dataOffset + chunkSize + chunkSize%2
	}
	return false, nil
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
