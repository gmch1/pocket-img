package backend

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type store struct {
	db *sql.DB
}

func openStore(dataDir string) (*store, error) {
	dbPath := filepath.Join(dataDir, "metadata.sqlite3")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	statements := []string{
		`PRAGMA journal_mode=WAL`,
		`PRAGMA synchronous=NORMAL`,
		`PRAGMA foreign_keys=ON`,
		`PRAGMA busy_timeout=5000`,
		`CREATE TABLE IF NOT EXISTS images (
			id TEXT PRIMARY KEY,
			owner_id TEXT NOT NULL,
			extension TEXT NOT NULL,
			media_type TEXT NOT NULL,
			width INTEGER NOT NULL,
			height INTEGER NOT NULL,
			byte_size INTEGER NOT NULL,
			thumbnail_size INTEGER NOT NULL,
			thumbnail_attempts INTEGER NOT NULL DEFAULT 0,
			thumbnail_next_attempt_ms INTEGER NOT NULL DEFAULT 0,
			animated INTEGER NOT NULL,
			created_at_ms INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS sessions (
			token_hash BLOB PRIMARY KEY,
			owner_id TEXT NOT NULL,
			token_fingerprint BLOB NOT NULL,
			expires_at_ms INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS users (
			id TEXT PRIMARY KEY,
			token_fingerprint BLOB UNIQUE,
			enabled INTEGER NOT NULL,
			is_admin INTEGER NOT NULL DEFAULT 0,
			quota_bytes INTEGER NOT NULL DEFAULT 10737418240,
			retention_days INTEGER NOT NULL DEFAULT 90,
			managed_by_config INTEGER NOT NULL DEFAULT 1,
			created_at_ms INTEGER NOT NULL
		)`,
	}
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			db.Close()
			return nil, fmt.Errorf("initialize sqlite: %w", err)
		}
	}
	if err := ensureColumn(db, "images", "owner_id", `ALTER TABLE images ADD COLUMN owner_id TEXT NOT NULL DEFAULT 'default'`); err != nil {
		db.Close()
		return nil, err
	}
	if err := ensureColumn(db, "sessions", "owner_id", `ALTER TABLE sessions ADD COLUMN owner_id TEXT NOT NULL DEFAULT 'default'`); err != nil {
		db.Close()
		return nil, err
	}
	for _, migration := range []struct {
		table     string
		column    string
		statement string
	}{
		{"users", "is_admin", `ALTER TABLE users ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0`},
		{"users", "quota_bytes", fmt.Sprintf(`ALTER TABLE users ADD COLUMN quota_bytes INTEGER NOT NULL DEFAULT %d`, defaultUserQuotaBytes)},
		{"users", "retention_days", fmt.Sprintf(`ALTER TABLE users ADD COLUMN retention_days INTEGER NOT NULL DEFAULT %d`, defaultRetentionDays)},
		{"users", "managed_by_config", `ALTER TABLE users ADD COLUMN managed_by_config INTEGER NOT NULL DEFAULT 1`},
		{"images", "thumbnail_attempts", `ALTER TABLE images ADD COLUMN thumbnail_attempts INTEGER NOT NULL DEFAULT 0`},
		{"images", "thumbnail_next_attempt_ms", `ALTER TABLE images ADD COLUMN thumbnail_next_attempt_ms INTEGER NOT NULL DEFAULT 0`},
	} {
		if err := ensureColumn(db, migration.table, migration.column, migration.statement); err != nil {
			db.Close()
			return nil, err
		}
	}
	for _, statement := range []string{
		`CREATE INDEX IF NOT EXISTS images_owner_created_idx ON images(owner_id, created_at_ms DESC, id DESC)`,
		`CREATE INDEX IF NOT EXISTS sessions_expiry_idx ON sessions(expires_at_ms)`,
		`CREATE INDEX IF NOT EXISTS sessions_owner_idx ON sessions(owner_id)`,
		`CREATE INDEX IF NOT EXISTS images_thumbnail_queue_idx ON images(thumbnail_size, thumbnail_next_attempt_ms, created_at_ms)`,
	} {
		if _, err := db.Exec(statement); err != nil {
			db.Close()
			return nil, fmt.Errorf("initialize sqlite indexes: %w", err)
		}
	}

	return &store{db: db}, nil
}

func ensureColumn(db *sql.DB, table, column, migration string) error {
	rows, err := db.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		return fmt.Errorf("inspect sqlite table %s: %w", table, err)
	}
	found := false
	for rows.Next() {
		var cid int
		var name, columnType string
		var notNull, primaryKey int
		var defaultValue any
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &primaryKey); err != nil {
			rows.Close()
			return err
		}
		if name == column {
			found = true
		}
	}
	if err := rows.Close(); err != nil {
		return err
	}
	if found {
		return nil
	}
	if _, err := db.Exec(migration); err != nil {
		return fmt.Errorf("migrate sqlite table %s: %w", table, err)
	}
	return nil
}

func (s *store) close() error {
	return s.db.Close()
}

func (s *store) insertImage(ctx context.Context, record imageRecord) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO images (
			id, owner_id, extension, media_type, width, height, byte_size,
			thumbnail_size, animated, created_at_ms
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		record.ID, record.OwnerID, record.Extension, record.MediaType, record.Width, record.Height,
		record.ByteSize, record.ThumbnailSize, record.Animated, record.CreatedAtMilli,
	)
	return err
}

func (s *store) insertImageWithinQuota(ctx context.Context, record imageRecord) (bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()

	var quotaBytes int64
	if err := tx.QueryRowContext(ctx, `SELECT quota_bytes FROM users WHERE id = ? AND enabled = 1`, record.OwnerID).Scan(&quotaBytes); err != nil {
		if err == sql.ErrNoRows {
			return false, nil
		}
		return false, err
	}
	var usedBytes int64
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE(SUM(byte_size + CASE WHEN thumbnail_size > 0 THEN thumbnail_size ELSE 0 END), 0)
		FROM images WHERE owner_id = ?`, record.OwnerID).Scan(&usedBytes); err != nil {
		return false, err
	}
	if record.ByteSize > quotaBytes || usedBytes > quotaBytes-record.ByteSize {
		return false, nil
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO images (
		id, owner_id, extension, media_type, width, height, byte_size,
		thumbnail_size, animated, created_at_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		record.ID, record.OwnerID, record.Extension, record.MediaType, record.Width, record.Height,
		record.ByteSize, record.ThumbnailSize, record.Animated, record.CreatedAtMilli,
	); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return true, nil
}

func (s *store) listPendingThumbnails(ctx context.Context, now time.Time, limit int) ([]imageRecord, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT owner_id, id, extension, media_type, width, height,
		byte_size, thumbnail_size, animated, created_at_ms, thumbnail_attempts, thumbnail_next_attempt_ms FROM images
		WHERE thumbnail_size = 0 AND thumbnail_next_attempt_ms <= ?
		ORDER BY thumbnail_next_attempt_ms, created_at_ms, id LIMIT ?`, now.UnixMilli(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var records []imageRecord
	for rows.Next() {
		var record imageRecord
		if err := rows.Scan(
			&record.OwnerID, &record.ID, &record.Extension, &record.MediaType, &record.Width,
			&record.Height, &record.ByteSize, &record.ThumbnailSize,
			&record.Animated, &record.CreatedAtMilli, &record.ThumbnailAttempts,
			&record.ThumbnailNextAttemptMilli,
		); err != nil {
			return nil, err
		}
		records = append(records, record)
	}
	return records, rows.Err()
}

func (s *store) commitThumbnailWithinQuota(ctx context.Context, ownerID, id string, size int64) (thumbnailCommitResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return thumbnailMissing, err
	}
	defer tx.Rollback()

	var quotaBytes int64
	var pending int
	if err := tx.QueryRowContext(ctx, `SELECT users.quota_bytes, images.thumbnail_size
		FROM images JOIN users ON users.id = images.owner_id
		WHERE images.owner_id = ? AND images.id = ?`, ownerID, id).Scan(&quotaBytes, &pending); err != nil {
		if err == sql.ErrNoRows {
			return thumbnailMissing, nil
		}
		return thumbnailMissing, err
	}
	if pending != 0 {
		return thumbnailMissing, nil
	}
	var usedBytes int64
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE(SUM(byte_size + CASE WHEN thumbnail_size > 0 THEN thumbnail_size ELSE 0 END), 0)
		FROM images WHERE owner_id = ?`, ownerID).Scan(&usedBytes); err != nil {
		return thumbnailMissing, err
	}
	result := thumbnailCommitted
	thumbnailSize := size
	if size > quotaBytes || usedBytes > quotaBytes-size {
		result = thumbnailQuotaExceeded
		thumbnailSize = thumbnailFailedSize
	}
	updated, err := tx.ExecContext(ctx, `UPDATE images SET thumbnail_size = ?, thumbnail_next_attempt_ms = 0
		WHERE owner_id = ? AND id = ? AND thumbnail_size = 0`, thumbnailSize, ownerID, id)
	if err != nil {
		return thumbnailMissing, err
	}
	rows, err := updated.RowsAffected()
	if err != nil || rows != 1 {
		return thumbnailMissing, err
	}
	if err := tx.Commit(); err != nil {
		return thumbnailMissing, err
	}
	return result, nil
}

func (s *store) recordThumbnailFailure(ctx context.Context, record imageRecord, nextAttempt time.Time) (bool, error) {
	nextAttempts := record.ThumbnailAttempts + 1
	thumbnailSize := int64(0)
	nextAttemptMilli := nextAttempt.UnixMilli()
	permanent := nextAttempts >= thumbnailMaxAttempts
	if permanent {
		thumbnailSize = thumbnailFailedSize
		nextAttemptMilli = 0
	}
	result, err := s.db.ExecContext(ctx, `UPDATE images
		SET thumbnail_attempts = ?, thumbnail_next_attempt_ms = ?, thumbnail_size = ?
		WHERE owner_id = ? AND id = ? AND thumbnail_size = 0`,
		nextAttempts, nextAttemptMilli, thumbnailSize, record.OwnerID, record.ID,
	)
	if err != nil {
		return false, err
	}
	updated, err := result.RowsAffected()
	return permanent && updated == 1, err
}

func (s *store) listImages(ctx context.Context, ownerID string, sinceMilli int64, limit int) ([]imageRecord, error) {
	query := `SELECT owner_id, id, extension, media_type, width, height, byte_size,
		thumbnail_size, animated, created_at_ms FROM images WHERE owner_id = ?`
	args := make([]any, 0, 3)
	args = append(args, ownerID)
	if sinceMilli > 0 {
		query += ` AND created_at_ms >= ?`
		args = append(args, sinceMilli)
	}
	query += ` ORDER BY created_at_ms DESC, id DESC LIMIT ?`
	args = append(args, limit)

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var records []imageRecord
	for rows.Next() {
		var record imageRecord
		if err := rows.Scan(
			&record.OwnerID, &record.ID, &record.Extension, &record.MediaType, &record.Width,
			&record.Height, &record.ByteSize, &record.ThumbnailSize,
			&record.Animated, &record.CreatedAtMilli,
		); err != nil {
			return nil, err
		}
		records = append(records, record)
	}
	return records, rows.Err()
}

func (s *store) listAllImagesForOwner(ctx context.Context, ownerID string) ([]imageRecord, error) {
	return s.listImages(ctx, ownerID, 0, int(^uint(0)>>1))
}

func (s *store) account(ctx context.Context, ownerID string) (accountRecord, bool, error) {
	var record accountRecord
	err := s.db.QueryRowContext(ctx, `SELECT users.id, users.is_admin, users.quota_bytes,
		COALESCE(SUM(images.byte_size + CASE WHEN images.thumbnail_size > 0 THEN images.thumbnail_size ELSE 0 END), 0),
		COUNT(images.id), users.retention_days, users.enabled, users.created_at_ms
		FROM users LEFT JOIN images ON images.owner_id = users.id
		WHERE users.id = ?
		GROUP BY users.id`, ownerID).Scan(
		&record.SpaceID, &record.IsAdmin, &record.QuotaBytes, &record.UsedBytes,
		&record.ImageCount, &record.RetentionDays, &record.Enabled, &record.CreatedAtMilli,
	)
	if err == sql.ErrNoRows {
		return accountRecord{}, false, nil
	}
	return record, err == nil, err
}

func (s *store) listAccounts(ctx context.Context) ([]accountRecord, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT users.id, users.is_admin, users.quota_bytes,
		COALESCE(SUM(images.byte_size + CASE WHEN images.thumbnail_size > 0 THEN images.thumbnail_size ELSE 0 END), 0),
		COUNT(images.id), users.retention_days, users.enabled, users.created_at_ms
		FROM users LEFT JOIN images ON images.owner_id = users.id
		GROUP BY users.id
		ORDER BY users.created_at_ms, users.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var records []accountRecord
	for rows.Next() {
		var record accountRecord
		if err := rows.Scan(
			&record.SpaceID, &record.IsAdmin, &record.QuotaBytes, &record.UsedBytes,
			&record.ImageCount, &record.RetentionDays, &record.Enabled, &record.CreatedAtMilli,
		); err != nil {
			return nil, err
		}
		records = append(records, record)
	}
	return records, rows.Err()
}

func (s *store) createAccount(ctx context.Context, ownerID string, fingerprint []byte, quotaBytes int64, retentionDays int) (bool, error) {
	result, err := s.db.ExecContext(ctx, `INSERT INTO users (
		id, token_fingerprint, enabled, created_at_ms, is_admin, quota_bytes, retention_days, managed_by_config
	) SELECT ?, ?, 1, ?, 0, ?, ?, 0
	WHERE NOT EXISTS (SELECT 1 FROM users WHERE id = ?)`,
		ownerID, fingerprint, time.Now().UTC().UnixMilli(), quotaBytes, retentionDays, ownerID,
	)
	if err != nil {
		return false, err
	}
	created, err := result.RowsAffected()
	return created == 1, err
}

func (s *store) credentialByFingerprint(ctx context.Context, fingerprint []byte) (credential, bool, error) {
	var result credential
	var stored []byte
	err := s.db.QueryRowContext(ctx, `SELECT id, token_fingerprint FROM users
		WHERE token_fingerprint = ? AND enabled = 1`, fingerprint).Scan(&result.ownerID, &stored)
	if err == sql.ErrNoRows {
		return credential{}, false, nil
	}
	if err != nil {
		return credential{}, false, err
	}
	if len(stored) != len(result.fingerprint) {
		return credential{}, false, fmt.Errorf("invalid stored token fingerprint for %q", result.ownerID)
	}
	copy(result.fingerprint[:], stored)
	return result, true, nil
}

func (s *store) getImages(ctx context.Context, ownerID string, ids []string) ([]imageRecord, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	placeholders := strings.TrimRight(strings.Repeat("?,", len(ids)), ",")
	args := make([]any, 0, len(ids)+1)
	args = append(args, ownerID)
	for _, id := range ids {
		args = append(args, id)
	}
	rows, err := s.db.QueryContext(ctx, `SELECT owner_id, id, extension, media_type, width, height,
		byte_size, thumbnail_size, animated, created_at_ms FROM images
		WHERE owner_id = ? AND id IN (`+placeholders+`)`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var records []imageRecord
	for rows.Next() {
		var record imageRecord
		if err := rows.Scan(
			&record.OwnerID, &record.ID, &record.Extension, &record.MediaType, &record.Width,
			&record.Height, &record.ByteSize, &record.ThumbnailSize,
			&record.Animated, &record.CreatedAtMilli,
		); err != nil {
			return nil, err
		}
		records = append(records, record)
	}
	return records, rows.Err()
}

func (s *store) getImageByID(ctx context.Context, id string) (imageRecord, bool, error) {
	var record imageRecord
	err := s.db.QueryRowContext(ctx, `SELECT owner_id, id, extension, media_type, width, height,
		byte_size, thumbnail_size, animated, created_at_ms FROM images WHERE id = ?`, id).Scan(
		&record.OwnerID, &record.ID, &record.Extension, &record.MediaType, &record.Width,
		&record.Height, &record.ByteSize, &record.ThumbnailSize, &record.Animated, &record.CreatedAtMilli,
	)
	if err == sql.ErrNoRows {
		return imageRecord{}, false, nil
	}
	return record, err == nil, err
}

func (s *store) deleteImages(ctx context.Context, ownerID string, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	placeholders := strings.TrimRight(strings.Repeat("?,", len(ids)), ",")
	args := make([]any, 0, len(ids)+1)
	args = append(args, ownerID)
	for _, id := range ids {
		args = append(args, id)
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM images WHERE owner_id = ? AND id IN (`+placeholders+`)`, args...)
	return err
}

func (s *store) deleteImage(ctx context.Context, ownerID, id string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM images WHERE owner_id = ? AND id = ?`, ownerID, id)
	return err
}

func (s *store) listExpiredImages(ctx context.Context, now time.Time, limit int) ([]imageRecord, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT images.owner_id, images.id, images.extension, images.media_type,
		images.width, images.height, images.byte_size, images.thumbnail_size, images.animated, images.created_at_ms
		FROM images JOIN users ON users.id = images.owner_id
		WHERE users.retention_days > 0
			AND images.created_at_ms <= ? - (users.retention_days * ?)
		ORDER BY images.created_at_ms, images.id LIMIT ?`, now.UnixMilli(), int64((24*time.Hour)/time.Millisecond), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var records []imageRecord
	for rows.Next() {
		var record imageRecord
		if err := rows.Scan(
			&record.OwnerID, &record.ID, &record.Extension, &record.MediaType, &record.Width,
			&record.Height, &record.ByteSize, &record.ThumbnailSize,
			&record.Animated, &record.CreatedAtMilli,
		); err != nil {
			return nil, err
		}
		records = append(records, record)
	}
	return records, rows.Err()
}

func (s *store) createSession(ctx context.Context, ownerID string, hash, fingerprint []byte, expires time.Time, replacedHash []byte) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sessions(token_hash, owner_id, token_fingerprint, expires_at_ms) VALUES (?, ?, ?, ?)`,
		hash, ownerID, fingerprint, expires.UnixMilli(),
	); err != nil {
		return err
	}
	if len(replacedHash) > 0 {
		if _, err := tx.ExecContext(ctx, `DELETE FROM sessions WHERE token_hash = ?`, replacedHash); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *store) sessionOwner(ctx context.Context, hash []byte, now time.Time) (string, bool, error) {
	value, valid, err := s.sessionPrincipal(ctx, hash, now)
	return value.OwnerID, valid, err
}

func (s *store) sessionPrincipal(ctx context.Context, hash []byte, now time.Time) (principal, bool, error) {
	var value principal
	err := s.db.QueryRowContext(ctx, `SELECT sessions.owner_id, users.is_admin
		FROM sessions JOIN users ON users.id = sessions.owner_id
		WHERE sessions.token_hash = ?
			AND sessions.expires_at_ms > ?
			AND users.enabled = 1
			AND users.token_fingerprint = sessions.token_fingerprint`,
		hash, now.UnixMilli(),
	).Scan(&value.OwnerID, &value.IsAdmin)
	if err == sql.ErrNoRows {
		return principal{}, false, nil
	}
	return value, err == nil, err
}

func (s *store) deleteSession(ctx context.Context, hash []byte) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE token_hash = ?`, hash)
	return err
}

func (s *store) deleteExpiredSessions(ctx context.Context, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE expires_at_ms <= ?`, now.UnixMilli())
	return err
}

func (s *store) adoptLegacyOwner(ctx context.Context, ownerID string) (bool, error) {
	var userCount int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users`).Scan(&userCount); err != nil {
		return false, err
	}
	if userCount != 0 {
		return false, nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `UPDATE images SET owner_id = ? WHERE owner_id = 'default'`, ownerID); err != nil {
		return false, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE sessions SET owner_id = ? WHERE owner_id = 'default'`, ownerID); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return true, nil
}

func (s *store) hasLegacyImages(ctx context.Context) (bool, error) {
	var userCount int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users`).Scan(&userCount); err != nil {
		return false, err
	}
	if userCount != 0 {
		return false, nil
	}
	var imageCount int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM images WHERE owner_id = 'default'`).Scan(&imageCount); err != nil {
		return false, err
	}
	return imageCount > 0, nil
}

func (s *store) syncUsers(ctx context.Context, credentials []credential, adminSpaceID string, quotaBytes int64, retentionDays int) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `UPDATE users SET enabled = 0, token_fingerprint = NULL, is_admin = 0
		WHERE managed_by_config = 1`); err != nil {
		return err
	}
	now := time.Now().UTC().UnixMilli()
	for _, configured := range credentials {
		isAdmin := configured.ownerID == adminSpaceID
		if _, err := tx.ExecContext(ctx, `INSERT INTO users(
			id, token_fingerprint, enabled, created_at_ms, is_admin, quota_bytes, retention_days, managed_by_config
		)
			VALUES (?, ?, 1, ?, ?, ?, ?, 1)
			ON CONFLICT(id) DO UPDATE SET
				token_fingerprint = excluded.token_fingerprint,
				enabled = 1,
				is_admin = excluded.is_admin,
				quota_bytes = excluded.quota_bytes,
				retention_days = excluded.retention_days,
				managed_by_config = 1`,
			configured.ownerID, configured.fingerprint[:], now, isAdmin, quotaBytes, retentionDays,
		); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM sessions
		WHERE NOT EXISTS (
			SELECT 1 FROM users
			WHERE users.id = sessions.owner_id
				AND users.enabled = 1
				AND users.token_fingerprint = sessions.token_fingerprint
		)`); err != nil {
		return err
	}
	return tx.Commit()
}
