package backend

import "time"

const (
	defaultUserQuotaBytes int64 = 10 << 30
	defaultRetentionDays        = 90
	thumbnailMaxAttempts        = 5
)

type thumbnailCommitResult int

const (
	thumbnailMissing thumbnailCommitResult = iota
	thumbnailCommitted
	thumbnailQuotaExceeded
)

type Config struct {
	DataDir              string
	Tokens               map[string]string
	AdminSpaceID         string
	CookieSecure         bool
	SessionTTL           time.Duration
	DefaultQuotaBytes    int64
	DefaultRetentionDays int
	CleanupInterval      time.Duration
	MaxUploadBytes       int64
	MaxPixels            int64
	ThumbnailMax         int
	WebPQuality          int
	ThumbQuality         int
	QueueDepth           int
	RateLimits           RateLimitConfig
}

type RateLimitConfig struct {
	LoginPerMinute             int
	LoginBurst                 int
	LoginGlobalPerMinute       int
	LoginGlobalBurst           int
	UploadPerHour              int
	UploadConcurrentPerOwner   int
	OriginalPerHour            int
	ThumbnailPerImagePerMinute int
	ThumbnailPerImagePerHour   int
	ThumbnailPerOwnerPerHour   int
}

func (cfg RateLimitConfig) withDefaults() RateLimitConfig {
	if cfg.LoginPerMinute <= 0 {
		cfg.LoginPerMinute = 10
	}
	if cfg.LoginBurst <= 0 {
		cfg.LoginBurst = 5
	}
	if cfg.LoginGlobalPerMinute <= 0 {
		cfg.LoginGlobalPerMinute = 120
	}
	if cfg.LoginGlobalBurst <= 0 {
		cfg.LoginGlobalBurst = 30
	}
	if cfg.UploadPerHour <= 0 {
		cfg.UploadPerHour = 500
	}
	if cfg.UploadConcurrentPerOwner <= 0 {
		cfg.UploadConcurrentPerOwner = 2
	}
	if cfg.OriginalPerHour <= 0 {
		cfg.OriginalPerHour = 500
	}
	if cfg.ThumbnailPerImagePerMinute <= 0 {
		cfg.ThumbnailPerImagePerMinute = 5
	}
	if cfg.ThumbnailPerImagePerHour <= 0 {
		cfg.ThumbnailPerImagePerHour = 10
	}
	if cfg.ThumbnailPerOwnerPerHour <= 0 {
		cfg.ThumbnailPerOwnerPerHour = 2000
	}
	return cfg
}

type imageRecord struct {
	OwnerID                   string
	ID                        string
	Extension                 string
	MediaType                 string
	Width                     int
	Height                    int
	ByteSize                  int64
	ThumbnailSize             int64
	ThumbnailAttempts         int
	ThumbnailNextAttemptMilli int64
	Animated                  bool
	CreatedAtMilli            int64
}

type principal struct {
	OwnerID string
	IsAdmin bool
}

type accountResponse struct {
	SpaceID       string `json:"space_id"`
	IsAdmin       bool   `json:"is_admin"`
	QuotaBytes    int64  `json:"quota_bytes"`
	UsedBytes     int64  `json:"used_bytes"`
	ImageCount    int64  `json:"image_count"`
	RetentionDays int    `json:"retention_days"`
	Enabled       bool   `json:"enabled"`
	CreatedAt     string `json:"created_at,omitempty"`
}

type accountRecord struct {
	SpaceID        string
	IsAdmin        bool
	QuotaBytes     int64
	UsedBytes      int64
	ImageCount     int64
	RetentionDays  int
	Enabled        bool
	CreatedAtMilli int64
}

func (record accountRecord) response() accountResponse {
	return accountResponse{
		SpaceID:       record.SpaceID,
		IsAdmin:       record.IsAdmin,
		QuotaBytes:    record.QuotaBytes,
		UsedBytes:     record.UsedBytes,
		ImageCount:    record.ImageCount,
		RetentionDays: record.RetentionDays,
		Enabled:       record.Enabled,
		CreatedAt:     time.UnixMilli(record.CreatedAtMilli).UTC().Format(time.RFC3339Nano),
	}
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
