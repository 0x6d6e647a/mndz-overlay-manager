{-# LANGUAGE OverloadedStrings #-}

-- | Unit coverage for smoke check combinators and the check interpreter
-- with a fake exec (no container).
module Test.SmokeCheck (tests) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Overlay.Version (parseEbuildVersion)
import Smoke.Check
  ( Check (..),
    CheckCtx (..),
    CheckIO (..),
    CheckResult (..),
    Command (..),
    Outcome (..),
    allOf,
    argv,
    check,
    exitsWith,
    failedCheckNames,
    filesExist,
    firstLineIs,
    helpCheck,
    networked,
    outputContains,
    outputContainsPv,
    outputLacks,
    runChecks,
    shell,
    step,
    timeoutAfter,
    versionCheck,
  )
import Test.Assert (assertEq, assertTrue)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)
import Update.Types (mkPackageKey)

tests :: TestTree
tests =
  testGroup
    "SmokeCheck"
    [ testGroup
        "combinators"
        [ testCase "exitsWith" $ do
            assertEq "pass" (Right ()) (exitsWith 0 ctx134 (out 0 ""))
            assertLeft' "fail" (exitsWith 0 ctx134 (out 1 "boom"))
            assertEq "accepted non-zero" (Right ()) (exitsWith 255 ctx134 (out 255 "")),
          testCase "outputContains reads stdout and stderr" $ do
            assertEq "stdout" (Right ()) (outputContains "libc" ctx134 (out 0 "libc 0.1"))
            assertEq "stderr" (Right ()) (outputContains "libc" ctx134 (Outcome 0 "" "libc"))
            assertLeft' "missing" (outputContains "libc" ctx134 (out 0 "serde")),
          testCase "outputContainsPv uses the PV under test" $ do
            assertEq "1.3.4" (Right ()) (outputContainsPv ctx134 (out 0 "bd version 1.3.4"))
            assertLeft' "other version" (outputContainsPv ctx104 (out 0 "bd version 1.3.4"))
            assertEq "1.0.4" (Right ()) (outputContainsPv ctx104 (out 0 "bd version 1.0.4")),
          testCase "outputLacks" $ do
            assertEq "pass" (Right ()) (outputLacks "/var/tmp/portage" ctx134 (out 0 "ready"))
            assertLeft' "fail" (outputLacks "/var/tmp/portage" ctx134 (out 0 "missing /var/tmp/portage/x")),
          testCase "firstLineIs substitutes the PV" $ do
            assertEq "pass" (Right ()) (firstLineIs "kiro-cli {PV}" ctx134 (out 0 "kiro-cli 1.3.4\nmore"))
            assertLeft' "fail" (firstLineIs "kiro-cli {PV}" ctx134 (out 0 "warning\nkiro-cli 1.3.4")),
          testCase "allOf reports the first failure" $ do
            assertEq "pass" (Right ()) (allOf [exitsWith 0, outputContains "a"] ctx134 (out 0 "a"))
            case allOf [exitsWith 0, outputContains "a"] ctx134 (out 3 "b") of
              Left why -> assertTrue "exit first" ("exited 3" `T.isInfixOf` why)
              Right () -> assertFailure "expected failure",
          testCase "versionCheck" $ do
            let c = versionCheck "bd" ["--version"]
            assertEq "name" "version" (ckName c)
            r <- runOne c (\_ -> out 0 "bd version 1.3.4")
            assertEq "pass" Nothing (crFailure r)
            r' <- runOne c (\_ -> out 0 "bd version 1.0.4")
            assertTrue "fail" (isJust (crFailure r')),
          testCase "helpCheck" $ do
            let c = helpCheck "bd"
            assertEq "name" "help" (ckName c)
            (_, cmds) <- runCapture (c :| []) (\_ -> out 0 "")
            assertEq "argv" [["bd", "--help"]] (map cmdArgv cmds),
          testCase "filesExist" $ do
            let c = filesExist ["/usr/share/craft-fonts/fonts"]
            (rs, cmds) <- runCapture (c :| []) (\_ -> out 1 "missing /usr/share/craft-fonts/fonts")
            assertEq "fails" ["files"] (failedCheckNames rs)
            assertTrue "path passed" (any (elem "/usr/share/craft-fonts/fonts" . cmdArgv) cmds)
        ],
      testGroup
        "interpreter"
        [ testCase "second check runs after the first fails" testSecondRuns,
          testCase "setup command failure stops the check" testSetupFails,
          testCase "program waiting for input is stopped at 60 seconds" testTimeout,
          testCase "a check's own timeout is passed through" testOwnTimeout,
          testCase "network is attached for a network check only" testNetwork,
          testCase "one of three checks fails" testOneOfThree,
          testCase "commands get stdin and env" testStdinEnv
        ]
    ]

ctxFor :: Text -> CheckCtx
ctxFor pv = CheckCtx {ccKey = mkPackageKey "dev-util" "beads", ccVersion = parseEbuildVersion pv, ccPv = pv}

ctx134, ctx104 :: CheckCtx
ctx134 = ctxFor "1.3.4"
ctx104 = ctxFor "1.0.4"

out :: Int -> Text -> Outcome
out code o = Outcome code o ""

assertLeft' :: String -> Either Text () -> IO ()
assertLeft' label = \case
  Left _ -> pure ()
  Right () -> assertFailure (label <> ": expected Left")

data Rec = Rec
  { recCmds :: IORef [(Int, Command)],
    recNet :: IORef [Text]
  }

newRec :: IO Rec
newRec = Rec <$> newIORef [] <*> newIORef []

fakeIO :: Rec -> (Command -> Outcome) -> CheckIO
fakeIO r respond =
  CheckIO
    { cioExec = \limit cmd -> do
        modifyIORef' (recCmds r) (++ [(limit, cmd)])
        modifyIORef' (recNet r) (++ ["exec " <> T.unwords (cmdArgv cmd)])
        pure (respond cmd),
      cioNetwork = \up -> do
        modifyIORef' (recNet r) (++ [if up then "attach" else "detach"])
        pure (Right ())
    }

runCapture :: NonEmpty Check -> (Command -> Outcome) -> IO ([CheckResult], [Command])
runCapture checks respond = do
  r <- newRec
  rs <- runChecks (fakeIO r respond) ctx134 checks
  cmds <- map snd <$> readIORef (recCmds r)
  pure (rs, cmds)

runOne :: Check -> (Command -> Outcome) -> IO CheckResult
runOne c respond = do
  (rs, _) <- runCapture (c :| []) respond
  case rs of
    [x] -> pure x
    other -> assertFailure ("expected one result, got " <> show other)

testSecondRuns :: IO ()
testSecondRuns = do
  let checks = versionCheck "bd" ["--version"] :| [helpCheck "bd"]
  (rs, cmds) <- runCapture checks $ \cmd ->
    if "--version" `elem` cmdArgv cmd then out 1 "" else out 0 ""
  assertEq "help ran" 2 (length cmds)
  assertEq "only version failed" ["version"] (failedCheckNames rs)

testSetupFails :: IO ()
testSetupFails = do
  let c =
        check
          "functional"
          (step (const (shell "cargo new --lib demo")) (exitsWith 0))
          [step (const (argv ["cargo", "outdated"])) (exitsWith 0)]
  (rs, cmds) <- runCapture (c :| []) (\_ -> out 101 "error: could not create")
  assertEq "later command skipped" 1 (length cmds)
  assertEq "failed" ["functional"] (failedCheckNames rs)

testTimeout :: IO ()
testTimeout = do
  let checks = check "start" (step (const (argv ["tool"])) (exitsWith 0)) [] :| [helpCheck "tool"]
  r <- newRec
  rs <- runChecks (fakeIO r (\cmd -> if cmdArgv cmd == ["tool"] then out 124 "" else out 0 "")) ctx134 checks
  case rs of
    [startR, helpR] -> do
      case crFailure startR of
        Just why -> assertTrue "states the limit" ("stopped after 60 seconds" `T.isInfixOf` why)
        Nothing -> assertFailure "expected the start check to fail"
      assertEq "next check ran and passed" Nothing (crFailure helpR)
    other -> assertFailure ("expected two results, got " <> show other)
  limits <- map fst <$> readIORef (recCmds r)
  assertEq "default limit" [60, 60] limits

testOwnTimeout :: IO ()
testOwnTimeout = do
  r <- newRec
  _ <- runChecks (fakeIO r (\_ -> out 0 "")) ctx134 (timeoutAfter 300 (helpCheck "tool") :| [])
  limits <- map fst <$> readIORef (recCmds r)
  assertEq "own limit" [300] limits

testNetwork :: IO ()
testNetwork = do
  r <- newRec
  let checks = networked (helpCheck "online") :| [helpCheck "offline"]
  _ <- runChecks (fakeIO r (\_ -> out 0 "")) ctx134 checks
  events <- readIORef (recNet r)
  assertEq "bracketed" ["attach", "exec online --help", "detach", "exec offline --help"] events

testOneOfThree :: IO ()
testOneOfThree = do
  let checks = helpCheck "a" :| [helpCheck "b" {- same name on purpose is avoided below -}, versionCheck "c" []]
      renamed = case checks of
        x :| [y, z] -> x {ckName = "help-a"} :| [y {ckName = "help-b"}, z]
        other -> other
  (rs, _) <- runCapture renamed $ \cmd -> if cmdArgv cmd == ["b", "--help"] then out 1 "" else out 0 "c 1.3.4"
  assertEq "names the failed check" ["help-b"] (failedCheckNames rs)

testStdinEnv :: IO ()
testStdinEnv = do
  let c =
        check
          "start"
          ( step
              (const ((argv ["autolith"]) {cmdStdin = "", cmdEnv = [("HOME", "/home/smoke")]}))
              (allOf [exitsWith 0, outputLacks "/var/tmp/portage"])
          )
          []
  (rs, cmds) <- runCapture (c :| []) (\_ -> out 0 "missing helper /var/tmp/portage/autolith/bin")
  assertEq "fails on portage path" ["start"] (failedCheckNames rs)
  assertEq "env passed" [[("HOME", "/home/smoke")]] (map cmdEnv cmds)
