// Package cmd provides CLI commands for the gt tool.
package cmd

import (
	"errors"
	"fmt"
	"sync"

	"github.com/steveyegge/gastown/internal/deps"
)

var (
	cachedVersionCheckResult error
	versionCheckOnce         sync.Once
	checkBeads               = deps.CheckBeads
)

type beadsVersionError struct {
	status deps.BeadsStatus
	err    error
}

func (e *beadsVersionError) Error() string {
	return e.err.Error()
}

func (e *beadsVersionError) Unwrap() error {
	return e.err
}

func isUnsupportedNewBeadsVersion(err error) bool {
	var versionErr *beadsVersionError
	return errors.As(err, &versionErr) && versionErr.status == deps.BeadsTooNew
}

// CheckBeadsVersion verifies that the installed beads version meets the minimum requirement.
// Returns nil if the version is sufficient, or an error with details if not.
// The check is performed only once per process execution.
func CheckBeadsVersion() error {
	versionCheckOnce.Do(func() {
		status, version := checkBeads()
		switch status {
		case deps.BeadsOK:
			cachedVersionCheckResult = nil
		case deps.BeadsUnknown:
			cachedVersionCheckResult = &beadsVersionError{
				status: status,
				err:    fmt.Errorf("beads (bd) version could not be determined\n\nTry reinstalling: go install %s", deps.BeadsInstallPath),
			}
		case deps.BeadsNotFound:
			cachedVersionCheckResult = &beadsVersionError{
				status: status,
				err:    fmt.Errorf("beads (bd) not found in PATH\n\nInstall with: go install %s", deps.BeadsInstallPath),
			}
		case deps.BeadsTooOld:
			cachedVersionCheckResult = &beadsVersionError{
				status: status,
				err: fmt.Errorf("beads %s is required, but %s is installed\n\nUpgrade: go install %s",
					deps.MinBeadsVersion, version, deps.BeadsInstallPath),
			}
		case deps.BeadsTooNew:
			cachedVersionCheckResult = &beadsVersionError{
				status: status,
				err: fmt.Errorf("beads %s is installed, but this Gas Town release supports at most %s\n\nDowngrade: go install %s",
					version, deps.MaxBeadsVersion, deps.BeadsInstallPath),
			}
		}
	})
	return cachedVersionCheckResult
}
