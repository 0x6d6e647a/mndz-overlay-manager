{-# LANGUAGE OverloadedStrings #-}

module Test.Properties (tests) where

import Data.Text qualified as T
import Overlay.Discovery (parseEbuildFileName)
import Overlay.Version
  ( EbuildVersion (..),
    comparePV,
    parseEbuildVersion,
    renderPV,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.QuickCheck
  ( Arbitrary (..),
    Gen,
    Property,
    choose,
    elements,
    forAll,
    listOf1,
    property,
    testProperty,
    (.&&.),
    (===),
  )
import Update.Engines (parseEnginesMinimum)

tests :: TestTree
tests =
  testGroup
    "Properties"
    [ testGroup
        "comparePV"
        [ testProperty "reflexive for numeric" propComparePVReflexive,
          testProperty "antisymmetric when both Just" propComparePVAntisymmetric
        ],
      testGroup
        "version round-trip"
        [ testProperty "parseEbuildVersion . renderPV round-trip (numeric)" propParseRenderRoundTrip
        ],
      testGroup
        "parseEbuildFileName"
        [ testProperty "well-formed pkg-ver.ebuild" propParseEbuildFileName
        ],
      testGroup
        "parseEnginesMinimum"
        [ testCase "accept bare" $ parseEnginesMinimum "1.2.3" @?= Just "1.2.3",
          testCase "accept v prefix" $ parseEnginesMinimum "v1.2.3" @?= Just "1.2.3",
          testCase "accept >=" $ parseEnginesMinimum ">=1.2.3" @?= Just "1.2.3",
          testCase "reject caret" $ parseEnginesMinimum "^1.2.3" @?= Nothing,
          testCase "reject or" $ parseEnginesMinimum "1.0.0 || 2.0.0" @?= Nothing,
          testCase "reject star" $ parseEnginesMinimum "1.*" @?= Nothing,
          testCase "reject empty" $ parseEnginesMinimum "" @?= Nothing,
          testProperty "complex ranges rejected" propEnginesComplexRejected
        ]
    ]

newtype NumericVersion = NumericVersion EbuildVersion
  deriving (Eq, Show)

instance Arbitrary NumericVersion where
  arbitrary = do
    comps <- listOf1 (choose (0, 99 :: Word))
    NumericVersion . Numeric comps <$> arbitrary

propComparePVReflexive :: NumericVersion -> Bool
propComparePVReflexive (NumericVersion v) =
  comparePV v v == Just EQ

propComparePVAntisymmetric :: NumericVersion -> NumericVersion -> Property
propComparePVAntisymmetric (NumericVersion a) (NumericVersion b) =
  case (comparePV a b, comparePV b a) of
    (Just x, Just y) -> property (x == flipOrd y)
    _ -> property False
  where
    flipOrd LT = GT
    flipOrd EQ = EQ
    flipOrd GT = LT

propParseRenderRoundTrip :: NumericVersion -> Property
propParseRenderRoundTrip (NumericVersion v) =
  parseEbuildVersion (renderPV v) === v

pkgNameGen :: Gen String
pkgNameGen = do
  let firstChars = ['a' .. 'z']
  let restChars = ['a' .. 'z'] ++ ['0' .. '9'] ++ ['+', '_', '-']
  n <- choose (1, 8 :: Int)
  rest <- mapM (\_ -> elements restChars) [1 .. n]
  c0 <- elements firstChars
  pure (c0 : rest)

verCompGen :: Gen String
verCompGen = do
  comps <- listOf1 (choose (0, 99 :: Int))
  pure $ go (map show comps)
  where
    go [] = ""
    go [x] = x
    go (x : xs) = x ++ "." ++ go xs

propParseEbuildFileName :: Property
propParseEbuildFileName =
  forAll pkgNameGen $ \pn ->
    forAll verCompGen $ \ver ->
      let fname = pn ++ "-" ++ ver ++ ".ebuild"
       in case parseEbuildFileName fname of
            Just (pn', ver') -> (pn' === pn) .&&. (ver' === ver)
            Nothing -> property False

propEnginesComplexRejected :: Property
propEnginesComplexRejected =
  forAll (elements ["^1.2.3", "~1.2.3", "1.0 || 2.0", "1.*", ">=1.0 <2.0", "1.0.0,2.0.0"]) $ \s ->
    parseEnginesMinimum (T.pack s) === Nothing
