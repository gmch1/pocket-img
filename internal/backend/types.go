package backend

import "time"

type Config struct {
	DataDir        string
	Tokens         map[string]string
	CookieSecure   bool
	SessionTTL     time.Duration
	MaxUploadBytes int64
	MaxPixels      int64
	ThumbnailMax   int
	WebPQuality    int
	ThumbQuality   int
	QueueDepth     int
}

type imageRecord struct {
	OwnerID        string
	ID             string
	Extension      string
	MediaType      string
	Width          int
	Height         int
	ByteSize       int64
	ThumbnailSize  int64
	Animated       bool
	CreatedAtMilli int64
}

type imageResponse struct {
	ID            string `json:"id"`
	Width         int    `json:"width"`
	Height        int    `json:"height"`
	ByteSize      int64  `json:"byte_size"`
	ThumbnailSize int64  `json:"thumbnail_size"`
	Animated      bool   `json:"animated"`
	CreatedAt     string `json:"created_at"`
	URL           string `json:"url"`
	ThumbnailURL  string `json:"thumbnail_url"`
}

func (record imageRecord) response() imageResponse {
	url := "/i/" + record.ID + "." + record.Extension
	thumbnailURL := url
	if record.ThumbnailSize > 0 {
		thumbnailURL = "/t/" + record.ID + ".webp"
	}
	return imageResponse{
		ID:            record.ID,
		Width:         record.Width,
		Height:        record.Height,
		ByteSize:      record.ByteSize,
		ThumbnailSize: record.ThumbnailSize,
		Animated:      record.Animated,
		CreatedAt:     time.UnixMilli(record.CreatedAtMilli).UTC().Format(time.RFC3339Nano),
		URL:           url,
		ThumbnailURL:  thumbnailURL,
	}
}
