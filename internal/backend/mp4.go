package backend

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
)

const maxMP4Boxes = 10_000

var errInvalidMP4 = errors.New("invalid MP4 container")

type mp4Inspection struct {
	width  int
	height int
}

type mp4Box struct {
	typ          string
	payloadStart int64
	end          int64
}

func (box mp4Box) payloadSize() int64 {
	return box.end - box.payloadStart
}

type mp4Range struct {
	start uint64
	end   uint64
}

type mp4Parser struct {
	file     *os.File
	fileSize int64
	boxes    int
}

type mp4Track struct {
	handler string
	width   int
	height  int
}

// inspectMP4 recognizes an upload by its first ISO BMFF box, then validates the
// relevant MP4 structure. The boolean distinguishes a non-MP4 image from a
// malformed file that claims to be MP4.
func inspectMP4(path string) (mp4Inspection, bool, error) {
	file, err := os.Open(path)
	if err != nil {
		return mp4Inspection{}, false, err
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return mp4Inspection{}, false, err
	}
	if info.Size() < 8 {
		return mp4Inspection{}, false, nil
	}
	var firstHeader [8]byte
	if _, err := file.ReadAt(firstHeader[:], 0); err != nil {
		return mp4Inspection{}, false, err
	}
	if string(firstHeader[4:8]) != "ftyp" {
		return mp4Inspection{}, false, nil
	}

	parser := &mp4Parser{file: file, fileSize: info.Size()}
	inspection, err := parser.inspect()
	if err != nil {
		return mp4Inspection{}, true, err
	}
	return inspection, true, nil
}

func (p *mp4Parser) inspect() (mp4Inspection, error) {
	var ftyp, moov mp4Box
	var mediaData []mp4Range
	topLevelIndex := 0
	err := p.walkBoxes(0, p.fileSize, func(box mp4Box) error {
		switch box.typ {
		case "ftyp":
			if topLevelIndex != 0 || ftyp.typ != "" {
				return errInvalidMP4
			}
			if err := p.validateFileType(box); err != nil {
				return err
			}
			ftyp = box
		case "moov":
			if moov.typ != "" {
				return errInvalidMP4
			}
			moov = box
		case "mdat":
			if box.payloadSize() > 0 {
				mediaData = append(mediaData, mp4Range{
					start: uint64(box.payloadStart),
					end:   uint64(box.end),
				})
			}
		}
		topLevelIndex++
		return nil
	})
	if err != nil {
		return mp4Inspection{}, err
	}
	if ftyp.typ == "" || moov.typ == "" || len(mediaData) == 0 {
		return mp4Inspection{}, errInvalidMP4
	}

	var movieHeader bool
	videoTracks := 0
	var inspection mp4Inspection
	err = p.walkBoxes(moov.payloadStart, moov.end, func(box mp4Box) error {
		switch box.typ {
		case "mvhd":
			if movieHeader {
				return errInvalidMP4
			}
			if err := p.validateMovieHeader(box); err != nil {
				return err
			}
			movieHeader = true
		case "trak":
			track, err := p.inspectTrack(box, mediaData)
			if err != nil {
				return err
			}
			switch track.handler {
			case "vide":
				videoTracks++
				inspection.width = track.width
				inspection.height = track.height
			case "soun":
				return fmt.Errorf("%w: audio tracks are not supported", errInvalidMP4)
			}
		}
		return nil
	})
	if err != nil {
		return mp4Inspection{}, err
	}
	if !movieHeader || videoTracks != 1 || inspection.width <= 0 || inspection.height <= 0 {
		return mp4Inspection{}, errInvalidMP4
	}
	return inspection, nil
}

func (p *mp4Parser) validateFileType(box mp4Box) error {
	if box.payloadSize() < 8 || box.payloadSize()%4 != 0 {
		return errInvalidMP4
	}
	compatible := false
	for offset := int64(0); offset < box.payloadSize(); offset += 4 {
		// The second field is the minor version, not a brand.
		if offset == 4 {
			continue
		}
		var value [4]byte
		if err := p.readAt(box.payloadStart+offset, value[:]); err != nil {
			return err
		}
		if isMP4Brand(string(value[:])) {
			compatible = true
		}
	}
	if !compatible {
		return errInvalidMP4
	}
	return nil
}

func isMP4Brand(brand string) bool {
	switch brand {
	case "isom", "iso2", "iso3", "iso4", "iso5", "iso6", "iso7", "iso8", "iso9",
		"mp41", "mp42", "avc1", "M4V ":
		return true
	default:
		return false
	}
}

func (p *mp4Parser) validateMovieHeader(box mp4Box) error {
	version, err := p.fullBoxVersion(box)
	if err != nil {
		return err
	}
	minimum := int64(100)
	timescaleOffset := int64(12)
	if version == 1 {
		minimum = 112
		timescaleOffset = 20
	} else if version != 0 {
		return errInvalidMP4
	}
	if box.payloadSize() < minimum {
		return errInvalidMP4
	}
	timescale, err := p.uint32At(box.payloadStart + timescaleOffset)
	if err != nil || timescale == 0 {
		return errInvalidMP4
	}
	return nil
}

func (p *mp4Parser) inspectTrack(box mp4Box, mediaData []mp4Range) (mp4Track, error) {
	var trackHeader, media mp4Box
	err := p.walkBoxes(box.payloadStart, box.end, func(child mp4Box) error {
		switch child.typ {
		case "tkhd":
			if trackHeader.typ != "" {
				return errInvalidMP4
			}
			trackHeader = child
		case "mdia":
			if media.typ != "" {
				return errInvalidMP4
			}
			media = child
		}
		return nil
	})
	if err != nil {
		return mp4Track{}, err
	}
	if trackHeader.typ == "" || media.typ == "" {
		return mp4Track{}, errInvalidMP4
	}
	if err := p.validateTrackHeader(trackHeader); err != nil {
		return mp4Track{}, err
	}
	return p.inspectMedia(media, mediaData)
}

func (p *mp4Parser) validateTrackHeader(box mp4Box) error {
	version, err := p.fullBoxVersion(box)
	if err != nil {
		return err
	}
	minimum := int64(84)
	trackIDOffset := int64(12)
	if version == 1 {
		minimum = 96
		trackIDOffset = 20
	} else if version != 0 {
		return errInvalidMP4
	}
	if box.payloadSize() < minimum {
		return errInvalidMP4
	}
	trackID, err := p.uint32At(box.payloadStart + trackIDOffset)
	if err != nil || trackID == 0 {
		return errInvalidMP4
	}
	return nil
}

func (p *mp4Parser) inspectMedia(box mp4Box, mediaData []mp4Range) (mp4Track, error) {
	var mediaHeader, handlerBox, mediaInfo mp4Box
	err := p.walkBoxes(box.payloadStart, box.end, func(child mp4Box) error {
		switch child.typ {
		case "mdhd":
			if mediaHeader.typ != "" {
				return errInvalidMP4
			}
			mediaHeader = child
		case "hdlr":
			if handlerBox.typ != "" {
				return errInvalidMP4
			}
			handlerBox = child
		case "minf":
			if mediaInfo.typ != "" {
				return errInvalidMP4
			}
			mediaInfo = child
		}
		return nil
	})
	if err != nil {
		return mp4Track{}, err
	}
	if mediaHeader.typ == "" || handlerBox.typ == "" || mediaInfo.typ == "" {
		return mp4Track{}, errInvalidMP4
	}
	if err := p.validateMediaHeader(mediaHeader); err != nil {
		return mp4Track{}, err
	}
	handler, err := p.handlerType(handlerBox)
	if err != nil {
		return mp4Track{}, err
	}
	track := mp4Track{handler: handler}
	if handler != "vide" {
		return track, nil
	}
	width, height, err := p.inspectVideoMediaInfo(mediaInfo, mediaData)
	if err != nil {
		return mp4Track{}, err
	}
	track.width = width
	track.height = height
	return track, nil
}

func (p *mp4Parser) validateMediaHeader(box mp4Box) error {
	version, err := p.fullBoxVersion(box)
	if err != nil {
		return err
	}
	minimum := int64(24)
	timescaleOffset := int64(12)
	if version == 1 {
		minimum = 36
		timescaleOffset = 20
	} else if version != 0 {
		return errInvalidMP4
	}
	if box.payloadSize() < minimum {
		return errInvalidMP4
	}
	timescale, err := p.uint32At(box.payloadStart + timescaleOffset)
	if err != nil || timescale == 0 {
		return errInvalidMP4
	}
	return nil
}

func (p *mp4Parser) handlerType(box mp4Box) (string, error) {
	if box.payloadSize() < 24 {
		return "", errInvalidMP4
	}
	version, err := p.fullBoxVersion(box)
	if err != nil || version != 0 {
		return "", errInvalidMP4
	}
	var handler [4]byte
	if err := p.readAt(box.payloadStart+8, handler[:]); err != nil {
		return "", err
	}
	return string(handler[:]), nil
}

func (p *mp4Parser) inspectVideoMediaInfo(box mp4Box, mediaData []mp4Range) (int, int, error) {
	var sampleTable mp4Box
	err := p.walkBoxes(box.payloadStart, box.end, func(child mp4Box) error {
		if child.typ == "stbl" {
			if sampleTable.typ != "" {
				return errInvalidMP4
			}
			sampleTable = child
		}
		return nil
	})
	if err != nil {
		return 0, 0, err
	}
	if sampleTable.typ == "" {
		return 0, 0, errInvalidMP4
	}
	return p.inspectVideoSampleTable(sampleTable, mediaData)
}

func (p *mp4Parser) inspectVideoSampleTable(box mp4Box, mediaData []mp4Range) (int, int, error) {
	var stsd, stts, stsc, sampleSizes, chunkOffsets mp4Box
	err := p.walkBoxes(box.payloadStart, box.end, func(child mp4Box) error {
		var target *mp4Box
		switch child.typ {
		case "stsd":
			target = &stsd
		case "stts":
			target = &stts
		case "stsc":
			target = &stsc
		case "stsz", "stz2":
			target = &sampleSizes
		case "stco", "co64":
			target = &chunkOffsets
		default:
			return nil
		}
		if target.typ != "" {
			return errInvalidMP4
		}
		*target = child
		return nil
	})
	if err != nil {
		return 0, 0, err
	}
	if stsd.typ == "" || stts.typ == "" || stsc.typ == "" || sampleSizes.typ == "" || chunkOffsets.typ == "" {
		return 0, 0, errInvalidMP4
	}
	width, height, descriptions, err := p.inspectVideoSampleDescriptions(stsd)
	if err != nil {
		return 0, 0, err
	}
	sampleCount, err := p.validateSampleSizes(sampleSizes)
	if err != nil {
		return 0, 0, err
	}
	timedSamples, err := p.validateTimeToSample(stts)
	if err != nil || timedSamples != uint64(sampleCount) {
		return 0, 0, errInvalidMP4
	}
	if err := p.validateSampleToChunk(stsc, descriptions); err != nil {
		return 0, 0, err
	}
	if err := p.validateChunkOffsets(chunkOffsets, mediaData); err != nil {
		return 0, 0, err
	}
	return width, height, nil
}

func (p *mp4Parser) inspectVideoSampleDescriptions(box mp4Box) (int, int, uint32, error) {
	if box.payloadSize() < 8 {
		return 0, 0, 0, errInvalidMP4
	}
	version, err := p.fullBoxVersion(box)
	if err != nil || version != 0 {
		return 0, 0, 0, errInvalidMP4
	}
	entryCount, err := p.uint32At(box.payloadStart + 4)
	if err != nil || entryCount != 1 {
		return 0, 0, 0, errInvalidMP4
	}
	var width, height int
	seen := uint32(0)
	err = p.walkBoxes(box.payloadStart+8, box.end, func(entry mp4Box) error {
		seen++
		if entry.typ != "avc1" && entry.typ != "avc3" {
			return fmt.Errorf("%w: video is not H.264", errInvalidMP4)
		}
		entryWidth, entryHeight, err := p.inspectAVCSampleEntry(entry)
		if err != nil {
			return err
		}
		width, height = entryWidth, entryHeight
		return nil
	})
	if err != nil {
		return 0, 0, 0, err
	}
	if seen != entryCount {
		return 0, 0, 0, errInvalidMP4
	}
	return width, height, entryCount, nil
}

func (p *mp4Parser) inspectAVCSampleEntry(box mp4Box) (int, int, error) {
	const visualSampleEntrySize = int64(78)
	if box.payloadSize() < visualSampleEntrySize {
		return 0, 0, errInvalidMP4
	}
	dataReference, err := p.uint16At(box.payloadStart + 6)
	if err != nil || dataReference == 0 {
		return 0, 0, errInvalidMP4
	}
	widthValue, err := p.uint16At(box.payloadStart + 24)
	if err != nil {
		return 0, 0, err
	}
	heightValue, err := p.uint16At(box.payloadStart + 26)
	if err != nil || widthValue == 0 || heightValue == 0 {
		return 0, 0, errInvalidMP4
	}
	avcConfiguration := false
	err = p.walkBoxes(box.payloadStart+visualSampleEntrySize, box.end, func(child mp4Box) error {
		if child.typ != "avcC" {
			return nil
		}
		if avcConfiguration {
			return errInvalidMP4
		}
		if err := p.validateAVCConfiguration(child); err != nil {
			return err
		}
		avcConfiguration = true
		return nil
	})
	if err != nil {
		return 0, 0, err
	}
	if !avcConfiguration {
		return 0, 0, errInvalidMP4
	}
	return int(widthValue), int(heightValue), nil
}

func (p *mp4Parser) validateAVCConfiguration(box mp4Box) error {
	if box.payloadSize() < 7 || box.payloadSize() > 1<<20 {
		return errInvalidMP4
	}
	content := make([]byte, box.payloadSize())
	if err := p.readAt(box.payloadStart, content); err != nil {
		return err
	}
	if content[0] != 1 || content[1] == 0 || content[4]&0xfc != 0xfc || content[5]&0xe0 != 0xe0 {
		return errInvalidMP4
	}
	offset := 6
	sequenceParameters := int(content[5] & 0x1f)
	if sequenceParameters == 0 {
		return errInvalidMP4
	}
	for index := 0; index < sequenceParameters; index++ {
		if offset+2 > len(content) {
			return errInvalidMP4
		}
		size := int(binary.BigEndian.Uint16(content[offset : offset+2]))
		offset += 2
		if size == 0 || offset+size > len(content) || content[offset]&0x1f != 7 {
			return errInvalidMP4
		}
		offset += size
	}
	if offset >= len(content) {
		return errInvalidMP4
	}
	pictureParameters := int(content[offset])
	offset++
	if pictureParameters == 0 {
		return errInvalidMP4
	}
	for index := 0; index < pictureParameters; index++ {
		if offset+2 > len(content) {
			return errInvalidMP4
		}
		size := int(binary.BigEndian.Uint16(content[offset : offset+2]))
		offset += 2
		if size == 0 || offset+size > len(content) || content[offset]&0x1f != 8 {
			return errInvalidMP4
		}
		offset += size
	}
	return nil
}

func (p *mp4Parser) validateSampleSizes(box mp4Box) (uint32, error) {
	if box.typ == "stsz" {
		if box.payloadSize() < 12 {
			return 0, errInvalidMP4
		}
		version, err := p.fullBoxVersion(box)
		if err != nil || version != 0 {
			return 0, errInvalidMP4
		}
		uniformSize, err := p.uint32At(box.payloadStart + 4)
		if err != nil {
			return 0, err
		}
		count, err := p.uint32At(box.payloadStart + 8)
		if err != nil || count == 0 {
			return 0, errInvalidMP4
		}
		expected := int64(12)
		if uniformSize == 0 {
			expected += int64(count) * 4
		}
		if expected != box.payloadSize() {
			return 0, errInvalidMP4
		}
		return count, nil
	}

	if box.payloadSize() < 12 {
		return 0, errInvalidMP4
	}
	version, err := p.fullBoxVersion(box)
	if err != nil || version != 0 {
		return 0, errInvalidMP4
	}
	var field [4]byte
	if err := p.readAt(box.payloadStart+4, field[:]); err != nil {
		return 0, err
	}
	fieldSize := field[3]
	if fieldSize != 4 && fieldSize != 8 && fieldSize != 16 {
		return 0, errInvalidMP4
	}
	count, err := p.uint32At(box.payloadStart + 8)
	if err != nil || count == 0 {
		return 0, errInvalidMP4
	}
	dataBytes := (uint64(count)*uint64(fieldSize) + 7) / 8
	if dataBytes > uint64(^uint64(0)>>1) || int64(dataBytes)+12 != box.payloadSize() {
		return 0, errInvalidMP4
	}
	return count, nil
}

func (p *mp4Parser) validateTimeToSample(box mp4Box) (uint64, error) {
	if box.payloadSize() < 8 {
		return 0, errInvalidMP4
	}
	version, err := p.fullBoxVersion(box)
	if err != nil || version != 0 {
		return 0, errInvalidMP4
	}
	count, err := p.uint32At(box.payloadStart + 4)
	if err != nil || count == 0 || int64(count) > (box.payloadSize()-8)/8 || int64(count)*8+8 != box.payloadSize() {
		return 0, errInvalidMP4
	}
	var samples uint64
	for index := uint32(0); index < count; index++ {
		entryOffset := box.payloadStart + 8 + int64(index)*8
		entrySamples, err := p.uint32At(entryOffset)
		if err != nil || entrySamples == 0 {
			return 0, errInvalidMP4
		}
		delta, err := p.uint32At(entryOffset + 4)
		if err != nil || delta == 0 || samples > ^uint64(0)-uint64(entrySamples) {
			return 0, errInvalidMP4
		}
		samples += uint64(entrySamples)
	}
	return samples, nil
}

func (p *mp4Parser) validateSampleToChunk(box mp4Box, descriptions uint32) error {
	if box.payloadSize() < 8 {
		return errInvalidMP4
	}
	version, err := p.fullBoxVersion(box)
	if err != nil || version != 0 {
		return errInvalidMP4
	}
	count, err := p.uint32At(box.payloadStart + 4)
	if err != nil || count == 0 || int64(count) > (box.payloadSize()-8)/12 || int64(count)*12+8 != box.payloadSize() {
		return errInvalidMP4
	}
	previousChunk := uint32(0)
	for index := uint32(0); index < count; index++ {
		entryOffset := box.payloadStart + 8 + int64(index)*12
		firstChunk, err := p.uint32At(entryOffset)
		if err != nil || firstChunk <= previousChunk || (index == 0 && firstChunk != 1) {
			return errInvalidMP4
		}
		samplesPerChunk, err := p.uint32At(entryOffset + 4)
		if err != nil || samplesPerChunk == 0 {
			return errInvalidMP4
		}
		description, err := p.uint32At(entryOffset + 8)
		if err != nil || description == 0 || description > descriptions {
			return errInvalidMP4
		}
		previousChunk = firstChunk
	}
	return nil
}

func (p *mp4Parser) validateChunkOffsets(box mp4Box, mediaData []mp4Range) error {
	if box.payloadSize() < 8 {
		return errInvalidMP4
	}
	version, err := p.fullBoxVersion(box)
	if err != nil || version != 0 {
		return errInvalidMP4
	}
	count, err := p.uint32At(box.payloadStart + 4)
	entrySize := int64(4)
	if box.typ == "co64" {
		entrySize = 8
	}
	if err != nil || count == 0 || int64(count) > (box.payloadSize()-8)/entrySize || int64(count)*entrySize+8 != box.payloadSize() {
		return errInvalidMP4
	}
	for index := uint32(0); index < count; index++ {
		offset := box.payloadStart + 8 + int64(index)*entrySize
		var chunkOffset uint64
		if entrySize == 4 {
			value, err := p.uint32At(offset)
			if err != nil {
				return err
			}
			chunkOffset = uint64(value)
		} else {
			value, err := p.uint64At(offset)
			if err != nil {
				return err
			}
			chunkOffset = value
		}
		insideMediaData := false
		for _, dataRange := range mediaData {
			if chunkOffset >= dataRange.start && chunkOffset < dataRange.end {
				insideMediaData = true
				break
			}
		}
		if !insideMediaData {
			return errInvalidMP4
		}
	}
	return nil
}

func (p *mp4Parser) walkBoxes(start, end int64, visit func(mp4Box) error) error {
	if start < 0 || end < start || end > p.fileSize {
		return errInvalidMP4
	}
	for offset := start; offset < end; {
		if end-offset < 8 || p.boxes >= maxMP4Boxes {
			return errInvalidMP4
		}
		var header [16]byte
		if err := p.readAt(offset, header[:8]); err != nil {
			return err
		}
		p.boxes++
		size := uint64(binary.BigEndian.Uint32(header[:4]))
		headerSize := int64(8)
		if size == 1 {
			if end-offset < 16 {
				return errInvalidMP4
			}
			if err := p.readAt(offset+8, header[8:16]); err != nil {
				return err
			}
			size = binary.BigEndian.Uint64(header[8:16])
			headerSize = 16
		} else if size == 0 {
			size = uint64(end - offset)
		}
		if size < uint64(headerSize) || size > uint64(end-offset) {
			return errInvalidMP4
		}
		boxEnd := offset + int64(size)
		box := mp4Box{
			typ:          string(header[4:8]),
			payloadStart: offset + headerSize,
			end:          boxEnd,
		}
		if err := visit(box); err != nil {
			return err
		}
		offset = boxEnd
	}
	return nil
}

func (p *mp4Parser) fullBoxVersion(box mp4Box) (byte, error) {
	if box.payloadSize() < 4 {
		return 0, errInvalidMP4
	}
	var value [1]byte
	if err := p.readAt(box.payloadStart, value[:]); err != nil {
		return 0, err
	}
	return value[0], nil
}

func (p *mp4Parser) uint16At(offset int64) (uint16, error) {
	var value [2]byte
	if err := p.readAt(offset, value[:]); err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint16(value[:]), nil
}

func (p *mp4Parser) uint32At(offset int64) (uint32, error) {
	var value [4]byte
	if err := p.readAt(offset, value[:]); err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint32(value[:]), nil
}

func (p *mp4Parser) uint64At(offset int64) (uint64, error) {
	var value [8]byte
	if err := p.readAt(offset, value[:]); err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint64(value[:]), nil
}

func (p *mp4Parser) readAt(offset int64, destination []byte) error {
	if offset < 0 || int64(len(destination)) > p.fileSize-offset {
		return errInvalidMP4
	}
	read, err := p.file.ReadAt(destination, offset)
	if err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	if read != len(destination) {
		return errInvalidMP4
	}
	return nil
}
