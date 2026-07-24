{-# LANGUAGE LambdaCase #-}

module Test.Assert
  ( assertEq,
    assertTrue,
    assertLeft,
    assertRight,
  )
where

import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure)

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq = assertEqual

assertTrue :: String -> Bool -> IO ()
assertTrue = assertBool

assertLeft :: (Show a) => String -> Either e a -> IO e
assertLeft label = \case
  Left e -> pure e
  Right a -> assertFailure $ label <> ": expected Left, got Right " <> show a

assertRight :: (Show e) => String -> Either e a -> IO a
assertRight label = \case
  Right a -> pure a
  Left e -> assertFailure $ label <> ": expected Right, got Left " <> show e
