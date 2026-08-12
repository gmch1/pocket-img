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
	for _, statement := range []string{
		`CREATE INDEX IF NOT EXISTS images_owner_created_idx ON images(owner_id, created_at_ms DESC, id DESC)`,
		`CREATE INDEX IF NOT EXISTS sessions_expiry_idx ON sessions(expires_at_ms)`,
		`CREATE INDEX IF NOT EXISTS sessions_owner_idx ON sessions(owner_id)`,
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

func (s *store) listPendingThumbnails(ctx context.Context) ([]imageRecord, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT owner_id, id, extension, media_type, width, height,
		byte_size, thumbnail_size, animated, created_at_ms FROM images
		WHERE thumbnail_size = 0 ORDER BY created_at_ms DESC, id DESC`)
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

func (s *store) setThumbnailSize(ctx context.Context, ownerID, id string, size int64) (bool, error) {
	result, err := s.db.ExecContext(ctx, `UPDATE images SET thumbnail_size = ?
		WHERE owner_id = ? AND id = ? AND thumbnail_size = 0`, size, ownerID, id)
	if err != nil {
		return false, err
	}
	updated, err := result.RowsAffected()
	return updated == 1, err
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
	var ownerID string
	err := s.db.QueryRowContext(ctx, `SELECT sessions.owner_id
		FROM sessions JOIN users ON users.id = sessions.owner_id
		WHERE sessions.token_hash = ?
			AND sessions.expires_at_ms > ?
			AND users.enabled = 1
			AND users.token_fingerprint = sessions.token_fingerprint`,
		hash, now.UnixMilli(),
	).Scan(&ownerID)
	if err == sql.ErrNoRows {
		return "", false, nil
	}
	return ownerID, err == nil, err
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

func (s *store) syncUsers(ctx context.Context, credentials []credential) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `UPDATE users SET enabled = 0, token_fingerprint = NULL`); err != nil {
		return err
	}
	now := time.Now().UTC().UnixMilli()
	for _, configured := range credentials {
		if _, err := tx.ExecContext(ctx, `INSERT INTO users(id, token_fingerprint, enabled, created_at_ms)
			VALUES (?, ?, 1, ?)
			ON CONFLICT(id) DO UPDATE SET token_fingerprint = excluded.token_fingerprint, enabled = 1`,
			configured.ownerID, configured.fingerprint[:], now,
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
