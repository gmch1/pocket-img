package backend

import (
	"log"
	"math"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"
)

const clientIPHeader = "X-PocketIMG-Client-IP"

type windowRule struct {
	key    string
	limit  int
	window time.Duration
}

type eventWindow struct {
	window time.Duration
	events []time.Time
}

type slidingWindowLimiter struct {
	mu          sync.Mutex
	windows     map[string]*eventWindow
	lastCleanup time.Time
}

func newSlidingWindowLimiter() *slidingWindowLimiter {
	return &slidingWindowLimiter{windows: make(map[string]*eventWindow)}
}

func (limiter *slidingWindowLimiter) allow(now time.Time, rules ...windowRule) (bool, time.Duration) {
	limiter.mu.Lock()
	defer limiter.mu.Unlock()

	limiter.cleanup(now)
	retryAfter := time.Duration(0)
	resolved := make([]*eventWindow, 0, len(rules))
	for _, rule := range rules {
		window := limiter.windows[rule.key]
		if window == nil {
			window = &eventWindow{window: rule.window}
			limiter.windows[rule.key] = window
		}
		window.events = trimEvents(window.events, now.Add(-rule.window))
		resolved = append(resolved, window)
		if len(window.events) < rule.limit {
			continue
		}
		candidate := window.events[0].Add(rule.window).Sub(now)
		if candidate > retryAfter {
			retryAfter = candidate
		}
	}
	if retryAfter > 0 {
		return false, retryAfter
	}
	for _, window := range resolved {
		window.events = append(window.events, now)
	}
	return true, 0
}

func (limiter *slidingWindowLimiter) cleanup(now time.Time) {
	if !limiter.lastCleanup.IsZero() && now.Sub(limiter.lastCleanup) < time.Minute {
		return
	}
	for key, window := range limiter.windows {
		window.events = trimEvents(window.events, now.Add(-window.window))
		if len(window.events) == 0 {
			delete(limiter.windows, key)
		}
	}
	limiter.lastCleanup = now
}

func trimEvents(events []time.Time, cutoff time.Time) []time.Time {
	first := 0
	for first < len(events) && !events[first].After(cutoff) {
		first++
	}
	if first == len(events) {
		return nil
	}
	if first > 0 {
		copy(events, events[first:])
		events = events[:len(events)-first]
	}
	return events
}

type tokenBucketRule struct {
	key             string
	tokensPerSecond float64
	burst           float64
}

type tokenBucket struct {
	tokens   float64
	last     time.Time
	lastSeen time.Time
}

type tokenBucketLimiter struct {
	mu          sync.Mutex
	buckets     map[string]tokenBucket
	lastCleanup time.Time
}

func newTokenBucketLimiter() *tokenBucketLimiter {
	return &tokenBucketLimiter{buckets: make(map[string]tokenBucket)}
}

func (limiter *tokenBucketLimiter) allow(now time.Time, rules ...tokenBucketRule) (bool, time.Duration) {
	limiter.mu.Lock()
	defer limiter.mu.Unlock()

	if limiter.lastCleanup.IsZero() || now.Sub(limiter.lastCleanup) >= 10*time.Minute {
		for key, bucket := range limiter.buckets {
			if now.Sub(bucket.lastSeen) >= time.Hour {
				delete(limiter.buckets, key)
			}
		}
		limiter.lastCleanup = now
	}

	resolved := make([]tokenBucket, len(rules))
	retryAfter := time.Duration(0)
	for index, rule := range rules {
		bucket, found := limiter.buckets[rule.key]
		if !found {
			bucket = tokenBucket{tokens: rule.burst, last: now}
		}
		elapsed := now.Sub(bucket.last).Seconds()
		if elapsed > 0 {
			bucket.tokens = math.Min(rule.burst, bucket.tokens+elapsed*rule.tokensPerSecond)
			bucket.last = now
		}
		bucket.lastSeen = now
		resolved[index] = bucket
		if bucket.tokens >= 1 {
			continue
		}
		candidate := time.Duration(math.Ceil((1 - bucket.tokens) / rule.tokensPerSecond * float64(time.Second)))
		if candidate > retryAfter {
			retryAfter = candidate
		}
	}
	for index, rule := range rules {
		bucket := resolved[index]
		if retryAfter == 0 {
			bucket.tokens--
		}
		limiter.buckets[rule.key] = bucket
	}
	if retryAfter > 0 {
		return false, retryAfter
	}
	return true, 0
}

type rateLimiter struct {
	cfg           RateLimitConfig
	windows       *slidingWindowLimiter
	buckets       *tokenBucketLimiter
	uploadMu      sync.Mutex
	activeUploads map[string]int
	logMu         sync.Mutex
	lastLimitLog  map[string]time.Time
}

func newRateLimiter(cfg RateLimitConfig) *rateLimiter {
	return &rateLimiter{
		cfg:           cfg,
		windows:       newSlidingWindowLimiter(),
		buckets:       newTokenBucketLimiter(),
		activeUploads: make(map[string]int),
		lastLimitLog:  make(map[string]time.Time),
	}
}

func (limiter *rateLimiter) allowLoginSource(now time.Time, source string) (bool, time.Duration) {
	return limiter.buckets.allow(now,
		tokenBucketRule{
			key:             "login-global",
			tokensPerSecond: float64(limiter.cfg.LoginGlobalPerMinute) / 60,
			burst:           float64(limiter.cfg.LoginGlobalBurst),
		},
		tokenBucketRule{
			key:             "login-source\x00" + source,
			tokensPerSecond: float64(limiter.cfg.LoginPerMinute) / 60,
			burst:           float64(limiter.cfg.LoginBurst),
		},
	)
}

func (limiter *rateLimiter) allowLoginOwner(now time.Time, ownerID string) (bool, time.Duration) {
	return limiter.buckets.allow(now, tokenBucketRule{
		key:             "login-owner\x00" + ownerID,
		tokensPerSecond: float64(limiter.cfg.LoginPerMinute) / 60,
		burst:           float64(limiter.cfg.LoginBurst),
	})
}

func (limiter *rateLimiter) acquireUpload(ownerID string) (func(), bool) {
	limiter.uploadMu.Lock()
	if limiter.activeUploads[ownerID] >= limiter.cfg.UploadConcurrentPerOwner {
		limiter.uploadMu.Unlock()
		return nil, false
	}
	limiter.activeUploads[ownerID]++
	limiter.uploadMu.Unlock()

	var once sync.Once
	return func() {
		once.Do(func() {
			limiter.uploadMu.Lock()
			limiter.activeUploads[ownerID]--
			if limiter.activeUploads[ownerID] == 0 {
				delete(limiter.activeUploads, ownerID)
			}
			limiter.uploadMu.Unlock()
		})
	}, true
}

func (limiter *rateLimiter) allowUpload(now time.Time, ownerID string) (bool, time.Duration) {
	return limiter.windows.allow(now, windowRule{
		key: "upload-hour\x00" + ownerID, limit: limiter.cfg.UploadPerHour, window: time.Hour,
	})
}

func (limiter *rateLimiter) allowOriginal(now time.Time, ownerID string) (bool, time.Duration) {
	return limiter.windows.allow(now, windowRule{
		key: "original-hour\x00" + ownerID, limit: limiter.cfg.OriginalPerHour, window: time.Hour,
	})
}

func (limiter *rateLimiter) allowThumbnail(now time.Time, ownerID, imageID string) (bool, time.Duration) {
	prefix := ownerID + "\x00" + imageID
	return limiter.windows.allow(now,
		windowRule{
			key:   "thumbnail-owner-hour\x00" + ownerID,
			limit: limiter.cfg.ThumbnailPerOwnerPerHour, window: time.Hour,
		},
		windowRule{
			key:   "thumbnail-image-hour\x00" + prefix,
			limit: limiter.cfg.ThumbnailPerImagePerHour, window: time.Hour,
		},
		windowRule{
			key:   "thumbnail-image-minute\x00" + prefix,
			limit: limiter.cfg.ThumbnailPerImagePerMinute, window: time.Minute,
		},
	)
}

func (limiter *rateLimiter) reject(
	w http.ResponseWriter,
	now time.Time,
	category, ownerID, imageID, source string,
	retryAfter time.Duration,
) {
	seconds := max(1, int(math.Ceil(retryAfter.Seconds())))
	w.Header().Set("Retry-After", strconv.Itoa(seconds))
	w.Header().Set("Cache-Control", "no-store")
	limiter.logRejection(now, category, ownerID, imageID, source, time.Duration(seconds)*time.Second)
	writeError(w, http.StatusTooManyRequests, "rate limit exceeded")
}

func (limiter *rateLimiter) logRejection(
	now time.Time,
	category, ownerID, imageID, source string,
	retryAfter time.Duration,
) {
	logKey := category + "\x00" + ownerID
	limiter.logMu.Lock()
	last := limiter.lastLimitLog[logKey]
	if !last.IsZero() && now.Sub(last) < time.Minute {
		limiter.logMu.Unlock()
		return
	}
	limiter.lastLimitLog[logKey] = now
	for key, loggedAt := range limiter.lastLimitLog {
		if now.Sub(loggedAt) >= time.Hour {
			delete(limiter.lastLimitLog, key)
		}
	}
	limiter.logMu.Unlock()

	if ownerID != "" {
		log.Printf("rate limit exceeded category=%s space=%q image=%q retry_after=%s", category, ownerID, imageID, retryAfter)
		return
	}
	log.Printf("rate limit exceeded category=%s source=%q retry_after=%s", category, source, retryAfter)
}

func requestSource(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	remote, remoteErr := netip.ParseAddr(strings.TrimSpace(host))
	if remoteErr == nil && remote.IsLoopback() {
		if forwarded, err := netip.ParseAddr(strings.TrimSpace(r.Header.Get(clientIPHeader))); err == nil {
			return forwarded.Unmap().String()
		}
	}
	if remoteErr == nil {
		return remote.Unmap().String()
	}
	return "unknown"
}
