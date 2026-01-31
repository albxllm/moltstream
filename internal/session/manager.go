package session

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type Manager struct {
	directory    string
	maxSizeBytes int64
	autoArchive  bool
}

func NewManager(directory string, maxSizeBytes int64, autoArchive bool) (*Manager, error) {
	// Expand ~
	if directory[:2] == "~/" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		directory = filepath.Join(home, directory[2:])
	}

	if err := os.MkdirAll(directory, 0755); err != nil {
		return nil, fmt.Errorf("create session directory: %w", err)
	}

	archiveDir := filepath.Join(directory, "archive")
	if err := os.MkdirAll(archiveDir, 0755); err != nil {
		return nil, fmt.Errorf("create archive directory: %w", err)
	}

	return &Manager{
		directory:    directory,
		maxSizeBytes: maxSizeBytes,
		autoArchive:  autoArchive,
	}, nil
}

func (m *Manager) SessionPath() string {
	return filepath.Join(m.directory, "session.md")
}

func (m *Manager) ArchiveDir() string {
	return filepath.Join(m.directory, "archive")
}

func (m *Manager) EnsureSession() (string, error) {
	path := m.SessionPath()

	if _, err := os.Stat(path); os.IsNotExist(err) {
		return path, m.createSession(path)
	}

	// Check size and auto-archive if needed
	if m.autoArchive {
		info, err := os.Stat(path)
		if err == nil && info.Size() > m.maxSizeBytes {
			if err := m.Archive(); err != nil {
				return "", fmt.Errorf("auto-archive: %w", err)
			}
			return path, m.createSession(path)
		}
	}

	return path, nil
}

func (m *Manager) createSession(path string) error {
	now := time.Now()
	header := fmt.Sprintf(`<!-- moltstream session -->
<!-- id: %s -->
<!-- created: %s -->

`, generateID(), now.Format(time.RFC3339))

	return os.WriteFile(path, []byte(header), 0644)
}

func (m *Manager) Archive() error {
	src := m.SessionPath()

	if _, err := os.Stat(src); os.IsNotExist(err) {
		return nil // Nothing to archive
	}

	timestamp := time.Now().Format("2006-01-02-150405")
	dst := filepath.Join(m.ArchiveDir(), fmt.Sprintf("session-%s.md", timestamp))

	return os.Rename(src, dst)
}

func (m *Manager) GetSize() (int64, error) {
	info, err := os.Stat(m.SessionPath())
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	return info.Size(), nil
}

func generateID() string {
	return fmt.Sprintf("%d", time.Now().UnixNano())
}
