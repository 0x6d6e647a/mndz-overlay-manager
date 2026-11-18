{-# LANGUAGE OverloadedStrings #-}

module Portage.MakeOpts (configureMakeOpts) where

import Data.Text (Text)
import Data.Text qualified as T

-- | Render a shell command using a trusted jobs expression. Append the
-- effective assignment without rewriting the image's shell configuration
-- or changing its file permissions.
configureMakeOpts :: Text -> Text
configureMakeOpts jobs =
  T.intercalate
    "; "
    [ "(jobs=" <> jobs,
      "conf=/etc/portage/make.conf",
      "case \"$jobs\" in ''|0*|*[!0-9]*) echo \"$conf: invalid jobs count: $jobs\" >&2; exit 1;; esac",
      "assignment=$(printf 'MAKEOPTS=\"-j%s -l%u\"' \"$jobs\" \"$((jobs + 1))\")",
      "umask 022",
      "if [ -e \"$conf\" ]; then last=$(tail -n 1 \"$conf\") || exit 1; else last=; fi",
      "[ \"$last\" = \"$assignment\" ] || printf '\\n%s\\n' \"$assignment\" >> \"$conf\")"
    ]
