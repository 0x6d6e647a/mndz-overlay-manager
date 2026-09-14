{-# LANGUAGE OverloadedStrings #-}

-- | Interactive @github-token@ command: prefix gate, fail-closed probe, wrap, splice.
module Update.GitHubToken
  ( GitHubTokenOps (..),
    productionGitHubTokenOps,
    runGitHubTokenCommand,
    probeFineGrainedPat,
    requireFineGrainedPat,
  )
where

import Config.Loader (spliceGitHubToken, writeConfigAtomic)
import Config.TokenEnvelope (wrapToken)
import Config.Types (OverlayConfig (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as T
import Network.HTTP.Client
  ( RequestBody (RequestBodyLBS),
    method,
    newManager,
    parseRequest,
    requestBody,
    requestHeaders,
    responseStatus,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (RequestHeaders, statusCode)
import System.Directory (makeAbsolute)
import Update.Auth
  ( SecretPrompt (..),
    isFineGrainedPat,
    productionSecretPrompt,
  )
import Update.GitHub (gitRemoteOriginUrl, parseGitHubOrigin)
import Update.Http (HttpLbs, httpLbsEither)

-- | Injectable seams for the setter (HTTP, prompts, wrap, origin).
data GitHubTokenOps = GitHubTokenOps
  { gtoHttp :: HttpLbs,
    gtoPrompt :: SecretPrompt,
    gtoWrap :: Text -> Text -> IO (Either Text Text),
    gtoOriginUrl :: FilePath -> IO (Either Text Text)
  }

productionGitHubTokenOps :: IO () -> IO () -> IO GitHubTokenOps
productionGitHubTokenOps pause resume = do
  mgr <- newManager tlsManagerSettings
  pure
    GitHubTokenOps
      { gtoHttp = httpLbsEither mgr,
        gtoPrompt = productionSecretPrompt pause resume,
        gtoWrap = wrapToken,
        gtoOriginUrl = gitRemoteOriginUrl
      }

-- | Refuse any token that does not start with @github_pat_@.
requireFineGrainedPat :: Text -> Either Text Text
requireFineGrainedPat raw =
  let tok = T.strip raw
   in if isFineGrainedPat tok
        then Right tok
        else
          Left
            "a fine-grained PAT (github_pat_) is required; classic tokens \
            \(ghp_ and others) are refused"

-- | Probe the assets origin: GET repo, empty POST /releases 422.
probeFineGrainedPat ::
  HttpLbs ->
  Text ->
  Text ->
  Text ->
  IO (Either Text ())
probeFineGrainedPat http owner repo token = do
  let headers = probeHeaders token
  got <- getAssetsRepo http headers owner repo
  case got of
    Left err -> pure (Left err)
    Right () -> postEmptyRelease http headers owner repo

probeHeaders :: Text -> RequestHeaders
probeHeaders token =
  [ ("User-Agent", "mndz-overlay-manager"),
    ("Accept", "application/vnd.github+json"),
    ("Authorization", encodeUtf8 ("Bearer " <> token))
  ]

getAssetsRepo :: HttpLbs -> RequestHeaders -> Text -> Text -> IO (Either Text ())
getAssetsRepo http headers owner repo = do
  let url =
        "https://api.github.com/repos/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
  req0 <- parseRequest url
  let req = req0 {method = "GET", requestHeaders = headers}
  eres <- http req
  pure $ case eres of
    Left err -> Left err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in if code >= 200 && code < 300
            then Right ()
            else
              Left
                ( "GET /repos/"
                    <> owner
                    <> "/"
                    <> repo
                    <> " failed with HTTP "
                    <> T.pack (show code)
                )

postEmptyRelease ::
  HttpLbs ->
  RequestHeaders ->
  Text ->
  Text ->
  IO (Either Text ())
postEmptyRelease http headers owner repo = do
  let url =
        "https://api.github.com/repos/"
          <> T.unpack owner
          <> "/"
          <> T.unpack repo
          <> "/releases"
  req0 <- parseRequest url
  let req =
        req0
          { method = "POST",
            requestHeaders =
              headers <> [("Content-Type", "application/json")],
            requestBody = RequestBodyLBS "{}"
          }
  eres <- http req
  pure $ case eres of
    Left err -> Left err
    Right resp ->
      let code = statusCode (responseStatus resp)
       in case code of
            422 -> Right ()
            403 ->
              Left
                "POST /releases returned HTTP 403; Contents: write is required \
                \on the assets repository"
            _ ->
              Left
                ( "empty POST /releases expected HTTP 422, got HTTP "
                    <> T.pack (show code)
                )

-- | Run the setter. @force@ replaces an existing key. Returns the config path.
runGitHubTokenCommand ::
  GitHubTokenOps ->
  FilePath ->
  OverlayConfig ->
  Bool ->
  IO (Either Text FilePath)
runGitHubTokenCommand ops configPath cfg force = do
  case (githubToken cfg, force) of
    (Just _, False) ->
      pure $
        Left
          "github-token is already set; pass --force to replace it after probe"
    _ -> case assetsPath cfg of
      Nothing ->
        pure (Left "github-token requires assets-path in the overlay-manager config")
      Just assets -> do
        mTty <- spControllingTty (gtoPrompt ops)
        case mTty of
          Nothing ->
            pure $
              Left
                "github-token requires a controlling terminal; the token and \
                \wrap password are not accepted as flags"
          Just tty -> do
            eUrl <- gtoOriginUrl ops assets
            case eUrl of
              Left err -> pure (Left err)
              Right url ->
                case parseGitHubOrigin url of
                  Left err -> pure (Left err)
                  Right (owner, repo) ->
                    collectAndWrite ops tty configPath owner repo

collectAndWrite ::
  GitHubTokenOps ->
  FilePath ->
  FilePath ->
  Text ->
  Text ->
  IO (Either Text FilePath)
collectAndWrite ops tty configPath owner repo = do
  let prompt = gtoPrompt ops
  eTok <-
    spReadSecret prompt tty "GitHub fine-grained PAT (github_pat_): "
  case eTok of
    Left err -> pure (Left err)
    Right raw ->
      case requireFineGrainedPat raw of
        Left err -> pure (Left err)
        Right tok -> do
          probed <- probeFineGrainedPat (gtoHttp ops) owner repo tok
          case probed of
            Left err -> pure (Left err)
            Right () -> do
              ePw1 <-
                spReadSecret prompt tty "Wrap password: "
              case ePw1 of
                Left err -> pure (Left err)
                Right pw1 -> do
                  ePw2 <-
                    spReadSecret prompt tty "Confirm wrap password: "
                  case ePw2 of
                    Left err -> pure (Left err)
                    Right pw2 ->
                      if pw1 /= pw2
                        then pure (Left "wrap passwords do not match")
                        else wrapAndSplice ops configPath pw1 tok

wrapAndSplice ::
  GitHubTokenOps ->
  FilePath ->
  Text ->
  Text ->
  IO (Either Text FilePath)
wrapAndSplice ops configPath password token = do
  eEnv <- gtoWrap ops password token
  case eEnv of
    Left err -> pure (Left err)
    Right envelope -> do
      current <- T.readFile configPath
      case spliceGitHubToken current envelope of
        Left err -> pure (Left err)
        Right spliced -> do
          absPath <- makeAbsolute configPath
          written <- writeConfigAtomic absPath spliced
          pure $ case written of
            Left err -> Left err
            Right () -> Right absPath
