{-# LANGUAGE OverloadedStrings #-}

module Overlay.Types
  ( Ebuild (..),
    ebuildAtom,
  )
where

import Data.Text (Text)

data Ebuild = Ebuild
  { ebuildCategory :: Text,
    ebuildPackage :: Text,
    ebuildVersion :: Text,
    ebuildPath :: FilePath
  }
  deriving (Eq, Show)

ebuildAtom :: Ebuild -> Text
ebuildAtom e =
  ebuildCategory e <> "/" <> ebuildPackage e <> "-" <> ebuildVersion e
